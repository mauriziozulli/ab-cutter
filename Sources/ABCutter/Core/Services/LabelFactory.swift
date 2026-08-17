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
/// Drawing is AppKit and therefore main-actor work, while sampling the picture
/// is not — keeping both behind one call means the exporter and the preview
/// ask the same way and always get the same result.
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

        let insetsAnything = look.frameTreatment.isInset(before: true)
            || look.frameTreatment.isInset(before: false)
        let strips = stripText(project: project, clip: clip)
        let anyStrip = look.showStrips && strips.hasAny

        // Nothing to draw at all when the labels and strips are off and the
        // picture is full bleed on both sides.
        guard look.showLabels || anyStrip || showsGuides
            || (look.showFrameBorder && insetsAnything) else { return .empty }

        // The house styles take their colour from the palette, so the two
        // frame decodes the sampler needs are skipped entirely.
        let tints = look.labelStyle.isHouse
            ? (before: LabelTint.white, after: LabelTint.white)
            : await self.tints(project: project, clip: clip, format: format)

        func overlay(isBefore: Bool, tint: LabelTint) -> CGImage? {
            OverlayRenderer.overlay(
                OverlayRequest(
                    targetSize: format.size,
                    layout: FrameRenderer.layout(
                        targetSize: format.size,
                        treatment: look.frameTreatment,
                        isBefore: isBefore,
                        insetScale: look.insetScale,
                        labelPosition: look.labelPosition,
                        safeArea: safeArea,
                        showStrips: anyStrip
                    ),
                    accent: look.accent.colour,
                    style: look.labelStyle,
                    tint: tint,
                    isBefore: isBefore,
                    showBorder: look.showFrameBorder,
                    title: look.showLabels
                        ? (isBefore ? look.beforeLabel : look.afterLabel)
                        : "",
                    subtitle: look.showLabels ? look.subtitleText : "",
                    position: look.labelPosition,
                    shadow: wantsShadow(tint, mode: look.labelShadow, style: look.labelStyle),
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
            before: overlay(isBefore: true, tint: tints.before),
            after: overlay(isBefore: false, tint: tints.after)
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

    /// Samples the picture for both halves, or returns neutral tints when the
    /// style makes the sampling pointless.
    private static func tints(
        project: ABProject,
        clip: Clip,
        format: SocialFormat
    ) async -> (before: LabelTint, after: LabelTint) {
        guard clip.look.labelStyle == .tinted, let url = project.videoURL else {
            return (.white, .white)
        }

        // The middle of each half is representative of the stretch that label
        // is actually on screen for. A loop shows the same picture on both
        // sides, so both samples read the same midpoint.
        let middle = clip.start + clip.duration / 2
        let beforeTime = CMTime(
            seconds: clip.kind == .loop ? middle : (clip.start + clip.splitTime) / 2,
            preferredTimescale: 600
        )
        let afterTime = CMTime(
            seconds: clip.kind == .loop ? middle : (clip.splitTime + clip.end) / 2,
            preferredTimescale: 600
        )

        async let beforeSample = PaletteSampler.tint(
            videoURL: url,
            at: beforeTime,
            format: format,
            look: clip.look,
            safeArea: project.export.safeArea(for: format),
            clip: clip,
            isBefore: true
        )
        async let afterSample = PaletteSampler.tint(
            videoURL: url,
            at: afterTime,
            format: format,
            look: clip.look,
            safeArea: project.export.safeArea(for: format),
            clip: clip,
            isBefore: false
        )
        return await (beforeSample, afterSample)
    }

    private static func wantsShadow(_ tint: LabelTint, mode: LabelShadowMode, style: LabelStyle) -> Bool {
        switch style {
        // A pill already guarantees contrast; a shadow on top only muddies it.
        case .pill: return false
        // The website puts `text-shadow: 0 2px 18px` on every line that lands
        // on a photograph, and the small type needs it more than the headline
        // does: bone at two thirds over a bright wall disappears, and the veil
        // is weakest where the strips sit — a tenth of the way in, not at the
        // very edge. So Auto means on here, and only Off turns it off.
        case .balken, .knochen:
            return mode != .off
        case .tinted:
            switch mode {
            case .always: return true
            case .off: return false
            case .auto: return tint.needsShadow
            }
        }
    }
}
