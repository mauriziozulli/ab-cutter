import SwiftUI

/// What the batch produces, where it lands, and how it is going.
@MainActor
struct ExportPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var queue: ExportQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            formatsSection
            cardsSection
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abCard()
        .abSection("Ausgabeformate")
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

    // MARK: - Cards in the video

    /// Title and end card built into the file, for a reel — which has no
    /// slides to put them on.
    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Im Video", selection: state.exportBinding(\.cardAttachment)) {
                ForEach(CardAttachment.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .controlSize(.small)

            if state.project.export.cardAttachment != .off {
                slider(
                    "Titelbild",
                    value: state.exportBinding(\.leadSeconds),
                    range: 0...5,
                    readout: seconds(state.project.export.leadSeconds)
                )
                slider(
                    "Abspann",
                    value: state.exportBinding(\.tailSeconds),
                    range: 0...10,
                    readout: seconds(state.project.export.tailSeconds)
                )

                Text(cardHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .abCard()
        .abSection("Karten im Video")
    }

    private var cardHint: String {
        let export = state.project.export
        let lead = export.leadSeconds
        if lead < 0.05 {
            return "Kein Titelbild am Anfang — im Reel macht das Cover diese Arbeit, und die erste Sekunde entscheidet, ob überhaupt geschaut wird. Der Abspann hat dagegen keinen anderen Platz als das Video selbst."
        }
        return "Das Titelbild kostet die erste Sekunde, und die entscheidet im Reel, ob überhaupt geschaut wird — das Cover macht diese Arbeit schon. Auf 0 stellen, wenn das Video direkt beginnen soll."
    }

    private func seconds(_ value: Double) -> String {
        value < 0.05 ? "aus" : String(format: "%.1f s", value)
    }

    private func slider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        readout: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 62, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
            Text(readout)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    // MARK: - Delivery

    private var deliverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Codec", selection: state.exportBinding(\.codec)) {
                ForEach(VideoCodecChoice.allCases) { codec in
                    Text(codec.title).tag(codec)
                }
            }
            .controlSize(.small)

            HStack(spacing: 6) {
                Image(systemName: state.project.export.outputFolderPath == nil ? "folder.badge.questionmark" : "folder")
                    .foregroundStyle(state.project.export.outputFolderPath == nil ? Color.orange : Color.secondary)
                Text(folderLabel)
                    .font(.caption)
                    .foregroundStyle(state.project.export.outputFolderPath == nil ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Wählen …") { state.chooseOutputFolder() }
                    .controlSize(.small)
            }
        }
        .abCard()
        .abSection("Ausgabe")
    }

    private var folderLabel: String {
        guard let path = state.project.export.outputFolderPath else { return "Kein Zielordner gewählt" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Run

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan)
                .font(.caption)
                .foregroundStyle(plannedFileCount == 0 ? Color.orange : Color.secondary)

            HStack {
                Button(queue.isRunning ? "Exportiere …" : "Stapel exportieren") {
                    state.startExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(queue.isRunning || plannedFileCount == 0)

                if queue.isRunning {
                    Button("Abbrechen") { queue.cancel() }
                        .controlSize(.small)
                }
                Spacer()
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
        .abCard()
        .abSection("Lauf")
    }

    private var enabledClipCount: Int {
        state.project.clips.filter { $0.isEnabled && $0.duration > 0 }.count
    }

    private var plannedFileCount: Int {
        enabledClipCount * state.project.export.formats.count
    }

    private var plan: String {
        let clips = enabledClipCount
        let formats = state.project.export.formats.count
        guard clips > 0 else { return "Kein Clip ist für den Export markiert." }
        guard formats > 0 else { return "Es ist kein Ausgabeformat gewählt." }
        let total = clips * formats
        return "\(clips) Clip\(clips == 1 ? "" : "s") × \(formats) Format\(formats == 1 ? "" : "e") = \(total) Datei\(total == 1 ? "" : "en")"
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
                        .help("Im Finder zeigen")
                    }
                }
            }
        }
        .abSection("Warteschlange")
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
