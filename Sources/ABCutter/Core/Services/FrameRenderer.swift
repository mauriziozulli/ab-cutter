import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO

/// Everything the per-frame Core Image pass needs. Values are fixed for the
/// whole clip, so the render closure stays cheap.
struct RenderPlan {
    var targetSize: CGSize
    var fitMode: FitMode
    var panX: Double
    var panY: Double
    /// Measured from the start of the clip.
    var splitTime: CMTime
    var beforeLook: LookStyle
    var afterLook: LookStyle
    /// Pre-rendered on the main actor before the export starts.
    var beforeLabel: CGImage?
    var afterLabel: CGImage?
    var labelPosition: LabelPosition
    var sourceNaturalSize: CGSize
    var sourcePreferredTransform: CGAffineTransform
}

/// Turns a decoded source frame into a finished social-format frame.
enum FrameRenderer {
    static func render(_ source: CIImage, at time: CMTime, plan: RenderPlan) -> CIImage {
        let isBefore = CMTimeCompare(time, plan.splitTime) < 0
        let look = isBefore ? plan.beforeLook : plan.afterLook
        let label = isBefore ? plan.beforeLabel : plan.afterLabel

        let target = CGRect(origin: .zero, size: plan.targetSize)
        var image = orient(source, naturalSize: plan.sourceNaturalSize, transform: plan.sourcePreferredTransform)

        // Normalise the origin so the crop maths below can assume (0, 0).
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            return CIImage(color: .black).cropped(to: target)
        }
        image = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))

        let scale: CGFloat
        switch plan.fitMode {
        case .fill: scale = max(target.width / extent.width, target.height / extent.height)
        case .fit: scale = min(target.width / extent.width, target.height / extent.height)
        }
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Positive slack means the scaled frame is larger than the target and
        // the pan control decides which part stays visible. Negative slack
        // (fit mode) is simply centred.
        let slackX = image.extent.width - target.width
        let slackY = image.extent.height - target.height
        let translateX = slackX > 0 ? -(slackX / 2) * (1 + CGFloat(clampPan(plan.panX))) : -(slackX / 2)
        let translateY = slackY > 0 ? -(slackY / 2) * (1 + CGFloat(clampPan(plan.panY))) : -(slackY / 2)
        image = image.transformed(
            by: CGAffineTransform(translationX: translateX.rounded(), y: translateY.rounded())
        )

        image = applyLook(look, to: image)

        var output = image
            .composited(over: CIImage(color: .black).cropped(to: target))
            .cropped(to: target)

        if let label {
            output = composite(label: label, over: output, target: target, position: plan.labelPosition)
        }

        return output.cropped(to: target)
    }

    private static func clampPan(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }

    private static func applyLook(_ look: LookStyle, to image: CIImage) -> CIImage {
        switch look {
        case .color:
            return image
        case .blackAndWhite:
            guard let filter = CIFilter(name: "CIPhotoEffectMono") else {
                return desaturate(image, saturation: 0)
            }
            filter.setValue(image, forKey: kCIInputImageKey)
            return filter.outputImage ?? image
        case .desaturated:
            return desaturate(image, saturation: 0.18)
        }
    }

    private static func desaturate(_ image: CIImage, saturation: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        return filter.outputImage ?? image
    }

    private static func composite(
        label: CGImage,
        over image: CIImage,
        target: CGRect,
        position: LabelPosition
    ) -> CIImage {
        let labelImage = CIImage(cgImage: label)
        let margin = (target.height * 0.055).rounded()
        let x = ((target.width - labelImage.extent.width) / 2).rounded()
        let y: CGFloat = position == .bottom
            ? margin
            : (target.height - margin - labelImage.extent.height).rounded()
        return labelImage
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .composited(over: image)
    }

    // MARK: - Orientation

    /// Applies the track's preferred transform when the compositor has not
    /// already done so. The extent is compared against both candidate sizes so
    /// the frame is never rotated twice.
    private static func orient(
        _ image: CIImage,
        naturalSize: CGSize,
        transform: CGAffineTransform
    ) -> CIImage {
        guard !transform.isIdentity, naturalSize.width > 0, naturalSize.height > 0 else { return image }

        let rotated = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let orientedSize = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        let extent = image.extent.size

        let matchesNatural = abs(extent.width - naturalSize.width) < 1 && abs(extent.height - naturalSize.height) < 1
        let matchesOriented = abs(extent.width - orientedSize.width) < 1 && abs(extent.height - orientedSize.height) < 1

        // Already upright, or an extent we do not recognise — leave it alone.
        if matchesOriented && !matchesNatural { return image }
        guard matchesNatural else { return image }

        return image.oriented(orientation(for: transform))
    }

    /// Maps the four right-angle preferred transforms onto EXIF orientations.
    /// `CIImage.oriented` handles the flip between UIKit-style and Core Image
    /// coordinates, which a raw `transformed(by:)` would get wrong.
    private static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = transform.a.rounded()
        let b = transform.b.rounded()
        let c = transform.c.rounded()
        let d = transform.d.rounded()

        switch (a, b, c, d) {
        case (0, 1, -1, 0): return .right   // 90° clockwise
        case (-1, 0, 0, -1): return .down   // 180°
        case (0, -1, 1, 0): return .left    // 90° counter-clockwise
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        default: return .up
        }
    }
}

// MARK: - Labels

/// Draws the VORHER / NACHHER pills. AppKit drawing is confined to the main
/// actor and the results are handed to the exporter as immutable images.
@MainActor
enum LabelRenderer {
    static func pill(text: String, targetSize: CGSize) -> CGImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, targetSize.width > 0, targetSize.height > 0 else { return nil }

        let fontSize = max(18, (targetSize.height * 0.032).rounded())
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: fontSize * 0.08
        ]
        let attributed = NSAttributedString(string: trimmed.uppercased(), attributes: attributes)
        let textSize = attributed.size()

        let paddingX = (fontSize * 0.9).rounded()
        let paddingY = (fontSize * 0.45).rounded()
        let width = Int((textSize.width + paddingX * 2).rounded())
        let height = Int((textSize.height + paddingY * 2).rounded())
        guard width > 0, height > 0 else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let bounds = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let radius = min(bounds.height / 2, 24)
        let pillPath = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
        pillPath.fill()

        attributed.draw(at: NSPoint(x: paddingX, y: paddingY))

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
