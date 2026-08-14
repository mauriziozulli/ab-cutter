import SwiftUI

/// Right column, lower half: what the batch produces and where it lands.
@MainActor
struct ExportPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var queue: ExportQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            formatsSection
            lookSection
            deliverySection
            runSection
            if !queue.jobs.isEmpty {
                jobsSection
            }
        }
    }

    // MARK: - Formats

    private var formatsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SocialFormat.allCases) { format in
                Toggle(isOn: formatBinding(format)) {
                    HStack(spacing: 6) {
                        Text(format.title)
                            .font(.system(size: 12, weight: .medium))
                        Text(format.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }

            Picker("Fit", selection: Binding(
                get: { state.project.export.fitMode },
                set: {
                    state.project.export.fitMode = $0
                    state.applyPlayerSettings()
                }
            )) {
                ForEach(FitMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .controlSize(.small)
        }
        .abCard()
        .abSection("Output formats")
    }

    /// Writes an export setting and re-applies it to the preview, so the look
    /// controls and the burnt-in labels stay in step with what will be encoded.
    private func exportBinding<Value>(_ keyPath: WritableKeyPath<ExportSettings, Value>) -> Binding<Value> {
        Binding(
            get: { state.project.export[keyPath: keyPath] },
            set: {
                state.project.export[keyPath: keyPath] = $0
                state.applyPlayerSettings()
            }
        )
    }

    private func formatBinding(_ format: SocialFormat) -> Binding<Bool> {
        Binding(
            get: { state.project.export.formats.contains(format) },
            set: { isOn in
                var formats = state.project.export.formats
                if isOn {
                    if !formats.contains(format) { formats.append(format) }
                } else {
                    formats.removeAll { $0 == format }
                }
                // Keep a stable, predictable order for filenames.
                state.project.export.formats = SocialFormat.allCases.filter { formats.contains($0) }
            }
        )
    }

    // MARK: - Look

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Before", selection: Binding(
                get: { state.project.export.beforeLook },
                set: {
                    state.project.export.beforeLook = $0
                    state.applyPlayerSettings()
                }
            )) {
                ForEach(LookStyle.allCases) { look in
                    Text(look.title).tag(look)
                }
            }
            .controlSize(.small)

            Picker("After", selection: Binding(
                get: { state.project.export.afterLook },
                set: {
                    state.project.export.afterLook = $0
                    state.applyPlayerSettings()
                }
            )) {
                ForEach(LookStyle.allCases) { look in
                    Text(look.title).tag(look)
                }
            }
            .controlSize(.small)

            Toggle("Burn in labels", isOn: exportBinding(\.showLabels))
                .toggleStyle(.checkbox)

            if state.project.export.showLabels {
                HStack(spacing: 6) {
                    TextField("Before", text: exportBinding(\.beforeLabel))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    TextField("After", text: exportBinding(\.afterLabel))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
                Picker("Style", selection: exportBinding(\.labelStyle)) {
                    ForEach(LabelStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .controlSize(.small)

                if state.project.export.labelStyle == .tinted {
                    Picker("Shadow", selection: exportBinding(\.labelShadow)) {
                        ForEach(LabelShadowMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .help("Auto adds a soft shadow only where the tint would not read against the picture")
                }

                Picker("Position", selection: exportBinding(\.labelPosition)) {
                    ForEach(LabelPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .controlSize(.small)

                if state.project.export.labelStyle == .tinted {
                    Text("The tint is read from the colour frame, so the black-and-white half keeps a coloured label.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Text("Audio crossfade")
                    .font(.caption)
                Slider(value: $state.project.export.audioCrossfadeMilliseconds, in: 0...500)
                    .controlSize(.mini)
                Text("\(Int(state.project.export.audioCrossfadeMilliseconds)) ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .abCard()
        .abSection("A/B look")
    }

    // MARK: - Delivery

    private var deliverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Codec", selection: $state.project.export.codec) {
                ForEach(VideoCodecChoice.allCases) { codec in
                    Text(codec.title).tag(codec)
                }
            }
            .controlSize(.small)

            HStack(spacing: 6) {
                Text(folderLabel)
                    .font(.caption)
                    .foregroundStyle(state.project.export.outputFolderPath == nil ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Choose…") { state.chooseOutputFolder() }
                    .controlSize(.small)
            }
        }
        .abCard()
        .abSection("Delivery")
    }

    private var folderLabel: String {
        guard let path = state.project.export.outputFolderPath else { return "No output folder chosen" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Run

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(queue.isRunning ? "Exporting…" : "Export batch") {
                    state.startExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(queue.isRunning || !state.project.hasVideo)

                if queue.isRunning {
                    Button("Cancel") { queue.cancel() }
                        .controlSize(.small)
                }

                Spacer()

                Text(plan)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if queue.isRunning {
                ProgressView(value: queue.overallProgress)
                    .controlSize(.small)
            }

            if let summary = queue.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(queue.failedCount > 0 ? Color.orange : Color.secondary)
            }
        }
    }

    private var plan: String {
        let clips = state.project.clips.filter { $0.isEnabled && $0.duration > 0 }.count
        let formats = state.project.export.formats.count
        let total = clips * formats
        return "\(clips) clip\(clips == 1 ? "" : "s") × \(formats) format\(formats == 1 ? "" : "s") = \(total) file\(total == 1 ? "" : "s")"
    }

    // MARK: - Jobs

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(queue.jobs) { job in
                HStack(spacing: 6) {
                    statusIcon(job.state)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(job.clipName) · \(job.format.title)")
                            .font(.caption)
                            .lineLimit(1)
                        if case .failed(let message) = job.state {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        } else if case .running(let value) = job.state {
                            ProgressView(value: value)
                                .controlSize(.mini)
                        }
                    }
                    Spacer()
                    if case .finished(let url) = job.state {
                        Button {
                            queue.revealInFinder(url)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Show in Finder")
                    }
                }
            }
        }
        .abSection("Queue")
    }

    @ViewBuilder
    private func statusIcon(_ jobState: ExportJobState) -> some View {
        switch jobState {
        case .waiting:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.accent)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
