import SwiftUI

/// The record page: frame, two inputs, one button.
@MainActor
struct RecordView: View {
    @ObservedObject var store: Store
    @Environment(\.studioStyle) private var style
    @State private var now = Date()

    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !store.hasScreenPermission {
                    permissionNote
                }
                frameSection
                soundSection
                filmSection
                recordButton
            }
            .frame(maxWidth: 560)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .onReceive(clock) { now = $0 }
        .onAppear {
            store.refreshDevices()
            store.armAudio()
        }
    }

    private var permissionNote: some View {
        Panel("Freigabe") {
            Hint("macOS muss Session Cutter die Bildschirmaufnahme erlauben. Nach dem Erlauben die App einmal neu starten.")
            Button("Freigabe anfragen") { store.requestScreenPermission() }
                .buttonStyle(StudioButtonStyle(kind: .primary))
        }
    }

    // MARK: - 1 Frame

    private var frameSection: some View {
        Panel("1  Rahmen über Pro Tools") {
            HStack {
                Button(store.frameVisible ? "Rahmen ausblenden" : "Rahmen zeigen") { store.toggleFrame() }
                    .buttonStyle(StudioButtonStyle())
                    .disabled(store.isRecording)
                Spacer()
                if store.frameVisible {
                    Text("\(Int(store.framePixels.width)) × \(Int(store.framePixels.height)) px")
                        .font(style.mono(AppType.meta))
                        .foregroundStyle(style.muted)
                }
            }
            Hint("Am blauen Reiter verschieben, an der Ecke unten rechts grösser ziehen. Das Format ist fest (3:2) — genau die untere Hälfte des 4:5-Posts. Pro Tools bleibt durch den Rahmen hindurch bedienbar; der Rahmen selbst wird nicht aufgenommen.")
        }
    }

    // MARK: - 2 Sound

    private var soundSection: some View {
        Panel("2  Ton aus Pro Tools") {
            routeRow(
                title: "Original",
                tint: Tint.original,
                route: $store.originalRoute,
                level: store.levels.original
            )
            routeRow(
                title: "Final Mix",
                tint: Tint.mix,
                route: $store.mixRoute,
                level: store.levels.mix
            )
            HStack {
                Hint("Ein Gerät mit vier Kanälen (1–2 Original, 3–4 Mix) oder zwei Geräte wie Audio Bridge 2A und 2B.")
                Spacer()
                Button("Geräte neu lesen") {
                    store.refreshDevices()
                    store.armAudio()
                }
                .buttonStyle(StudioButtonStyle(kind: .quiet))
                .disabled(store.isRecording)
            }
        }
    }

    private func routeRow(title: String, tint: Color, route: Binding<AudioRoute?>, level: Float) -> some View {
        let device = store.device(for: route.wrappedValue)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(title)
                    .font(style.ui(AppType.body, weight: .semibold))
                    .foregroundStyle(style.text)
                    .frame(width: 80, alignment: .leading)

                Picker("", selection: Binding<String>(
                    get: { route.wrappedValue?.deviceUID ?? "" },
                    set: { uid in
                        let channels = store.devices.first { $0.uid == uid }?.channels ?? 2
                        let first = min(route.wrappedValue?.firstChannel ?? 0, max(channels - 2, 0))
                        route.wrappedValue = AudioRoute(deviceUID: uid, firstChannel: first)
                    }
                )) {
                    if route.wrappedValue == nil || device == nil {
                        Text("— Gerät wählen —").tag("")
                    }
                    ForEach(store.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .disabled(store.isRecording)

                if let device {
                    Picker("", selection: Binding<Int>(
                        get: { route.wrappedValue?.firstChannel ?? 0 },
                        set: { route.wrappedValue?.firstChannel = $0 }
                    )) {
                        ForEach(device.pairs, id: \.self) { first in
                            Text(AudioRoute.pairTitle(first, channels: device.channels)).tag(first)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .disabled(store.isRecording)
                }
            }
            Meter(level: level, tint: tint)
                .padding(.leading, 16)
        }
    }

    // MARK: - 3 Film

    private var filmSection: some View {
        Panel("3  Film (optional, auch später)") {
            HStack {
                Text(store.session.filmURL?.lastPathComponent ?? "Kein Film gewählt")
                    .font(style.mono(AppType.meta))
                    .foregroundStyle(store.session.filmURL == nil ? style.faint : style.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Film wählen …") { store.presentFilmPicker() }
                    .buttonStyle(StudioButtonStyle())
                    .disabled(store.isRecording)
            }
            Hint("Das Bild oben im Post kommt aus der Filmdatei, nicht vom Bildschirm — volle Qualität. Nach der Aufnahme wird es automatisch am Originalton synchronisiert.")
        }
    }

    // MARK: - Record

    private var recordButton: some View {
        HStack(spacing: 16) {
            Button { store.toggleRecording() } label: {
                HStack(spacing: 10) {
                    Image(systemName: store.isRecording ? "stop.fill" : "record.circle")
                        .font(.system(size: 18, weight: .bold))
                    Text(store.isRecording ? "Stop" : "Record")
                        .font(style.ui(AppType.title, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .frame(height: 46)
                .background(Tint.record, in: RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)

            if let start = store.recordingStart {
                Text(Clock.string(now.timeIntervalSince(start)))
                    .font(style.mono(AppType.title + 4, weight: .semibold))
                    .foregroundStyle(Tint.record)
            } else {
                Hint("⌘R startet und stoppt. In Pro Tools abspielen, während aufgenommen wird.")
            }
        }
    }
}

/// A horizontal peak meter, -60 … 0 dBFS.
struct Meter: View {
    let level: Float
    let tint: Color
    @Environment(\.studioStyle) private var style

    init(level: Float, tint: Color) {
        self.level = level
        self.tint = tint
    }

    private var fraction: CGFloat {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(style.deep)
                RoundedRectangle(cornerRadius: 2)
                    .fill(level >= 0.99 ? style.error : tint)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
    }
}
