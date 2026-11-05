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
            title: title(session.title, subtitle: session.subtitle, style: session.titleStyle, canvas: format.size, band: rects.film),
            labelOriginal: label(session.labelOriginal, canvas: format.size, band: rects.screen),
            labelMix: label(session.labelMix, canvas: format.size, band: rects.screen)
        )
    }

    // MARK: - Title

    /// The title near the foot of the film band — typed in a house face, or
    /// the film's own title design as a PNG — with the subtitle in Space Mono
    /// under it, and a soft shade beneath both so they read on any picture.
    static func title(
        _ headline: String,
        subtitle: String,
        style: TitleStyle,
        canvas: CGSize,
        band: CGRect
    ) -> CGImage? {
        let sub = subtitle.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let picture: NSImage? = style.mode == .image ? style.imagePath.flatMap { NSImage(contentsOfFile: $0) } : nil
        let head: String = {
            let trimmed = headline.trimmingCharacters(in: .whitespacesAndNewlines)
            return style.face == .fett ? trimmed.uppercased() : trimmed
        }()
        let hasHead = picture != nil || (style.mode == .text && !head.isEmpty)
        guard hasHead || !sub.isEmpty else { return nil }

        return draw(canvas: canvas) { context in
            if style.position == .bottom {
                shade(context, band: band)
            }

            // Measured off the reference post: the title spans about seven
            // tenths of the frame, the subtitle about half, tight under it,
            // the pair just clear of the band's foot.
            let maxWidth = band.width * 0.72
            let subMaxWidth = band.width * 0.52
            let bone = Brand.knochen.nsColor

            // Measure first, so the block can be centred when asked to.
            var subLine: NSAttributedString?
            var subSize: CGFloat = 0
            if !sub.isEmpty {
                subSize = fit(sub, maxWidth: subMaxWidth, start: 52, font: { Typography.mono($0) }, tracking: Typography.monoTracking)
                subLine = attributed(sub, font: Typography.mono(subSize), colour: bone, tracking: Typography.monoTracking)
            }
            let subHeight = subLine == nil ? 0 : subSize * 1.25

            var headRect = CGRect.zero
            var headLine: NSAttributedString?
            var headFont: NSFont?
            if let picture, picture.size.width > 0, picture.size.height > 0 {
                let scale = min(max(style.imageScale, 0.2), 1)
                var width = band.width * scale
                var height = width * picture.size.height / picture.size.width
                let tallest = band.height * 0.62 - subHeight
                if height > tallest {
                    height = max(tallest, 1)
                    width = height * picture.size.width / picture.size.height
                }
                headRect = CGRect(x: band.midX - width / 2, y: 0, width: width, height: height)
            } else if style.mode == .text, !head.isEmpty {
                let face: (CGFloat) -> NSFont = style.face == .fett ? { Typography.fett($0) } : { Typography.serif($0) }
                let tracking = style.face == .fett ? Typography.fettTracking : Typography.serifTracking
                let size = fit(head, maxWidth: maxWidth, start: style.face == .fett ? 170 : 190, font: face, tracking: tracking)
                let font = face(size)
                let line = attributed(head, font: font, colour: bone, tracking: tracking)
                let width = Typography.advance(of: line, kern: Typography.kern(tracking, at: size))
                headRect = CGRect(x: band.midX - width / 2, y: 0, width: width, height: font.capHeight)
                headLine = line
                headFont = font
            }

            let gap: CGFloat = headRect.height > 0 && subLine != nil ? band.height * 0.02 : 0
            let block = headRect.height + gap + subHeight
            let bottom = style.position == .bottom
                ? band.minY + band.height * 0.05
                : band.midY - block / 2

            if let subLine {
                let width = Typography.advance(of: subLine, kern: Typography.kern(Typography.monoTracking, at: subSize))
                subLine.draw(at: CGPoint(x: band.midX - width / 2, y: bottom))
            }
            let headBottom = bottom + subHeight + gap
            if let picture {
                picture.draw(
                    in: CGRect(x: headRect.minX, y: headBottom, width: headRect.width, height: headRect.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            } else if let headLine, let headFont {
                // Sit the capitals, not the line box, on the baseline.
                headLine.draw(at: CGPoint(x: headRect.minX, y: headBottom + headFont.descender * 0.2))
            }
        }
    }

    /// Transparent at mid-band, darker at its foot.
    private static func shade(_ context: CGContext, band: CGRect) {
        let height = band.height * 0.55
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                NSColor.black.withAlphaComponent(0.45).cgColor,
                NSColor.black.withAlphaComponent(0).cgColor
            ] as CFArray,
            locations: [0, 1]
        ) else { return }
        context.saveGState()
        context.clip(to: CGRect(x: band.minX, y: band.minY, width: band.width, height: height))
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: band.midX, y: band.minY),
            end: CGPoint(x: band.midX, y: band.minY + height),
            options: []
        )
        context.restoreGState()
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
            let top = band.maxY - band.height * 0.05
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
