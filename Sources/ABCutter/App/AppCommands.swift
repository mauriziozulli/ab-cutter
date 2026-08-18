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
            Button("Video öffnen …") { state.presentVideoPicker() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Ton hinzufügen …") { state.presentAudioPicker() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Alle per Wellenform syncen") { state.alignAllByWaveform() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(!state.project.hasVideo)
                .disabled(!state.project.hasVideo)

            Divider()

            Button("Projekt öffnen …") { state.openProject() }
                .keyboardShortcut("o", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Projekt sichern …") { state.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!state.project.hasVideo)

            Divider()

            Button("Zielordner wählen …") { state.chooseOutputFolder() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Stapel exportieren") { state.startExport() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!state.project.hasVideo || state.exportQueue.isRunning)
            Button("Titelbild greifen") { state.grabStill() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!state.project.hasVideo)
        }

        CommandMenu("Clip") {
            Button("Neuer A/B-Clip am Abspielkopf") { state.addClipAtPlayhead(kind: .ab) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!state.project.hasVideo)
            Button("Neuer Loop-Clip am Abspielkopf") { state.addClipAtPlayhead(kind: .loop) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!state.project.hasVideo)

            Divider()

            Button(state.player.isClipPreview ? "Clip-Vorschau verlassen" : "Clip-Vorschau") {
                state.toggleClipPreview()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!state.hasSelectedClip)

            Divider()

            Button("In setzen") { state.markIn() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!state.hasSelectedClip)
            Button("Out setzen") { state.markOut() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!state.hasSelectedClip)
            Button("A/B-Wechsel hier einfügen") { state.addSwitchAtPlayhead() }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(!state.hasSelectedClip)
            Button("Nur ein Wechsel hier") { state.setSplitToPlayhead() }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(!state.hasSelectedClip)
            Button("Nächsten Wechsel entfernen") { state.removeSwitchNearestPlayhead() }
                .disabled(!state.hasSelectedClip)
            Button("Auf einen Wechsel in der Mitte") { state.resetSplitToMiddle() }
                .disabled(!state.hasSelectedClip)

            Divider()

            Button("Nur A abhören") { state.monitorOnlySide(before: true) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
                .disabled(state.project.audioSources.isEmpty)
            Button("Nur B abhören") { state.monitorOnlySide(before: false) }
                .keyboardShortcut("2", modifiers: [.command, .shift])
                .disabled(state.project.audioSources.isEmpty)

            Divider()

            Button("Vorheriger Clip") { state.selectAdjacentClip(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(state.project.clips.isEmpty)
            Button("Nächster Clip") { state.selectAdjacentClip(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(state.project.clips.isEmpty)

            Divider()

            Button("Clip löschen") { state.deleteSelectedClip() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!state.hasSelectedClip)
        }

        CommandMenu("Wiedergabe") {
            Button(state.player.isPlaying ? "Pause" : "Abspielen") { state.player.togglePlay() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!state.project.hasVideo)

            Divider()

            Button("Ein Bild zurück") { state.player.step(frames: -1, frameRate: state.project.frameRate) }
                .keyboardShortcut("j", modifiers: .command)
            Button("Ein Bild vor") { state.player.step(frames: 1, frameRate: state.project.frameRate) }
                .keyboardShortcut("l", modifiers: .command)
            Button("Zehn Bilder zurück") { state.player.step(frames: -10, frameRate: state.project.frameRate) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Button("Zehn Bilder vor") { state.player.step(frames: 10, frameRate: state.project.frameRate) }
                .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button("Zum Clip-Anfang") { state.goToSelectedClipStart() }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(!state.hasSelectedClip)
            Button("Zum ersten A/B-Wechsel") { state.goToSelectedClipSplit() }
                .disabled(!state.hasSelectedClip)
            Button("Zum Clip-Ende") { state.goToSelectedClipEnd() }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(!state.hasSelectedClip)

            Divider()

            Toggle("Im Clip bleiben", isOn: Binding(
                get: { state.player.limitToClip },
                set: {
                    state.player.limitToClip = $0
                    state.applyPlayerSettings()
                }
            ))
        }

        CommandMenu("Ansicht") {
            Button("Ganzes Bild") { state.setPreviewFormat(nil) }
                .keyboardShortcut("0", modifiers: .command)
            ForEach(Array(SocialFormat.allCases.enumerated()), id: \.element) { index, format in
                Button("Vorschau \(format.title)") { state.setPreviewFormat(format) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }

            Divider()

            Button("Zeitleiste vergrössern (T)") { state.zoomTimeline(by: 1.6) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zeitleiste verkleinern (R)") { state.zoomTimeline(by: 1 / 1.6) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Ganzer Film") { state.zoom = 1 }

            Divider()

            ForEach(InspectorTab.allCases) { tab in
                Button(tab.title) { state.showInspector(tab) }
            }
        }
    }
}
