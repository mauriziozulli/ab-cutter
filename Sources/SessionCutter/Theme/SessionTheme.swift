import SwiftUI

/// What things *are* on the timeline. The chrome itself comes from the Studio
/// faceplate; these only name the two sides and the markers.
enum Tint {
    /// The original sound: Rost, as in AB Cutter.
    static let original = Color(red: 0.71, green: 0.34, blue: 0.18)
    /// The final mix: blue.
    static let mix = Color(red: 0.20, green: 0.62, blue: 0.94)
    static let still = StudioStyle.studio.counterpoint
    static let record = StudioStyle.studio.error
}

/// A heading inside a surface.
struct SectionLabel: View {
    let text: String
    @Environment(\.studioStyle) private var style

    init(text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(style.ui(AppType.small + 0.5, weight: .semibold))
            .foregroundStyle(style.muted)
    }
}

/// A raised group with a heading above it.
struct Panel<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.studioStyle) private var style

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: title)
            VStack(alignment: .leading, spacing: 10) { content }
                .studioCard(style, padding: 12)
        }
    }
}

/// A quiet line of explanation under a control.
struct Hint: View {
    let text: String
    @Environment(\.studioStyle) private var style

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(style.ui(AppType.small))
            .foregroundStyle(style.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum Clock {
    /// m:ss:ff at 25 fps — a recording has no timecode of its own.
    static func string(_ seconds: Double) -> String {
        let frames = Int((max(seconds, 0) * 25).rounded())
        let minutes = frames / (25 * 60)
        let secs = (frames / 25) % 60
        let rest = frames % 25
        return String(format: "%d:%02d:%02d", minutes, secs, rest)
    }
}
