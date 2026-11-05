import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFailure: LocalizedError {
    case sessionUnavailable
    case failed(String)
    case imageFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable: "Der Export konnte nicht gestartet werden."
        case .failed(let detail): "Der Export ist fehlgeschlagen. \(detail)"
        case .imageFailed(let name): "Das Bild «\(name)» konnte nicht geschrieben werden."
        }
    }
}

/// Writes posts and stills. Never touches a source file: everything lands in
/// the session's Export folder as a new file.
enum Exporter {
    /// The post as an MP4, H.264, the platforms' common denominator.
    static func exportVideo(
        _ post: BuiltPost,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let export = AVAssetExportSession(
            asset: post.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else { throw ExportFailure.sessionUnavailable }
        export.videoComposition = post.videoComposition
        export.audioMix = post.audioMix
        export.outputURL = url
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(export.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        ticker.cancel()

        guard export.status == .completed else {
            throw ExportFailure.failed(export.error?.localizedDescription ?? "")
        }
        progress(1)
    }

    /// One frame of the composed post.
    static func postFrame(_ post: BuiltPost, atRecordingTime seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: post.composition)
        generator.videoComposition = post.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: max(seconds - post.origin, 0), preferredTimescale: 600)
        return try await generator.image(at: time).image
    }

    /// One frame of the film at its own full resolution.
    static func filmFrame(url: URL, at seconds: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        return try await generator.image(at: time).image
    }

    /// Never enlarges.
    static func resized(_ image: CGImage, longEdge: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > longEdge else { return image }
        let factor = Double(longEdge) / Double(longest)
        let width = max(Int((Double(image.width) * factor).rounded()), 1)
        let height = max(Int((Double(image.height) * factor).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func write(_ image: CGImage, to url: URL, jpeg: Bool) throws {
        let type = jpeg ? UTType.jpeg : UTType.png
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil
        ) else { throw ExportFailure.imageFailed(url.lastPathComponent) }
        let options: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportFailure.imageFailed(url.lastPathComponent)
        }
    }
}
