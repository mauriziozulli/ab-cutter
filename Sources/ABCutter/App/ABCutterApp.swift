import AppKit
import SwiftUI

@main
struct ABCutterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Owned here rather than by the root view, so the menu bar can drive the
    /// same actions the panels do.
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView(state: state)
        }
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(state: state)
        }
    }
}

/// A SwiftPM executable has no bundle main nib, so the activation policy has
/// to be set explicitly or the window opens behind everything.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
