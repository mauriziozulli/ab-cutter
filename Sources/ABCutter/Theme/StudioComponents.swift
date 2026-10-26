import SwiftUI

// The component vocabulary of the Studio faceplate.
//
// Every one of these replaces a hard-edged shared component of the same name
// (`ParanoidHairline`, `ParanoidButtonStyle`, …) and keeps its call signature,
// so adopting the faceplate was a rename at the call sites rather than a
// rewrite of them.
//
// The rule they all follow: a raised surface is a gradient with a rim light on
// its top edge and a soft shadow under it; a recessed one is a gradient the
// other way round with an inner shadow. Neither gets a border. The border is
// reserved for the one element that is currently selected or focused, where it
// is then the thing that says so.

// MARK: - Hairline

/// A precise 1px rule.
///
/// Far rarer than it used to be: the faceplate separates with surface and
/// space, and a rule is for the places where a real edge exists — under a bar,
/// along the seam between two panes.
struct StudioHairline: View {
    @Environment(\.studioStyle) private var style
    private let soft: Bool
    private let color: Color?

    init(soft: Bool = false) {
        self.soft = soft
        self.color = nil
    }

    /// An explicit colour, for the rim light and similar cases.
    init(color: Color) {
        self.soft = false
        self.color = color
    }

    var body: some View {
        Rectangle()
            .fill(color ?? (soft ? style.lineSoft : style.line))
            .frame(height: 1)
    }
}

// MARK: - Bars

extension View {
    /// The one construction every bar in the app is built from: the fade, the
    /// rim light along the top, the shadow along the bottom.
    ///
    /// It was three constructions — a gradient here, a flat `sunken` there, a
    /// hairline top on one bar and bottom on the next — which is why the
    /// window used to look assembled rather than made.
    func studioBar(_ style: StudioStyle) -> some View {
        self
            .background(style.bar)
            .overlay(alignment: .top) { StudioHairline(color: style.hair) }
            .overlay(alignment: .bottom) {
                Rectangle().fill(style.lineSoft).frame(height: 1)
            }
    }

    /// A raised surface: card, tile, grouped block.
    ///
    /// The rim light is masked to fade out down the sides, so the top edge
    /// catches the light and the bottom does not — an outline that is lit
    /// all the way round is a border again, whatever it is made of.
    func studioCard(_ style: StudioStyle, padding: CGFloat = 15) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous)
        return self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.panel)
            .clipShape(shape)
            .overlay { shape.strokeBorder(style.lineSoft, lineWidth: 1) }
    }

    /// A recessed well: a field, a bed, the inside of a control.
    func studioWell(_ style: StudioStyle, radius: CGFloat? = nil, focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? style.controlRadius, style: .continuous)
        return self
            .background(style.well)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(focused ? style.accent : Color.white.opacity(0.1), lineWidth: focused ? 2 : 1)
            }
    }
}

/// The recurring header of a section.
///
/// It was letter-spaced uppercase monospace, which made a heading look like a
/// reading off an instrument and every line on the surface look equally
/// important. It is language now — small, semibold, sentence case — and the
/// `meta` slot keeps doing its real job: letting a panel report its own state
/// without being opened (`3 of 5 met`, `12 projects`, `4.2 TB`).
struct StudioPanelBar: View {
    @Environment(\.studioStyle) private var style

    private let title: String
    private let meta: String?
    private let collapsedMeta: String?
    private let isExpanded: Binding<Bool>?

    init(title: String, meta: String? = nil) {
        self.title = title
        self.meta = meta
        self.collapsedMeta = nil
        self.isExpanded = nil
    }

    init(
        title: String,
        meta: String? = nil,
        collapsedMeta: String? = nil,
        isExpanded: Binding<Bool>
    ) {
        self.title = title
        self.meta = meta
        self.collapsedMeta = collapsedMeta
        self.isExpanded = isExpanded
    }

    var body: some View {
        if let isExpanded {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.wrappedValue.toggle() }
            } label: {
                bar(expanded: isExpanded.wrappedValue)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(isExpanded.wrappedValue ? "Collapse" : "Expand")
        } else {
            bar(expanded: true)
        }
    }

    private func bar(expanded: Bool) -> some View {
        HStack(spacing: 9) {
            if isExpanded != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(expanded ? style.accent : style.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
            }

            Text(title)
                .font(style.ui(AppType.body, weight: .semibold))
                .foregroundStyle(style.text)

            Spacer(minLength: 8)

            if !expanded, let collapsedMeta {
                Text(collapsedMeta)
                    .font(style.mono(AppType.small))
                    .foregroundStyle(style.faint)
            }

            if let meta {
                Text(meta)
                    .font(style.mono(AppType.small))
                    .foregroundStyle(style.faint)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: style.barHeight)
        .background(style.bar)
    }
}

// MARK: - Status dot

/// A small glowing indicator — the family's status vocabulary, kept.
///
/// It survives the redesign unchanged in principle because it is the one thing
/// the instrument look got exactly right: at row density, a coloured dot is
/// read faster than any icon and takes a tenth of the room.
struct StudioLED: View {
    @Environment(\.studioStyle) private var style

    private let explicitColor: Color?
    private let diameter: CGFloat
    private let glow: Bool
    private let hollow: Bool

    init(color: Color, diameter: CGFloat = 8, glow: Bool = true, hollow: Bool = false) {
        self.explicitColor = color
        self.diameter = diameter
        self.glow = glow
        self.hollow = hollow
    }

    var body: some View {
        let colour = explicitColor ?? style.unchecked

        return Group {
            if hollow {
                // An answer the app does not have. A ring is visibly a place
                // where a dot would be, which is what "not read yet" is — and
                // it cannot be mistaken for the filled grey that means dormant.
                Circle()
                    .strokeBorder(colour.opacity(0.7), lineWidth: 1.5)
            } else {
                Circle()
                    .fill(colour)
                    // A dot on a dark faceplate is a flat disc until something
                    // catches its top edge. The bright rim and the halo are
                    // what make it read as lit rather than as printed.
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)
                    }
                    .overlay {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color.white.opacity(0.45), .clear],
                                    center: .init(x: 0.35, y: 0.3),
                                    startRadius: 0,
                                    endRadius: diameter * 0.6
                                )
                            )
                    }
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: glow && !hollow ? colour.opacity(0.85) : .clear, radius: glow ? 5 : 0)
        .shadow(color: glow && !hollow ? colour.opacity(0.45) : .clear, radius: glow ? 10 : 0)
    }
}

// MARK: - Controls

/// A checkbox glyph (visual only; the caller owns state).
struct StudioCheckMark: View {
    @Environment(\.studioStyle) private var style
    private let isOn: Bool
    private let size: CGFloat

    init(isOn: Bool, size: CGFloat = 15) {
        self.isOn = isOn
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(isOn ? style.accent : Color.white.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .strokeBorder(isOn ? Color.clear : Color.white.opacity(0.18), lineWidth: 1)
            }
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.6, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// A checkbox toggle. Replaces the system `.checkbox` style.
struct StudioCheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // The system checkbox: its look, its animation, its focus ring.
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.checkbox)
    }
}

/// A sliding switch.
///
/// Off reads as a deliberate state — a dim knob to the left — rather than a
/// greyed-out control, so "this is off" never looks like "you cannot change
/// this".
struct StudioSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.label
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

extension ToggleStyle where Self == StudioCheckToggleStyle {
    static var studioCheck: StudioCheckToggleStyle { StudioCheckToggleStyle() }
}

extension ToggleStyle where Self == StudioSwitchToggleStyle {
    static var studioSwitch: StudioSwitchToggleStyle { StudioSwitchToggleStyle() }
}

/// A push-button that reads as a thing rather than a boxed word.
///
/// The rim light sits on the top edge, where light from above would leave it,
/// and the button lifts a point when hovered. That lift is the whole of the
/// difference between a control somebody presses and a rectangle with a label
/// in it, and it costs nothing but doing it everywhere.
///
/// `.primary` is the one committing action on a surface — an accent fill is the
/// commit and nothing else — `.counterpoint` is for what goes somewhere safe
/// (copying out, replicating), and `.danger` for irreversible actions.
struct StudioButtonStyle: ButtonStyle {
    enum Kind: Sendable { case normal, primary, counterpoint, danger, quiet }

    private let kind: Kind

    init(kind: Kind = .normal) {
        self.kind = kind
    }

    func makeBody(configuration: Configuration) -> some View {
        Face(kind: kind, configuration: configuration)
    }

    /// The button as a view of its own.
    ///
    /// `@Environment` read in the `ButtonStyle` itself is not kept up to date —
    /// it holds whatever it had when the style was made, so a disabled button
    /// would draw as an enabled one. Inside a view, `isEnabled` is reliable.
    private struct Face: View {
        let kind: Kind
        let configuration: ButtonStyleConfiguration

        @Environment(\.studioStyle) private var style
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false

        private var height: CGFloat { controlSize == .small ? 24 : 28 }
        private var fontSize: CGFloat { controlSize == .small ? AppType.small + 1 : AppType.meta + 0.5 }

        var body: some View {
            // The way a macOS push button behaves: a soft rounded fill that
            // brightens under the pointer and gives a little when pressed.
            configuration.label
                .font(style.ui(fontSize, weight: kind == .primary ? .semibold : .regular))
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .quiet ? 8 : 12)
                .frame(height: height)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: style.controlRadius, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary: Color.white
            case .counterpoint: style.counterpoint
            case .danger: style.error
            case .quiet: style.muted
            case .normal: style.text
            }
        }

        @ViewBuilder
        private var background: some View {
            switch kind {
            case .primary:
                style.accent.brightness(hovering && isEnabled ? 0.06 : 0)
            case .quiet:
                Color.white.opacity(hovering && isEnabled ? 0.05 : 0)
            case .danger:
                style.raisedFill(hovering: hovering)
                    .overlay(style.error.opacity(0.1))
            default:
                style.raisedFill(hovering: hovering)
            }
        }
    }
}

/// A toggleable chip for filters and options.
///
/// A capsule rather than a bordered square, and sentence case rather than
/// letter-spaced uppercase: a filter is a word somebody reads, not a reading.
struct StudioFilterChip: View {
    @Environment(\.studioStyle) private var style
    private let title: String
    private let count: Int?
    private let isOn: Bool
    private let tint: Color?
    private let action: () -> Void

    @State private var hovering = false

    init(
        _ title: String,
        count: Int? = nil,
        isOn: Bool,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.count = count
        self.isOn = isOn
        self.tint = tint
        self.action = action
    }

    var body: some View {
        let colour = tint ?? style.accent
        // A chip the other chips leave nothing stays in place, greyed.
        let empty = count == 0 && !isOn
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(style.ui(AppType.small))
                    .lineLimit(1)
                if let count {
                    Text(count.formatted())
                        .font(style.mono(AppType.small - 1, weight: .semibold))
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: count)
                }
            }
            .foregroundStyle(isOn ? colour : (hovering && !empty ? style.text : style.muted))
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(Capsule().fill(isOn ? colour.opacity(0.2) : Color.white.opacity(hovering && !empty ? 0.1 : 0.05)))
            .contentShape(Capsule())
            .opacity(empty ? 0.35 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .disabled(empty)
        .onHover { hovering = $0 }
    }
}

/// Chips laid out like words in a paragraph: as many on a line as fit, the
/// rest on the next.
///
/// For a narrow column of filters, where a fixed grid would either waste the
/// width or cut a long name short.
struct StudioChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(subviews, width: width)
        let height = lines.last.map { $0.y + $0.height } ?? 0
        let used = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + line.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Line {
        var items: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !line.items.isEmpty, line.width + spacing + size.width > width {
                lines.append(line)
                line = Line(y: line.y + line.height + lineSpacing)
            }
            line.width += (line.items.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.items.append(index)
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}

/// A row of mutually exclusive options.
///
/// Built the way a modern one is: a recessed track with the chosen option
/// raised inside it, rather than three boxes sharing a border.
struct StudioSegmentedControl<Value: Hashable>: View {
    @Environment(\.studioStyle) private var style
    private let options: [Value]
    private let title: (Value) -> String
    @Binding private var selection: Value

    init(
        options: [Value],
        selection: Binding<Value>,
        title: @escaping (Value) -> String
    ) {
        self.options = options
        self._selection = selection
        self.title = title
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(title(option)).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

// MARK: - Progress

/// A progress well.
///
/// Pass `nil` when the total amount of work is genuinely unknown. Use
/// `height: 3` inside a list row and the default elsewhere.
struct StudioProgressWell: View {
    @Environment(\.studioStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let fraction: Double?
    private let height: CGFloat
    /// Unknown progress: a short bar that sweeps across, rather than one
    /// standing still as if something were stuck.
    @State private var sweeping = false

    init(fraction: Double?, height: CGFloat = 6) {
        self.fraction = fraction
        self.height = height
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                if let fraction {
                    let filled: CGFloat = max(height, width * CGFloat(min(max(fraction, 0), 1)))
                    Capsule()
                        .fill(style.accent)
                        .frame(width: filled)
                        // The bar glides between reports instead of jumping.
                        .animation(.linear(duration: 0.25), value: fraction)
                } else {
                    let piece: CGFloat = max(height, width * 0.25)
                    Capsule()
                        .fill(style.accent.opacity(0.8))
                        .frame(width: piece)
                        .offset(x: reduceMotion ? 0 : (sweeping ? width : -piece))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
        .onAppear { startSweep() }
        .onChange(of: fraction == nil) { _ in startSweep() }
    }

    private func startSweep() {
        guard fraction == nil, !reduceMotion else {
            sweeping = false
            return
        }
        sweeping = false
        withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { sweeping = true }
    }
}

// MARK: - Containers

/// A panel with a title bar. Replaces the system `GroupBox`.
struct StudioSheetPanel<Content: View>: View {
    @Environment(\.studioStyle) private var style
    private let title: String
    private let meta: String?
    private let content: Content

    init(title: String, meta: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.meta = meta
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioPanelBar(title: title, meta: meta)

            VStack(alignment: .leading, spacing: 11) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(style.panel)
        .clipShape(RoundedRectangle(cornerRadius: style.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: style.panelRadius, style: .continuous).strokeBorder(style.lineSoft, lineWidth: 1))
    }
}

// MARK: - Empty state

/// The empty state — a quiet centred readout with an optional primary action.
///
/// The glyph sits in a soft tile rather than a 1px circle, and the title is a
/// sentence rather than a letter-spaced readout. An empty window is the first
/// thing a new user sees, and an instrument panel reporting `NO PROJECTS` is a
/// poor way to say "drop a folder here".
struct StudioEmptyReadout: View {
    @Environment(\.studioStyle) private var style
    private let glyph: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    init(
        glyph: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 13) {
            Text(glyph)
                .font(.system(size: 21))
                .foregroundStyle(style.muted)
                .frame(width: 52, height: 52)
                .background(
                    Rectangle()
                        .fill(style.panel)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .strokeBorder(style.rim, lineWidth: 1)
                        }
                )
                .shadow(color: style.cast, radius: 8, y: 3)

            Text(title)
                .font(style.ui(AppType.title - 1, weight: .semibold))
                .foregroundStyle(style.text)

            Text(message)
                .font(style.ui(AppType.meta + 0.5))
                .foregroundStyle(style.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 340)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

// MARK: - Surfaces

extension View {
    /// A small raised control: an icon button, a chip, a stepper.
    ///
    /// The same construction as ``StudioButtonStyle`` for the places that draw
    /// their own button rather than using it.
    func studioRaised(_ style: StudioStyle, radius: CGFloat? = nil, active: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? style.controlRadius, style: .continuous)
        return self
            .background(
                active
                    ? AnyShapeStyle(LinearGradient(colors: style.accentGradient, startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(style.raisedFill(hovering: false))
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(active ? Color.white.opacity(0.3) : style.rim)
                    .frame(height: 1)
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(active ? style.accent : style.line, lineWidth: 1) }
    }

    /// A flat grouped surface: a note, a summary block, a panel that is not a
    /// card and does not want a shadow of its own.
    func studioSurface(_ style: StudioStyle, radius: CGFloat? = nil, fill: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? style.cardRadius, style: .continuous)
        return self
            .background(fill ?? style.panel)
            .clipShape(shape)
            .overlay { shape.strokeBorder(style.lineSoft, lineWidth: 1) }
    }
}
