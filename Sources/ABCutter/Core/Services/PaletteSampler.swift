import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

/// A colour for burnt-in type, plus how well it reads against the frame.
struct LabelTint: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    /// WCAG contrast ratio against the strip the label sits in, 1 … 21.
    var contrastRatio: Double

    static let white = LabelTint(red: 1, green: 1, blue: 1, contrastRatio: 1)

    /// Below this, plain type starts to disappear into the picture.
    static let legibleContrast: Double = 3.0

    var needsShadow: Bool { contrastRatio < Self.legibleContrast }
}

/// Reads the dominant hue out of the *cropped* frame so a label can be tinted
/// from the picture it sits on.
///
/// Two deliberate choices live here. The hue is taken from the ungraded frame,
/// so the black-and-white "before" half still gets a coloured label — that is
/// the whole point of tinting. And the hue is only a hue: the lightness is
/// forced away from the strip behind the text, because a colour sampled from
/// an image is by definition close to that image and would otherwise vanish.
enum PaletteSampler {
    /// Samples one frame and returns the tint to draw the label in.
    static func tint(
        videoURL: URL,
        at time: CMTime,
        format: SocialFormat,
        settings: ExportSettings,
        clip: Clip,
        isBefore: Bool
    ) async -> LabelTint {
        guard let frame = await frameImage(videoURL: videoURL, at: time) else { return .white }

        // A small proxy of the real output. The layout is scale-invariant, so
        // the sampled region matches the export exactly at a fraction of the
        // cost. The looks are forced to colour: the before half is graded down,
        // and a tint read off a monochrome frame would come back grey.
        let aspect = format.size.height / format.size.width
        let proxy = CGSize(width: 200, height: (200 * aspect).rounded())
        let plan = RenderPlan(
            targetSize: proxy,
            fitMode: settings.fitMode,
            panX: clip.panX,
            panY: clip.panY,
            splitTime: .zero,
            beforeLook: .color,
            afterLook: .color,
            frameTreatment: settings.frameTreatment,
            frameBackdrop: settings.frameBackdrop,
            insetScale: settings.insetScale,
            labelPosition: settings.labelPosition,
            beforeOverlay: nil,
            afterOverlay: nil,
            // The generator already applied the track transform.
            sourceNaturalSize: CGSize(width: frame.width, height: frame.height),
            sourcePreferredTransform: .identity
        )

        // `render` picks the half by comparing against the split, which sits at
        // zero here — so the after look is what a non-negative time returns.
        let sampleTime = isBefore ? CMTime(seconds: -1, preferredTimescale: 600) : .zero
        let composed = FrameRenderer.render(CIImage(cgImage: frame), at: sampleTime, plan: plan)
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])

        let pictureRect = FrameRenderer.pictureRect(
            targetSize: proxy,
            treatment: settings.frameTreatment,
            isBefore: isBefore,
            insetScale: settings.insetScale,
            labelPosition: settings.labelPosition
        )

        // The hue comes from the picture itself, the contrast from whatever the
        // type will actually sit on — backdrop included.
        return tint(
            of: composed,
            sceneRect: pictureRect,
            bandRect: FrameRenderer.labelBand(
                targetSize: proxy,
                pictureRect: pictureRect,
                position: settings.labelPosition
            ),
            context: context
        )
    }

    /// Reads a tint straight off an already-composed image — used by the title
    /// card, whose background is blurred and dimmed before any type lands on it.
    static func tint(
        of image: CIImage,
        sceneRect: CGRect,
        bandRect: CGRect,
        context: CIContext
    ) -> LabelTint {
        guard let scene = pixels(of: image, in: sceneRect, context: context) else { return .white }
        let band = pixels(of: image, in: bandRect, context: context) ?? scene
        return tint(scene: scene, band: band)
    }

    // MARK: - Colour maths

    private struct Pixels {
        var values: [UInt8]
        var count: Int
    }

    private static func tint(scene: Pixels, band: Pixels) -> LabelTint {
        let (hue, saturation) = dominantHue(scene)
        let bandLuminance = meanLuminance(band)
        // Light type on a dark strip, deep type on a bright one.
        let wantsLight = bandLuminance < 0.45

        // A near-monochrome scene has no hue worth borrowing.
        guard saturation > 0.05 else {
            let plain: LabelTint = wantsLight
                ? LabelTint(red: 1, green: 1, blue: 1, contrastRatio: 0)
                : LabelTint(red: 0.06, green: 0.06, blue: 0.06, contrastRatio: 0)
            return scored(plain, against: bandLuminance)
        }

        // Push the borrowed hue until it clears the picture behind it. Light
        // type desaturates towards white; dark type simply gets darker.
        var best = scored(
            rgb(hue: hue, saturation: min(max(saturation * 1.4, 0.55), 0.95), brightness: wantsLight ? 1 : 0.5),
            against: bandLuminance
        )
        var step = 0
        while best.contrastRatio < LabelTint.legibleContrast, step < 12 {
            step += 1
            let fraction = Double(step) / 12.0
            let candidate: LabelTint
            if wantsLight {
                candidate = rgb(
                    hue: hue,
                    saturation: min(max(saturation * 1.4, 0.55), 0.95) * (1 - fraction),
                    brightness: 1
                )
            } else {
                candidate = rgb(
                    hue: hue,
                    saturation: min(max(saturation * 1.4, 0.55), 0.95),
                    brightness: max(0.5 * (1 - fraction), 0.04)
                )
            }
            let ranked = scored(candidate, against: bandLuminance)
            if ranked.contrastRatio > best.contrastRatio { best = ranked }
        }
        return best
    }

    private static func scored(_ tint: LabelTint, against bandLuminance: Double) -> LabelTint {
        var result = tint
        result.contrastRatio = contrastRatio(relativeLuminance(tint), bandLuminance)
        return result
    }

    /// Saturation-weighted circular mean, so grey pixels do not drag the hue.
    private static func dominantHue(_ pixels: Pixels) -> (hue: Double, saturation: Double) {
        var x = 0.0
        var y = 0.0
        var saturationSum = 0.0
        var weightSum = 0.0

        for index in stride(from: 0, to: pixels.count * 4, by: 4) {
            let r = Double(pixels.values[index]) / 255
            let g = Double(pixels.values[index + 1]) / 255
            let b = Double(pixels.values[index + 2]) / 255
            let (hue, saturation, value) = hsv(r: r, g: g, b: b)
            // Very dark pixels carry no reliable hue.
            let weight = saturation * value
            let angle = hue * 2 * Double.pi
            x += cos(angle) * weight
            y += sin(angle) * weight
            saturationSum += saturation * value
            weightSum += value
        }

        guard weightSum > 0, x != 0 || y != 0 else { return (0, 0) }
        var hue = atan2(y, x) / (2 * Double.pi)
        if hue < 0 { hue += 1 }
        return (hue, saturationSum / weightSum)
    }

    private static func meanLuminance(_ pixels: Pixels) -> Double {
        guard pixels.count > 0 else { return 0.5 }
        var total = 0.0
        for index in stride(from: 0, to: pixels.count * 4, by: 4) {
            total += relativeLuminance(
                red: Double(pixels.values[index]) / 255,
                green: Double(pixels.values[index + 1]) / 255,
                blue: Double(pixels.values[index + 2]) / 255
            )
        }
        return total / Double(pixels.count)
    }

    private static func hsv(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maximum = max(r, max(g, b))
        let minimum = min(r, min(g, b))
        let delta = maximum - minimum
        guard delta > 0, maximum > 0 else { return (0, 0, maximum) }

        var hue: Double
        if maximum == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / maximum, maximum)
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> LabelTint {
        let sector = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let index = Int(sector)
        let fraction = sector - Double(index)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))

        switch index % 6 {
        case 0: return LabelTint(red: brightness, green: t, blue: p, contrastRatio: 0)
        case 1: return LabelTint(red: q, green: brightness, blue: p, contrastRatio: 0)
        case 2: return LabelTint(red: p, green: brightness, blue: t, contrastRatio: 0)
        case 3: return LabelTint(red: p, green: q, blue: brightness, contrastRatio: 0)
        case 4: return LabelTint(red: t, green: p, blue: brightness, contrastRatio: 0)
        default: return LabelTint(red: brightness, green: p, blue: q, contrastRatio: 0)
        }
    }

    private static func relativeLuminance(_ tint: LabelTint) -> Double {
        relativeLuminance(red: tint.red, green: tint.green, blue: tint.blue)
    }

    /// WCAG 2.1 relative luminance.
    private static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    // MARK: - Frame access

    private static func pixels(of image: CIImage, in rect: CGRect, context: CIContext) -> Pixels? {
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        guard width > 0, height > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(
                image,
                toBitmap: base,
                rowBytes: width * 4,
                bounds: CGRect(x: rect.origin.x, y: rect.origin.y, width: CGFloat(width), height: CGFloat(height)),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }
        return Pixels(values: buffer, count: width * height)
    }

    private static func frameImage(videoURL: URL, at time: CMTime) async -> CGImage? {
        let asset = AVURLAsset(url: videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        // A tolerant seek lands on a nearby keyframe, which is plenty for a
        // colour reading and much faster than an exact one.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        return try? await generator.image(at: time).image
    }
}
