import AppKit
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
        guard let canvas = canvasSize(format: format, scale: scale) else { return nil }
        let target = CGRect(origin: .zero, size: canvas)
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])

        var background = place(
            CIImage(cgImage: frame), into: target, mode: fitMode, panX: panX, panY: panY
        )
        background = soften(background, target: target, strength: settings.blurStrength)
        background = dim(background, target: target, amount: settings.dimStrength)

        var composed = background
        if let overlay = CardRenderer.titleCard(
            targetSize: canvas,
            headline: settings.headline,
            subline: settings.subline,
            accent: settings.accent.colour,
            position: settings.textPosition,
            safeArea: safeArea
        ) {
            composed = CIImage(cgImage: overlay).composited(over: composed)
        }

        return context.createCGImage(composed.cropped(to: target), from: target)
    }

    /// The card that closes a post. The frame is optional: on ink the wordmark
    /// stands on its own, which is what a card whose job is the address wants.
    @MainActor
    static func endCard(
        frame: CGImage?,
        format: SocialFormat,
        settings: StillSettings,
        fitMode: FitMode,
        panX: Double,
        panY: Double,
        safeArea: SafeArea = .none,
        scale: CGFloat = 1
    ) -> CGImage? {
        guard let canvas = canvasSize(format: format, scale: scale) else { return nil }
        let target = CGRect(origin: .zero, size: canvas)
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])

        var background = CIImage(color: Brand.tinte.ciColor).cropped(to: target)
        if settings.endGround == .frame, let frame {
            var picture = place(
                CIImage(cgImage: frame), into: target, mode: fitMode, panX: panX, panY: panY
            )
            picture = soften(picture, target: target, strength: max(settings.blurStrength, 55))
            // Darker than a title card: here the wordmark has to win outright.
            picture = dim(picture, target: target, amount: max(settings.dimStrength, 0.45))
            background = picture
        }

        guard let overlay = CardRenderer.endCard(
            targetSize: canvas,
            wordmarkTop: settings.endWordmarkTop,
            wordmarkBar: settings.endWordmarkBar,
            address: settings.endAddress,
            note: settings.endNote,
            accent: settings.accent.colour,
            safeArea: safeArea
        ) else { return nil }

        let composed = CIImage(cgImage: overlay).composited(over: background)
        return context.createCGImage(composed.cropped(to: target), from: target)
    }

    private static func canvasSize(format: SocialFormat, scale: CGFloat) -> CGSize? {
        let canvas = CGSize(
            width: (format.size.width * scale).rounded(),
            height: (format.size.height * scale).rounded()
        )
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        return canvas
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

    // MARK: - Contact sheet

    /// A copy no wider than `maxWidth`, so a sheet of many 4K frames does not
    /// have to keep them all in memory.
    static func thumbnail(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let width = maxWidth
        let height = max(Int((Double(image.height) * Double(width) / Double(image.width)).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Every marker's frame on one sheet, in film order, with its number and
    /// timecode under it. Ink ground and bone type, like the end card — it is
    /// one more printed surface.
    @MainActor
    static func contactSheet(
        cells: [(image: CGImage, label: String)],
        columns: Int,
        title: String
    ) -> CGImage? {
        guard let first = cells.first else { return nil }
        let columns = min(max(columns, 1), max(cells.count, 1))
        let rows = (cells.count + columns - 1) / columns

        let cellWidth: CGFloat = 640
        let aspect = CGFloat(first.image.height) / CGFloat(max(first.image.width, 1))
        let cellHeight = (cellWidth * aspect).rounded()
        let caption: CGFloat = 44
        let gap: CGFloat = 28
        let margin: CGFloat = 56
        let header: CGFloat = 84

        let width = Int(margin * 2 + CGFloat(columns) * cellWidth + CGFloat(columns - 1) * gap)
        let height = Int(
            margin + header + CGFloat(rows) * (cellHeight + caption) + CGFloat(rows - 1) * gap + margin
        )
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let ink = Brand.tinte.nsColor
        context.setFillColor(ink.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        func draw(_ text: String, size: CGFloat, colour: NSColor, at point: CGPoint, mono: Bool = false) {
            let font = mono
                ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
                : NSFont.systemFont(ofSize: size, weight: .semibold)
            NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: colour]
            ).draw(at: point)
        }

        draw(
            title,
            size: 30,
            colour: Brand.knochen.nsColor,
            at: CGPoint(x: margin, y: CGFloat(height) - margin - 34)
        )
        draw(
            "\(cells.count) Still\(cells.count == 1 ? "" : "s")",
            size: 18,
            colour: Brand.leise.nsColor,
            at: CGPoint(x: margin, y: CGFloat(height) - margin - 62),
            mono: true
        )

        for (index, cell) in cells.enumerated() {
            let column = CGFloat(index % columns)
            let row = CGFloat(index / columns)
            let x = margin + column * (cellWidth + gap)
            // CoreGraphics counts from the bottom; rows are laid out from the top.
            let top = CGFloat(height) - margin - header - row * (cellHeight + caption + gap)
            let picture = CGRect(x: x, y: top - cellHeight, width: cellWidth, height: cellHeight)

            let fit = min(
                cellWidth / CGFloat(max(cell.image.width, 1)),
                cellHeight / CGFloat(max(cell.image.height, 1))
            )
            let drawn = CGSize(
                width: CGFloat(cell.image.width) * fit,
                height: CGFloat(cell.image.height) * fit
            )
            context.draw(
                cell.image,
                in: CGRect(
                    x: picture.midX - drawn.width / 2,
                    y: picture.midY - drawn.height / 2,
                    width: drawn.width,
                    height: drawn.height
                )
            )
            draw(
                cell.label,
                size: 20,
                colour: Brand.knochen.nsColor,
                at: CGPoint(x: x, y: picture.minY - caption + 12),
                mono: true
            )
        }

        return context.makeImage()
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
