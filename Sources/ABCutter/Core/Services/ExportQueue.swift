import AppKit
import Foundation

enum ExportJobState: Equatable {
    case waiting
    case running(Double)
    case finished(URL)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .finished, .failed: true
        case .waiting, .running: false
        }
    }
}

struct ExportJobStatus: Identifiable {
    let id = UUID()
    var clipID: UUID
    var clipName: String
    var format: SocialFormat
    var outputURL: URL
    var state: ExportJobState = .waiting

    var progress: Double {
        switch state {
        case .waiting: 0
        case .running(let value): value
        case .finished: 1
        case .failed: 0
        }
    }
}

/// Runs the batch: every enabled clip against every selected format, one at a
/// time so the encoder is not fighting itself.
@MainActor
final class ExportQueue: ObservableObject {
    @Published private(set) var jobs: [ExportJobStatus] = []
    @Published private(set) var isRunning = false
    @Published private(set) var summary: String?

    private var task: Task<Void, Never>?

    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        return jobs.reduce(0) { $0 + $1.progress } / Double(jobs.count)
    }

    var finishedCount: Int {
        jobs.filter { if case .finished = $0.state { return true } else { return false } }.count
    }

    var failedCount: Int {
        jobs.filter { if case .failed = $0.state { return true } else { return false } }.count
    }

    func clear() {
        guard !isRunning else { return }
        jobs = []
        summary = nil
    }

    func cancel() {
        task?.cancel()
    }

    /// Builds the job list and starts encoding. Returns immediately.
    func start(project: ABProject, outputFolder: URL) {
        guard !isRunning else { return }

        let clips = project.clips.filter { $0.isEnabled && $0.duration > 0 }
        let formats = project.export.formats
        guard !clips.isEmpty, !formats.isEmpty else {
            summary = clips.isEmpty
                ? "No clips are marked for export."
                : "No output format is selected."
            return
        }

        let projectName = project.name
        var planned: [ExportJobStatus] = []
        for clip in clips {
            for format in formats {
                let filename = "\(projectName)_\(clip.safeName)_\(format.fileSuffix).mp4"
                planned.append(
                    ExportJobStatus(
                        clipID: clip.id,
                        clipName: clip.name,
                        format: format,
                        outputURL: outputFolder.appendingPathComponent(filename)
                    )
                )
            }
        }

        jobs = planned
        summary = nil
        isRunning = true

        // Labels are AppKit-drawn, so they are made here on the main actor and
        // handed to the exporter as finished images.
        var labelCache: [SocialFormat: (before: CGImage?, after: CGImage?)] = [:]
        if project.export.showLabels {
            for format in formats {
                labelCache[format] = (
                    LabelRenderer.pill(text: project.export.beforeLabel, targetSize: format.size),
                    LabelRenderer.pill(text: project.export.afterLabel, targetSize: format.size)
                )
            }
        }

        task = Task { [weak self] in
            await self?.run(project: project, labelCache: labelCache)
        }
    }

    private func run(project: ABProject, labelCache: [SocialFormat: (before: CGImage?, after: CGImage?)]) async {
        defer {
            isRunning = false
            task = nil
        }

        for index in jobs.indices {
            if Task.isCancelled {
                jobs[index].state = .failed("Cancelled")
                continue
            }

            guard let clip = project.clips.first(where: { $0.id == jobs[index].clipID }) else {
                jobs[index].state = .failed("The clip no longer exists.")
                continue
            }

            jobs[index].state = .running(0)
            let labels = labelCache[jobs[index].format]
            let request = ExportRequest(
                clip: clip,
                format: jobs[index].format,
                settings: project.export,
                outputURL: jobs[index].outputURL,
                beforeLabel: labels?.before,
                afterLabel: labels?.after
            )

            do {
                // The progress callback arrives on the encoder's queue. Bind a
                // strong reference here so the hop back to the main actor is
                // not capturing the mutable `weak self` slot.
                try await ClipExporter.export(project: project, request: request) { [weak self] value in
                    guard let queue = self else { return }
                    Task { @MainActor in
                        guard index < queue.jobs.count else { return }
                        if case .running = queue.jobs[index].state {
                            queue.jobs[index].state = .running(value)
                        }
                    }
                }
                jobs[index].state = .finished(jobs[index].outputURL)
            } catch {
                jobs[index].state = Task.isCancelled
                    ? .failed("Cancelled")
                    : .failed(error.localizedDescription)
            }
        }

        if failedCount == 0 {
            summary = "Exported \(finishedCount) file\(finishedCount == 1 ? "" : "s")."
        } else {
            summary = "Exported \(finishedCount), failed \(failedCount)."
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
