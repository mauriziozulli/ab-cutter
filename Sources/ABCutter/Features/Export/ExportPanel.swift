import SwiftUI

/// What the batch produces, where it lands, and how it is going.
@MainActor
struct ExportPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var queue: ExportQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            formatsSection
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
        .abSection("Output formats")
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
        VStack(alignment: .leading, spacing: 8) {
            Text(plan)
                .font(.caption)
                .foregroundStyle(plannedFileCount == 0 ? Color.orange : Color.secondary)

            HStack {
                Button(queue.isRunning ? "Exporting…" : "Export batch") {
                    state.startExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(queue.isRunning || plannedFileCount == 0)

                if queue.isRunning {
                    Button("Cancel") { queue.cancel() }
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
        .abSection("Run")
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
        guard clips > 0 else { return "No clips are marked for export." }
        guard formats > 0 else { return "No output format is selected." }
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
