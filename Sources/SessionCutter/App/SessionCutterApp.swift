import AppKit
import SwiftUI

@main
struct SessionCutterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("Session Cutter") {
            RootView(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { SessionCommands(store: store) }
    }
}

/// A SwiftPM executable has no bundle main nib, so the activation policy has
/// to be set explicitly or the window opens behind everything.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Typography.register()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

enum AppVersion {
    static let string = "0.1.0"
}

struct SessionCommands: Commands {
    @ObservedObject var store: Store

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neue Aufnahme") { store.enterRecordPhase() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Session öffnen …") { store.presentOpenSession() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Film wählen …") { store.presentFilmPicker() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Exportieren") { store.export() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store.session.recording == nil || store.isExporting)
        }
        CommandMenu("Schnitt") {
            Button("A/B-Wechsel hier") { store.addSwitchAtPlayhead() }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(store.session.recording == nil)
            Button("Still hier") { store.addStillAtPlayhead() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(store.session.recording == nil)
            Button("Gewählten Marker löschen") { store.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.selection == nil)
            Divider()
            Button("In setzen") { store.markIn() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Out setzen") { store.markOut() }
                .keyboardShortcut("]", modifiers: .command)
            Button("In/Out zurücksetzen") { store.clearInOut() }
            Divider()
            Button("Film am Originalton syncen") { store.syncFilm() }
                .disabled(store.session.filmURL == nil || store.session.recording == nil)
        }
    }
}
