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
    /// Measured from the start of the clip. The overlay alternates between
    /// the before and after side at each of these.
    var switchTimes: [CMTime]
    /// False only for the plain preview with no clip selected — the design
    /// itself is fixed: framed picture over a blurred backdrop.
    var inset: Bool = true
    var insetScale: Double
    /// Strips the composition keeps clear of the platform's own controls.
    var safeArea: SafeArea = .none
    /// Whether the layout reserves the two mono strips.
    var showStrips: Bool = false
    /// Grain over the finished picture, `.26` on the website. Zero is off.
    var grainStrength: Double = 0
    /// Radial darkening towards the corners. Zero is off.
    var vignetteStrength: Double = 0
    /// Full-canvas furniture — border, label, subtitle — drawn ahead of time.
    var beforeOverlay: CGImage?
    var afterOverlay: CGImage?
    /// Finished, opaque cards held before and after the film. Both optional:
    /// most deliveries have neither.
    var titleCard: CGImage?
    var endCard: CGImage?
    /// The stretch the film occupies. Everything outside it belongs to a card.
    /// Infinite by default, so a plain clip never takes the card path.
    var pictureRange: CMTimeRange = CMTimeRange(start: .zero, duration: .positiveInfinity)
    var sourceNaturalSize: CGSize
    var sourcePreferredTransform: CGAffineTransform
}

/// Turns a decoded source frame into a finished social-format frame.
enum FrameRenderer {
    static func render(_ source: CIImage, at time: CMTime, plan: RenderPlan) -> CIImage {
        let target = CGRect(origin: .zero, size: plan.targetSize)

        // Outside the film's own stretch a card owns the whole canvas. The
        // frames underneath are a slowed seed of the clip that exists only so
        // the compositor asks for anything here at all, and the card is opaque,
        // so the source is dropped rather than composited over.
        if let card = card(at: time, plan: plan) {
            return CIImage(cgImage: card).cropped(to: target)
        }

        let isBefore = Self.isBeforeSegment(at: time, switches: plan.switchTimes)
        let overlay = isBefore ? plan.beforeOverlay : plan.afterOverlay

        let oriented = orient(source, naturalSize: plan.sourceNaturalSize, transform: plan.sourcePreferredTransform)
        guard oriented.extent.width > 0, oriented.extent.height > 0 else {
            return CIImage(color: .black).cropped(to: target)
        }

        let frame = layout(
            targetSize: plan.targetSize,
            inset: plan.inset,
            insetScale: plan.insetScale,
            safeArea: plan.safeArea,
            showStrips: plan.showStrips
        ).picture

        // The picture always keeps its colour: the A/B is an audio switch,
        // and the sides are told apart by the frame and type colours.
        let picture = place(oriented, into: frame, mode: plan.fitMode, panX: plan.panX, panY: plan.panY)

        // A full-bleed frame needs no backdrop; an inset one sits on a blurred
        // copy of itself so the canvas is never empty.
        let base: CIImage
        if frame == target {
            base = CIImage(color: Brand.tinte.ciColor).cropped(to: target)
        } else {
            base = backdrop(
                from: place(oriented, into: target, mode: .fill, panX: plan.panX, panY: plan.panY),
                target: target
            )
        }

        var output = picture.composited(over: base).cropped(to: target)

        // Veil and grain go under the furniture, not over it: on the website
        // they are the section's `::after` and `::before`, and the type sits
        // above both. Over the type they would only make it harder to read.
        output = veil(output, target: target, strength: plan.vignetteStrength)
        output = grain(output, target: target, strength: plan.grainStrength)

        if let overlay {
            output = CIImage(cgImage: overlay).composited(over: output)
        }
        return output.cropped(to: target)
    }

    /// The card owning this instant, if any. A missing card means the hold
    /// falls back to the picture rather than to a hole in the file.
    private static func card(at time: CMTime, plan: RenderPlan) -> CGImage? {
        guard CMTIME_IS_NUMERIC(plan.pictureRange.duration) else { return nil }
        if CMTimeCompare(time, plan.pictureRange.start) < 0 { return plan.titleCard }
        if CMTimeCompare(time, plan.pictureRange.end) >= 0 { return plan.endCard }
        return nil
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

    /// Side margin, `--rand` on the website. Stated against the width because
    /// that is what it holds type away from.
    static let sideMarginFraction: CGFloat = 0.055

    /// Height of one mono strip, generous enough that the line inside it has
    /// air above and below the rule.
    static let stripFraction: CGFloat = 0.030

    /// Everywhere a playout puts something, worked out once.
    ///
    /// The pieces used to be computed in four places from two loose functions,
    /// which was already awkward before the strips arrived — the label needed
    /// the picture, the picture needed the safe area, and the tint sampler
    /// needed both. One struct means the exporter, the preview and the sampler
    /// cannot disagree about where anything is.
    struct PlayoutLayout {
        var canvas: CGRect
        /// Canvas minus the strips reserved for the platform's own controls.
        var content: CGRect
        /// Mono line and its rule. Empty when the strips are off.
        var topStrip: CGRect
        var bottomStrip: CGRect
        /// The picture itself — the whole canvas when it is full bleed.
        var picture: CGRect
        /// Where the before/after label sits.
        var labelBand: CGRect
        var sideMargin: CGFloat

        var isInset: Bool { picture != canvas }
        var hasStrips: Bool { topStrip.height > 0 }
    }

    static func layout(
        targetSize: CGSize,
        inset: Bool = true,
        insetScale: Double,
        safeArea: SafeArea = .none,
        showStrips: Bool = false
    ) -> PlayoutLayout {
        let canvas = CGRect(origin: .zero, size: targetSize)
        let content = contentRect(targetSize: targetSize, safeArea: safeArea)
        let side = (targetSize.width * sideMarginFraction).rounded()

        // The strips sit at the inner edges of the safe area; everything else
        // is laid out between them.
        let stripHeight = showStrips
            ? min((targetSize.height * stripFraction).rounded(), (content.height / 5).rounded())
            : 0
        let stripWidth = max(targetSize.width - side * 2, 0)
        let topStrip = stripHeight > 0
            ? CGRect(x: side, y: content.maxY - stripHeight, width: stripWidth, height: stripHeight)
            : .zero
        let bottomStrip = stripHeight > 0
            ? CGRect(x: side, y: content.minY, width: stripWidth, height: stripHeight)
            : .zero

        let inner = CGRect(
            x: 0,
            y: content.minY + stripHeight,
            width: targetSize.width,
            height: max(content.height - stripHeight * 2, 1)
        )

        let picture = pictureRect(
            targetSize: targetSize,
            inset: inset,
            insetScale: insetScale,
            within: inner
        )

        return PlayoutLayout(
            canvas: canvas,
            content: content,
            topStrip: topStrip,
            bottomStrip: bottomStrip,
            picture: picture,
            labelBand: labelBand(
                targetSize: targetSize,
                pictureRect: picture,
                within: inner
            ),
            sideMargin: side
        )
    }

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

    /// Where the picture itself sits. An inset picture is pushed away from the
    /// label side, so the type gets a band of its own rather than sitting on
    /// the image. `region` is whatever is left after the safe area and the
    /// strips have taken their share.
    private static func pictureRect(
        targetSize: CGSize,
        inset: Bool,
        insetScale: Double,
        within region: CGRect
    ) -> CGRect {
        let full = CGRect(origin: .zero, size: targetSize)
        guard inset else { return full }

        // Scaled against the region's height rather than the canvas height, so
        // what is reserved comes out of the picture instead of being covered by
        // it. The width is untouched: nothing is reserved down the sides.
        let scale = CGFloat(min(max(insetScale, 0.6), 0.98))
        let width = (targetSize.width * scale).rounded()
        let height = (region.height * scale).rounded()
        let freeX = targetSize.width - width
        let freeY = region.height - height
        // Roughly three-quarters of the slack goes to the label side, which
        // is always the bottom.
        let bottom = region.minY + (freeY * 0.72).rounded()

        return CGRect(x: (freeX / 2).rounded(), y: bottom, width: width, height: height)
    }

    /// The band the label block sits in — the margin beside an inset picture,
    /// or a band at the region's edge when the picture is full bleed.
    private static func labelBand(
        targetSize: CGSize,
        pictureRect: CGRect,
        within region: CGRect
    ) -> CGRect {
        let isInset = pictureRect != CGRect(origin: .zero, size: targetSize)
        if isInset {
            return CGRect(
                x: 0,
                y: region.minY,
                width: targetSize.width,
                height: max(pictureRect.minY - region.minY, 0)
            )
        }
        let height = min((targetSize.height * 0.16).rounded(), region.height)
        return CGRect(
            x: 0,
            y: region.minY,
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

    /// The blurred, darkened copy of the frame behind the inset picture.
    private static func backdrop(from fill: CIImage, target: CGRect) -> CIImage {
        let black = CIImage(color: .black).cropped(to: target)
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

    // MARK: - Texture

    /// The website's `::after`: a radial darkening that keeps type readable
    /// over any picture. Its inner stop is barely there and the corners carry
    /// almost all of it, which is what stops it reading as a filter.
    private static func veil(_ image: CIImage, target: CGRect, strength: Double) -> CIImage {
        let amount = min(max(strength, 0), 0.95)
        guard amount > 0.01, let gradient = CIFilter(name: "CIRadialGradient") else { return image }

        let centre = CIVector(x: target.midX, y: target.height * 0.54)
        // 92 % of the height at the outer stop, as in the CSS.
        gradient.setValue(centre, forKey: "inputCenter")
        gradient.setValue(0, forKey: "inputRadius0")
        gradient.setValue(target.height * 0.6, forKey: "inputRadius1")
        gradient.setValue(CIColor(red: 0.063, green: 0.063, blue: 0.078, alpha: amount * 0.17), forKey: "inputColor0")
        gradient.setValue(CIColor(red: 0.063, green: 0.063, blue: 0.078, alpha: amount), forKey: "inputColor1")

        guard let scrim = gradient.outputImage?.cropped(to: target) else { return image }
        return scrim.composited(over: image).cropped(to: target)
    }

    /// The website's `::before`: fractal noise at `.26`, which is what turns a
    /// flat colour field into something that reads as a recording.
    ///
    /// Regenerated per frame on purpose. Still grain over moving picture looks
    /// like dirt on the lens; grain that moves is the one every viewer has
    /// already accepted as film.
    private static func grain(_ image: CIImage, target: CGRect, strength: Double) -> CIImage {
        let amount = min(max(strength, 0), 1)
        guard amount > 0.01, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }

        // Desaturated and scaled up a little, so it reads as grain rather than
        // as coloured pixel confetti.
        var texture = noise.transformed(by: CGAffineTransform(scaleX: 1.6, y: 1.6)).cropped(to: target)
        if let mono = CIFilter(name: "CIColorMatrix") {
            mono.setValue(texture, forKey: kCIInputImageKey)
            mono.setValue(CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0), forKey: "inputRVector")
            mono.setValue(CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0), forKey: "inputGVector")
            mono.setValue(CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0), forKey: "inputBVector")
            mono.setValue(CIVector(x: 0, y: 0, z: 0, w: amount * 0.5), forKey: "inputAVector")
            texture = mono.outputImage ?? texture
        }

        guard let blend = CIFilter(name: "CIOverlayBlendMode") else { return image }
        blend.setValue(texture.cropped(to: target), forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        return (blend.outputImage ?? image).cropped(to: target)
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
