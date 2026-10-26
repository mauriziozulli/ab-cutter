import SwiftUI

/// The «Studio» faceplate — the one Paranoid Projects draws itself with.
///
/// Restated from Paranoid Projects (`Studio/StudioStyle.swift` there is the source;
/// change it first and follow it here). A documented divergence from `ParanoidStyle`,
/// ``ProjectPalette`` and ``AppType``, and a larger one: the whole faceplate
/// rather than a handful of values. The shared variants are `.instrument`
/// (Paranoid QC — a measuring device: cool graphite, cyan, monospace-dominant,
/// hard 1px edges) and `.cabinet` (warm charcoal, copper), and this app used
/// the latter.
///
/// Why it moved off it. This is not a measuring tool and it is not a device
/// somebody glances at — it is the bench a cutting room is tidied at. Folders
/// of film projects get found, read, checked, archived, copied and let go, day
/// after day, often at the end of a long one. A bench that looks like a test
/// rig makes ordinary work feel more consequential than it is, and puts a 1px
/// box around every name somebody is trying to read.
///
/// Three decisions, and everything else follows from them:
///
/// 1. **Depth instead of edges.** A surface with a gradient, a top rim light
///    and a soft shadow reads as a thing; the same surface with a stroke
///    around it reads as a form field. Borders are kept for the one element
///    that is currently meant — selection and focus — where they then say
///    something.
/// 2. **Language instead of readouts.** The system face carries anything that
///    is a sentence: labels, names, buttons. Monospace is kept for what needs
///    equal character widths — paths, sizes, dates, checksums. Letter-spaced
///    uppercase is left to the window's own name, which is a mark rather than
///    a word.
/// 3. **Calm instead of density.** Rows are taller, padding is larger,
///    hairlines are rarer. What belongs together is grouped by space.
///
/// The colour follows the workflow rather than decorating it. Neutral night
/// graphite, one accent in indigo — awake, friendly, and far from every
/// judgment colour. The accent drives the controls (buttons, selection, focus)
/// and never states anything about a project: "good" is still ``passed``. The
/// ``counterpoint`` is a cool steel and belongs to what is safely elsewhere —
/// archives, copies, released sources. Warmth is reserved for ``ready``: the
/// one state the app is actually asking about.
///
/// Read it the way the shared faceplate is read, so call sites are unchanged:
///
/// ```swift
/// RootView().studioStyle()
///
/// // …and inside any view
/// @Environment(\.studioStyle) private var style
/// Text(name).foregroundStyle(style.text)
/// ```
///
/// If a second app in the family ever wants this, it moves to
/// ParanoidDesignSystem as a third variant.
struct StudioStyle: Sendable {

    // MARK: Surfaces

    /// The main working surface.
    let bg: Color
    /// Side columns, cards and panels.
    let panel: Color
    /// Hovered and selected rows, buttons.
    let raised: Color
    /// Headers, footers, control bars, status bars.
    let sunken: Color
    /// Wells, beds, control interiors.
    let deep: Color

    // MARK: Lines

    /// Region separators, and the border of the one selected thing.
    let line: Color
    /// The rare separator inside a list.
    let lineSoft: Color
    /// Gridlines inside a well.
    let grid: Color
    /// The rim light along the top edge of a raised surface.
    let hair: Color

    // MARK: Text

    /// Values and active labels.
    let text: Color
    /// Field names and inactive controls.
    let muted: Color
    /// Meta readouts, column headers, hints.
    let faint: Color

    // MARK: Accents

    /// Active, selected, primary action, focus.
    ///
    /// Never means "good" — a passed result is ``passed`` — and never states
    /// anything about a project. It belongs to the controls.
    let accent: Color
    /// The top of the accent's gradient, and its hover state.
    let accentLit: Color
    /// Secondary selection, and borders of active-but-unfocused things.
    let accentDim: Color
    /// What is safely elsewhere: archives, verified copies, released sources.
    ///
    /// Bright for a cool colour. Every status colour here is mixed to be the
    /// lit thing in its row rather than a tint of the surface — on a night
    /// graphite faceplate a dot at paper saturation reads as printed, and a
    /// status nobody's eye stops on is a status nobody reads.
    ///
    /// Cool on purpose. The one warm colour in the interface is ``ready``, and
    /// keeping it that way means a warm dot in a list always answers the same
    /// question: this is the one waiting for you.
    let counterpoint: Color
    /// Ready to be archived — the single thing this app asks for.
    ///
    /// Its own token rather than the accent. When the two were the same value,
    /// changing the accent moved a colour in the list of project dots, where a
    /// colour has a meaning that has nothing to do with buttons.
    let ready: Color

    // MARK: Judgment — constant across the family

    let passed: Color
    let warning: Color
    let error: Color
    let unchecked: Color

    // MARK: Chrome

    /// Panel title bars.
    let barHeight: CGFloat
    /// List rows (minimum).
    let rowHeight: CGFloat
    /// Status bars and column footers.
    let statusBarHeight: CGFloat
    /// Padding inside panel content.
    let contentPadding: CGFloat

    /// The two-stop vertical fade on a bar.
    let barGradient: [Color]
    /// A raised control: button, chip, field.
    let raisedGradient: [Color]
    /// The same, hovered.
    let raisedGradientHover: [Color]
    /// The committing action.
    let accentGradient: [Color]
    /// A recessed well: text fields, progress beds.
    let sunkenGradient: [Color]

    /// The rim light on the top edge of a raised surface.
    let rim: Color
    /// The shadow a raised surface casts.
    let cast: Color

    // MARK: Radii

    /// Buttons, fields, chips, segments.
    let controlRadius: CGFloat
    /// Cards and list rows.
    let cardRadius: CGFloat
    /// Panels, sheets, the window itself.
    let panelRadius: CGFloat

    // MARK: Type

    /// The face used for data: sizes, counts, dates, paths, checksums.
    /// Readouts — counts, dates, timecode, file names. San Francisco with
    /// figures of one width, as macOS sets them, rather than a typewriter face.
    func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    /// The face used for language: labels, names, descriptions, buttons.
    func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// The standard interface text size.
    let bodySize: CGFloat
    /// The size used for readouts and meta text.
    let metaSize: CGFloat
}

// MARK: - The faceplate

extension StudioStyle {

    /// Warm grey-brown, flat, one cool blue for the thing to press.
    ///
    /// It was night graphite with an indigo accent and soft gradients, which
    /// read as an app rather than a tool. The ground now is the warm grey of
    /// a console in a dim room; surfaces step lighter and darker in that one
    /// hue instead of shading, so the faceplate is flat and still has depth.
    /// The accent went cool on purpose: against a warm ground the single
    /// colour that means "press this" stands out without having to glow, and
    /// it cannot be mistaken for the warm `ready` or the amber warning.
    ///
    /// Next to Pro Tools and rekordbox it read faded, so the ground went
    /// almost black, text went full white, and every signal colour went to
    /// full strength. The warmth stays in the panels, not in a haze.
    /// macOS's own dark palette, so the app sits beside Finder, Logic and
    /// Pro Tools as one of them rather than as a custom faceplate: the
    /// system's greys, its blue, its signal colours, its rounded corners.
    static let studio = StudioStyle(
        bg: Color(studioHex: 0x1C1C1E),
        panel: Color(studioHex: 0x232325),
        raised: Color(studioHex: 0x3A3A3C),
        sunken: Color(studioHex: 0x161618),
        deep: Color(studioHex: 0x111113),
        line: Color.white.opacity(0.12),
        lineSoft: Color.white.opacity(0.07),
        grid: Color.white.opacity(0.04),
        hair: Color.white.opacity(0.06),
        text: Color.white,
        muted: Color(studioHex: 0xAEAEB2),
        faint: Color(studioHex: 0x8E8E93),
        accent: Color(studioHex: 0x0A84FF),
        accentLit: Color(studioHex: 0x409CFF),
        accentDim: Color(studioHex: 0x0A3D7A),
        counterpoint: Color(studioHex: 0x64D2FF),
        ready: Color(studioHex: 0xFF9F0A),
        passed: Color(studioHex: 0x30D158),
        warning: Color(studioHex: 0xFFD60A),
        error: Color(studioHex: 0xFF453A),
        unchecked: Color(studioHex: 0x636366),
        barHeight: 34,
        rowHeight: 48,
        statusBarHeight: 30,
        contentPadding: 20,
        barGradient: [Color(studioHex: 0x232325), Color(studioHex: 0x232325)],
        raisedGradient: [Color.white.opacity(0.08), Color.white.opacity(0.08)],
        raisedGradientHover: [Color.white.opacity(0.13), Color.white.opacity(0.13)],
        accentGradient: [Color(studioHex: 0x0A84FF), Color(studioHex: 0x0A84FF)],
        sunkenGradient: [Color.black.opacity(0.25), Color.black.opacity(0.25)],
        rim: Color.white.opacity(0.06),
        cast: Color.black.opacity(0.25),
        controlRadius: 6,
        cardRadius: 10,
        panelRadius: 12,
        bodySize: AppType.body,
        metaSize: AppType.small
    )

    /// The colour a raised surface is filled with when it is hovered or not.
    func raisedFill(hovering: Bool) -> LinearGradient {
        LinearGradient(
            colors: hovering ? raisedGradientHover : raisedGradient,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The fade every bar in the app is built on.
    var bar: LinearGradient {
        LinearGradient(colors: barGradient, startPoint: .top, endPoint: .bottom)
    }

    /// The recessed fill of a well.
    var well: LinearGradient {
        LinearGradient(colors: sunkenGradient, startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Environment

private struct StudioStyleKey: EnvironmentKey {
    static let defaultValue: StudioStyle = .studio
}

extension EnvironmentValues {
    /// The faceplate the surrounding views draw with.
    var studioStyle: StudioStyle {
        get { self[StudioStyleKey.self] }
        set { self[StudioStyleKey.self] = newValue }
    }
}

extension View {
    /// Adopts the faceplate for this view and everything inside it.
    ///
    /// Apply once at the root of every window — a window does not inherit the
    /// environment of the one that opened it — together with the dark colour
    /// scheme and the accent tint it expects.
    func studioStyle(_ style: StudioStyle = .studio) -> some View {
        self
            .environment(\.studioStyle, style)
            .tint(style.accent)
            .preferredColorScheme(.dark)
    }
}

extension Color {
    /// Builds an sRGB colour from a `0xRRGGBB` literal, so the palette stays
    /// legible beside the design tokens it came from.
    init(studioHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
