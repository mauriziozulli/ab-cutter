import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum AudioRecordError: LocalizedError {
    case deviceMissing(String)
    case deviceRefused(String)
    case fileFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceMissing(let name):
            "Das Audiogerät «\(name)» ist nicht da. Läuft Pro Tools bzw. die Audio Bridge?"
        case .deviceRefused(let name):
            "Das Audiogerät «\(name)» lässt sich nicht öffnen. Mikrofon-Freigabe in den Systemeinstellungen prüfen."
        case .fileFailed(let detail):
            "Die Tondatei konnte nicht angelegt werden. \(detail)"
        }
    }
}

/// Records the two sides — original and final mix — each from its own stereo
/// pair, on one device or two.
///
/// One engine per device. When both sides come from the same device (Audio
/// Bridge with four channels), one tap feeds both files and they are sample
/// locked; from two devices they run on the same Pro Tools clock and the
/// start is matched by host time.
///
/// The engines run while the record page is open, so the meters answer before
/// anything is recorded; `startWriting` and `stopWriting` only open and close
/// the files.
final class AudioRecorder: @unchecked Sendable {
    enum Side: Int, CaseIterable {
        case original
        case mix
    }

    private struct Tap {
        var engine: AVAudioEngine
        var sides: [(side: Side, firstChannel: Int)]
    }

    private var taps: [Tap] = []
    private let lock = NSLock()
    private var files: [Side: AVAudioFile] = [:]
    private var firstHostTime: [Side: UInt64] = [:]
    private var peaks: [Side: Float] = [:]

    /// The loudest sample of each side since the last call, 0 … 1.
    func takePeaks() -> (original: Float, mix: Float) {
        lock.lock()
        defer { lock.unlock() }
        let result = (peaks[.original] ?? 0, peaks[.mix] ?? 0)
        peaks = [:]
        return result
    }

    // MARK: - Engines

    func arm(original: AudioRoute, mix: AudioRoute) throws {
        disarm()

        var byDevice: [String: [(Side, Int)]] = [:]
        byDevice[original.deviceUID, default: []].append((.original, original.firstChannel))
        byDevice[mix.deviceUID, default: []].append((.mix, mix.firstChannel))

        for (uid, sides) in byDevice {
            guard let device = AudioDevices.device(uid: uid) else {
                disarm()
                throw AudioRecordError.deviceMissing(uid)
            }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            guard let unit = input.audioUnit else {
                disarm()
                throw AudioRecordError.deviceRefused(device.name)
            }
            var deviceID = device.id
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                disarm()
                throw AudioRecordError.deviceRefused(device.name)
            }

            let format = input.outputFormat(forBus: 0)
            let mapped = sides.map { (side: $0.0, firstChannel: $0.1) }
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, when in
                self?.receive(buffer, at: when, sides: mapped)
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                disarm()
                throw AudioRecordError.deviceRefused(device.name)
            }
            taps.append(Tap(engine: engine, sides: mapped))
        }
    }

    func disarm() {
        for tap in taps {
            tap.engine.inputNode.removeTap(onBus: 0)
            tap.engine.stop()
        }
        taps = []
        lock.lock()
        files = [:]
        lock.unlock()
    }

    var isArmed: Bool { !taps.isEmpty }

    // MARK: - Files

    /// Opens one stereo WAV per side at the device's own rate. The next buffer
    /// of each device goes into them.
    func startWriting(originalURL: URL, mixURL: URL) throws {
        var opened: [Side: AVAudioFile] = [:]
        for tap in taps {
            let rate = tap.engine.inputNode.outputFormat(forBus: 0).sampleRate
            for entry in tap.sides {
                let url = entry.side == .original ? originalURL : mixURL
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                do {
                    opened[entry.side] = try AVAudioFile(
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

    /// Closes the files and reports where each one started, in host seconds.
    func stopWriting() -> (original: Double?, mix: Double?) {
        lock.lock()
        files = [:]
        let starts = firstHostTime
        lock.unlock()
        return (
            starts[.original].map { AVAudioTime.seconds(forHostTime: $0) },
            starts[.mix].map { AVAudioTime.seconds(forHostTime: $0) }
        )
    }

    // MARK: - The tap

    private func receive(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime, sides: [(side: Side, firstChannel: Int)]) {
        guard let source = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        for entry in sides {
            let left = min(entry.firstChannel, channels - 1)
            let right = min(entry.firstChannel + 1, channels - 1)

            var peak: Float = 0
            for index in 0..<frames {
                peak = max(peak, abs(source[left][index]), abs(source[right][index]))
            }
            peaks[entry.side] = max(peaks[entry.side] ?? 0, peak)

            guard let file = files[entry.side],
                  let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let target = out.floatChannelData else { continue }
            out.frameLength = AVAudioFrameCount(frames)
            target[0].update(from: source[left], count: frames)
            target[1].update(from: source[right], count: frames)

            if firstHostTime[entry.side] == nil, when.isHostTimeValid {
                firstHostTime[entry.side] = when.hostTime
            }
            try? file.write(from: out)
        }
    }
}
