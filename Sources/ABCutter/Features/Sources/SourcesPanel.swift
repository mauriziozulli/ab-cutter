import SwiftUI

/// Left column: the picture and every audio layer under it, with the sync
/// controls that decide where each one sits.
@MainActor
struct SourcesPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                videoSection
                audioSection
                defaultsSection
            }
            .padding(Theme.panelPadding)
        }
        .background(Theme.panelBackground)
    }

    // MARK: - Video

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = state.project.videoURL {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("\(Int(state.project.videoNaturalWidth))×\(Int(state.project.videoNaturalHeight))")
                    Text("·")
                    Text(state.project.frameRate.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(videoTimecodeLine)
                    .font(.caption)
                    .foregroundStyle(state.project.videoTimecodeStartSeconds == nil ? Color.orange : Color.secondary)

                HStack {
                    Picker("", selection: frameRateBinding) {
                        ForEach(FrameRate.allCases) { rate in
                            Text(rate.title).tag(rate)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)

                    if state.project.frameRate.supportsDropFrame {
                        Toggle("DF", isOn: dropFrameBinding)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .help("Drop-Frame-Timecode anzeigen")
                    }
                }
            } else {
                Text("Kein Video geladen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(state.project.hasVideo ? "Video ersetzen …" : "Video wählen …") {
                state.presentVideoPicker()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abCard()
        .abSection("Bild")
    }

    private var videoTimecodeLine: String {
        guard let start = state.project.videoTimecodeStartSeconds else {
            return "Kein eingebetteter Timecode"
        }
        let formatted = Timecode.string(
            fromSeconds: start,
            rate: state.project.frameRate,
            dropFrame: state.project.dropFrame
        )
        return "Beginnt bei \(formatted)"
    }

    private var frameRateBinding: Binding<FrameRate> {
        Binding(
            get: { state.project.frameRate },
            set: { state.project.frameRate = $0 }
        )
    }

    private var dropFrameBinding: Binding<Bool> {
        Binding(
            get: { state.project.dropFrame },
            set: { state.project.dropFrame = $0 }
        )
    }

    // MARK: - Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.project.audioSources) { source in
                AudioSourceRow(state: state, source: source)
            }

            if state.project.audioSources.isEmpty {
                Text("Noch keine Tonspuren.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Ton hinzufügen …") { state.presentAudioPicker() }
                    .controlSize(.small)
                Button("Auto-Sync") { state.autoSyncAll() }
                Button("Wellenform") { state.alignAllByWaveform() }
                    .help("Alle Mixe am Originalton des Videos ausrichten — der Zwei-Pop steckt schon im Film")
                    .controlSize(.small)
                    .disabled(state.project.videoTimecodeStartSeconds == nil)
                    .help("Jede gestempelte Datei per eingebettetem Timecode aufs Bild legen")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abSection("Tonspuren")
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sourcePicker(
                title: "A (vorher)",
                tint: Theme.beforeTint,
                selection: Binding(
                    get: { state.project.defaultBeforeSourceID },
                    set: {
                        state.project.defaultBeforeSourceID = $0
                        state.applyPlayerSettings()
                    }
                )
            )
            sourcePicker(
                title: "B (nachher)",
                tint: Theme.afterTint,
                selection: Binding(
                    get: { state.project.defaultAfterSourceID },
                    set: {
                        state.project.defaultAfterSourceID = $0
                        state.applyPlayerSettings()
                    }
                )
            )
            Text("Clips verwenden diese, sofern sie nichts eigenes setzen.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abCard()
        .abSection("Standard-A/B-Paar")
    }

    private func sourcePicker(title: String, tint: Color, selection: Binding<UUID?>) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .frame(width: 62, alignment: .leading)
            Picker("", selection: selection) {
                Text("—").tag(UUID?.none)
                ForEach(state.project.audioSources) { source in
                    Text(source.name).tag(UUID?.some(source.id))
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

/// One audio layer: name, sync state, offset nudges and gain.
@MainActor
struct AudioSourceRow: View {
    @ObservedObject var state: AppState
    let source: AudioSource

    @State private var offsetText: String = ""
    @State private var isEditingOffset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("", isOn: enabledBinding)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("In der Vorschau berücksichtigen")

                Text(source.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if !source.isEmbedded {
                    Button {
                        state.removeSource(source)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Diese Spur entfernen")
                }
            }

            HStack(spacing: 6) {
                Text(source.channelDescription)
                Text("·")
                Text(Timecode.clockString(fromSeconds: source.durationSeconds))
                Text("·")
                Text(source.syncMode.title)
                    .foregroundStyle(
                        source.syncMode == .timecode || source.syncMode == .waveform
                            ? Color.green
                            : .secondary
                    )
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            channelControl

            if !source.isEmbedded {
                offsetControls
                gainControl
            } else {
                gainControl
            }
        }
        .padding(8)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { source.isEnabled },
            set: { newValue in
                var updated = source
                updated.isEnabled = newValue
                state.updateSource(updated)
            }
        )
    }

    private var offsetControls: some View {
        HStack(spacing: 4) {
            Button {
                state.alignByWaveform(source)
            } label: {
                Image(systemName: "waveform.badge.magnifyingglass")
            }
            .help("Per Wellenform am Originalton ausrichten")

            Button("−10f") { state.nudgeOffset(-10 * state.project.frameDuration, for: source) }
            Button("−1f") { state.nudgeOffset(-state.project.frameDuration, for: source) }

            TextField("", text: offsetBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 92)
                .multilineTextAlignment(.center)
                .onSubmit { isEditingOffset = false }
                .help("Versatz zum ersten Bild des Films, in Sekunden. HH:MM:SS:FF geht auch.")

            Button("+1f") { state.nudgeOffset(state.project.frameDuration, for: source) }
            Button("+10f") { state.nudgeOffset(10 * state.project.frameDuration, for: source) }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    /// Shows the live offset unless the field is being typed into, so nudges
    /// stay visible without stomping on an in-progress edit.
    private var offsetBinding: Binding<String> {
        Binding(
            get: {
                isEditingOffset ? offsetText : String(format: "%.3f", source.offsetSeconds)
            },
            set: { newValue in
                isEditingOffset = true
                offsetText = newValue
                if let parsed = Timecode.seconds(
                    fromString: newValue,
                    rate: state.project.frameRate,
                    dropFrame: state.project.dropFrame
                ) {
                    state.setOffset(parsed, for: source)
                }
            }
        )
    }

    /// Production sound often puts the dialogue on one channel only, and the
    /// fold is rendered out rather than mixed live — so this is a deliberate
    /// choice with a wait attached, not a toggle.
    private var channelControl: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker("", selection: Binding(
                get: { source.channelMode },
                set: { state.setChannelMode($0, for: source) }
            )) {
                ForEach(ChannelMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .help("Liegt der Dialog nur auf einem Kanal, zentriert »Nur links« ihn ohne Pegelverlust — die Summe würde ihn halbieren.")

            if source.channelMode.foldsToMono, source.needsFold {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Mono-Datei wird gerechnet …")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var gainControl: some View {
        HStack(spacing: 6) {
            Text("Pegel")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { source.gainDB },
                    set: { newValue in
                        var updated = source
                        updated.gainDB = newValue
                        state.updateSource(updated)
                    }
                ),
                in: -24...12
            )
            .controlSize(.mini)
            Text(String(format: "%+.1f dB", source.gainDB))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }
}
