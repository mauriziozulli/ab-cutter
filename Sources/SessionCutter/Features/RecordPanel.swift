import SwiftUI

/// The record inspector on the left: what is framed, what comes in, and
/// whether it arrives. Record itself sits in the title bar.
@MainActor
struct RecordPanel: View {
    @ObservedObject var store: Store
    @Environment(\.studioStyle) private var style

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !store.hasScreenPermission {
                    permissionNote
                }
                if store.micPermission == .denied || store.micPermission == .restricted {
                    micNote
                }
                frameSection
                soundSection
                Hint("Record nimmt ab dem Abspielkopf auf — nach 5 Sekunden Countdown. Ein neuer Take ersetzt ab seiner Stelle, was dort lag. Mit Film setzt der Ton jeden Take genau an seine Filmstelle.")
            }
            .padding(14)
        }
        .background(style.bg)
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

    private var micNote: some View {
        Panel("Ton-Freigabe") {
            Hint("macOS lässt Session Cutter keinen Ton aufnehmen — auch die Audio Bridge zählt als «Mikrofon». Ohne Freigabe kommt nur Stille an. Freigabe erteilen, dann die App neu starten. Läuft sie aus Xcode, braucht Xcode die Freigabe.")
            Button("Mikrofon-Einstellungen öffnen") { store.openMicrophoneSettings() }
                .buttonStyle(StudioButtonStyle(kind: .primary))
        }
    }

    // MARK: - 1 Frame

    private var frameSection: some View {
        Panel("Rahmen über Pro Tools") {
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
        Panel("Ton aus Pro Tools") {
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
            Hint("Ein Gerät mit vier Kanälen (1–2 Original, 3–4 Mix) oder zwei Geräte wie Audio Bridge 2A und 2B.")
            HStack {
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
                    .frame(width: 66, alignment: .leading)

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
                    .frame(width: 96)
                    .disabled(store.isRecording)
                }
            }
            Meter(level: level, tint: tint)
                .padding(.leading, 16)
            if let device, let channels = store.channelLevels[device.uid] {
                ChannelMeters(
                    levels: channels,
                    selected: route.wrappedValue.map { [$0.firstChannel, $0.firstChannel + 1] } ?? [],
                    tint: tint
                )
                .padding(.leading, 16)
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

/// One small meter per channel of a device, numbered, with the pair this side
/// records from lit in its colour. Answers "is anything arriving, and where?"
struct ChannelMeters: View {
    let levels: [Float]
    let selected: [Int]
    let tint: Color
    @Environment(\.studioStyle) private var style

    init(levels: [Float], selected: [Int], tint: Color) {
        self.levels = levels
        self.selected = selected
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let isSelected = selected.contains(index)
                VStack(spacing: 2) {
                    GeometryReader { geometry in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(style.deep)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(level >= 0.99 ? style.error : (isSelected ? tint : style.muted))
                                .frame(height: geometry.size.height * Self.fraction(level))
                        }
                    }
                    .frame(width: 10, height: 34)
                    Text("\(index + 1)")
                        .font(style.mono(9, weight: isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? tint : style.faint)
                }
            }
        }
    }

    static func fraction(_ level: Float) -> CGFloat {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }
}
