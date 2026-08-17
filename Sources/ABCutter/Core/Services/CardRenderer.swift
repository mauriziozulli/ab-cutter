import AppKit
import CoreGraphics
import Foundation

/// The two still cards: the one that opens a post and the one that closes it.
///
/// Separate from `OverlayRenderer` because a card carries a sentence and a
/// wordmark, while a clip label carries a single word — they share the
/// palette and the faces, not the layout.
@MainActor
enum CardRenderer {
    // MARK: - Title card

    /// A large wrapping headline with an optional quieter line under it.
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
            let textWidth = size.width - side * 2

            let titleSize = max(28, (size.height * 0.072).rounded())
            let captionSize = max(14, (titleSize * 0.34).rounded())
            let gap = (titleSize * 0.4).rounded()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineHeightMultiple = 0.96

            let colour = house
                ? Brand.knochen.nsColor
                : NSColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
            // The quieter line takes the accent, the way a kicker does on the
            // website's detail layer.
            let captionColour = house
                ? accent.nsColor
                : colour.withAlphaComponent(0.85)

            var titleAttributes: [NSAttributedString.Key: Any] = [
                .font: house ? Typography.fett(titleSize) : NSFont.systemFont(ofSize: titleSize, weight: .bold),
                .foregroundColor: colour,
                .paragraphStyle: paragraph,
                .kern: Typography.kern(house ? -0.045 : 0.01, at: titleSize)
            ]
            var captionAttributes: [NSAttributedString.Key: Any] = [
                .font: house ? Typography.mono(captionSize) : NSFont.systemFont(ofSize: captionSize, weight: .medium),
                .foregroundColor: captionColour,
                .paragraphStyle: paragraph,
                .kern: Typography.kern(house ? Typography.monoTracking : 0.05, at: captionSize)
            ]
            if shadow {
                titleAttributes[.shadow] = shadowBox(titleSize * 0.22)
                captionAttributes[.shadow] = shadowBox(captionSize * 0.9)
            }

            let titleText = title.isEmpty
                ? nil
                : NSAttributedString(string: house ? title.uppercased() : title, attributes: titleAttributes)
            let captionText = caption.isEmpty
                ? nil
                : NSAttributedString(
                    string: house ? caption.uppercased() : caption,
                    attributes: captionAttributes
                )

            let bounds = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
            let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            let titleHeight = titleText?.boundingRect(with: bounds, options: options).height.rounded(.up) ?? 0
            let captionHeight = captionText?.boundingRect(with: bounds, options: options).height.rounded(.up) ?? 0
            let blockHeight = titleHeight + (titleText != nil && captionText != nil ? gap : 0) + captionHeight

            let edge = (size.height * 0.085).rounded()
            let blockTop: CGFloat
            switch position {
            case .top: blockTop = content.maxY - edge
            case .centre: blockTop = (size.height + blockHeight) / 2
            case .bottom: blockTop = content.minY + edge + blockHeight
            }

            // `usesLineFragmentOrigin` flows text downward from the top of the rect.
            var cursor = blockTop
            if let titleText {
                titleText.draw(
                    with: CGRect(x: side, y: cursor - titleHeight, width: textWidth, height: titleHeight),
                    options: options
                )
                cursor -= titleHeight + gap
            }
            if let captionText {
                captionText.draw(
                    with: CGRect(x: side, y: cursor - captionHeight, width: textWidth, height: captionHeight),
                    options: options
                )
            }
        }
    }

    // MARK: - End card

    /// The card that closes a post: the wordmark in the sticker's own
    /// arrangement — first line plain, second line in a field of the accent —
    /// with the address under a rule at the foot.
    ///
    /// Everything here is fitted to the canvas rather than set at a fixed
    /// size, because the wordmark is the widest thing the app draws and a 4:5
    /// card is 1080 across whatever the words are.
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
            let available = size.width - side * 2

            // The bar's own padding is part of its width, so it is measured
            // into the fit rather than discovered afterwards.
            let nominal = min(size.width * 0.145, size.height * 0.115).rounded()
            let wordSize = fittedSize(
                lines: [(top, 0.0), (bar, 0.26)],
                nominal: nominal,
                available: available
            )
            let padX = (wordSize * 0.13).rounded()
            let padTop = (wordSize * 0.14).rounded()
            let padBottom = (wordSize * 0.12).rounded()

            let topLine = top.isEmpty ? nil : wordmarkLine(top, size: wordSize, colour: Brand.knochen.nsColor)
            let barLine = bar.isEmpty ? nil : wordmarkLine(bar, size: wordSize, colour: accent.onAccent.nsColor)

            let topMeasure = topLine?.size() ?? .zero
            let barMeasure = barLine?.size() ?? .zero
            let barHeight = barLine == nil ? 0 : barMeasure.height + padTop + padBottom
            let lineGap = (wordSize * 0.1).rounded()
            let blockHeight = topMeasure.height
                + (topLine != nil && barLine != nil ? lineGap : 0)
                + barHeight

            // The wordmark sits a little above the middle, so the address at
            // the foot does not look like an afterthought hanging off it.
            var cursor = (content.midY + blockHeight / 2 + content.height * 0.06).rounded()

            if let topLine {
                cursor -= topMeasure.height
                topLine.draw(at: NSPoint(x: ((size.width - topMeasure.width) / 2).rounded(), y: cursor.rounded()))
                cursor -= lineGap
            }
            if let barLine {
                cursor -= barHeight
                let field = NSRect(
                    x: ((size.width - barMeasure.width) / 2 - padX).rounded(),
                    y: cursor.rounded(),
                    width: (barMeasure.width + padX * 2).rounded(),
                    height: barHeight.rounded()
                )
                let radius = (field.height * 0.1).rounded()
                accent.nsColor.setFill()
                NSBezierPath(roundedRect: field, xRadius: radius, yRadius: radius).fill()

                let contourWidth = max(2, (wordSize * 0.07).rounded())
                let contour = NSBezierPath(
                    roundedRect: field.insetBy(dx: contourWidth / 2, dy: contourWidth / 2),
                    xRadius: radius, yRadius: radius
                )
                contour.lineWidth = contourWidth
                Brand.tinte.nsColor.setStroke()
                contour.stroke()

                barLine.draw(at: NSPoint(
                    x: ((size.width - barMeasure.width) / 2).rounded(),
                    y: (cursor + padBottom).rounded()
                ))
            }

            drawFoot(
                size: size, content: content, side: side,
                address: line, note: footnote, accent: accent
            )
        }
    }

    /// Address and note at the foot, over a hard rule — the same furniture as
    /// the bottom strip of a clip, so a post's last image belongs to the cut
    /// that came before it.
    private static func drawFoot(
        size: CGSize, content: CGRect, side: CGFloat,
        address: String, note: String, accent: Brand.Colour
    ) {
        guard !address.isEmpty || !note.isEmpty else { return }

        let addressSize = max(13, (size.height * 0.019).rounded())
        let noteSize = max(12, (addressSize * 0.92).rounded())
        let ruleWidth = max(2, (size.height * Brand.ruleFraction).rounded())
        let gap = (addressSize * 0.9).rounded()

        let addressLine = address.isEmpty ? nil : NSAttributedString(
            string: address.uppercased(),
            attributes: [
                .font: Typography.mono(addressSize),
                // The address is the point of the card, so it takes the accent
                // rather than the muted bone the strips use.
                .foregroundColor: accent.nsColor,
                .kern: Typography.kern(0.18, at: addressSize)
            ]
        )
        let noteLine = note.isEmpty ? nil : NSAttributedString(
            string: note,
            attributes: [
                .font: Typography.serif(noteSize * 1.18),
                .foregroundColor: Brand.knochen.withAlpha(0.7).nsColor,
                .kern: Typography.kern(Typography.serifTracking, at: noteSize)
            ]
        )

        let addressMeasure = addressLine?.size() ?? .zero
        let noteMeasure = noteLine?.size() ?? .zero
        let footHeight = addressMeasure.height
            + (addressLine != nil && noteLine != nil ? gap * 0.5 : 0)
            + noteMeasure.height

        let bottom = content.minY + (content.height * 0.06).rounded()
        var cursor = bottom
        if let noteLine {
            noteLine.draw(at: NSPoint(x: ((size.width - noteMeasure.width) / 2).rounded(), y: cursor.rounded()))
            cursor += noteMeasure.height + gap * 0.5
        }
        if let addressLine {
            addressLine.draw(at: NSPoint(
                x: ((size.width - addressMeasure.width) / 2).rounded(),
                y: cursor.rounded()
            ))
        }

        Brand.knochen.withAlpha(Brand.ruleAlpha).nsColor.setFill()
        NSRect(
            x: side,
            y: (bottom + footHeight + gap).rounded(),
            width: size.width - side * 2,
            height: ruleWidth
        ).fill()
    }

    // MARK: - Helpers

    /// Largest size at which every line still fits the available width.
    /// `slack` is the extra width a line carries beyond its glyphs, as a
    /// fraction of the size — the bar's padding and contour.
    private static func fittedSize(
        lines: [(String, CGFloat)], nominal: CGFloat, available: CGFloat
    ) -> CGFloat {
        var size = nominal
        for (text, slack) in lines where !text.isEmpty {
            let measured = wordmarkLine(text, size: nominal, colour: .black).size().width
                + nominal * slack
            guard measured > available, measured > 0 else { continue }
            size = min(size, (nominal * available / measured).rounded(.down))
        }
        return max(size, 12)
    }

    private static func wordmarkLine(_ text: String, size: CGFloat, colour: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: Typography.fett(size),
            .foregroundColor: colour,
            .kern: Typography.kern(Typography.fettTracking, at: size)
        ])
    }

    private static func shadowBox(_ radius: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.6)
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = .zero
        return shadow
    }

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
