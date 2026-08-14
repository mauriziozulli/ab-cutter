import AppKit
import CoreGraphics
import Foundation

/// Draws the full-canvas furniture for one half of a clip: the frame border,
/// the before/after label, and the quieter second line under it.
///
/// One transparent image per half is cheaper to reason about than a stack of
/// Core Image steps, and AppKit lays out type far better than CIFilters do.
/// Drawing is main-actor work; the exporter only ever receives the result.
@MainActor
enum OverlayRenderer {
    static func overlay(
        targetSize: CGSize,
        pictureRect: CGRect,
        showBorder: Bool,
        tint: LabelTint,
        title: String,
        subtitle: String,
        style: LabelStyle,
        position: LabelPosition,
        shadow: Bool
    ) -> CGImage? {
        let width = Int(targetSize.width.rounded())
        let height = Int(targetSize.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let isInset = pictureRect != CGRect(origin: .zero, size: targetSize)
        let drawsBorder = showBorder && isInset
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard drawsBorder || !heading.isEmpty || !caption.isEmpty else { return nil }

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

        let colour: NSColor = style == .pill
            ? .white
            : NSColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)

        if drawsBorder {
            let lineWidth = max(2, (targetSize.height * 0.0022).rounded())
            let path = NSBezierPath(rect: pictureRect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2))
            path.lineWidth = lineWidth
            colour.withAlphaComponent(style == .pill ? 0.75 : 0.92).setStroke()
            path.stroke()
        }

        drawText(
            heading: heading,
            caption: caption,
            targetSize: targetSize,
            pictureRect: pictureRect,
            colour: colour,
            style: style,
            position: position,
            shadow: shadow
        )

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static func drawText(
        heading: String,
        caption: String,
        targetSize: CGSize,
        pictureRect: CGRect,
        colour: NSColor,
        style: LabelStyle,
        position: LabelPosition,
        shadow: Bool
    ) {
        guard !heading.isEmpty || !caption.isEmpty else { return }

        let titleSize = max(20, (targetSize.height * 0.038).rounded())
        let captionSize = max(12, (titleSize * 0.46).rounded())
        let gap = (titleSize * 0.32).rounded()

        var titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: titleSize, weight: .bold),
            .foregroundColor: colour,
            .kern: titleSize * 0.06
        ]
        var captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: captionSize, weight: .medium),
            .foregroundColor: colour.withAlphaComponent(0.82),
            .kern: captionSize * 0.04
        ]
        if shadow {
            // Soft and centred, so it reads as weight rather than as a plate.
            let dropShadow = NSShadow()
            dropShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.55)
            dropShadow.shadowBlurRadius = titleSize * 0.3
            dropShadow.shadowOffset = .zero
            titleAttributes[.shadow] = dropShadow
            captionAttributes[.shadow] = dropShadow
        }

        let titleLine = heading.isEmpty
            ? nil
            : NSAttributedString(string: heading.uppercased(), attributes: titleAttributes)
        let captionLine = caption.isEmpty
            ? nil
            : NSAttributedString(string: caption, attributes: captionAttributes)

        let titleMeasure = titleLine?.size() ?? .zero
        let captionMeasure = captionLine?.size() ?? .zero
        let blockHeight = titleMeasure.height
            + (titleLine != nil && captionLine != nil ? gap : 0)
            + captionMeasure.height
        let blockWidth = max(titleMeasure.width, captionMeasure.width)
        guard blockHeight > 0, blockWidth > 0 else { return }

        let band = FrameRenderer.labelBand(
            targetSize: targetSize,
            pictureRect: pictureRect,
            position: position
        )
        let minimumMargin = (targetSize.height * FrameRenderer.labelMarginFraction * 0.6).rounded()

        // Centre the block in its band, then keep it clear of the canvas edge.
        var blockBottom = band.midY - blockHeight / 2
        blockBottom = max(blockBottom, minimumMargin)
        blockBottom = min(blockBottom, targetSize.height - minimumMargin - blockHeight)

        if style == .pill {
            let padX = (titleSize * 0.9).rounded()
            let padY = (titleSize * 0.45).rounded()
            let plate = NSRect(
                x: ((targetSize.width - blockWidth) / 2 - padX).rounded(),
                y: (blockBottom - padY).rounded(),
                width: (blockWidth + padX * 2).rounded(),
                height: (blockHeight + padY * 2).rounded()
            )
            let radius = min(plate.height / 2, 26)
            NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
            NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
        }

        // The caption sits below the heading, so it is drawn first.
        var cursor = blockBottom
        if let captionLine {
            captionLine.draw(
                at: NSPoint(x: ((targetSize.width - captionMeasure.width) / 2).rounded(), y: cursor.rounded())
            )
            cursor += captionMeasure.height + gap
        }
        if let titleLine {
            titleLine.draw(
                at: NSPoint(x: ((targetSize.width - titleMeasure.width) / 2).rounded(), y: cursor.rounded())
            )
        }
    }
}
