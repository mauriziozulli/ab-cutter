import SwiftUI

@MainActor
struct RootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SourcesPanel(state: state)
                    .frame(minWidth: 240, idealWidth: 290, maxWidth: 420)

                VStack(spacing: 0) {
                    PlayerPane(state: state, player: state.player)
                    Divider()
                    TimelineView(state: state, player: state.player)
                }
                .frame(minWidth: 480)

                inspector
                    .frame(minWidth: 300, idealWidth: 350, maxWidth: 470)
            }

            Divider()
            statusBar
        }
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
    }

    // MARK: - Inspector

    /// One tab at a time rather than one long scroll. The four tabs match the
    /// four moments of the job: cut it, style it, make its cover, ship it.
    private var inspector: some View {
        VStack(spacing: 0) {
            if state.project.hasVideo {
                Picker("", selection: $state.inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Theme.panelPadding)
                .padding(.vertical, 8)

                Divider()

                ScrollView {
                    Group {
                        switch state.inspectorTab {
                        case .clips: ClipsPanel(state: state)
                        case .look: LookPanel(state: state)
                        case .cover: StillsPanel(state: state)
                        case .export: ExportPanel(state: state, queue: state.exportQueue)
                        }
                    }
                    .padding(Theme.panelPadding)
                }
            } else {
                gettingStarted
            }
        }
        .background(Theme.panelBackground)
    }

    /// Without a film every panel is speculative, so the column explains the
    /// run of play instead of showing controls that cannot do anything yet.
    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("So läuft es")
                .font(.system(size: 12, weight: .semibold))

            step(1, "Fertigen Film laden.", "Timecode und Bildrate werden automatisch gelesen.")
            step(2, "Mixe und Stems hinzufügen.", "Gestempelte Dateien legen sich selbst; den Rest schiebst du.")
            step(3, "Clips in Hauslänge setzen.", "Suchen, ⌘N, suchen, ⌘N — der A/B-Wechsel landet in der Mitte.")
            step(4, "Titelbild greifen und exportieren.", "Jeder Clip in jedem Format, in einem Lauf.")

            Divider()

            Button("Video wählen …") { state.presentVideoPicker() }
                .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding(Theme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

            Button { state.startExport() } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!state.project.hasVideo || state.exportQueue.isRunning)
            .help("Alle aktiven Clips exportieren (⌘E)")
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if state.isLoadingMedia {
                ProgressView().controlSize(.small)
            }

            Text(state.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            if state.project.hasVideo {
                Divider().frame(height: 12)
                Text(state.summaryLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            if state.exportQueue.isRunning {
                ProgressView(value: state.exportQueue.overallProgress)
                    .controlSize(.small)
                    .frame(width: 110)
            }

            Text("v\(AppVersion.string)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.vertical, 6)
        .background(Theme.panelBackground)
    }
}
