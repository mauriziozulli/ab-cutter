import SwiftUI

/// Coloured crop outlines over the full picture: one rectangle per delivery
/// format, each marking exactly the part of the film that format's export
/// keeps — through the real layout, so the safe area, the strips and the
/// clip's pan all count. The eye keeps the whole frame and sees every
/// delivery at once, without flipping the preview through the formats.
///
/// Each format holds one fixed colour so a guide is recognisable at a
/// glance, and the label sits in its own corner so stacked guides on a
/// matching aspect stay readable.
@MainActor
struct FormatGuidesOverlay: View {
    let project: ABProject
    let clip: Clip?

    var body: some View {
        GeometryReader { geometry in
            let video = project.videoNaturalSize
            if video.width > 1, video.height > 1 {
                let display = displayRect(video: video, in: geometry.size)
                ForEach(Array(project.export.formats.enumerated()), id: \.element) { index, format in
                    guide(
                        format: format,
                        rect: cropRect(format: format, video: video, display: display),
                        corner: index % 4
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - One guide

    private func guide(format: SocialFormat, rect: CGRect, corner: Int) -> some View {
        let colour = Self.colour(for: format)
        return ZStack(alignment: alignment(for: corner)) {
            Rectangle()
                .strokeBorder(colour.opacity(0.9), lineWidth: 1.5)

            Text(format.title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(colour.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                .padding(3)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }

    private func alignment(for corner: Int) -> Alignment {
        switch corner {
        case 0: .topLeading
        case 1: .topTrailing
        case 2: .bottomLeading
        default: .bottomTrailing
        }
    }

    /// Every format keeps its colour across sessions, so the guides can be
    /// read without their labels once they are familiar.
    static func colour(for format: SocialFormat) -> Color {
        let rgb: RGBColor
        switch format {
        case .portrait45: rgb = .rost
        case .landscape169: rgb = .ocker
        case .portrait916: rgb = .staubblau
        case .square11: rgb = .verdigris
        }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    // MARK: - Geometry

    /// Where the video actually sits inside the player surface — the layer
    /// letterboxes with `resizeAspect`, so the guides must too.
    private func displayRect(video: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / video.width, container.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The visible part of the film in `format`'s export, mapped into the
    /// displayed picture. The export scales the film to fill the layout's
    /// picture rect, so what survives is decided by that rect's aspect —
    /// not the canvas's — and by the clip's pan.
    private func cropRect(format: SocialFormat, video: CGSize, display: CGRect) -> CGRect {
        let look = clip?.look ?? project.clips.first?.look ?? ClipLook()
        let picture = FrameRenderer.layout(
            targetSize: format.size,
            inset: true,
            insetScale: look.insetScale,
            safeArea: project.export.safeArea(for: format),
            showStrips: look.showStrips
        ).picture

        guard picture.width > 0, picture.height > 0, look.fitMode == .fill else {
            // Fit mode letterboxes instead of cropping: the whole film is in
            // every delivery, and the honest guide is the picture's edge.
            return display
        }

        let scale = max(picture.width / video.width, picture.height / video.height)
        let visibleWidth = min(picture.width / (video.width * scale), 1)
        let visibleHeight = min(picture.height / (video.height * scale), 1)

        let panX = min(max(clip?.panX ?? 0, -1), 1)
        let panY = min(max(clip?.panY ?? 0, -1), 1)
        // The renderer pans in Core Image coordinates, which run bottom-up;
        // the view runs top-down, so the vertical pan flips sign here.
        let x = (1 - visibleWidth) / 2 * (1 + panX)
        let y = (1 - visibleHeight) / 2 * (1 - panY)

        return CGRect(
            x: display.minX + x * display.width,
            y: display.minY + y * display.height,
            width: visibleWidth * display.width,
            height: visibleHeight * display.height
        )
    }
}
