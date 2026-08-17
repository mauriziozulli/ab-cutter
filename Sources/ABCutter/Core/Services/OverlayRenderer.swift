import AppKit
import CoreGraphics
import Foundation

/// Everything drawn over one half of a clip. Gathered into a struct because
/// the furniture grew past the point where a parameter list stays readable —
/// and because the exporter and the preview must pass the identical thing.
struct OverlayRequest {
    var targetSize: CGSize
    var layout: FrameRenderer.PlayoutLayout
    var accent: Brand.Colour
    var style: LabelStyle
    /// Only consulted by the two styles that read their colour off the picture.
    var tint: LabelTint = .white
    var isBefore: Bool
    var showBorder: Bool
    var title: String = ""
    var subtitle: String = ""
    var position: LabelPosition = .bottom
    var shadow: Bool = false
    /// The mono strips. Empty corners are simply left clear.
    var stripTopLeft: String = ""
    var stripTopRight: String = ""
    var stripBottomLeft: String = ""
    var stripBottomRight: String = ""
    var safeArea: SafeArea = .none
    var guides: Bool = false
}

/// Draws the full-canvas furniture for one half of a clip: the two mono
/// strips with their rules, the frame border, the before/after label, and the
/// quieter second line under it.
///
/// The arrangement is the website's, section for section: a rule and a line of
/// mono at each end — "the frame of the sticker, unfolded", as `global.css`
/// puts it — with the heavy grotesque between them, and the accent carried in
/// a hard-edged bar rather than in a tint sampled from the picture.
///
/// One transparent image per half is cheaper to reason about than a stack of
/// Core Image steps, and AppKit lays out type far better than CIFilters do.
@MainActor
enum OverlayRenderer {
    static func overlay(_ request: OverlayRequest) -> CGImage? {
        let size = request.targetSize
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let heading = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = request.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let drawsBorder = request.showBorder && request.layout.isInset
        let drawsStrips = request.layout.hasStrips && request.hasStripText
        let drawsGuides = request.guides && !request.safeArea.clamped.isEmpty
        guard drawsBorder || drawsStrips || drawsGuides || !heading.isEmpty || !caption.isEmpty else {
            return nil
        }

        Typography.register()

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
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        if drawsBorder { drawBorder(request) }
        if drawsStrips { drawStrips(request) }
        drawLabel(request, heading: heading, caption: caption)
        if drawsGuides { drawGuides(targetSize: size, safeArea: request.safeArea) }

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    // MARK: - Border

    /// A hairline around the inset picture, in the accent. On the website the
    /// same contour is what makes the bar read as a printed field rather than
    /// as a highlight.
    private static func drawBorder(_ request: OverlayRequest) {
        let lineWidth = max(2, (request.targetSize.height * 0.0022).rounded())
        let colour = borderColour(request)
        let path = NSBezierPath(rect: request.layout.picture.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2))
        path.lineWidth = lineWidth
        colour.setStroke()
        path.stroke()
    }

    private static func borderColour(_ request: OverlayRequest) -> NSColor {
        switch request.style {
        case .balken, .knochen:
            return request.accent.nsColor.withAlphaComponent(0.92)
        case .pill:
            return NSColor.white.withAlphaComponent(0.75)
        case .tinted:
            return NSColor(
                srgbRed: request.tint.red,
                green: request.tint.green,
                blue: request.tint.blue,
                alpha: 0.92
            )
        }
    }

    // MARK: - The two strips

    /// Mono, uppercase, wide tracking, bone at two thirds — and one hard rule
    /// per strip, on the side that faces the picture.
    private static func drawStrips(_ request: OverlayRequest) {
        let size = request.targetSize
        let ruleWidth = max(2, (size.height * Brand.ruleFraction).rounded())
        let rule = Brand.knochen.withAlpha(Brand.ruleAlpha).nsColor

        for (strip, isTop) in [(request.layout.topStrip, true), (request.layout.bottomStrip, false)] {
            guard strip.height > 0 else { continue }
            let left = isTop ? request.stripTopLeft : request.stripBottomLeft
            let right = isTop ? request.stripTopRight : request.stripBottomRight
            guard !left.isEmpty || !right.isEmpty else { continue }

            // The rule faces the picture: under the top strip, over the bottom.
            let ruleY = isTop ? strip.minY : strip.maxY - ruleWidth
            rule.setFill()
            NSRect(x: strip.minX, y: ruleY, width: strip.width, height: ruleWidth).fill()

            let fontSize = max(11, (strip.height * 0.40).rounded())
            let attributes = monoAttributes(size: fontSize, shadow: request.shadow)
            // Centred in the space the rule leaves, so the two strips are
            // mirror images of each other rather than merely both present.
            let free = strip.height - ruleWidth
            let baseline = isTop
                ? strip.minY + ruleWidth + (free - fontSize) / 2 + fontSize * 0.16
                : strip.minY + (free - fontSize) / 2 + fontSize * 0.16

            if !left.isEmpty {
                NSAttributedString(string: left.uppercased(), attributes: attributes)
                    .draw(at: NSPoint(x: strip.minX.rounded(), y: baseline.rounded()))
            }
            if !right.isEmpty {
                let line = NSAttributedString(string: right.uppercased(), attributes: attributes)
                // The trailing letter's tracking is real space in the measured
                // width; dropping it keeps the right edge flush with the rule.
                let advance = line.size().width - Typography.kern(Typography.monoTracking, at: fontSize)
                line.draw(at: NSPoint(x: (strip.maxX - advance).rounded(), y: baseline.rounded()))
            }
        }
    }

    private static func monoAttributes(size: CGFloat, shadow: Bool) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: Typography.mono(size),
            .foregroundColor: Brand.leise.nsColor,
            .kern: Typography.kern(Typography.monoTracking, at: size)
        ]
        if shadow { attributes[.shadow] = softShadow(radius: size * 0.5) }
        return attributes
    }

    // MARK: - The label

    private static func drawLabel(_ request: OverlayRequest, heading: String, caption: String) {
        guard !heading.isEmpty || !caption.isEmpty else { return }

        let size = request.targetSize
        let band = request.layout.labelBand
        // Sized against the band as well as the canvas, so the strips taking
        // their share never pushes the word out of the space left for it.
        let ceiling = band.height > 0 ? band.height * 0.44 : size.height
        let titleSize = max(20, min((size.height * 0.038).rounded(), ceiling.rounded()))
        let captionSize = max(12, (titleSize * 0.46).rounded())
        let gap = (titleSize * 0.34).rounded()

        let house = request.style.isHouse
        let titleLine = heading.isEmpty ? nil : headingLine(request, text: heading, size: titleSize)
        let captionLine = caption.isEmpty
            ? nil
            : NSAttributedString(string: caption, attributes: captionAttributes(request, size: captionSize))

        // A bar is a field, not just glyphs: it needs the padding measured
        // into its height or the rule below it lands on the contour.
        let barPadX = house && request.wantsBar ? (titleSize * 0.13).rounded() : 0
        let barPadTop = house && request.wantsBar ? (titleSize * 0.14).rounded() : 0
        let barPadBottom = house && request.wantsBar ? (titleSize * 0.12).rounded() : 0

        let titleMeasure = titleLine?.size() ?? .zero
        let captionMeasure = captionLine?.size() ?? .zero
        let titleHeight = titleMeasure.height + barPadTop + barPadBottom
        let blockHeight = titleHeight
            + (titleLine != nil && captionLine != nil ? gap : 0)
            + captionMeasure.height
        let blockWidth = max(titleMeasure.width + barPadX * 2, captionMeasure.width)
        guard blockHeight > 0, blockWidth > 0 else { return }

        let content = FrameRenderer.contentRect(targetSize: size, safeArea: request.safeArea)
        let margin = (size.height * FrameRenderer.labelMarginFraction * 0.6).rounded()

        // Centre the block in its band, then keep it clear of the safe edge.
        // Where the band is too shallow to hold the type with its margins the
        // bounds would cross over, so it is centred instead of being pushed
        // out of the picture by whichever clamp ran last.
        var blockBottom = band.midY - blockHeight / 2
        let lowest = content.minY + margin
        let highest = content.maxY - margin - blockHeight
        blockBottom = highest >= lowest
            ? min(max(blockBottom, lowest), highest)
            : content.midY - blockHeight / 2

        if request.style == .pill {
            drawPill(size: size, blockBottom: blockBottom, blockWidth: blockWidth,
                     blockHeight: blockHeight, titleSize: titleSize)
        }

        // The caption sits below the heading, so it is drawn first.
        var cursor = blockBottom
        if let captionLine {
            captionLine.draw(
                at: NSPoint(x: ((size.width - captionMeasure.width) / 2).rounded(), y: cursor.rounded())
            )
            cursor += captionMeasure.height + gap
        }
        if let titleLine {
            let x = ((size.width - titleMeasure.width) / 2).rounded()
            if house, request.wantsBar {
                drawBar(
                    request,
                    around: NSRect(
                        x: x - barPadX,
                        y: cursor,
                        width: titleMeasure.width + barPadX * 2,
                        height: titleMeasure.height + barPadTop + barPadBottom
                    ),
                    lineWidth: max(2, (titleSize * 0.07).rounded())
                )
            }
            titleLine.draw(at: NSPoint(x: x, y: (cursor + barPadBottom).rounded()))
        }
    }

    /// The bar: a field in the accent with a hard contour in ink, exactly the
    /// `.balken` rule from `global.css`. The contour is what makes it read as
    /// printed rather than as a highlighter.
    private static func drawBar(_ request: OverlayRequest, around rect: NSRect, lineWidth: CGFloat) {
        let radius = (rect.height * 0.1).rounded()
        let field = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        request.accent.nsColor.setFill()
        field.fill()

        let contour = NSBezierPath(
            roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            xRadius: radius, yRadius: radius
        )
        contour.lineWidth = lineWidth
        Brand.tinte.nsColor.setStroke()
        contour.stroke()
    }

    private static func drawPill(
        size: CGSize, blockBottom: CGFloat, blockWidth: CGFloat,
        blockHeight: CGFloat, titleSize: CGFloat
    ) {
        let padX = (titleSize * 0.9).rounded()
        let padY = (titleSize * 0.45).rounded()
        let plate = NSRect(
            x: ((size.width - blockWidth) / 2 - padX).rounded(),
            y: (blockBottom - padY).rounded(),
            width: (blockWidth + padX * 2).rounded(),
            height: (blockHeight + padY * 2).rounded()
        )
        let radius = min(plate.height / 2, 26)
        NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
    }

    private static func headingLine(
        _ request: OverlayRequest, text: String, size: CGFloat
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: Typography.fett(size),
            .foregroundColor: headingColour(request),
            .kern: Typography.kern(
                request.style.isHouse ? Typography.fettTracking : 0.06,
                at: size
            )
        ]
        // A bar carries its own contrast; a shadow on it only muddies the edge.
        if request.shadow && !request.wantsBar {
            attributes[.shadow] = softShadow(radius: size * 0.3)
        }
        return NSAttributedString(string: text.uppercased(), attributes: attributes)
    }

    private static func headingColour(_ request: OverlayRequest) -> NSColor {
        switch request.style {
        case .balken:
            // In the bar the type is ink; the half without the bar is bone —
            // the wordmark's own arrangement, and the A/B reads as a snap.
            return request.wantsBar ? request.accent.onAccent.nsColor : Brand.knochen.nsColor
        case .knochen:
            return request.isBefore ? Brand.knochen.nsColor : request.accent.nsColor
        case .pill:
            return .white
        case .tinted:
            return NSColor(
                srgbRed: request.tint.red, green: request.tint.green,
                blue: request.tint.blue, alpha: 1
            )
        }
    }

    /// The counter-voice, for the quieter line under the label. Deliberately
    /// mixed case: in capitals a didone's hairlines break away.
    private static func captionAttributes(
        _ request: OverlayRequest, size: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        let colour: NSColor = request.style.isHouse
            ? Brand.knochen.withAlpha(0.82).nsColor
            : NSColor(
                srgbRed: request.tint.red, green: request.tint.green,
                blue: request.tint.blue, alpha: 0.82
            )
        var attributes: [NSAttributedString.Key: Any] = [
            .font: request.style.isHouse
                ? Typography.serif(size * 1.18)
                : NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: colour,
            .kern: Typography.kern(request.style.isHouse ? Typography.serifTracking : 0.04, at: size)
        ]
        if request.shadow { attributes[.shadow] = softShadow(radius: size * 0.6) }
        return attributes
    }

    private static func softShadow(radius: CGFloat) -> NSShadow {
        // Soft and centred, so it reads as weight rather than as a plate.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.55)
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = .zero
        return shadow
    }

    // MARK: - Guides

    /// Two dashed rules showing where the story player's own controls land.
    /// The preview asks for these; the exporter never does, so they cannot
    /// reach a delivered file.
    private static func drawGuides(targetSize: CGSize, safeArea: SafeArea) {
        let content = FrameRenderer.contentRect(targetSize: targetSize, safeArea: safeArea)
        let lineWidth = max(1.5, (targetSize.height * 0.0018).rounded())
        var dash: [CGFloat] = [lineWidth * 6, lineWidth * 5]
        NSColor(calibratedRed: 1, green: 0.82, blue: 0.2, alpha: 0.5).setStroke()

        for edge in [content.minY, content.maxY] where edge > 0.5 && edge < targetSize.height - 0.5 {
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.setLineDash(&dash, count: dash.count, phase: 0)
            path.move(to: NSPoint(x: 0, y: edge))
            path.line(to: NSPoint(x: targetSize.width, y: edge))
            path.stroke()
        }
    }
}

extension OverlayRequest {
    /// The bar belongs to the second half, the way `matters.` is the line that
    /// sits in it on the sticker.
    var wantsBar: Bool { style == .balken && !isBefore }

    var hasStripText: Bool {
        !stripTopLeft.isEmpty || !stripTopRight.isEmpty
            || !stripBottomLeft.isEmpty || !stripBottomRight.isEmpty
    }
}
