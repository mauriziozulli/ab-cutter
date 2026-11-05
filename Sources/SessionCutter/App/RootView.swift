import AppKit
import SwiftUI

/// One window: record inspector on the left when wanted, the post and its
/// settings in the middle and right, the timeline underneath. Record sits in
/// the title bar and records from the playhead.
@MainActor
struct RootView: View {
    @ObservedObject var store: Store
    @Environment(\.studioStyle) private var style
    @State private var keyMonitor: Any?
    @State private var now = Date()

    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                if store.showRecordPanel {
                    RecordPanel(store: store)
                        .frame(width: 330)
                    Rectangle().fill(style.line).frame(width: 1)
                }
                EditView(store: store)
            }
            statusBar
        }
        .frame(minWidth: 1180, minHeight: 760)
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
        .onReceive(clock) { now = $0 }
        .onAppear {
            installKeys()
            if store.showRecordPanel {
                store.refreshDevices()
                store.armAudio()
                if store.hasScreenPermission { store.showFrame() }
            }
        }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 62, height: 1)

            Button { store.toggleRecordPanel() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(StudioButtonStyle(kind: store.showRecordPanel ? .normal : .quiet))
            .help("Aufnahme-Inspektor: Rahmen, Eingänge, Pegel")

            HStack(spacing: 6) {
                Text("SESSION").foregroundStyle(style.text)
                Text("CUTTER").foregroundStyle(style.counterpoint)
            }
            .font(style.mono(AppType.meta, weight: .semibold))
            .tracking(AppType.titleTracking)

            Rectangle().fill(style.line).frame(width: 1, height: 18)

            Button { store.toggleFrame() } label: {
                Label(store.frameVisible ? "Rahmen aus" : "Rahmen", systemImage: "viewfinder")
            }
            .buttonStyle(StudioButtonStyle(kind: store.frameVisible ? .counterpoint : .normal))
            .disabled(store.isRecording)
            .help("Den Aufnahmerahmen über Pro Tools zeigen oder ausblenden")

            Button { store.presentFilmPicker() } label: {
                Label(store.session.filmURL == nil ? "Film …" : store.session.filmURL!.lastPathComponent, systemImage: "film")
                    .lineLimit(1)
                    .frame(maxWidth: 220)
            }
            .buttonStyle(StudioButtonStyle())
            .disabled(store.isRecording)
            .help("Den fertigen Film wählen — er wird nur gelesen")

            Spacer()

            recordButton

            Spacer()

            Text(store.sessionName)
                .font(style.ui(AppType.small + 1))
                .foregroundStyle(style.muted)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .trailing)

            Menu {
                Button("Neue Session") { store.newSession() }
                Button("Session öffnen …") { store.presentOpenSession() }
                Button("Speichern") { store.saveSession() }
                Button("Speichern unter …") { store.saveSessionAs() }
                Divider()
                Button("Im Finder zeigen") { store.revealFolder() }
                    .disabled(store.folder == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.isRecording)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .studioBar(style)
    }

    private var recordButton: some View {
        HStack(spacing: 10) {
            Button { store.toggleRecording() } label: {
                HStack(spacing: 7) {
                    Image(systemName: store.isRecording ? "stop.fill" : (store.countdown != nil ? "xmark" : "record.circle"))
                        .font(.system(size: 13, weight: .bold))
                    Text(store.isRecording ? "Stop" : (store.countdown != nil ? "Abbrechen" : "Record ab \(Clock.string(store.currentTime))"))
                        .font(style.ui(AppType.body, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Tint.record, in: RoundedRectangle(cornerRadius: style.controlRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("⌘R — nimmt nach 5 Sekunden Countdown ab dem Abspielkopf auf")

            if let countdown = store.countdown {
                Text("\(countdown)")
                    .font(style.mono(AppType.title + 2, weight: .bold))
                    .foregroundStyle(style.ready)
                    .frame(minWidth: 70, alignment: .leading)
            } else if let start = store.recordingStart {
                Text(Clock.string(now.timeIntervalSince(start)))
                    .font(style.mono(AppType.title, weight: .semibold))
                    .foregroundStyle(Tint.record)
                    .frame(minWidth: 70, alignment: .leading)
            } else {
                Color.clear.frame(width: 70, height: 1)
            }
        }
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
    /// while a text field is being typed into, never while recording.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !store.isRecording else { return event }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }

            switch event.keyCode {
            case 53 where store.countdown != nil: store.cancelCountdown(); return nil   // esc
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
            case "t": store.zoom = min(store.zoom * 1.6, Store.zoomRange.upperBound); return nil
            case "r": store.zoom = max(store.zoom / 1.6, Store.zoomRange.lowerBound); return nil
            default: return event
            }
        }
    }
}
