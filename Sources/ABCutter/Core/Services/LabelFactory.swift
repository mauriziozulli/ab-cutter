import CoreGraphics
import CoreMedia
import Foundation

/// Produces the finished before/after label images for one clip in one format.
///
/// Drawing is AppKit and therefore main-actor work, while sampling the picture
/// is not — keeping both behind one call means the exporter and the preview
/// ask for labels the same way and always get the same result.
@MainActor
enum LabelFactory {
    static func labels(
        project: ABProject,
        clip: Clip,
        format: SocialFormat
    ) async -> (before: CGImage?, after: CGImage?) {
        let settings = project.export
        guard settings.showLabels else { return (nil, nil) }

        switch settings.labelStyle {
        case .pill:
            return (
                LabelRenderer.pill(text: settings.beforeLabel, targetSize: format.size),
                LabelRenderer.pill(text: settings.afterLabel, targetSize: format.size)
            )

        case .tinted:
            guard let url = project.videoURL else { return (nil, nil) }

            // The middle of each half is representative of the stretch that
            // label is actually on screen for.
            let beforeTime = CMTime(seconds: (clip.start + clip.splitTime) / 2, preferredTimescale: 600)
            let afterTime = CMTime(seconds: (clip.splitTime + clip.end) / 2, preferredTimescale: 600)

            async let beforeSample = PaletteSampler.tint(
                videoURL: url,
                at: beforeTime,
                format: format,
                fitMode: settings.fitMode,
                panX: clip.panX,
                panY: clip.panY,
                labelPosition: settings.labelPosition
            )
            async let afterSample = PaletteSampler.tint(
                videoURL: url,
                at: afterTime,
                format: format,
                fitMode: settings.fitMode,
                panX: clip.panX,
                panY: clip.panY,
                labelPosition: settings.labelPosition
            )
            let (beforeTint, afterTint) = await (beforeSample, afterSample)

            func wantsShadow(_ tint: LabelTint) -> Bool {
                switch settings.labelShadow {
                case .always: true
                case .off: false
                case .auto: tint.needsShadow
                }
            }

            return (
                LabelRenderer.tinted(
                    text: settings.beforeLabel,
                    targetSize: format.size,
                    tint: beforeTint,
                    shadow: wantsShadow(beforeTint)
                ),
                LabelRenderer.tinted(
                    text: settings.afterLabel,
                    targetSize: format.size,
                    tint: afterTint,
                    shadow: wantsShadow(afterTint)
                )
            )
        }
    }
}
