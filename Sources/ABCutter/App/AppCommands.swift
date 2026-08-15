import SwiftUI

/// The real macOS menu bar.
///
/// Every action the app can perform lives here as well as on a button, which
/// is what makes it discoverable — a toolbar teaches nothing about shortcuts,
/// and a panel buries anything below the fold.
///
/// Shortcuts all carry a modifier on purpose. A bare `I` or `O` in a menu
/// becomes a global key equivalent and would be swallowed before it reached a
/// text field, so the J / K / L transport familiar from an NLE is bound with
/// Command instead.
struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Video…") { state.presentVideoPicker() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Add Audio…") { state.presentAudioPicker() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!state.project.hasVideo)

            Divider()

            Button("Open Project…") { state.openProject() }
                .keyboardShortcut("o", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Project…") { state.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!state.project.hasVideo)

            Divider()

            Button("Choose Output Folder…") { state.chooseOutputFolder() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Export Batch") { state.startExport() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!state.project.hasVideo || state.exportQueue.isRunning)
            Button("Grab Cover Frame") { state.grabStill() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!state.project.hasVideo)
        }

        CommandMenu("Clip") {
            Button("New Clip at Playhead") { state.addClipAtPlayhead() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!state.project.hasVideo)

            Divider()

            Button("Mark In") { state.markIn() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!state.hasSelectedClip)
            Button("Mark Out") { state.markOut() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!state.hasSelectedClip)
            Button("Split Here") { state.setSplitToPlayhead() }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(!state.hasSelectedClip)
            Button("Split at Middle") { state.resetSplitToMiddle() }
                .disabled(!state.hasSelectedClip)

            Divider()

            Button("Snap to House Length") { state.snapSelectedClipToHouseLength() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!state.hasSelectedClip)
            Button("Snap All Clips") { state.applyDefaultLengthToAllClips() }
                .disabled(state.project.clips.isEmpty)

            Divider()

            Button("Select Previous Clip") { state.selectAdjacentClip(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(state.project.clips.isEmpty)
            Button("Select Next Clip") { state.selectAdjacentClip(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(state.project.clips.isEmpty)

            Divider()

            Button("Delete Clip") { state.deleteSelectedClip() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!state.hasSelectedClip)
        }

        CommandMenu("Playback") {
            Button(state.player.isPlaying ? "Pause" : "Play") { state.player.togglePlay() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!state.project.hasVideo)

            Divider()

            Button("Back One Frame") { state.player.step(frames: -1, frameRate: state.project.frameRate) }
                .keyboardShortcut("j", modifiers: .command)
            Button("Forward One Frame") { state.player.step(frames: 1, frameRate: state.project.frameRate) }
                .keyboardShortcut("l", modifiers: .command)
            Button("Back Ten Frames") { state.player.step(frames: -10, frameRate: state.project.frameRate) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Button("Forward Ten Frames") { state.player.step(frames: 10, frameRate: state.project.frameRate) }
                .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button("Go to Clip Start") { state.goToSelectedClipStart() }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(!state.hasSelectedClip)
            Button("Go to A/B Switch") { state.goToSelectedClipSplit() }
                .disabled(!state.hasSelectedClip)
            Button("Go to Clip End") { state.goToSelectedClipEnd() }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(!state.hasSelectedClip)

            Divider()

            Toggle("Loop Inside Clip", isOn: Binding(
                get: { state.player.limitToClip },
                set: {
                    state.player.limitToClip = $0
                    state.applyPlayerSettings()
                }
            ))
        }

        CommandMenu("View") {
            Button("Full Frame") { state.setPreviewFormat(nil) }
                .keyboardShortcut("0", modifiers: .command)
            ForEach(Array(SocialFormat.allCases.enumerated()), id: \.element) { index, format in
                Button("Preview \(format.title)") { state.setPreviewFormat(format) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }

            Divider()

            Button("Zoom Timeline In") { state.zoomTimeline(by: 1.6) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Timeline Out") { state.zoomTimeline(by: 1 / 1.6) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Fit Whole Film") { state.zoom = 1 }

            Divider()

            ForEach(InspectorTab.allCases) { tab in
                Button(tab.title) { state.showInspector(tab) }
            }
        }
    }
}
