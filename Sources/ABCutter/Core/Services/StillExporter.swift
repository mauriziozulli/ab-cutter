import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum StillError: LocalizedError {
    case grabFailed
    case renderFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .grabFailed: "Dieses Bild konnte nicht aus dem Film gelesen werden."
        case .renderFailed: "Das Titelbild konnte nicht gerendert werden."
        case .writeFailed(let detail): "Das Bild konnte nicht geschrieben werden. \(detail)"
        }
    }
}

/// Grabs single frames at full resolution and lays them out as cover images.
///
/// This is the one place in the app that produces stills rather than video, so
/// it deliberately keeps its own small pipeline instead of borrowing the clip
/// exporter's — a cover image wants no grade, no A/B, and no encoder.
enum StillExporter {
    /// Pulls one frame at the film's native resolution, frame-accurately.
    static func grab(videoURL: URL, at seconds: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // No maximumSize: the whole point is the full resolution.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else {
            throw StillError.grabFailed
        }
        return image
    }

    /// Composes a cover image: the frame cropped to the format, softened and
    /// darkened so type can sit on it, with the headline over the top.
    ///
    /// Every size in the layout is a fraction of the canvas, so `scale` renders
    /// a smaller but otherwise identical card — which is what keeps the live
    /// preview cheap enough to follow a slider.
    @MainActor
    static func titleCard(
        frame: CGImage,
        format: SocialFormat,
        settings: StillSettings,
        fitMode: FitMode,
        panX: Double,
        panY: Double,
        safeArea: SafeArea = .none,
        scale: CGFloat = 1
    ) -> CGImage? {
        let canvas = CGSize(
            width: (format.size.width * scale).rounded(),
            height: (format.size.height * scale).rounded()
        )
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let target = CGRect(origin: .zero, size: canvas)
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])

        var background = place(CIImage(cgImage: frame), into: target, mode: fitMode, panX: panX, panY: panY)
        background = soften(background, target: target, strength: settings.blurStrength)
        background = dim(background, target: target, amount: settings.dimStrength)

        // The tint is read from the finished backdrop, not the raw frame, so it
        // contrasts with what the type will actually sit on.
        let band = textBand(targetSize: canvas, position: settings.textPosition, safeArea: safeArea)
        let tint = PaletteSampler.tint(
            of: background,
            sceneRect: target,
            bandRect: band,
            context: context
        )

        var composed = background
        if let overlay = OverlayRenderer.titleCard(
            targetSize: canvas,
            headline: settings.headline,
            subline: settings.subline,
            tint: tint,
            position: settings.textPosition,
            shadow: tint.needsShadow,
            safeArea: safeArea
        ) {
            composed = CIImage(cgImage: overlay).composited(over: composed)
        }

        return context.createCGImage(composed.cropped(to: target), from: target)
    }

    static func write(_ image: CGImage, to url: URL, as fileFormat: StillFileFormat) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let type = fileFormat == .png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw StillError.writeFailed("Kein Encoder für \(fileFormat.fileExtension).")
        }

        let options: [CFString: Any] = fileFormat == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.95]
            : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw StillError.writeFailed("Der Encoder hat das Bild abgelehnt.")
        }
    }

    // MARK: - Layout

    /// Where the type sits, used to measure the contrast it has to beat. The
    /// picture behind a cover still bleeds to the canvas edge; only the type
    /// keeps out of the story player's strips.
    static func textBand(
        targetSize: CGSize,
        position: StillTextPosition,
        safeArea: SafeArea = .none
    ) -> CGRect {
        let content = FrameRenderer.contentRect(targetSize: targetSize, safeArea: safeArea)
        let height = min((targetSize.height * 0.34).rounded(), content.height)
        switch position {
        case .top:
            return CGRect(x: 0, y: content.maxY - height, width: targetSize.width, height: height)
        case .centre:
            return CGRect(
                x: 0,
                y: ((targetSize.height - height) / 2).rounded(),
                width: targetSize.width,
                height: height
            )
        case .bottom:
            return CGRect(x: 0, y: content.minY, width: targetSize.width, height: height)
        }
    }

    private static func place(
        _ image: CIImage,
        into rect: CGRect,
        mode: FitMode,
        panX: Double,
        panY: Double
    ) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        var result = image.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        )
        let scale: CGFloat = mode == .fill
            ? max(rect.width / extent.width, rect.height / extent.height)
            : min(rect.width / extent.width, rect.height / extent.height)
        result = result.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let slackX = result.extent.width - rect.width
        let slackY = result.extent.height - rect.height
        let clampedX = min(max(panX, -1), 1)
        let clampedY = min(max(panY, -1), 1)
        let offsetX = slackX > 0 ? -(slackX / 2) * (1 + CGFloat(clampedX)) : -(slackX / 2)
        let offsetY = slackY > 0 ? -(slackY / 2) * (1 + CGFloat(clampedY)) : -(slackY / 2)

        return result
            .transformed(
                by: CGAffineTransform(
                    translationX: (rect.minX + offsetX).rounded(),
                    y: (rect.minY + offsetY).rounded()
                )
            )
            .composited(over: CIImage(color: .black).cropped(to: rect))
            .cropped(to: rect)
    }

    private static func soften(_ image: CIImage, target: CGRect, strength: Double) -> CIImage {
        let amount = min(max(strength, 0), 100)
        guard amount > 0.5, let blur = CIFilter(name: "CIGaussianBlur") else { return image }

        // Clamping first stops the blur pulling transparent edges inwards.
        blur.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(target.height * 0.0009 * amount, forKey: kCIInputRadiusKey)
        return (blur.outputImage ?? image).cropped(to: target)
    }

    private static func dim(_ image: CIImage, target: CGRect, amount: Double) -> CIImage {
        let alpha = min(max(amount, 0), 0.8)
        guard alpha > 0.01 else { return image }
        let scrim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: alpha)).cropped(to: target)
        return scrim.composited(over: image).cropped(to: target)
    }
}
