import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

enum ExportError: LocalizedError {
    case readerSetupFailed(String)
    case writerSetupFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .readerSetupFailed(let detail): "Der Clip konnte nicht zum Lesen vorbereitet werden. \(detail)"
        case .writerSetupFailed(let detail): "Die Ausgabedatei konnte nicht angelegt werden. \(detail)"
        case .readFailed(let detail): "Das Lesen des Clips ist fehlgeschlagen. \(detail)"
        case .writeFailed(let detail): "Das Schreiben des Clips ist fehlgeschlagen. \(detail)"
        case .cancelled: "Export abgebrochen."
        }
    }
}

/// Everything one output file needs. Labels are pre-rendered so the exporter
/// never touches AppKit.
struct ExportRequest {
    var clip: Clip
    var format: SocialFormat
    var settings: ExportSettings
    var outputURL: URL
    var overlays: ClipOverlays
}

/// Renders one clip into one social format using an AVAssetReader →
/// AVAssetWriter pass, so bitrate, colour tags and the stereo downmix are all
/// under explicit control.
enum ClipExporter {
    static func export(
        project: ABProject,
        request: ExportRequest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let clipComposition = try await CompositionBuilder.buildClip(project: project, clip: request.clip)
        let composition = clipComposition.composition

        let totalSeconds = CMTimeGetSeconds(clipComposition.duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else { throw CompositionError.emptyClip }

        let plan = RenderPlan(
            targetSize: request.format.size,
            fitMode: request.settings.fitMode,
            panX: request.clip.panX,
            panY: request.clip.panY,
            switchTimes: clipComposition.switchTimes,
            beforeLook: request.settings.beforeLook,
            afterLook: request.settings.afterLook,
            frameTreatment: request.settings.frameTreatment,
            frameBackdrop: request.settings.frameBackdrop,
            insetScale: request.settings.insetScale,
            labelPosition: request.settings.labelPosition,
            safeArea: request.settings.safeArea(for: request.format),
            beforeOverlay: request.overlays.before,
            afterOverlay: request.overlays.after,
            sourceNaturalSize: clipComposition.videoNaturalSize,
            sourcePreferredTransform: clipComposition.videoPreferredTransform
        )

        let videoComposition = AVMutableVideoComposition(asset: composition) { filterRequest in
            let output = FrameRenderer.render(
                filterRequest.sourceImage,
                at: filterRequest.compositionTime,
                plan: plan
            )
            filterRequest.finish(with: output, context: nil)
        }
        videoComposition.renderSize = request.format.size
        videoComposition.frameDuration = clipComposition.frameDuration

        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)

        let frameRate = CMTimeGetSeconds(clipComposition.frameDuration) > 0
            ? 1.0 / CMTimeGetSeconds(clipComposition.frameDuration)
            : 25

        // Some multichannel stems refuse the forced stereo downmix; fall back
        // to the native layout rather than failing the whole export. Reading
        // is started here so a rejected layout surfaces before any output file
        // is created.
        var started = try? startedReader(
            composition: composition,
            videoComposition: videoComposition,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            audioMix: clipComposition.audioMix,
            forceStereo: true
        )
        if started == nil {
            started = try startedReader(
                composition: composition,
                videoComposition: videoComposition,
                videoTracks: videoTracks,
                audioTracks: audioTracks,
                audioMix: clipComposition.audioMix,
                forceStereo: false
            )
        }
        guard let started else {
            throw ExportError.readerSetupFailed("Der Clip konnte nicht dekodiert werden.")
        }

        let reader = started.reader
        let videoOutput = started.video
        let audioOutput = started.audio

        try? FileManager.default.removeItem(at: request.outputURL)
        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: request.outputURL, fileType: .mp4)
        } catch {
            throw ExportError.writerSetupFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings(
                format: request.format,
                codec: request.settings.codec,
                frameRate: frameRate,
                bitrateOverrideMbps: request.settings.videoBitrateMbps
            )
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            reader.cancelReading()
            throw ExportError.writerSetupFailed("Der Video-Encoder hat die Einstellungen abgelehnt.")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings())
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            reader.cancelReading()
            throw ExportError.writerSetupFailed(writer.error?.localizedDescription ?? "Unbekannter Schreibfehler.")
        }
        writer.startSession(atSourceTime: .zero)

        let videoQueue = DispatchQueue(label: "com.mauriziozulli.abcutter.export.video")
        let audioQueue = DispatchQueue(label: "com.mauriziozulli.abcutter.export.audio")

        // Cancelling the reader is what unblocks the pumps: copyNextSampleBuffer
        // then returns nil and both inputs finish on their own.
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump(input: videoInput, output: videoOutput, queue: videoQueue) { sampleBuffer in
                        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                        if seconds.isFinite {
                            progress(min(max(seconds / totalSeconds, 0), 1))
                        }
                    }
                }
                if let audioInput, let audioOutput {
                    group.addTask {
                        await pump(input: audioInput, output: audioOutput, queue: audioQueue, onSample: nil)
                    }
                }
            }
        } onCancel: {
            reader.cancelReading()
        }

        if Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: request.outputURL)
            throw ExportError.cancelled
        }

        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: request.outputURL)
            throw ExportError.readFailed(reader.error?.localizedDescription ?? "Unbekannter Lesefehler.")
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: request.outputURL)
            throw ExportError.writeFailed(writer.error?.localizedDescription ?? "Unbekannter Schreibfehler.")
        }

        reader.cancelReading()
        progress(1)
    }

    // MARK: - Reader

    private static func startedReader(
        composition: AVMutableComposition,
        videoComposition: AVVideoComposition,
        videoTracks: [AVAssetTrack],
        audioTracks: [AVAssetTrack],
        audioMix: AVAudioMix?,
        forceStereo: Bool
    ) throws -> (reader: AVAssetReader, video: AVAssetReaderVideoCompositionOutput, audio: AVAssetReaderAudioMixOutput?) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            throw ExportError.readerSetupFailed(error.localizedDescription)
        }

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportError.readerSetupFailed("Der Video-Compositor konnte nicht angehängt werden.")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: decodedAudioSettings(forceStereo: forceStereo)
            )
            output.audioMix = audioMix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw ExportError.readerSetupFailed("Der Audio-Mixer konnte nicht angehängt werden.")
            }
            reader.add(output)
            audioOutput = output
        }

        guard reader.startReading() else {
            throw ExportError.readerSetupFailed(reader.error?.localizedDescription ?? "Unbekannter Lesefehler.")
        }

        return (reader, videoOutput, audioOutput)
    }

    /// Intermediate LPCM the reader hands to the AAC encoder. Forcing two
    /// channels is what folds a 5.1 stem down to a social-ready stereo bed.
    private static func decodedAudioSettings(forceStereo: Bool) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000
        ]
        if forceStereo {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            settings[AVNumberOfChannelsKey] = 2
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return settings
    }

    // MARK: - Writer settings

    private static func videoSettings(
        format: SocialFormat,
        codec: VideoCodecChoice,
        frameRate: Double,
        bitrateOverrideMbps: Double?
    ) -> [String: Any] {
        let size = format.size
        let bitrate: Int
        if let bitrateOverrideMbps, bitrateOverrideMbps > 0 {
            bitrate = Int(bitrateOverrideMbps * 1_000_000)
        } else {
            bitrate = estimatedBitrate(size: size, frameRate: frameRate, codec: codec)
        }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: true
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        return [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
    }

    /// Roughly 0.15 bits per pixel per frame for H.264, less for HEVC, held
    /// inside a range that social platforms accept without re-crushing.
    private static func estimatedBitrate(size: CGSize, frameRate: Double, codec: VideoCodecChoice) -> Int {
        let rate = frameRate.isFinite && frameRate > 0 ? min(frameRate, 60) : 25
        let pixels = Double(size.width * size.height)
        let bitsPerPixel = codec == .hevc ? 0.09 : 0.15
        let raw = pixels * rate * bitsPerPixel
        return Int(min(max(raw, 4_000_000), 24_000_000))
    }

    private static func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000
        ]
    }

    // MARK: - Sample pump

    /// Drains one reader output into one writer input, resuming exactly once.
    private static func pump(
        input: AVAssetWriterInput,
        output: AVAssetReaderOutput,
        queue: DispatchQueue,
        onSample: (@Sendable (CMSampleBuffer) -> Void)?
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = FinishFlag()
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if finished.isSet { return }

                    guard let sampleBuffer = output.copyNextSampleBuffer() else {
                        finished.set()
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }

                    onSample?(sampleBuffer)

                    if !input.append(sampleBuffer) {
                        finished.set()
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    /// The writer callback can fire on several queue iterations; this keeps the
    /// continuation single-resume without pulling in a full actor.
    private final class FinishFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }
}
