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
                            .help("Display drop-frame timecode")
                    }
                }
            } else {
                Text("No video loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(state.project.hasVideo ? "Replace video…" : "Choose video…") {
                state.presentVideoPicker()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abCard()
        .abSection("Picture")
    }

    private var videoTimecodeLine: String {
        guard let start = state.project.videoTimecodeStartSeconds else {
            return "No embedded timecode"
        }
        let formatted = Timecode.string(
            fromSeconds: start,
            rate: state.project.frameRate,
            dropFrame: state.project.dropFrame
        )
        return "Starts at \(formatted)"
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
                Text("No audio layers yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Add audio…") { state.presentAudioPicker() }
                    .controlSize(.small)
                Button("Auto-sync") { state.autoSyncAll() }
                    .controlSize(.small)
                    .disabled(state.project.videoTimecodeStartSeconds == nil)
                    .help("Line every stamped file up with the picture using its embedded timecode")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abSection("Audio layers")
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sourcePicker(
                title: "Before",
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
                title: "After",
                tint: Theme.afterTint,
                selection: Binding(
                    get: { state.project.defaultAfterSourceID },
                    set: {
                        state.project.defaultAfterSourceID = $0
                        state.applyPlayerSettings()
                    }
                )
            )
            Text("Clips use these unless they override them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abCard()
        .abSection("Default A/B pair")
    }

    private func sourcePicker(title: String, tint: Color, selection: Binding<UUID?>) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .frame(width: 44, alignment: .leading)
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
                    .help("Include in the preview timeline")

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
                    .help("Remove this layer")
                }
            }

            HStack(spacing: 6) {
                Text(source.channelDescription)
                Text("·")
                Text(Timecode.clockString(fromSeconds: source.durationSeconds))
                Text("·")
                Text(source.syncMode.title)
                    .foregroundStyle(source.syncMode == .timecode ? Color.green : .secondary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !source.isEmbedded {
                offsetControls
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
            Button("−10f") { state.nudgeOffset(-10 * state.project.frameDuration, for: source) }
            Button("−1f") { state.nudgeOffset(-state.project.frameDuration, for: source) }

            TextField("", text: offsetBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 92)
                .multilineTextAlignment(.center)
                .onSubmit { isEditingOffset = false }
                .help("Offset from the first frame of the picture, in seconds. HH:MM:SS:FF is accepted too.")

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

    private var gainControl: some View {
        HStack(spacing: 6) {
            Text("Gain")
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
