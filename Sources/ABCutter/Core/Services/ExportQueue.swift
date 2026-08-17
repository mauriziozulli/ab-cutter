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
                ? "Kein Clip ist für den Export markiert."
                : "Es ist kein Ausgabeformat gewählt."
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

        task = Task { [weak self] in
            await self?.run(project: project)
        }
    }

    private func run(project: ABProject) async {
        defer {
            isRunning = false
            task = nil
        }

        for index in jobs.indices {
            if Task.isCancelled {
                jobs[index].state = .failed("Abgebrochen")
                continue
            }

            guard let clip = project.clips.first(where: { $0.id == jobs[index].clipID }) else {
                jobs[index].state = .failed("Der Clip existiert nicht mehr.")
                continue
            }

            jobs[index].state = .running(0)

            // Overlays are built per clip and format: a tinted label has to
            // read the picture it will sit on, and the frame border follows
            // the crop, both of which differ with every format.
            let overlays = await LabelFactory.overlays(
                project: project,
                clip: clip,
                format: jobs[index].format
            )
            let cards = await Self.cards(project: project, clip: clip, format: jobs[index].format)
            let request = ExportRequest(
                clip: clip,
                format: jobs[index].format,
                settings: project.export,
                outputURL: jobs[index].outputURL,
                overlays: overlays,
                titleCard: cards.title,
                endCard: cards.end
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
                    ? .failed("Abgebrochen")
                    : .failed(error.localizedDescription)
            }
        }

        if failedCount == 0 {
            summary = "\(finishedCount) Datei\(finishedCount == 1 ? "" : "en") exportiert."
        } else {
            summary = "\(finishedCount) exportiert, \(failedCount) fehlgeschlagen."
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - The two cards

    /// Builds the cards a reel carries at each end.
    ///
    /// Each is made from the clip's *own* first frame rather than from the
    /// still held in the Cover tab, so a batch of a dozen excerpts gets a
    /// dozen matching title cards without anyone parking a playhead twelve
    /// times. A card that cannot be built comes back nil and the exporter
    /// simply gives it no hold.
    private static func cards(
        project: ABProject,
        clip: Clip,
        format: SocialFormat
    ) async -> (title: CGImage?, end: CGImage?) {
        var settings = project.stills
        let hold = project.export.cardHold(for: format)
        let wantsTitle = hold.lead > 0
        let wantsEnd = hold.tail > 0
        guard wantsTitle || wantsEnd else { return (nil, nil) }

        // Each clip may carry its own card texts — a different selection
        // often needs a different title. Empty fields fall back to the Cover
        // tab, and the headline finally to the film's name.
        func chosen(_ own: String, over shared: String) -> String {
            let trimmed = own.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? shared : trimmed
        }
        settings.headline = chosen(clip.look.cardHeadline, over: settings.headline)
        settings.subline = chosen(clip.look.cardSubline, over: settings.subline)
        settings.endNote = chosen(clip.look.cardNote, over: settings.endNote)
        if settings.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.headline = project.name
        }

        // Only decoded when something is actually laid on top of the picture.
        var frame: CGImage?
        if let url = project.videoURL, wantsTitle || settings.endGround == .frame {
            frame = try? await StillExporter.grab(videoURL: url, at: clip.start)
        }

        let safeArea = project.export.safeArea(for: format)
        let title = wantsTitle ? frame.flatMap {
            StillExporter.titleCard(
                frame: $0, format: format, settings: settings, fitMode: clip.look.fitMode,
                panX: clip.panX, panY: clip.panY, safeArea: safeArea
            )
        } : nil
        let end = wantsEnd
            ? StillExporter.endCard(
                frame: frame, format: format, settings: settings, fitMode: clip.look.fitMode,
                panX: clip.panX, panY: clip.panY, safeArea: safeArea
            )
            : nil
        return (title, end)
    }
}
