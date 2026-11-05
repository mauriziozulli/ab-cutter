import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

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
    private let writeQueue = DispatchQueue(label: "SessionCutter.audioWrite")
    private var files: [Side: AVAudioFile] = [:]
    private var firstHostTime: [Side: UInt64] = [:]
    private var channelPeaks: [String: [Float]] = [:]

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
        lock.lock()
        defer { lock.unlock() }
        let result = channelPeaks
        for key in channelPeaks.keys {
            channelPeaks[key] = Array(repeating: 0, count: channelPeaks[key]?.count ?? 0)
        }
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
            let input = HALInput(uid: uid, sides: sides) { [weak self] block in
                self?.receive(block)
            }
            do {
                try input.open(device: device)
            } catch {
                input.close()
                disarm()
                throw error
            }
            inputs.append(input)
            lock.lock()
            channelPeaks[uid] = Array(repeating: 0, count: input.channels)
            lock.unlock()
        }
    }

    func disarm() {
        for input in inputs { input.close() }
        inputs = []
        lock.lock()
        files = [:]
        channelPeaks = [:]
        lock.unlock()
    }

    // MARK: - Files

    /// Opens one stereo WAV per side at the device's own rate. The next block
    /// of each device goes into them.
    func startWriting(originalURL: URL, mixURL: URL) throws {
        var opened: [Side: AVAudioFile] = [:]
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
                    opened[side] = try AVAudioFile(
                        forWriting: url,
                        settings: settings,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    )
                } catch {
                    throw AudioRecordError.fileFailed(error.localizedDescription)
                }
            }
        }
        lock.lock()
        firstHostTime = [:]
        files = opened
        lock.unlock()
    }

    /// Closes the files once every queued block is written, and reports where
    /// each one started, in host seconds.
    func stopWriting() -> (original: Double?, mix: Double?) {
        lock.lock()
        files = [:]
        let starts = firstHostTime
        lock.unlock()
        writeQueue.sync {}
        return (
            starts[.original].map { AVAudioTime.seconds(forHostTime: $0) },
            starts[.mix].map { AVAudioTime.seconds(forHostTime: $0) }
        )
    }

    // MARK: - Blocks

    fileprivate struct Block {
        var uid: String
        var hostTime: UInt64
        var peaks: [Float]
        var pairs: [(side: Side, left: [Float], right: [Float])]
    }

    private func receive(_ block: Block) {
        lock.lock()
        if var current = channelPeaks[block.uid], current.count == block.peaks.count {
            for index in current.indices { current[index] = max(current[index], block.peaks[index]) }
            channelPeaks[block.uid] = current
        } else {
            channelPeaks[block.uid] = block.peaks
        }
        var targets: [(AVAudioFile, [Float], [Float])] = []
        for pair in block.pairs {
            guard let file = files[pair.side] else { continue }
            if firstHostTime[pair.side] == nil { firstHostTime[pair.side] = block.hostTime }
            targets.append((file, pair.left, pair.right))
        }
        lock.unlock()

        guard !targets.isEmpty else { return }
        writeQueue.async {
            for (file, left, right) in targets {
                let frames = left.count
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(frames)
                ), let data = buffer.floatChannelData else { continue }
                buffer.frameLength = AVAudioFrameCount(frames)
                left.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: frames) }
                right.withUnsafeBufferPointer { data[1].update(from: $0.baseAddress!, count: frames) }
                try? file.write(from: buffer)
            }
        }
    }
}

// MARK: - One device

/// A HAL output unit with only its input side switched on.
private final class HALInput {
    let uid: String
    let sides: [(AudioRecorder.Side, Int)]
    private(set) var channels = 0
    private(set) var sampleRate: Double = 48_000

    private var unit: AudioUnit?
    private var buffers: UnsafeMutableAudioBufferListPointer?
    private let capacity = 8192
    private let deliver: (AudioRecorder.Block) -> Void

    init(uid: String, sides: [(AudioRecorder.Side, Int)], deliver: @escaping (AudioRecorder.Block) -> Void) {
        self.uid = uid
        self.sides = sides
        self.deliver = deliver
    }

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
    }

    private func check(_ status: OSStatus, _ device: AudioInputDevice) throws {
        guard status == noErr else { throw AudioRecordError.deviceRefused(device.name, status) }
    }

    /// Called on the device's I/O thread with fresh input.
    fileprivate func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit, let buffers, Int(frames) <= capacity else { return noErr }
        for index in 0..<buffers.count {
            buffers[index].mDataByteSize = frames * 4
        }
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffers.unsafeMutablePointer)
        guard status == noErr else { return status }

        let count = Int(frames)
        var channelData: [UnsafeMutablePointer<Float>] = []
        var peaks: [Float] = []
        for index in 0..<buffers.count {
            guard let raw = buffers[index].mData else { return noErr }
            let samples = raw.assumingMemoryBound(to: Float.self)
            channelData.append(samples)
            var peak: Float = 0
            for frame in 0..<count { peak = max(peak, abs(samples[frame])) }
            peaks.append(peak)
        }

        let pairs = sides.map { entry -> (side: AudioRecorder.Side, left: [Float], right: [Float]) in
            let (side, first) = entry
            let left = min(first, channelData.count - 1)
            let right = min(first + 1, channelData.count - 1)
            return (
                side,
                Array(UnsafeBufferPointer(start: channelData[left], count: count)),
                Array(UnsafeBufferPointer(start: channelData[right], count: count))
            )
        }
        deliver(AudioRecorder.Block(uid: uid, hostTime: timeStamp.pointee.mHostTime, peaks: peaks, pairs: pairs))
        return noErr
    }
}

private let halInputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    let input = Unmanaged<HALInput>.fromOpaque(refCon).takeUnretainedValue()
    return input.render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
}
