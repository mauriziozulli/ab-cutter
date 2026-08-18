import AppKit
import SwiftUI

/// A small, deliberately flat set of tokens so the app reads as one surface
/// rather than a pile of default controls.
enum Theme {
    static let panelBackground = Color(nsColor: .underPageBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let accent = Color.accentColor

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

    static let cornerRadius: CGFloat = 8
    static let rowSpacing: CGFloat = 8
    static let panelPadding: CGFloat = 12
}

extension View {
    /// A grouped block with a title, used for every side-panel section.
    func abSection(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            self
        }
    }

    func abCard() -> some View {
        padding(10)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

/// Monospaced digits keep timecode fields from jittering as they count.
extension Text {
    func timecodeStyle(size: CGFloat = 12) -> Text {
        font(.system(size: size, weight: .medium, design: .monospaced))
    }
}
