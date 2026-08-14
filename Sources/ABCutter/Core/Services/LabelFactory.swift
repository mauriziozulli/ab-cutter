import CoreGraphics
import CoreMedia
import Foundation

/// The finished furniture for one clip in one format: a full-canvas overlay
/// per half, holding the frame border, the label and the second line.
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
    static func overlays(
        project: ABProject,
        clip: Clip,
        format: SocialFormat
    ) async -> ClipOverlays {
        let settings = project.export
        let showsBorder = settings.showFrameBorder
        let hasText = settings.showLabels

        // Nothing to draw at all when the labels are off and the picture is
        // full bleed on both sides.
        let insetsAnything = settings.frameTreatment.isInset(before: true)
            || settings.frameTreatment.isInset(before: false)
        guard hasText || (showsBorder && insetsAnything) else { return .empty }

        let tints = await self.tints(project: project, clip: clip, format: format)

        func overlay(isBefore: Bool, tint: LabelTint) -> CGImage? {
            OverlayRenderer.overlay(
                targetSize: format.size,
                pictureRect: FrameRenderer.pictureRect(
                    targetSize: format.size,
                    treatment: settings.frameTreatment,
                    isBefore: isBefore,
                    insetScale: settings.insetScale,
                    labelPosition: settings.labelPosition
                ),
                showBorder: showsBorder,
                tint: tint,
                title: hasText ? (isBefore ? settings.beforeLabel : settings.afterLabel) : "",
                subtitle: hasText ? settings.subtitleText : "",
                style: settings.labelStyle,
                position: settings.labelPosition,
                shadow: wantsShadow(tint, mode: settings.labelShadow, style: settings.labelStyle)
            )
        }

        return ClipOverlays(
            before: overlay(isBefore: true, tint: tints.before),
            after: overlay(isBefore: false, tint: tints.after)
        )
    }

    /// Samples the picture for both halves, or returns neutral tints when the
    /// pill style makes the sampling pointless.
    private static func tints(
        project: ABProject,
        clip: Clip,
        format: SocialFormat
    ) async -> (before: LabelTint, after: LabelTint) {
        let settings = project.export
        guard settings.labelStyle == .tinted, let url = project.videoURL else {
            return (.white, .white)
        }

        // The middle of each half is representative of the stretch that label
        // is actually on screen for.
        let beforeTime = CMTime(seconds: (clip.start + clip.splitTime) / 2, preferredTimescale: 600)
        let afterTime = CMTime(seconds: (clip.splitTime + clip.end) / 2, preferredTimescale: 600)

        async let beforeSample = PaletteSampler.tint(
            videoURL: url,
            at: beforeTime,
            format: format,
            settings: settings,
            clip: clip,
            isBefore: true
        )
        async let afterSample = PaletteSampler.tint(
            videoURL: url,
            at: afterTime,
            format: format,
            settings: settings,
            clip: clip,
            isBefore: false
        )
        return await (beforeSample, afterSample)
    }

    private static func wantsShadow(_ tint: LabelTint, mode: LabelShadowMode, style: LabelStyle) -> Bool {
        // A pill already guarantees contrast; a shadow on top only muddies it.
        guard style == .tinted else { return false }
        switch mode {
        case .always: return true
        case .off: return false
        case .auto: return tint.needsShadow
        }
    }
}
