import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

enum AudioRecordError: LocalizedError {
    case deviceMissing(String)
    case deviceRefused(String, OSStatus)
    case fileFailed(String)
    case noPermission

    var errorDescription: String? {
        switch self {
        case .deviceMissing(let name):
            "Das Audiogerät «\(name)» ist nicht da. Läuft Pro Tools bzw. die Audio Bridge?"
        case .deviceRefused(let name, let status):
            "Das Audiogerät «\(name)» lässt sich nicht öffnen (Fehler \(status))."
        case .fileFailed(let detail):
            "Die Tondatei konnte nicht angelegt werden. \(detail)"
        case .noPermission:
            "Session Cutter darf keinen Ton aufnehmen. Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon."
        }
    }
}

/// Records the two sides — original and final mix — each from its own stereo
/// pair, on one device or two.
///
/// Each device is opened directly through a HAL input unit rather than
/// through AVAudioEngine: the engine ties input and output to one device, and
/// a Pro Tools bridge as input next to the speakers as output is exactly the
/// case it gets wrong. One unit per device; both sides from the same device
/// are sample locked, from two devices they are matched by host time.
///
/// The units run while the record page is open, so every channel's meter
/// answers before anything is recorded; `startWriting` and `stopWriting` only
/// open and close the files.
final class AudioRecorder: @unchecked Sendable {
    enum Side: Int, CaseIterable {
        case original
        case mix
    }

    private var inputs: [HALInput] = []
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "SessionCutter.audioWrite", qos: .userInitiated)
    private var drainTimer: DispatchSourceTimer?
    private var files: [Side: AVAudioFile] = [:]
    private var scratch: [Side: AVAudioPCMBuffer] = [:]

    var isArmed: Bool { !inputs.isEmpty }

    /// Microphone access, which macOS demands for any audio input — a virtual
    /// bridge included. Without it the device delivers silence, not an error.
    static var permission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// The loudest sample per channel of every open device since the last
    /// call, keyed by device UID.
    func takeChannelPeaks() -> [String: [Float]] {
        var result: [String: [Float]] = [:]
        for input in inputs { result[input.uid] = input.takePeaks() }
        return result
    }

    // MARK: - Devices

    func arm(original: AudioRoute, mix: AudioRoute) throws {
        disarm()
        guard Self.permission == .authorized else { throw AudioRecordError.noPermission }

        var byDevice: [String: [(Side, Int)]] = [:]
        byDevice[original.deviceUID, default: []].append((.original, original.firstChannel))
        byDevice[mix.deviceUID, default: []].append((.mix, mix.firstChannel))

        for (uid, sides) in byDevice {
            guard let device = AudioDevices.device(uid: uid) else {
                disarm()
                throw AudioRecordError.deviceMissing(uid)
            }
            let input = HALInput(uid: uid, name: device.name, sides: sides)
            do {
                try input.open(device: device)
            } catch {
                input.close()
                disarm()
                throw error
            }
            inputs.append(input)
            Diagnostics.log(String(
                format: "Toneingang «%@»: %ld Kanäle, %.0f Hz, Puffer %u Frames",
                device.name, input.channels, input.sampleRate, input.bufferFrames
            ))
        }

        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    func disarm() {
        drainTimer?.cancel()
        drainTimer = nil
        writeQueue.sync {}
        for input in inputs { input.close() }
        inputs = []
        lock.lock()
        files = [:]
        scratch = [:]
        lock.unlock()
    }

    // MARK: - Files

    /// Opens one stereo WAV per side at the device's own rate. From the next
    /// block of each device on, its sound goes into them.
    func startWriting(originalURL: URL, mixURL: URL) throws {
        var opened: [Side: AVAudioFile] = [:]
        var buffers: [Side: AVAudioPCMBuffer] = [:]
        for input in inputs {
            for (side, _) in input.sides {
                let url = side == .original ? originalURL : mixURL
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: input.sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                do {
                    let file = try AVAudioFile(
                        forWriting: url,
                        settings: settings,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    )
                    opened[side] = file
                    buffers[side] = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: HALInput.drainChunk)
                } catch {
                    throw AudioRecordError.fileFailed(error.localizedDescription)
                }
            }
        }
        writeQueue.sync {
            self.lock.lock()
            self.files = opened
            self.scratch = buffers
            self.lock.unlock()
        }
        for input in inputs { input.beginWriting() }
    }

    /// Closes the files once every queued block is written, and reports where
    /// each one started, in host seconds.
    func stopWriting() -> (original: Double?, mix: Double?) {
        var starts: [Side: UInt64] = [:]
        for input in inputs {
            let first = input.endWriting()
            if let first { for (side, _) in input.sides { starts[side] = first } }
        }
        // Everything the devices delivered is flushed before the files close.
        writeQueue.sync {
            self.drain()
            self.lock.lock()
            self.files = [:]
            self.scratch = [:]
            self.lock.unlock()
        }
        return (
            starts[.original].map { AVAudioTime.seconds(forHostTime: $0) },
            starts[.mix].map { AVAudioTime.seconds(forHostTime: $0) }
        )
    }

    /// Runs on the write queue only: moves what the I/O threads collected
    /// into the files.
    private func drain() {
        lock.lock()
        let files = self.files
        let scratch = self.scratch
        lock.unlock()
        guard !files.isEmpty else { return }

        for input in inputs {
            while true {
                let frames = input.pull()
                if frames == 0 { break }
                for (side, slot) in input.sides.enumerated().map({ ($0.element.0, $0.offset) }) {
                    guard let file = files[side], let buffer = scratch[side],
                          let data = buffer.floatChannelData else { continue }
                    buffer.frameLength = AVAudioFrameCount(frames)
                    data[0].update(from: input.pulled[slot * 2], count: frames)
                    data[1].update(from: input.pulled[slot * 2 + 1], count: frames)
                    do { try file.write(from: buffer) } catch {
                        Diagnostics.log("Tonaufnahme schreibt nicht: \(Diagnostics.describe(error))")
                    }
                }
            }
        }
    }
}

// MARK: - One device

/// A HAL output unit with only its input side switched on.
///
/// The I/O thread does nothing but render, copy the wanted channels into a
/// preallocated ring and note the peaks: no allocation, no file access, no
/// waiting on anything but a lock held for a few microseconds. The write
/// queue drains the ring.
private final class HALInput {
    static let drainChunk: AVAudioFrameCount = 16_384
    private static let ringFrames = 1 << 19          // ~11 s at 48 kHz

    let uid: String
    let name: String
    let sides: [(AudioRecorder.Side, Int)]
    private(set) var channels = 0
    private(set) var sampleRate: Double = 48_000
    private(set) var bufferFrames: UInt32 = 0

    private var unit: AudioUnit?
    private var buffers: UnsafeMutableAudioBufferListPointer?
    private let capacity = 16_384

    /// Hardware channel behind each ring channel: left, right of every side.
    private var tracked: [Int] = []
    private var ring: [UnsafeMutablePointer<Float>] = []
    /// What `pull` hands to the write queue; one pointer per ring channel.
    private(set) var pulled: [UnsafeMutablePointer<Float>] = []
    private var writeIndex = 0
    private var readIndex = 0

    private var lock = os_unfair_lock()
    private var peaks: [Float] = []
    private var writing = false
    private var firstHost: UInt64?

    // Diagnostics, written on the I/O thread, read at the end of a take.
    private var callbacks = 0
    private var maxFrames = 0
    private var skipped = 0
    private var renderErrors = 0
    private var overruns = 0
    private var jumps = 0
    private var expectedSample: Float64 = -1
    private var lastHostNs: UInt64 = 0
    private var maxGapMs: Double = 0

    init(uid: String, name: String, sides: [(AudioRecorder.Side, Int)]) {
        self.uid = uid
        self.name = name
        self.sides = sides
    }

    deinit { close() }

    func open(device: AudioInputDevice) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioRecordError.deviceRefused(device.name, -1)
        }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), device)
        guard let unit = created else { throw AudioRecordError.deviceRefused(device.name, -1) }
        self.unit = unit

        var on: UInt32 = 1
        var off: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flagSize), device)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flagSize), device)

        var deviceID = device.id
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        ), device)

        var hardware = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &formatSize), device)
        channels = max(Int(hardware.mChannelsPerFrame), 1)
        sampleRate = hardware.mSampleRate > 0 ? hardware.mSampleRate : 48_000

        var frameSize = UInt32(MemoryLayout<UInt32>.size)
        var bufferSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(device.id, &address, 0, nil, &frameSize, &bufferSize) == noErr {
            bufferFrames = bufferSize
        }

        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, formatSize), device)

        let list = AudioBufferList.allocate(maximumBuffers: channels)
        for index in 0..<channels {
            list[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(capacity * 4),
                mData: UnsafeMutableRawPointer.allocate(byteCount: capacity * 4, alignment: 16)
            )
        }
        buffers = list

        for (_, first) in sides {
            tracked.append(min(first, channels - 1))
            tracked.append(min(first + 1, channels - 1))
        }
        for _ in tracked {
            let channel = UnsafeMutablePointer<Float>.allocate(capacity: Self.ringFrames)
            channel.initialize(repeating: 0, count: Self.ringFrames)
            ring.append(channel)
            let out = UnsafeMutablePointer<Float>.allocate(capacity: Int(Self.drainChunk))
            out.initialize(repeating: 0, count: Int(Self.drainChunk))
            pulled.append(out)
        }
        peaks = Array(repeating: 0, count: channels)

        var callback = AURenderCallbackStruct(
            inputProc: halInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ), device)

        try check(AudioUnitInitialize(unit), device)
        try check(AudioOutputUnitStart(unit), device)
    }

    func close() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        if let buffers {
            for buffer in buffers { buffer.mData?.deallocate() }
            free(buffers.unsafeMutablePointer)
        }
        buffers = nil
        for pointer in ring { pointer.deallocate() }
        for pointer in pulled { pointer.deallocate() }
        ring = []
        pulled = []
    }

    private func check(_ status: OSStatus, _ device: AudioInputDevice) throws {
        guard status == noErr else { throw AudioRecordError.deviceRefused(device.name, status) }
    }

    // MARK: Control (not the I/O thread)

    func takePeaks() -> [Float] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let result = peaks
        for index in peaks.indices { peaks[index] = 0 }
        return result
    }

    func beginWriting() {
        os_unfair_lock_lock(&lock)
        readIndex = writeIndex
        firstHost = nil
        callbacks = 0; maxFrames = 0; skipped = 0; renderErrors = 0
        overruns = 0; jumps = 0; maxGapMs = 0
        writing = true
        os_unfair_lock_unlock(&lock)
    }

    /// Stops collecting; returns the host time of the first collected sample.
    func endWriting() -> UInt64? {
        os_unfair_lock_lock(&lock)
        writing = false
        let first = firstHost
        let stats = (callbacks, maxFrames, skipped, renderErrors, overruns, jumps, maxGapMs)
        os_unfair_lock_unlock(&lock)
        Diagnostics.log(String(
            format: "Toneingang «%@»: %ld Blöcke, größter %ld Frames, längste Lücke %.0f ms, Zeit-Sprünge %ld, Render-Fehler %ld, übersprungen %ld, Ring-Überläufe %ld",
            name, stats.0, stats.1, stats.6, stats.5, stats.3, stats.2, stats.4
        ))
        return first
    }

    /// Write queue: copies up to a chunk out of the ring. Returns the frames.
    func pull() -> Int {
        os_unfair_lock_lock(&lock)
        let available = writeIndex - readIndex
        let count = min(available, Int(Self.drainChunk))
        for slot in ring.indices {
            for frame in 0..<count {
                pulled[slot][frame] = ring[slot][(readIndex + frame) & (Self.ringFrames - 1)]
            }
        }
        readIndex += count
        os_unfair_lock_unlock(&lock)
        return count
    }

    // MARK: I/O thread

    fileprivate func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit, let buffers else { return noErr }
        let count = Int(frames)
        guard count <= capacity else {
            os_unfair_lock_lock(&lock); skipped += 1; os_unfair_lock_unlock(&lock)
            return noErr
        }
        for index in 0..<buffers.count { buffers[index].mDataByteSize = frames * 4 }
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffers.unsafeMutablePointer)
        guard status == noErr else {
            os_unfair_lock_lock(&lock); renderErrors += 1; os_unfair_lock_unlock(&lock)
            return status
        }

        os_unfair_lock_lock(&lock)
        callbacks += 1
        maxFrames = max(maxFrames, count)
        for index in 0..<min(buffers.count, peaks.count) {
            guard let raw = buffers[index].mData else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)
            var peak = peaks[index]
            for frame in 0..<count { peak = max(peak, abs(samples[frame])) }
            peaks[index] = peak
        }

        let now = timeStamp.pointee.mHostTime
        if writing {
            if expectedSample >= 0, abs(timeStamp.pointee.mSampleTime - expectedSample) > 0.5 { jumps += 1 }
            if lastHostNs != 0 {
                let gap = AVAudioTime.seconds(forHostTime: now - lastHostNs) * 1000
                maxGapMs = max(maxGapMs, gap)
            }
            if firstHost == nil { firstHost = now }
            if writeIndex - readIndex + count > Self.ringFrames {
                overruns += 1
            } else {
                for (slot, hardware) in tracked.enumerated() {
                    guard hardware < buffers.count, let raw = buffers[hardware].mData else { continue }
                    let samples = raw.assumingMemoryBound(to: Float.self)
                    let target = ring[slot]
                    for frame in 0..<count {
                        target[(writeIndex + frame) & (Self.ringFrames - 1)] = samples[frame]
                    }
                }
                writeIndex += count
            }
        }
        expectedSample = timeStamp.pointee.mSampleTime + Float64(count)
        lastHostNs = now
        os_unfair_lock_unlock(&lock)
        return noErr
    }
}

private let halInputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    let input = Unmanaged<HALInput>.fromOpaque(refCon).takeUnretainedValue()
    return input.render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
}
