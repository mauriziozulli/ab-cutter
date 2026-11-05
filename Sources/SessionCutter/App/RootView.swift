import AppKit
import SwiftUI

@MainActor
struct RootView: View {
    @ObservedObject var store: Store
    @Environment(\.studioStyle) private var style
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            switch store.phase {
            case .record: RecordView(store: store)
            case .edit: EditView(store: store)
            }
            statusBar
        }
        .frame(minWidth: 1100, minHeight: 760)
        .background(style.bg)
        .alert(
            "Da ist etwas zu klären",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            ),
            actions: { Button("OK") { store.errorMessage = nil } },
            message: { Text(store.errorMessage ?? "") }
        )
        .studioStyle()
        .onAppear {
            installKeys()
            if store.phase == .record { store.enterRecordPhase() }
        }
    }

    // MARK: - Chrome

    private var titleBar: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 62, height: 1)
            HStack(spacing: 6) {
                Text("SESSION")
                    .foregroundStyle(style.text)
                Text("CUTTER")
                    .foregroundStyle(style.counterpoint)
            }
            .font(style.mono(AppType.meta, weight: .semibold))
            .tracking(AppType.titleTracking)

            Spacer()

            Picker("", selection: Binding(
                get: { store.phase },
                set: { $0 == .record ? store.enterRecordPhase() : store.enterEditPhase() }
            )) {
                ForEach(Phase.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(store.isRecording || store.session.recording == nil)

            Spacer()

            Text(store.sessionName)
                .font(style.ui(AppType.small + 1))
                .foregroundStyle(style.muted)
                .lineLimit(1)
                .frame(width: 220, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .studioBar(style)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(store.status)
                .font(style.ui(AppType.small))
                .foregroundStyle(style.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("v\(AppVersion.string)")
                .font(style.mono(AppType.small))
                .foregroundStyle(style.faint)
        }
        .padding(.horizontal, 14)
        .frame(height: style.statusBarHeight)
        .background(style.sunken)
    }

    // MARK: - Keys

    /// Bare keys for the cut, the way an editor's hand expects them. Never
    /// while a text field is being typed into.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  store.phase == .edit else { return event }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }

            switch event.keyCode {
            case 49: store.togglePlay(); return nil              // space
            case 123: store.step(frames: event.modifierFlags.contains(.shift) ? -10 : -1); return nil
            case 124: store.step(frames: event.modifierFlags.contains(.shift) ? 10 : 1); return nil
            case 51, 117: store.deleteSelection(); return nil   // ⌫, ⌦
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": store.addSwitchAtPlayhead(); return nil
            case "s": store.addStillAtPlayhead(); return nil
            case "i": store.markIn(); return nil
            case "o": store.markOut(); return nil
            case "t": store.zoom = min(store.zoom * 1.6, 60); return nil
            case "r": store.zoom = max(store.zoom / 1.6, 1); return nil
            default: return event
            }
        }
    }
}
