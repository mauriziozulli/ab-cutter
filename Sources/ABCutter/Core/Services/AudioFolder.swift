import AVFoundation
import CoreMedia
import Foundation

enum AudioFoldError: LocalizedError {
    case noAudioTrack
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "Diese Quelle enthält keine lesbare Tonspur."
        case .readFailed(let detail): "Der Ton konnte nicht gelesen werden. \(detail)"
        case .writeFailed(let detail): "Die Mono-Datei konnte nicht geschrieben werden. \(detail)"
        }
    }
}

/// Renders a mono companion for a source whose channels need folding.
///
/// An `AVAudioMix` can set a track's volume but cannot re-route its channels,
/// and an audio processing tap is not honoured on every rendering path — so a
/// tap would risk sounding right in the preview and wrong in the file. Writing
/// the fold out once removes the question: both the preview and the export
/// then read the same audio.
///
/// The result is genuinely one channel rather than a doubled stereo pair, so
/// AVFoundation centres it on playback and the file is half the size.
enum AudioFolder {
    static let cacheDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ABCutter/Kanalfaltung", isDirectory: true)

    /// Reads `assetURL`, folds its channels and writes a mono CAF.
    /// Returns the file it wrote.
    static func fold(
        assetURL: URL,
        mode: ChannelMode,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard mode.foldsToMono else { throw AudioFoldError.readFailed("Kein Faltmodus gewählt.") }

        let asset = AVURLAsset(url: assetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioFoldError.noAudioTrack
        }

        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        let basic = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = basic?.mSampleRate ?? 48_000
        let channels = max(Int(basic?.mChannelsPerFrame ?? 2), 1)
        let totalSeconds = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioFoldError.readFailed(error.localizedDescription)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioFoldError.readFailed("Die Tonspur konnte nicht dekodiert werden.")
        }
        reader.add(output)

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let destination = cacheDirectory.appendingPathComponent("\(UUID().uuidString).caf")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFoldError.writeFailed("Kein gültiges Mono-Format.")
        }

        // AVAudioFile has no close(): the header is only finalised when the
        // object is released. Held in an optional so it can be dropped
        // explicitly before anybody opens the result — otherwise the caller
        // can read a file whose frame count is still zero, which plays as
        // silence rather than as an error.
        var file: AVAudioFile?
        do {
            file = try AVAudioFile(
                forWriting: destination,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioFoldError.writeFailed(error.localizedDescription)
        }

        guard reader.startReading() else {
            throw AudioFoldError.readFailed(reader.error?.localizedDescription ?? "Unbekannter Lesefehler.")
        }

        var writtenFrames: Double = 0
        let expectedFrames = max(totalSeconds * sampleRate, 1)

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                try? FileManager.default.removeItem(at: destination)
                throw CancellationError()
            }

            // The retained-buffer form guarantees one contiguous run per
            // buffer, which a raw block-buffer pointer does not.
            var list = AudioBufferList()
            var blockBuffer: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample,
                bufferListSizeNeededOut: nil,
                bufferListOut: &list,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr else { continue }

            let buffers = UnsafeMutableAudioBufferListPointer(&list)
            guard let raw = buffers.first?.mData else { continue }
            let byteCount = Int(buffers[0].mDataByteSize)
            let floatCount = byteCount / MemoryLayout<Float>.size
            let frames = floatCount / channels
            guard frames > 0 else { continue }

            guard let monoBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            ), let destinationChannel = monoBuffer.floatChannelData?[0] else {
                reader.cancelReading()
                throw AudioFoldError.writeFailed("Kein Puffer verfügbar.")
            }
            monoBuffer.frameLength = AVAudioFrameCount(frames)

            let source = raw.bindMemory(to: Float.self, capacity: floatCount)
            switch mode {
            case .leftOnly:
                for frame in 0..<frames { destinationChannel[frame] = source[frame * channels] }
            case .rightOnly:
                let channel = min(1, channels - 1)
                for frame in 0..<frames { destinationChannel[frame] = source[frame * channels + channel] }
            case .sumToMono:
                let scale = 1 / Float(channels)
                for frame in 0..<frames {
                    var total: Float = 0
                    for channel in 0..<channels { total += source[frame * channels + channel] }
                    destinationChannel[frame] = total * scale
                }
            case .stereo:
                break
            }

            do {
                try file?.write(from: monoBuffer)
            } catch {
                reader.cancelReading()
                file = nil
                try? FileManager.default.removeItem(at: destination)
                throw AudioFoldError.writeFailed(error.localizedDescription)
            }

            writtenFrames += Double(frames)
            progress(min(writtenFrames / expectedFrames, 1))
        }

        let writtenLength = file?.length ?? 0
        // Release the writer so the container header is finalised on disk.
        file = nil

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: destination)
            throw AudioFoldError.readFailed(reader.error?.localizedDescription ?? "Unbekannter Lesefehler.")
        }

        // Read the result back before handing it on. A file that decodes to
        // nothing would otherwise play as silence, which is far harder to
        // diagnose than a plain failure.
        let check = AVURLAsset(url: destination, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let checkSeconds = CMTimeGetSeconds((try? await check.load(.duration)) ?? .zero)
        guard writtenLength > 0, checkSeconds.isFinite, checkSeconds > 0.05 else {
            try? FileManager.default.removeItem(at: destination)
            throw AudioFoldError.writeFailed("Die Mono-Datei blieb leer.")
        }

        progress(1)
        return destination
    }

    static func discard(_ url: URL?) {
        guard let url, url.path.hasPrefix(cacheDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
