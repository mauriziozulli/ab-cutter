import AppKit
import CoreGraphics
import Foundation

/// The two still cards: the one that opens a post and the one that closes it.
///
/// They are deliberately the same object seen twice. Both set their line in the
/// heavy grotesque, both carry a mono line over a hard rule at the foot, and
/// the only difference is that the end card puts the second half of the
/// wordmark in a field of the accent — the sticker's own arrangement — while a
/// title card is plain type. A viewer should recognise the second card from
/// having seen the first.
///
/// Separate from `OverlayRenderer` because a card carries a sentence and a
/// wordmark, while a clip label carries a single word: they share the palette,
/// the faces and the foot, not the layout.
@MainActor
enum CardRenderer {
    /// A headline never runs past this many lines; it shrinks instead.
    private static let maximumLines = 3

    // MARK: - Title card

    /// The card that opens a post: the headline set large in the lead face,
    /// with the second line at the foot over a rule.
    static func titleCard(
        targetSize: CGSize,
        headline: String,
        subline: String,
        accent: Brand.Colour,
        house: Bool,
        tint: LabelTint,
        position: StillTextPosition,
        shadow: Bool,
        safeArea: SafeArea = .none
    ) -> CGImage? {
        let title = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = subline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !caption.isEmpty else { return nil }

        return draw(targetSize: targetSize) { size in
            let content = FrameRenderer.contentRect(targetSize: size, safeArea: safeArea)
            let side = (size.width * FrameRenderer.sideMarginFraction).rounded()
            let colour = house
                ? Brand.knochen.nsColor
                : NSColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)

            // The foot is placed first: it decides how much room the headline
            // has, rather than the other way round.
            let footTop = drawFoot(
                size: size, content: content, side: side,
                primary: caption, secondary: "",
                accent: house ? accent : Brand.Colour(red: tint.red, green: tint.green, blue: tint.blue),
                house: house, shadow: shadow
            )

            guard !title.isEmpty else { return }

            let edge = (size.height * 0.085).rounded()
            let floor = (footTop ?? content.minY) + edge * 0.6
            let ceiling = content.maxY - edge

            let nominal = min(size.width * 0.135, size.height * 0.10).rounded()
            let fitted = fit(
                title.uppercased(),
                nominal: nominal,
                available: size.width - side * 2,
                room: ceiling - floor,
                house: house
            )
            guard !fitted.lines.isEmpty else { return }

            let font = leadFace(fitted.size, house: house)
            let kern = leadKern(fitted.size, house: house)
            let caps = Typography.capBox(font)
            let lineGap = (fitted.size * 0.12).rounded()
            let blockHeight = CGFloat(fitted.lines.count) * caps.capHeight
                + CGFloat(fitted.lines.count - 1) * lineGap

            var blockTop: CGFloat
            switch position {
            case .top: blockTop = ceiling
            case .centre: blockTop = ((floor + ceiling) / 2 + blockHeight / 2).rounded()
            case .bottom: blockTop = floor + blockHeight
            }
            blockTop = min(max(blockTop, floor + blockHeight), ceiling)

            // Drawn top line first, walking down.
            var baselineTop = blockTop
            for line in fitted.lines {
                let attributed = capsLine(line, font: font, kern: kern, colour: colour, shadow: shadow)
                let width = Typography.advance(of: attributed, kern: kern)
                attributed.draw(at: NSPoint(
                    x: ((size.width - width) / 2).rounded(),
                    y: caps.origin(fieldBottom: baselineTop - caps.capHeight, padBottom: 0).rounded()
                ))
                baselineTop -= caps.capHeight + lineGap
            }
        }
    }

    // MARK: - End card

    /// The card that closes a post: the wordmark in the sticker's own
    /// arrangement — first line plain, second in a field of the accent — with
    /// the address under a rule at the foot.
    static func endCard(
        targetSize: CGSize,
        wordmarkTop: String,
        wordmarkBar: String,
        address: String,
        note: String,
        accent: Brand.Colour,
        safeArea: SafeArea = .none
    ) -> CGImage? {
        let top = wordmarkTop.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let bar = wordmarkBar.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let line = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let footnote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty || !bar.isEmpty || !line.isEmpty else { return nil }

        return draw(targetSize: targetSize) { size in
            let content = FrameRenderer.contentRect(targetSize: size, safeArea: safeArea)
            let side = (size.width * FrameRenderer.sideMarginFraction).rounded()

            let footTop = drawFoot(
                size: size, content: content, side: side,
                primary: line, secondary: footnote,
                accent: accent, house: true, shadow: false
            )

            guard !top.isEmpty || !bar.isEmpty else { return }

            // The bar's padding is part of its width, so it is measured into
            // the fit rather than discovered after the fact.
            let nominal = min(size.width * 0.145, size.height * 0.115).rounded()
            let padRatio: CGFloat = 0.32
            let wordSize = fitSingles(
                [(top, 0), (bar, padRatio)],
                nominal: nominal,
                available: size.width - side * 2
            )

            let font = leadFace(wordSize, house: true)
            let kern = leadKern(wordSize, house: true)
            let caps = Typography.capBox(font)
            let padX = (wordSize * 0.16).rounded()
            let padY = (wordSize * 0.13).rounded()

            let topLine = top.isEmpty
                ? nil
                : capsLine(top, font: font, kern: kern, colour: Brand.knochen.nsColor, shadow: false)
            let barLine = bar.isEmpty
                ? nil
                : capsLine(bar, font: font, kern: kern, colour: accent.onAccent.nsColor, shadow: false)

            let lineGap = (wordSize * 0.12).rounded()
            let barHeight = barLine == nil ? 0 : caps.height(padTop: padY, padBottom: padY)
            let blockHeight = (topLine == nil ? 0 : caps.capHeight)
                + (topLine != nil && barLine != nil ? lineGap : 0)
                + barHeight

            // A little above centre, so the address at the foot does not read
            // as something hanging off the wordmark.
            let bottomLimit = (footTop ?? content.minY) + (size.height * 0.05).rounded()
            var cursor = (content.midY + blockHeight / 2 + content.height * 0.06).rounded()
            cursor = min(max(cursor, bottomLimit + blockHeight), content.maxY)

            if let topLine {
                cursor -= caps.capHeight
                let width = Typography.advance(of: topLine, kern: kern)
                topLine.draw(at: NSPoint(
                    x: ((size.width - width) / 2).rounded(),
                    y: caps.origin(fieldBottom: cursor, padBottom: 0).rounded()
                ))
                cursor -= lineGap
            }

            if let barLine {
                cursor -= barHeight
                let width = Typography.advance(of: barLine, kern: kern)
                let field = NSRect(
                    x: ((size.width - width) / 2 - padX).rounded(),
                    y: cursor.rounded(),
                    width: (width + padX * 2).rounded(),
                    height: barHeight.rounded()
                )
                drawBar(field, accent: accent, lineWidth: max(2, (wordSize * 0.07).rounded()))
                barLine.draw(at: NSPoint(
                    x: ((size.width - width) / 2).rounded(),
                    y: caps.origin(fieldBottom: cursor, padBottom: padY).rounded()
                ))
            }
        }
    }

    // MARK: - Shared furniture

    /// The bar: a field in the accent with a hard contour in ink, the
    /// `.balken` rule from `global.css`. The contour is what makes it read as
    /// printed rather than as a highlighter.
    private static func drawBar(_ rect: NSRect, accent: Brand.Colour, lineWidth: CGFloat) {
        let radius = (rect.height * 0.1).rounded()
        accent.nsColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let contour = NSBezierPath(
            roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            xRadius: radius, yRadius: radius
        )
        contour.lineWidth = lineWidth
        Brand.tinte.nsColor.setStroke()
        contour.stroke()
    }

    /// A mono line in the accent and a quieter serif line under it, over a hard
    /// rule — the same furniture as the bottom strip of a clip, so both cards
    /// belong to the cut they sit around.
    ///
    /// Returns the rule's own height in the canvas, so a caller knows how much
    /// room is left above it. Nil when there was nothing to draw.
    @discardableResult
    private static func drawFoot(
        size: CGSize, content: CGRect, side: CGFloat,
        primary: String, secondary: String,
        accent: Brand.Colour, house: Bool, shadow: Bool
    ) -> CGFloat? {
        guard !primary.isEmpty || !secondary.isEmpty else { return nil }

        let primarySize = max(13, (size.height * 0.019).rounded())
        let secondarySize = max(12, (primarySize * 0.92).rounded())
        let ruleWidth = max(2, (size.height * Brand.ruleFraction).rounded())
        let gap = (primarySize * 0.9).rounded()

        let primaryFont = house
            ? Typography.mono(primarySize)
            : NSFont.systemFont(ofSize: primarySize, weight: .semibold)
        let primaryKern = Typography.kern(0.18, at: primarySize)
        let primaryLine = primary.isEmpty ? nil : NSAttributedString(
            string: primary.uppercased(),
            attributes: [
                .font: primaryFont,
                // The address is the point of an end card, so it takes the
                // accent rather than the muted bone the clip strips use.
                .foregroundColor: accent.nsColor,
                .kern: primaryKern
            ]
        )
        let secondaryKern = Typography.kern(Typography.serifTracking, at: secondarySize)
        let secondaryLine = secondary.isEmpty ? nil : NSAttributedString(
            string: secondary,
            attributes: [
                .font: house
                    ? Typography.serif(secondarySize * 1.18)
                    : NSFont.systemFont(ofSize: secondarySize, weight: .regular),
                .foregroundColor: Brand.knochen.withAlpha(0.7).nsColor,
                .kern: secondaryKern
            ]
        )

        let primaryCaps = Typography.capBox(primaryFont)
        let primaryHeight = primaryLine == nil ? 0 : primaryCaps.capHeight
        let secondaryHeight = secondaryLine?.size().height ?? 0
        let footHeight = primaryHeight
            + (primaryLine != nil && secondaryLine != nil ? gap * 0.6 : 0)
            + secondaryHeight

        let bottom = content.minY + (content.height * 0.06).rounded()
        var cursor = bottom
        if let secondaryLine {
            let width = Typography.advance(of: secondaryLine, kern: secondaryKern)
            secondaryLine.draw(at: NSPoint(x: ((size.width - width) / 2).rounded(), y: cursor.rounded()))
            cursor += secondaryHeight + gap * 0.6
        }
        if let primaryLine {
            let width = Typography.advance(of: primaryLine, kern: primaryKern)
            primaryLine.draw(at: NSPoint(
                x: ((size.width - width) / 2).rounded(),
                y: primaryCaps.origin(fieldBottom: cursor, padBottom: 0).rounded()
            ))
        }

        let ruleY = (bottom + footHeight + gap).rounded()
        Brand.knochen.withAlpha(Brand.ruleAlpha).nsColor.setFill()
        NSRect(x: side, y: ruleY, width: size.width - side * 2, height: ruleWidth).fill()
        return ruleY + ruleWidth
    }

    // MARK: - Fitting

    private static func leadFace(_ size: CGFloat, house: Bool) -> NSFont {
        house ? Typography.fett(size) : NSFont.systemFont(ofSize: size, weight: .bold)
    }

    private static func leadKern(_ size: CGFloat, house: Bool) -> CGFloat {
        Typography.kern(house ? -0.045 : 0.01, at: size)
    }

    private static func capsLine(
        _ text: String, font: NSFont, kern: CGFloat, colour: NSColor, shadow: Bool
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colour,
            .kern: kern
        ]
        if shadow {
            let drop = NSShadow()
            drop.shadowColor = Brand.tinte.withAlpha(0.8).nsColor
            drop.shadowBlurRadius = font.pointSize * 0.24
            drop.shadowOffset = NSSize(width: 0, height: -font.pointSize * 0.02)
            attributes[.shadow] = drop
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// Largest size at which every one of these single lines fits the width.
    /// `slack` is extra width the line carries beyond its glyphs, as a
    /// fraction of the size — a bar's padding and contour.
    private static func fitSingles(
        _ lines: [(String, CGFloat)], nominal: CGFloat, available: CGFloat
    ) -> CGFloat {
        var size = nominal
        for (text, slack) in lines where !text.isEmpty {
            let font = leadFace(nominal, house: true)
            let kern = leadKern(nominal, house: true)
            let measured = Typography.advance(
                of: capsLine(text, font: font, kern: kern, colour: .black, shadow: false),
                kern: kern
            ) + nominal * slack
            guard measured > available, measured > 0 else { continue }
            size = min(size, (nominal * available / measured).rounded(.down))
        }
        return max(size, 12)
    }

    /// Wraps a headline and shrinks it until it fits both the width and the
    /// room left between the foot and the top of the safe area.
    private static func fit(
        _ text: String, nominal: CGFloat, available: CGFloat, room: CGFloat, house: Bool
    ) -> (size: CGFloat, lines: [String]) {
        var size = max(nominal, 14)
        while size > 14 {
            let font = leadFace(size, house: house)
            let kern = leadKern(size, house: house)
            let lines = wrap(text, font: font, kern: kern, available: available)
            let caps = Typography.capBox(font)
            let height = CGFloat(lines.count) * caps.capHeight
                + CGFloat(max(lines.count - 1, 0)) * (size * 0.12).rounded()
            if lines.count <= maximumLines, height <= room, fits(lines, font: font, kern: kern, available: available) {
                return (size, lines)
            }
            size = (size * 0.94).rounded(.down)
        }
        let font = leadFace(size, house: house)
        return (size, wrap(text, font: font, kern: leadKern(size, house: house), available: available))
    }

    private static func fits(
        _ lines: [String], font: NSFont, kern: CGFloat, available: CGFloat
    ) -> Bool {
        lines.allSatisfy {
            Typography.advance(
                of: capsLine($0, font: font, kern: kern, colour: .black, shadow: false),
                kern: kern
            ) <= available
        }
    }

    /// Greedy word wrap. A single word longer than the line is left alone —
    /// the size loop shrinks it instead of hyphenating something nobody asked
    /// to be hyphenated.
    private static func wrap(
        _ text: String, font: NSFont, kern: CGFloat, available: CGFloat
    ) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return [] }

        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            let width = Typography.advance(
                of: capsLine(candidate, font: font, kern: kern, colour: .black, shadow: false),
                kern: kern
            )
            if width <= available || current.isEmpty {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    // MARK: - Canvas

    private static func draw(targetSize: CGSize, _ body: (CGSize) -> Void) -> CGImage? {
        let width = Int(targetSize.width.rounded())
        let height = Int(targetSize.height.rounded())
        guard width > 0, height > 0 else { return nil }

        Typography.register()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        body(targetSize)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
