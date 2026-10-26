import SwiftUI

@MainActor
struct RootView: View {
    @ObservedObject var state: AppState

    /// Bare R and T zoom the timeline, exactly as a Pro Tools hand expects —
    /// R out, T in, T sits to the right of R. Bare keys cannot be menu
    /// equivalents here, because those fire even while a text field is being
    /// typed into; a local monitor can check who has focus first.
    @State private var zoomKeyMonitor: Any?

    @Environment(\.studioStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SourcesPanel(state: state)
                    .frame(minWidth: 240, idealWidth: 290, maxWidth: 420)

                VStack(spacing: 0) {
                    PlayerPane(state: state, player: state.player)
                    StudioHairline()
                    TimelineView(state: state, player: state.player)
                }
                .frame(minWidth: 480)

                inspector
                    .frame(minWidth: 300, idealWidth: 350, maxWidth: 470)
            }

            StudioHairline()
            statusBar
        }
        .background(style.bg)
        .frame(minWidth: 1120, minHeight: 720)
        .toolbar { toolbarItems }
        .alert(
            "Da ist etwas zu klären",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            ),
            actions: { Button("OK") { state.errorMessage = nil } },
            message: { Text(state.errorMessage ?? "") }
        )
        .navigationTitle(state.windowTitle)
        .studioStyle()
        .onAppear { installZoomKeys() }
    }

    private func installZoomKeys() {
        guard zoomKeyMonitor == nil else { return }
        zoomKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only bare keys — anything with a modifier belongs to the menus.
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                return event
            }
            // Typing beats zooming: while any text field is being edited the
            // keystroke is text, not a command. (A focused TextField routes
            // through the window's field editor, which is an NSTextView.)
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "t":
                state.zoomTimeline(by: 1.6)
                return nil
            case "r":
                state.zoomTimeline(by: 1 / 1.6)
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Inspector

    /// One tab at a time rather than one long scroll. Three tabs since the
    /// look moved onto the clip: cut and style it, make its cover, ship it.
    private var inspector: some View {
        VStack(spacing: 0) {
            if state.project.hasVideo {
                Picker("", selection: $state.inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Theme.panelPadding)
                .frame(height: style.barHeight + 8)
                .studioBar(style)

                ScrollView {
                    Group {
                        switch state.inspectorTab {
                        case .clips: ClipsPanel(state: state)
                        case .cover: StillsPanel(state: state)
                        case .stills: MarkerStillsPanel(state: state)
                        case .export: ExportPanel(state: state, queue: state.exportQueue)
                        }
                    }
                    .padding(Theme.panelPadding)
                }
            } else {
                gettingStarted
            }
        }
        .background(style.bg)
    }

    /// Without a film every panel is speculative, so the column explains the
    /// run of play instead of showing controls that cannot do anything yet.
    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("So läuft es")
                .font(style.ui(AppType.body, weight: .semibold))
                .foregroundStyle(style.text)

            step(1, "Fertigen Film laden.", "Timecode und Bildrate werden automatisch gelesen.")
            step(2, "Mixe und Stems hinzufügen.", "Gestempelte Dateien legen sich selbst; den Rest schiebst du.")
            step(3, "Clips setzen.", "Suchen, ⌘N, suchen, ⌘N — Kanten ziehst du nach Gehör, der A/B-Wechsel bleibt stehen.")
            step(4, "Stills markieren.", "Mit + einen Marker am Abspielkopf setzen, in der Zeitleiste verschieben — gerendert wird aus allen Markern.")
            step(5, "Exportieren.", "Jeder Clip in jedem Format, in einem Lauf.")

            StudioHairline(soft: true)

            Button("Video wählen …") { state.presentVideoPicker() }
                .buttonStyle(StudioButtonStyle(kind: .primary))

            Spacer()
        }
        .padding(Theme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(style.mono(AppType.small - 1, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(style.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(style.ui(AppType.small + 1, weight: .medium))
                    .foregroundStyle(style.text)
                Text(detail)
                    .font(style.ui(AppType.small))
                    .foregroundStyle(style.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Toolbar

    /// Deliberately short. Everything here is also in the menu bar with a
    /// shortcut; the toolbar only carries the handful of actions that start a
    /// session or end one.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Button { state.presentVideoPicker() } label: {
                Label("Video", systemImage: "film")
            }
            .help("Fertigen Film laden (⌘O)")

            Button { state.presentAudioPicker() } label: {
                Label("Ton", systemImage: "waveform")
            }
            .disabled(!state.project.hasVideo)
            .help("Mix oder Stem unters Bild legen (⇧⌘O)")

            Button { state.autoSyncAll() } label: {
                Label("Sync", systemImage: "timeline.selection")
            }
            .disabled(state.project.videoTimecodeStartSeconds == nil)
            .help("Alle gestempelten Dateien per Timecode syncen")

            Spacer()

            Button { state.grabStill() } label: {
                Label("Titelbild", systemImage: "camera")
            }
            .disabled(!state.project.hasVideo)
            .help("Bild am Abspielkopf greifen (⇧⌘G)")

            Button { state.addStillMarkerAtPlayhead() } label: {
                Label("Still", systemImage: "plus.viewfinder")
            }
            .disabled(!state.project.hasVideo)
            .help("Still-Marker am Abspielkopf setzen (⇧⌘M)")

            Button { state.startExport() } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!state.project.hasVideo || state.exportQueue.isRunning)
            .help("Alle aktiven Clips exportieren (⌘E)")
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if state.isLoadingMedia {
                ProgressView().controlSize(.small)
            }

            Text(state.status)
                .font(style.ui(AppType.small))
                .foregroundStyle(style.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            if state.project.hasVideo {
                Text(state.summaryLine)
                    .font(style.mono(AppType.small))
                    .foregroundStyle(style.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            if state.exportQueue.isRunning {
                ProgressView(value: state.exportQueue.overallProgress)
                    .controlSize(.small)
                    .frame(width: 110)
            }

            if state.isExportingStills {
                ProgressView(value: state.stillExportProgress)
                    .controlSize(.small)
                    .frame(width: 110)
            }

            Text("v\(AppVersion.string)")
                .font(style.mono(AppType.small))
                .foregroundStyle(style.faint)
        }
        .padding(.horizontal, Theme.panelPadding)
        .frame(height: style.statusBarHeight)
        .background(style.sunken)
    }
}
