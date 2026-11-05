import AppKit
import CoreGraphics

/// Draws the type of a post — the film title inside the film band, the
/// side's name over Pro Tools — as full-canvas transparent images, once per
/// format. AppKit text, so on the main actor; the compositor only stacks.
@MainActor
enum OverlayFactory {
    struct Overlays {
        var title: CGImage?
        var labelOriginal: CGImage?
        var labelMix: CGImage?
    }

    static func overlays(for format: OutputFormat, session: Session) -> Overlays {
        let rects = LayoutPlan.rects(for: format)
        return Overlays(
            title: title(session.title, subtitle: session.subtitle, canvas: format.size, band: rects.film),
            labelOriginal: label(session.labelOriginal, canvas: format.size, band: rects.screen),
            labelMix: label(session.labelMix, canvas: format.size, band: rects.screen)
        )
    }

    // MARK: - Title

    /// Heavy capitals near the bottom of the film band, a lighter line under
    /// them, and a soft shade beneath both so they read on any picture.
    static func title(_ headline: String, subtitle: String, canvas: CGSize, band: CGRect) -> CGImage? {
        let head = headline.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let sub = subtitle.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !head.isEmpty || !sub.isEmpty else { return nil }

        return draw(canvas: canvas) { context in
            // Shade: transparent at mid-band, darker at its foot.
            let shade = band.height * 0.55
            if let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [
                    NSColor.black.withAlphaComponent(0.6).cgColor,
                    NSColor.black.withAlphaComponent(0).cgColor
                ] as CFArray,
                locations: [0, 1]
            ) {
                context.saveGState()
                context.clip(to: CGRect(x: band.minX, y: band.minY, width: band.width, height: shade))
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: band.midX, y: band.minY),
                    end: CGPoint(x: band.midX, y: band.minY + shade),
                    options: []
                )
                context.restoreGState()
            }

            let maxWidth = band.width * 0.86
            let bone = Brand.knochen.nsColor
            var baseline = band.minY + band.height * 0.09

            if !sub.isEmpty {
                let size = fit(sub, maxWidth: maxWidth, start: 40, font: { NSFont.systemFont(ofSize: $0, weight: .medium) }, tracking: 0.04)
                let line = attributed(sub, font: NSFont.systemFont(ofSize: size, weight: .medium), colour: bone, tracking: 0.04)
                let width = line.size().width
                line.draw(at: CGPoint(x: band.midX - width / 2, y: baseline))
                baseline += size * 1.1
            }
            if !head.isEmpty {
                let size = fit(head, maxWidth: maxWidth, start: 132, font: { Typography.fett($0) }, tracking: Typography.fettTracking)
                let font = Typography.fett(size)
                let line = attributed(head, font: font, colour: bone, tracking: Typography.fettTracking)
                let width = Typography.advance(of: line, kern: Typography.kern(Typography.fettTracking, at: size))
                // Sit the capitals, not the line box, on the baseline.
                line.draw(at: CGPoint(x: band.midX - width / 2, y: baseline + font.descender * 0.2))
            }
        }
    }

    // MARK: - Side label

    /// "Original" or "Final Mix", centred near the top of the Pro Tools band.
    static func label(_ text: String, canvas: CGSize, band: CGRect) -> CGImage? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        return draw(canvas: canvas) { _ in
            let size = fit(value, maxWidth: band.width * 0.8, start: 76, font: { Typography.fett($0) }, tracking: Typography.fettTracking)
            let font = Typography.fett(size)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            let line = NSAttributedString(string: value, attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .kern: Typography.kern(Typography.fettTracking, at: size),
                .shadow: shadow
            ])
            let width = Typography.advance(of: line, kern: Typography.kern(Typography.fettTracking, at: size))
            let top = band.maxY - band.height * 0.06
            line.draw(at: CGPoint(x: band.midX - width / 2, y: top - font.ascender))
        }
    }

    // MARK: - Helpers

    private static func attributed(_ text: String, font: NSFont, colour: NSColor, tracking: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: colour,
            .kern: Typography.kern(tracking, at: font.pointSize)
        ])
    }

    /// The largest size up to `start` at which the line fits `maxWidth`.
    private static func fit(
        _ text: String,
        maxWidth: CGFloat,
        start: CGFloat,
        font: (CGFloat) -> NSFont,
        tracking: CGFloat
    ) -> CGFloat {
        var size = start
        while size > 14 {
            let line = attributed(text, font: font(size), colour: .white, tracking: tracking)
            if Typography.advance(of: line, kern: Typography.kern(tracking, at: size)) <= maxWidth { break }
            size -= 2
        }
        return size
    }

    private static func draw(canvas: CGSize, _ body: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
