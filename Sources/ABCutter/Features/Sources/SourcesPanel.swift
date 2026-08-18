import SwiftUI

/// Left column: the picture and every audio layer under it, with the sync
/// controls that decide where each one sits.
@MainActor
struct SourcesPanel: View {
    @ObservedObject var state: AppState

    @State private var timecodeText = ""
    @State private var isEditingTimecode = false

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
                HStack(spacing: 5) {
                    Image(systemName: "film")
                        .font(.caption)
                        .foregroundStyle(Theme.videoTint)
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text("\(Int(state.project.videoNaturalWidth))×\(Int(state.project.videoNaturalHeight))")
                    Text("·")
                    Text(state.project.frameRate.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // The film's start timecode, editable: a delivery without an
                // embedded stamp still has a known base — mixes are stamped
                // against the sequence, so typing that base here is all
                // Auto-Sync needs.
                HStack(spacing: 6) {
                    Text("Erstes Bild bei")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("--:--:--:--", text: videoTimecodeBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 96)
                        .multilineTextAlignment(.center)
                        .onSubmit { isEditingTimecode = false }
                        .help("Timecode des ersten Bilds. Ohne eingebetteten Stempel hier setzen — 00:00:00:00 oder 01:00:00:00, je nachdem worauf die Mixe gestempelt sind.")
                }

                if state.project.videoTimecodeStartSeconds == nil {
                    Text("Kein Timecode — für Auto-Sync oben eintragen, oder per Wellenform syncen.")
                        .font(.caption2)
                        .foregroundStyle(Color.orange)
                }

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

    /// Shows the live start timecode unless the field is being typed into.
    /// An emptied field clears the base; a parsed one becomes it, and every
    /// timecode-stamped audio file can sync against it from then on.
    private var videoTimecodeBinding: Binding<String> {
        Binding(
            get: {
                if isEditingTimecode { return timecodeText }
                guard let start = state.project.videoTimecodeStartSeconds else { return "" }
                return Timecode.string(
                    fromSeconds: start,
                    rate: state.project.frameRate,
                    dropFrame: state.project.dropFrame
                )
            },
            set: { newValue in
                isEditingTimecode = true
                timecodeText = newValue
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    state.project.videoTimecodeStartSeconds = nil
                } else if let parsed = Timecode.seconds(
                    fromString: newValue,
                    rate: state.project.frameRate,
                    dropFrame: state.project.dropFrame
                ) {
                    state.project.videoTimecodeStartSeconds = parsed
                }
            }
        )
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
                // The modifiers below used to hang off the wrong button:
                // «Wellenform» was disabled whenever the video had no
                // timecode — exactly the situation waveform sync exists for.
                Button("Auto-Sync") { state.autoSyncAll() }
                    .controlSize(.small)
                    .disabled(state.project.videoTimecodeStartSeconds == nil)
                    .help("Jede gestempelte Datei per Timecode aufs Bild legen — dazu oben den Start-Timecode des Films setzen")
                Button("Wellenform") { state.alignAllByWaveform() }
                    .controlSize(.small)
                    .help("Alle Mixe am Originalton des Videos ausrichten — der Zwei-Pop steckt schon im Film")
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

                // What the layer is: violet film for sound out of a video
                // file (the embedded track included), green wave for a plain
                // audio file. What it plays comes after the name.
                Image(systemName: source.isEmbedded || source.isFromVideoFile ? "film" : "waveform")
                    .font(.caption)
                    .foregroundStyle(
                        source.isEmbedded || source.isFromVideoFile
                            ? Theme.videoTint
                            : Theme.audioFileTint
                    )
                    .help(
                        source.isEmbedded
                            ? "Tonspur des geladenen Films"
                            : source.isFromVideoFile
                                ? "Ton aus einer Videodatei — nur die Tonspur wird verwendet"
                                : "Audiodatei"
                    )

                Text(source.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                roleBadge

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
                if let stamp = source.timecodeStartSeconds {
                    Text("·")
                    // The file's own stamp, so the base the mixes are set
                    // against can be read straight off the list.
                    Text("TC \(Timecode.string(fromSeconds: stamp, rate: state.project.frameRate, dropFrame: state.project.dropFrame))")
                }
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

    /// What the monitor does with this layer right now: A in Rost, B in
    /// blue, or a quiet grey «stumm» — the same colours the timeline lanes
    /// wear, fed by the same resolution.
    @ViewBuilder
    private var roleBadge: some View {
        let (beforeID, afterID) = state.monitoredPair
        if source.id == beforeID {
            badge("A", tint: Theme.beforeTint)
        } else if source.id == afterID {
            badge("B", tint: Theme.afterTint)
        } else {
            Text("stumm")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .help("Keiner Seite zugewiesen — unten als A oder B wählen, damit die Spur zu hören ist")
        }
    }

    private func badge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint, in: Capsule())
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
                state.syncByTimecode(source)
            } label: {
                Image(systemName: "clock.badge.checkmark")
            }
            .help("Per Timecode aufs Bild legen — Stempel der Datei minus «Erstes Bild bei» des Films. Deterministisch, wo die Wellenform schätzt.")
            .disabled(source.timecodeStartSeconds == nil || state.project.videoTimecodeStartSeconds == nil)

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
