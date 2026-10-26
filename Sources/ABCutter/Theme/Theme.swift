import AppKit
import SwiftUI

/// The chrome tokens, now read off the Studio faceplate it shares with
/// Paranoid Projects (`StudioStyle`). The tints below still name what a clip,
/// a source or a marker *is*; the Brand palette stays what the exports wear.
enum Theme {
    private static let studio = StudioStyle.studio

    static let panelBackground = studio.bg
    static let cardBackground = studio.panel
    static let hairline = studio.line
    static let accent = studio.accent

    /// Still markers on the timeline: the cool counterpoint, so a marker never
    /// reads as a clip (ochre) or as a side of the A/B (rost, blue).
    static let stillTint = studio.counterpoint

    /// Before / after identity colours, reused across the timeline and
    /// panels: the reference side wears Rost, the mix side blue. Red against
    /// blue survives every glance; the old grey A disappeared next to the
    /// unassigned lanes, which are the ones that are *actually* grey.
    static let beforeTint = Color(red: 0.71, green: 0.34, blue: 0.18)     // Rost
    static let afterTint = Color(red: 0.20, green: 0.62, blue: 0.94)

    /// What a source *is*, as opposed to what it plays: violet marks the
    /// picture and any sound that came out of a video file, green a plain
    /// audio file. Together with the role colours above, the sources list
    /// answers both questions at a glance.
    static let videoTint = Color(red: 0.55, green: 0.44, blue: 0.78)      // Violett
    static let audioFileTint = Color(red: 0.18, green: 0.56, blue: 0.48)  // Verdigris

    /// One identity colour per clip kind, both taken from the brand family:
    /// ochre for an A/B, dust blue for a loop. The timeline, the clip list
    /// and the inspector all read these, so a glance tells the kinds apart.
    static let clipTint = Color(red: 0.85, green: 0.59, blue: 0.17)      // Ocker
    static let loopTint = Color(red: 0.43, green: 0.58, blue: 0.65)      // Staubblau

    static func tint(for kind: ClipKind) -> Color {
        kind == .loop ? loopTint : clipTint
    }

    static let cornerRadius: CGFloat = 10
    static let rowSpacing: CGFloat = 8
    static let panelPadding: CGFloat = 14
}

extension View {
    /// A grouped block with a heading, used for every side-panel section.
    /// Sentence case and quiet — the heading is a label, not a reading.
    func abSection(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: title)
            self
        }
    }

    /// A raised group: the panel surface on the bed, no border.
    func abCard() -> some View {
        modifier(CardSurface())
    }
}

private struct CardSurface: ViewModifier {
    @Environment(\.studioStyle) private var style

    func body(content: Content) -> some View {
        content.studioCard(style, padding: 12)
    }
}

/// A heading inside a surface: the label above a group of rows.
struct SectionLabel: View {
    let text: String
    @Environment(\.studioStyle) private var style

    var body: some View {
        Text(text)
            .font(style.ui(AppType.small + 0.5, weight: .semibold))
            .foregroundStyle(style.muted)
    }
}

/// Monospaced digits keep timecode fields from jittering as they count.
extension Text {
    func timecodeStyle(size: CGFloat = 12) -> Text {
        font(.system(size: size, weight: .medium).monospacedDigit())
    }
}
