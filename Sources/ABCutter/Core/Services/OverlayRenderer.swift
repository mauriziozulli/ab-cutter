import AppKit
import CoreGraphics
import Foundation

/// Everything drawn over one half of a clip. Gathered into a struct because
/// the furniture grew past the point where a parameter list stays readable —
/// and because the exporter and the preview must pass the identical thing.
struct OverlayRequest {
    var targetSize: CGSize
    var layout: FrameRenderer.PlayoutLayout
    /// This side's colour — the border and the type carry it together, which
    /// is what makes the switch legible: white to blue is one event, not two.
    var colour: Brand.Colour
    var isBefore: Bool
    var title: String = ""
    var subtitle: String = ""
    /// The mono strips. Empty corners are simply left clear.
    var stripTopLeft: String = ""
    var stripTopRight: String = ""
    var stripBottomLeft: String = ""
    var stripBottomRight: String = ""
    var safeArea: SafeArea = .none
    var guides: Bool = false
}

/// Draws the full-canvas furniture for one half of a clip: the two mono
/// strips with their rules, the frame border in the side's colour, the small
/// before/after label in the same colour, and the quieter second line.
///
/// The design is fixed; only the two side colours are free. Border and type
/// share the colour on purpose — the switch then reads as one event.
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
        let drawsBorder = request.layout.isInset
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

    /// A thin line around the inset picture, in this side's colour.
    private static func drawBorder(_ request: OverlayRequest) {
        let lineWidth = max(2, (request.targetSize.height * 0.0022).rounded())
        let path = NSBezierPath(rect: request.layout.picture.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2))
        path.lineWidth = lineWidth
        request.colour.nsColor.withAlphaComponent(0.92).setStroke()
        path.stroke()
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
            let attributes = monoAttributes(size: fontSize)
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

    private static func monoAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        // Blurred nearly a full em, rather than the website's half. Its own
        // strips sit hard against the canvas edge, deep in the veil; these sit
        // a tenth of the way in, where a bright wall can still swallow bone at
        // two thirds.
        [
            .font: Typography.mono(size),
            .foregroundColor: Brand.leise.nsColor,
            .kern: Typography.kern(Typography.monoTracking, at: size),
            .shadow: softShadow(radius: size * 0.9)
        ]
    }

    // MARK: - The label

    private static func drawLabel(_ request: OverlayRequest, heading: String, caption: String) {
        guard !heading.isEmpty || !caption.isEmpty else { return }

        let size = request.targetSize
        let band = request.layout.labelBand

        // Small type, by request — the label is a caption on the cut, not a
        // poster line. Still sized against the band as well as the canvas, so
        // the strips taking their share never pushes it out of its space.
        let ratio: CGFloat = caption.isEmpty ? 0.52 : 0.34
        let ceiling = band.height > 0 ? band.height * ratio : size.height
        let titleSize = max(15, min((size.height * 0.024).rounded(), ceiling.rounded()))
        let captionSize = max(11, (titleSize * 0.6).rounded())
        let gap = (titleSize * 0.4).rounded()

        let titleFont = Typography.fett(titleSize)
        let titleKern = Typography.kern(0.06, at: titleSize)
        let titleLine = heading.isEmpty ? nil : NSAttributedString(
            string: heading.uppercased(),
            attributes: [
                .font: titleFont,
                .foregroundColor: request.colour.nsColor,
                .kern: titleKern,
                .shadow: softShadow(radius: titleSize * 0.5)
            ]
        )
        let captionKern = Typography.kern(Typography.serifTracking, at: captionSize)
        let captionLine = caption.isEmpty ? nil : NSAttributedString(
            string: caption,
            attributes: [
                .font: Typography.serif(captionSize * 1.18),
                .foregroundColor: request.colour.nsColor.withAlphaComponent(0.82),
                .kern: captionKern,
                .shadow: softShadow(radius: captionSize * 0.8)
            ]
        )

        let caps = Typography.capBox(titleFont)
        let titleWidth = titleLine.map { Typography.advance(of: $0, kern: titleKern) } ?? 0
        let captionMeasure = captionLine?.size() ?? .zero
        let titleHeight = titleLine == nil ? 0 : caps.capHeight
        let blockHeight = titleHeight
            + (titleLine != nil && captionLine != nil ? gap : 0)
            + captionMeasure.height
        let blockWidth = max(titleWidth, captionMeasure.width)
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

        // The caption sits below the heading, so it is drawn first.
        var cursor = blockBottom
        if let captionLine {
            let width = Typography.advance(of: captionLine, kern: captionKern)
            captionLine.draw(
                at: NSPoint(x: ((size.width - width) / 2).rounded(), y: cursor.rounded())
            )
            cursor += captionMeasure.height + gap
        }
        if let titleLine {
            titleLine.draw(at: NSPoint(
                x: ((size.width - titleWidth) / 2).rounded(),
                y: caps.origin(fieldBottom: cursor, padBottom: 0).rounded()
            ))
        }
    }

    /// The website's `text-shadow: 0 2px 18px rgba(16, 16, 20, .8)`, restated:
    /// ink rather than black, and offset a little downwards so it reads as
    /// weight under the type rather than as a plate behind it.
    private static func softShadow(radius: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = Brand.tinte.withAlpha(0.8).nsColor
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = NSSize(width: 0, height: -radius * 0.12)
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
    var hasStripText: Bool {
        !stripTopLeft.isEmpty || !stripTopRight.isEmpty
            || !stripBottomLeft.isEmpty || !stripBottomRight.isEmpty
    }
}
