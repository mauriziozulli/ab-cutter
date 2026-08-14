import SwiftUI

@MainActor
struct RootView: View {
    @StateObject private var state = AppState()

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

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ClipsPanel(state: state)
                        Divider()
                        StillsPanel(state: state)
                        Divider()
                        ExportPanel(state: state, queue: state.exportQueue)
                    }
                    .padding(Theme.panelPadding)
                }
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
                .background(Theme.panelBackground)
            }

            Divider()
            statusBar
        }
        .frame(minWidth: 1120, minHeight: 720)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    state.presentVideoPicker()
                } label: {
                    Label("Video", systemImage: "film")
                }
                .help("Load the finished film")

                Button {
                    state.presentAudioPicker()
                } label: {
                    Label("Audio", systemImage: "waveform")
                }
                .help("Add a mix or stem under the picture")

                Button {
                    state.autoSyncAll()
                } label: {
                    Label("Sync", systemImage: "timeline.selection")
                }
                .help("Sync every stamped file by timecode")

                Spacer()

                Button {
                    state.openProject()
                } label: {
                    Label("Open", systemImage: "folder")
                }

                Button {
                    state.saveProject()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
            }
        }
        .alert(
            "Something needs attention",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            ),
            actions: {
                Button("OK") { state.errorMessage = nil }
            },
            message: {
                Text(state.errorMessage ?? "")
            }
        )
        .navigationTitle(state.windowTitle)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if state.isLoadingMedia {
                ProgressView().controlSize(.small)
            }
            Text(state.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("v\(AppVersion.string)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.vertical, 6)
        .background(Theme.panelBackground)
    }
}
