import AppKit
import SwiftUI

/// A small, deliberately flat set of tokens so the app reads as one surface
/// rather than a pile of default controls.
enum Theme {
    static let panelBackground = Color(nsColor: .underPageBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let accent = Color.accentColor

    /// Before / after identity colours, reused across the timeline and panels.
    static let beforeTint = Color(red: 0.62, green: 0.64, blue: 0.68)
    static let afterTint = Color(red: 0.20, green: 0.62, blue: 0.94)

    static let clipTint = Color(red: 0.98, green: 0.72, blue: 0.24)

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
