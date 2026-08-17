import CoreGraphics
import CoreMedia
import Foundation

/// The finished furniture for one clip in one format: a full-canvas overlay
/// per half, holding the strips, the frame border, the label and the second
/// line.
struct ClipOverlays {
    var before: CGImage?
    var after: CGImage?

    static let empty = ClipOverlays(before: nil, after: nil)
}

/// Builds those overlays.
///
/// Drawing is AppKit and therefore main-actor work; keeping it behind one
/// call means the exporter and the preview ask the same way and always get
/// the same result. Since the design became fixed there is nothing async
/// left in here, but the callers treat it as potentially slow, which is the
/// honest contract for anything that rasterises type.
@MainActor
enum LabelFactory {
    /// `guides` marks the reserved strips with a dashed rule. The preview asks
    /// for it so the safe area can be judged against the picture; the export
    /// never does.
    static func overlays(
        project: ABProject,
        clip: Clip,
        format: SocialFormat,
        guides: Bool = false
    ) async -> ClipOverlays {
        let look = clip.look
        let safeArea = project.export.safeArea(for: format)
        let showsGuides = guides && !safeArea.isEmpty

        let strips = stripText(project: project, clip: clip)
        let anyStrip = look.showStrips && strips.hasAny

        func overlay(isBefore: Bool) -> CGImage? {
            OverlayRenderer.overlay(
                OverlayRequest(
                    targetSize: format.size,
                    layout: FrameRenderer.layout(
                        targetSize: format.size,
                        insetScale: look.insetScale,
                        safeArea: safeArea,
                        showStrips: anyStrip
                    ),
                    colour: Brand.Colour(isBefore ? look.beforeColor : look.afterColor),
                    isBefore: isBefore,
                    title: look.showLabels
                        ? (isBefore ? look.beforeLabel : look.afterLabel)
                        : "",
                    subtitle: look.showLabels ? look.subtitleText : "",
                    stripTopLeft: anyStrip ? strips.title : "",
                    stripTopRight: anyStrip ? (isBefore ? strips.beforeSource : strips.afterSource) : "",
                    stripBottomLeft: anyStrip ? strips.note : "",
                    stripBottomRight: anyStrip ? strips.address : "",
                    safeArea: safeArea,
                    guides: showsGuides
                )
            )
        }

        return ClipOverlays(
            before: overlay(isBefore: true),
            after: overlay(isBefore: false)
        )
    }

    /// What goes in the four corners.
    struct StripText {
        var title: String
        /// Which layer is heard on that half. This is the one caption an A/B
        /// actually needs, and it is the website's `einordnung` slot.
        var beforeSource: String
        var afterSource: String
        var note: String
        var address: String

        var hasAny: Bool {
            !title.isEmpty || !beforeSource.isEmpty || !afterSource.isEmpty
                || !note.isEmpty || !address.isEmpty
        }
    }

    static func stripText(project: ABProject, clip: Clip) -> StripText {
        let look = clip.look
        let given = look.stripLeft.trimmingCharacters(in: .whitespacesAndNewlines)
        return StripText(
            title: given.isEmpty ? project.name : given,
            beforeSource: project.beforeSource(for: clip)?.name ?? "",
            afterSource: project.afterSource(for: clip)?.name ?? "",
            note: look.stripNote.trimmingCharacters(in: .whitespacesAndNewlines),
            address: look.stripAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
