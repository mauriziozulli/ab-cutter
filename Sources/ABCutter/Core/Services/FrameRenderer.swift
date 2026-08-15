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
    /// Measured from the start of the clip. The picture alternates between the
    /// before and after treatment at each of these.
    var switchTimes: [CMTime]
    var beforeLook: LookStyle
    var afterLook: LookStyle
    var frameTreatment: FrameTreatment
    var frameBackdrop: FrameBackdrop
    var insetScale: Double
    var labelPosition: LabelPosition
    /// Strips the composition keeps clear of the platform's own controls.
    var safeArea: SafeArea = .none
    /// Full-canvas furniture — border, label, subtitle — drawn ahead of time.
    var beforeOverlay: CGImage?
    var afterOverlay: CGImage?
    var sourceNaturalSize: CGSize
    var sourcePreferredTransform: CGAffineTransform
}

/// Turns a decoded source frame into a finished social-format frame.
enum FrameRenderer {
    static func render(_ source: CIImage, at time: CMTime, plan: RenderPlan) -> CIImage {
        let isBefore = Self.isBeforeSegment(at: time, switches: plan.switchTimes)
        let look = isBefore ? plan.beforeLook : plan.afterLook
        let overlay = isBefore ? plan.beforeOverlay : plan.afterOverlay

        let target = CGRect(origin: .zero, size: plan.targetSize)
        let oriented = orient(source, naturalSize: plan.sourceNaturalSize, transform: plan.sourcePreferredTransform)
        guard oriented.extent.width > 0, oriented.extent.height > 0 else {
            return CIImage(color: .black).cropped(to: target)
        }

        let frame = pictureRect(
            targetSize: plan.targetSize,
            treatment: plan.frameTreatment,
            isBefore: isBefore,
            insetScale: plan.insetScale,
            labelPosition: plan.labelPosition,
            safeArea: plan.safeArea
        )

        let picture = applyLook(
            look,
            to: place(oriented, into: frame, mode: plan.fitMode, panX: plan.panX, panY: plan.panY)
        )

        // A full-bleed frame needs no backdrop; an inset one sits on a blurred
        // or solid card so the canvas is never empty.
        let base: CIImage
        if frame == target {
            base = CIImage(color: .black).cropped(to: target)
        } else {
            base = backdrop(
                from: place(oriented, into: target, mode: .fill, panX: plan.panX, panY: plan.panY),
                target: target,
                style: plan.frameBackdrop
            )
        }

        var output = picture.composited(over: base).cropped(to: target)
        if let overlay {
            output = CIImage(cgImage: overlay).composited(over: output)
        }
        return output.cropped(to: target)
    }

    /// Segments alternate, so the side is simply the parity of how many
    /// switches the playhead has passed.
    static func isBeforeSegment(at time: CMTime, switches: [CMTime]) -> Bool {
        var crossed = 0
        for point in switches where CMTimeCompare(time, point) >= 0 { crossed += 1 }
        return crossed.isMultiple(of: 2)
    }

    // MARK: - Layout

    static let labelMarginFraction: CGFloat = 0.055

    /// The canvas minus the strips reserved for the platform's own controls.
    /// Everything the app draws itself — inset picture, border, type — is laid
    /// out inside this rect, while a full-bleed picture still fills the canvas:
    /// a story's header may sit over the film, it just must not sit over the
    /// frame or the label.
    ///
    /// With no safe area this is the whole canvas, so the layout is unchanged
    /// for every format that plays inside a feed card.
    static func contentRect(targetSize: CGSize, safeArea: SafeArea) -> CGRect {
        let full = CGRect(origin: .zero, size: targetSize)
        let area = safeArea.clamped
        guard !area.isEmpty else { return full }

        let top = (targetSize.height * CGFloat(area.top)).rounded()
        let bottom = (targetSize.height * CGFloat(area.bottom)).rounded()
        let height = targetSize.height - top - bottom
        guard height > 1 else { return full }

        return CGRect(x: 0, y: bottom, width: targetSize.width, height: height)
    }

    /// Where the picture itself sits inside the canvas. An inset picture is
    /// pushed away from the label side, so the type gets a band of its own
    /// rather than sitting on the image.
    static func pictureRect(
        targetSize: CGSize,
        treatment: FrameTreatment,
        isBefore: Bool,
        insetScale: Double,
        labelPosition: LabelPosition,
        safeArea: SafeArea = .none
    ) -> CGRect {
        let full = CGRect(origin: .zero, size: targetSize)
        guard treatment.isInset(before: isBefore) else { return full }

        // Scaled against the safe height rather than the canvas height, so the
        // reserved strips take their room out of the picture instead of being
        // eaten by it. The width is untouched: no platform draws down the side.
        let content = contentRect(targetSize: targetSize, safeArea: safeArea)
        let scale = CGFloat(min(max(insetScale, 0.6), 0.98))
        let width = (targetSize.width * scale).rounded()
        let height = (content.height * scale).rounded()
        let freeX = targetSize.width - width
        let freeY = content.height - height
        // Roughly three-quarters of the slack goes to the label side.
        let bottom = content.minY + (labelPosition == .bottom ? freeY * 0.72 : freeY * 0.28).rounded()

        return CGRect(x: (freeX / 2).rounded(), y: bottom, width: width, height: height)
    }

    /// The strip of canvas the label block sits in — the margin beside an
    /// inset picture, or a band at the edge when the picture is full bleed.
    static func labelBand(
        targetSize: CGSize,
        pictureRect: CGRect,
        position: LabelPosition,
        safeArea: SafeArea = .none
    ) -> CGRect {
        let content = contentRect(targetSize: targetSize, safeArea: safeArea)
        let isInset = pictureRect != CGRect(origin: .zero, size: targetSize)
        if isInset {
            return position == .bottom
                ? CGRect(
                    x: 0,
                    y: content.minY,
                    width: targetSize.width,
                    height: max(pictureRect.minY - content.minY, 0)
                )
                : CGRect(
                    x: 0,
                    y: pictureRect.maxY,
                    width: targetSize.width,
                    height: max(content.maxY - pictureRect.maxY, 0)
                )
        }
        let height = min((targetSize.height * 0.16).rounded(), content.height)
        return CGRect(
            x: 0,
            y: position == .bottom ? content.minY : content.maxY - height,
            width: targetSize.width,
            height: height
        )
    }

    // MARK: - Placement

    /// Scales `image` to fill or fit `rect`, honouring the pan, and crops it
    /// to that rect so it never bleeds over the backdrop.
    private static func place(
        _ image: CIImage,
        into rect: CGRect,
        mode: FitMode,
        panX: Double,
        panY: Double
    ) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, rect.width > 0, rect.height > 0 else { return image }

        var result = image.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        )
        let scale: CGFloat = mode == .fill
            ? max(rect.width / extent.width, rect.height / extent.height)
            : min(rect.width / extent.width, rect.height / extent.height)
        result = result.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Positive slack means the scaled frame is larger than the rect and the
        // pan control decides which part stays visible.
        let slackX = result.extent.width - rect.width
        let slackY = result.extent.height - rect.height
        let offsetX = slackX > 0 ? -(slackX / 2) * (1 + CGFloat(clampPan(panX))) : -(slackX / 2)
        let offsetY = slackY > 0 ? -(slackY / 2) * (1 + CGFloat(clampPan(panY))) : -(slackY / 2)

        return result
            .transformed(
                by: CGAffineTransform(
                    translationX: (rect.minX + offsetX).rounded(),
                    y: (rect.minY + offsetY).rounded()
                )
            )
            .cropped(to: rect)
    }

    private static func clampPan(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }

    // MARK: - Backdrop

    private static func backdrop(from fill: CIImage, target: CGRect, style: FrameBackdrop) -> CIImage {
        let black = CIImage(color: .black).cropped(to: target)
        switch style {
        case .solid:
            return CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.06)).cropped(to: target)
        case .blur:
            // Downsample, blur small, scale back. Visually identical to a
            // large-radius blur once darkened, at a fraction of the cost.
            let ratio: CGFloat = 0.12
            var small = fill
                .transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
                .clampedToExtent()
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(small, forKey: kCIInputImageKey)
                blur.setValue(6.0, forKey: kCIInputRadiusKey)
                small = blur.outputImage ?? small
            }
            var wide = small.transformed(by: CGAffineTransform(scaleX: 1 / ratio, y: 1 / ratio))
            // Darkened and drained so the inset picture stays dominant.
            if let controls = CIFilter(name: "CIColorControls") {
                controls.setValue(wide, forKey: kCIInputImageKey)
                controls.setValue(-0.34, forKey: kCIInputBrightnessKey)
                controls.setValue(0.65, forKey: kCIInputSaturationKey)
                wide = controls.outputImage ?? wide
            }
            return wide.cropped(to: target).composited(over: black)
        }
    }

    // MARK: - Grade

    private static func applyLook(_ look: LookStyle, to image: CIImage) -> CIImage {
        switch look {
        case .color:
            return image
        case .blackAndWhite:
            guard let filter = CIFilter(name: "CIPhotoEffectMono") else {
                return desaturate(image, saturation: 0)
            }
            filter.setValue(image, forKey: kCIInputImageKey)
            return filter.outputImage?.cropped(to: image.extent) ?? image
        case .desaturated:
            return desaturate(image, saturation: 0.35)
        }
    }

    private static func desaturate(_ image: CIImage, saturation: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        return filter.outputImage?.cropped(to: image.extent) ?? image
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
