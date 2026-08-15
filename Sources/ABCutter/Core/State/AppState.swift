import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

/// Owns the project, the media it points at, and the derived state the views
/// read. Media is only ever read — nothing is copied or rewritten.
@MainActor
final class AppState: ObservableObject {
    @Published var project = ABProject()
    @Published var selectedClipID: UUID?
    @Published var status: String = "Zum Start ein Video laden."
    @Published var errorMessage: String?
    @Published private(set) var isLoadingMedia = false
    /// Peak envelopes for the timeline, keyed by audio source.
    @Published private(set) var waveforms: [UUID: [Float]] = [:]

    /// Timeline zoom: 1 shows the whole film, higher values zoom in.
    @Published var zoom: Double = 1
    /// Which inspector the right-hand column is showing.
    @Published var inspectorTab: InspectorTab = .clips

    let player = PlayerController()
    let exportQueue = ExportQueue()

    private var projectURL: URL?
    private var waveformTasks: [UUID: Task<Void, Never>] = [:]
    private var reloadTask: Task<Void, Never>?
    private var labelTask: Task<Void, Never>?

    var selectedClip: Clip? {
        guard let selectedClipID else { return nil }
        return project.clips.first { $0.id == selectedClipID }
    }

    var selectedClipIndex: Int? {
        guard let selectedClipID else { return nil }
        return project.clips.firstIndex { $0.id == selectedClipID }
    }

    var windowTitle: String {
        project.hasVideo ? "\(AppVersion.productName) — \(project.name)" : AppVersion.productName
    }

    // MARK: - Loading media

    func presentVideoPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.message = "Fertigen Film wählen."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await loadVideo(url: url) }
    }

    func presentAudioPicker() {
        guard project.hasVideo else {
            errorMessage = "Erst das Video laden, dann Ton darunterlegen."
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .wav, .aiff, .mp3, .mpeg4Audio, .movie]
        panel.message = "Mixe oder Stems wählen, die unters Bild sollen."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addAudio(urls: urls) }
    }

    func loadVideo(url: URL) async {
        isLoadingMedia = true
        status = "Lese \(url.lastPathComponent) …"
        defer { isLoadingMedia = false }

        do {
            let probe = try await MediaProbe.probeVideo(url: url)

            var fresh = ABProject()
            fresh.videoPath = url.path
            fresh.videoDurationSeconds = probe.duration
            fresh.videoNaturalWidth = probe.naturalSize.width
            fresh.videoNaturalHeight = probe.naturalSize.height
            fresh.videoTimecodeStartSeconds = probe.timecode?.seconds
            fresh.frameRate = FrameRate.closest(to: probe.nominalFrameRate)
            // Loading a new film keeps the delivery preferences you already set.
            fresh.export = project.export
            fresh.defaultClipLengthSeconds = project.defaultClipLengthSeconds
            fresh.keepClipLengthFixed = project.keepClipLengthFixed
            // Look and delivery choices survive a new film; the cover text does
            // not, because it belongs to the film that was just replaced.
            fresh.stills = project.stills
            fresh.stills.headline = ""
            fresh.stills.subline = ""

            if probe.hasAudio {
                var embedded = AudioSource(
                    name: "Original (im Video)",
                    path: nil,
                    offsetSeconds: 0,
                    syncMode: .fileStart,
                    timecodeStartSeconds: probe.timecode?.seconds,
                    durationSeconds: probe.duration,
                    channelCount: probe.audioChannelCount,
                    sampleRate: probe.audioSampleRate
                )
                // The embedded track shares the picture's timeline by
                // definition, so it never needs an offset.
                embedded.syncMode = probe.timecode == nil ? .fileStart : .timecode
                fresh.audioSources = [embedded]
                fresh.defaultBeforeSourceID = embedded.id
                fresh.defaultAfterSourceID = embedded.id
            }

            project = fresh
            waveforms = [:]
            selectedClipID = nil
            addDefaultClip()

            let timecodeNote: String
            if let timecode = probe.timecode {
                timecodeNote = "Start \(Timecode.string(fromSeconds: timecode.seconds, rate: project.frameRate, dropFrame: project.dropFrame)) aus \(timecode.origin.title)"
            } else {
                timecodeNote = "kein Timecode — Ton wird ab Dateianfang gelegt"
            }
            status = "\(url.lastPathComponent) · \(Int(probe.naturalSize.width))×\(Int(probe.naturalSize.height)) · \(project.frameRate.title) · \(timecodeNote)"

            await player.reload(project: project, selectedClip: selectedClip)
            refreshWaveforms()
        } catch {
            errorMessage = error.localizedDescription
            status = "Das Video konnte nicht gelesen werden."
        }
    }

    func addAudio(urls: [URL]) async {
        isLoadingMedia = true
        defer { isLoadingMedia = false }

        var added = 0
        var syncedByTimecode = 0

        for url in urls {
            do {
                let probe = try await MediaProbe.probeAudio(url: url)
                var source = AudioSource(
                    name: url.deletingPathExtension().lastPathComponent,
                    path: url.path,
                    durationSeconds: probe.duration,
                    channelCount: probe.channelCount,
                    sampleRate: probe.sampleRate
                )
                source.timecodeStartSeconds = probe.timecode?.seconds

                if let audioStart = probe.timecode?.seconds,
                   let videoStart = project.videoTimecodeStartSeconds {
                    source.offsetSeconds = audioStart - videoStart
                    source.syncMode = .timecode
                    syncedByTimecode += 1
                } else {
                    source.offsetSeconds = 0
                    source.syncMode = .fileStart
                }

                project.audioSources.append(source)
                added += 1

                if project.defaultAfterSourceID == nil || project.audioSources.count == 2 {
                    // The first file added next to the original becomes the
                    // "after" side, which is what an A/B nearly always wants.
                    project.defaultAfterSourceID = source.id
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        guard added > 0 else { return }

        if project.defaultBeforeSourceID == nil {
            project.defaultBeforeSourceID = project.audioSources.first?.id
        }

        status = syncedByTimecode > 0
            ? "\(added) Spur\(added == 1 ? "" : "en") hinzugefügt — \(syncedByTimecode) per Timecode synchronisiert."
            : "\(added) Spur\(added == 1 ? "" : "en") hinzugefügt — kein Timecode, bitte von Hand syncen."

        await player.reload(project: project, selectedClip: selectedClip)
        refreshWaveforms()
    }

    func removeSource(_ source: AudioSource) {
        project.audioSources.removeAll { $0.id == source.id }
        if project.defaultBeforeSourceID == source.id {
            project.defaultBeforeSourceID = project.audioSources.first?.id
        }
        if project.defaultAfterSourceID == source.id {
            project.defaultAfterSourceID = project.audioSources.last?.id
        }
        for index in project.clips.indices {
            if project.clips[index].beforeSourceID == source.id { project.clips[index].beforeSourceID = nil }
            if project.clips[index].afterSourceID == source.id { project.clips[index].afterSourceID = nil }
        }
        waveforms[source.id] = nil
        waveformTasks[source.id]?.cancel()
        waveformTasks[source.id] = nil
        reloadPlayer()
    }

    // MARK: - Sync

    /// Re-derives every offset from embedded timecode where both sides have it.
    func autoSyncAll() {
        guard let videoStart = project.videoTimecodeStartSeconds else {
            errorMessage = "Das Video trägt keinen Timecode — es gibt nichts, wogegen synchronisiert werden könnte. Bitte von Hand ausrichten."
            return
        }

        var synced = 0
        for index in project.audioSources.indices {
            guard !project.audioSources[index].isEmbedded else {
                project.audioSources[index].offsetSeconds = 0
                continue
            }
            guard let audioStart = project.audioSources[index].timecodeStartSeconds else { continue }
            project.audioSources[index].offsetSeconds = audioStart - videoStart
            project.audioSources[index].syncMode = .timecode
            synced += 1
        }

        status = synced > 0
            ? "\(synced) Spur\(synced == 1 ? "" : "en") per Timecode synchronisiert."
            : "Keine Tonspur trägt einen Timecode."
        reloadPlayer()
    }

    func setOffset(_ seconds: Double, for source: AudioSource) {
        guard let index = project.audioSources.firstIndex(where: { $0.id == source.id }) else { return }
        project.audioSources[index].offsetSeconds = seconds
        project.audioSources[index].syncMode = .manual
        reloadPlayer(coalesce: true)
    }

    /// Shifts by a delta rather than an absolute value, so a drag stays correct
    /// even when the view it came from is holding a stale copy of the source.
    func shiftOffset(_ delta: Double, forSourceID id: UUID) {
        guard let index = project.audioSources.firstIndex(where: { $0.id == id }) else { return }
        project.audioSources[index].offsetSeconds += delta
        project.audioSources[index].syncMode = .manual
        reloadPlayer(coalesce: true)
    }

    func nudgeOffset(_ delta: Double, for source: AudioSource) {
        shiftOffset(delta, forSourceID: source.id)
    }

    func updateSource(_ source: AudioSource) {
        guard let index = project.audioSources.firstIndex(where: { $0.id == source.id }) else { return }
        let needsRebuild = project.audioSources[index].isEnabled != source.isEnabled
            || project.audioSources[index].offsetSeconds != source.offsetSeconds
        project.audioSources[index] = source
        if needsRebuild {
            reloadPlayer()
        } else {
            player.apply(project: project, selectedClip: selectedClip)
        }
    }

    // MARK: - Clips

    /// Fits a window of `length` starting at `start` inside the film. The
    /// length is preserved by sliding the window back from the end rather than
    /// truncating it; only a film shorter than the house length is cut short.
    private func fittedRange(start: Double, length: Double) -> (start: Double, end: Double) {
        let limit = project.videoDurationSeconds
        guard limit > 0 else { return (0, 0) }
        let clamped = min(max(length, project.frameDuration), limit)
        var begin = max(start, 0)
        if begin + clamped > limit { begin = limit - clamped }
        return (begin, begin + clamped)
    }

    /// Moves a clip to a new window while keeping the A/B switch at the same
    /// point proportionally, so a re-length never moves the reveal.
    private func reshaped(_ clip: Clip, start: Double, length: Double) -> Clip {
        var updated = clip
        let fraction = clip.splitFraction
        let range = fittedRange(start: start, length: length)
        updated.start = range.start
        updated.end = range.end
        if !clip.switchPoints.isEmpty {
            // Carry the switches proportionally, so a re-length never moves a
            // reveal relative to the material around it.
            let oldSpan = max(clip.duration, 0.001)
            updated.switchPoints = clip.switchPoints.map {
                range.start + (($0 - clip.start) / oldSpan) * (range.end - range.start)
            }
        }
        _ = fraction
        return updated
    }

    func addDefaultClip() {
        addClipAtPlayhead()
    }

    func addClipAtPlayhead() {
        guard project.videoDurationSeconds > 0 else { return }
        let range = fittedRange(start: player.currentTime, length: project.defaultClipLengthSeconds)
        let clip = Clip(name: "Clip \(project.clips.count + 1)", start: range.start, end: range.end)
        project.clips.append(clip)
        selectedClipID = clip.id
        player.apply(project: project, selectedClip: clip)
    }

    /// Snaps every clip to the house length, anchored on its existing in point.
    func applyDefaultLengthToAllClips() {
        guard !project.clips.isEmpty else { return }
        let length = project.defaultClipLengthSeconds
        for index in project.clips.indices {
            project.clips[index] = reshaped(project.clips[index], start: project.clips[index].start, length: length)
        }
        status = "\(project.clips.count) Clip\(project.clips.count == 1 ? "" : "s") auf \(formattedLength(length)) gesetzt."
        player.apply(project: project, selectedClip: selectedClip)
    }

    func setDefaultClipLength(_ seconds: Double) {
        project.defaultClipLengthSeconds = max(seconds, project.frameDuration)
    }

    private func formattedLength(_ seconds: Double) -> String {
        seconds == seconds.rounded()
            ? "\(Int(seconds)) s"
            : String(format: "%.1f s", seconds)
    }

    func removeClip(_ clip: Clip) {
        project.clips.removeAll { $0.id == clip.id }
        if selectedClipID == clip.id {
            selectedClipID = project.clips.first?.id
        }
        player.apply(project: project, selectedClip: selectedClip)
    }

    func updateClip(_ clip: Clip) {
        guard let index = project.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        project.clips[index] = clip
        project.clampClips()
        player.apply(project: project, selectedClip: selectedClip)
    }

    func selectClip(_ clip: Clip) {
        selectedClipID = clip.id
        player.seek(to: clip.start)
        player.apply(project: project, selectedClip: clip)
        refreshPreviewLabels()
    }

    /// Sets the selected clip's in point to the playhead. With a fixed house
    /// length the whole window slides instead of the head being trimmed.
    func markIn() {
        guard var clip = selectedClip else { return }
        if project.keepClipLengthFixed {
            clip = reshaped(clip, start: player.currentTime, length: project.defaultClipLengthSeconds)
        } else {
            clip.start = min(player.currentTime, clip.end - project.frameDuration)
        }
        updateClip(clip)
    }

    /// Sets the out point to the playhead — with a fixed length, the window
    /// ends here and its head follows.
    func markOut() {
        guard var clip = selectedClip else { return }
        if project.keepClipLengthFixed {
            let length = project.defaultClipLengthSeconds
            clip = reshaped(clip, start: player.currentTime - length, length: length)
        } else {
            clip.end = max(player.currentTime, clip.start + project.frameDuration)
        }
        updateClip(clip)
    }

    /// Selects a clip without moving the playhead — used while dragging, where
    /// a seek would fight the gesture.
    func focusClip(_ id: UUID) {
        guard selectedClipID != id else { return }
        selectedClipID = id
    }

    // MARK: - Direct manipulation
    //
    // These mutate the project without touching the player, because a drag
    // fires many times a second and rebuilding a Core Image video composition
    // per pixel would stall the gesture. The caller re-applies once on release.

    /// Slides a clip so it begins at `start`, keeping its length and the
    /// relative position of the A/B switch.
    func moveClip(_ id: UUID, toStart start: Double) {
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = project.clips[index]
        let range = fittedRange(start: start, length: clip.duration)
        let shift = range.start - clip.start
        project.clips[index].start = range.start
        project.clips[index].end = range.end
        if !clip.switchPoints.isEmpty {
            project.clips[index].switchPoints = clip.switchPoints.map { $0 + shift }
        }
    }

    /// Trims one clip's edges directly.
    func trimClip(_ id: UUID, start: Double, end: Double) {
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let limit = project.videoDurationSeconds
        let minimum = max(project.frameDuration, 0.04)

        var begin = min(max(start, 0), max(limit - minimum, 0))
        var finish = min(max(end, minimum), limit)
        if finish - begin < minimum {
            // Whichever edge moved is the one that gives way.
            if abs(begin - project.clips[index].start) > abs(finish - project.clips[index].end) {
                begin = finish - minimum
            } else {
                finish = begin + minimum
            }
        }

        project.clips[index].start = max(begin, 0)
        project.clips[index].end = min(finish, limit)
        if !project.clips[index].switchPoints.isEmpty {
            let lower = project.clips[index].start
            let upper = project.clips[index].end
            project.clips[index].switchPoints = project.clips[index].switchPoints
                .map { min(max($0, lower), upper) }
        }
    }

    /// Moves one clip's A/B switch directly.
    /// Moves the switch nearest `original` to `seconds` — what a drag on a
    /// switch mark on the timeline does.
    func moveSwitch(_ id: UUID, from original: Double, to seconds: Double) {
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var clip = project.clips[index]
        var points = clip.switches
        guard let nearest = points.indices.min(by: {
            abs(points[$0] - original) < abs(points[$1] - original)
        }) else { return }
        points[nearest] = min(max(seconds, clip.start), clip.end)
        clip.switchPoints = points.sorted()
        project.clips[index] = clip
    }

    /// Changes one clip's own length, anchored on its in point.
    func setLength(_ length: Double, for clip: Clip) {
        updateClip(reshaped(clip, start: clip.start, length: length))
    }

    /// Adds an A/B switch at the playhead. The sides simply alternate, so any
    /// number of these builds an A/B/A/B rhythm without further bookkeeping.
    func addSwitchAtPlayhead() {
        guard var clip = selectedClip else { return }
        guard player.currentTime > clip.start, player.currentTime < clip.end else {
            errorMessage = "Der Abspielkopf steht ausserhalb des Clips."
            return
        }
        clip.addSwitch(at: player.currentTime)
        updateClip(clip)
    }

    /// Replaces every switch with a single one at the playhead.
    func setSplitToPlayhead() {
        guard var clip = selectedClip else { return }
        clip.switchPoints = [min(max(player.currentTime, clip.start), clip.end)]
        updateClip(clip)
    }

    func removeSwitchNearestPlayhead() {
        guard var clip = selectedClip, clip.switches.count > 1 else { return }
        clip.removeSwitch(nearest: player.currentTime)
        updateClip(clip)
    }

    func resetSplitToMiddle() {
        guard var clip = selectedClip else { return }
        clip.resetSwitchesToMiddle()
        updateClip(clip)
    }

    // MARK: - Player plumbing

    /// Rebuilds the preview composition. Dragging a lane fires this on every
    /// pixel, so `coalesce` holds the rebuild until the gesture settles.
    func reloadPlayer(coalesce: Bool = false) {
        reloadTask?.cancel()
        let snapshot = project
        let clip = selectedClip
        reloadTask = Task { [weak self] in
            if coalesce {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
            }
            await self?.player.reload(project: snapshot, selectedClip: clip)
            self?.refreshPreviewLabels()
        }
    }

    func applyPlayerSettings() {
        player.apply(project: project, selectedClip: selectedClip)
        refreshPreviewLabels()
    }

    /// Re-samples the burnt-in labels for the selected clip so the preview
    /// shows the colours the export will use. Coalesced, because a tinted
    /// label decodes two frames and the controls driving it are sliders.
    func refreshPreviewLabels() {
        labelTask?.cancel()

        guard let format = player.previewFormat, let clip = selectedClip else {
            guard player.previewOverlays.before != nil || player.previewOverlays.after != nil else { return }
            player.previewOverlays = .empty
            player.apply(project: project, selectedClip: selectedClip)
            return
        }

        let snapshot = project
        labelTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let overlays = await LabelFactory.overlays(project: snapshot, clip: clip, format: format)
            guard let self, !Task.isCancelled else { return }
            self.player.previewOverlays = overlays
            self.player.apply(project: self.project, selectedClip: self.selectedClip)
        }
    }

    // MARK: - Waveforms

    func refreshWaveforms() {
        for source in project.audioSources {
            guard waveforms[source.id] == nil, waveformTasks[source.id] == nil else { continue }
            let url = source.url ?? project.videoURL
            guard let url else { continue }
            let id = source.id
            waveformTasks[id] = Task { [weak self] in
                let peaks = await WaveformExtractor.peaks(url: url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.waveformTasks[id] = nil
                    guard !peaks.isEmpty else { return }
                    self.waveforms[id] = peaks
                }
            }
        }
    }

    // MARK: - Project file

    func saveProject() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name).\(ProjectStore.fileExtension)"
        // The `.abcut` type is declared by the app bundle; when the app runs
        // unbundled the panel simply accepts the typed extension instead.
        if let type = UTType(filenameExtension: ProjectStore.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectStore.save(project, to: url)
            projectURL = url
            status = "\(url.lastPathComponent) gespeichert."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectStore.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var loaded = try ProjectStore.load(from: url)
            loaded.clampClips()
            project = loaded
            projectURL = url
            selectedClipID = loaded.clips.first?.id
            waveforms = [:]
            status = "\(url.lastPathComponent) geöffnet."
            reloadPlayer()
            refreshWaveforms()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Stills

    /// The frame currently held for the cover image, at full resolution.
    @Published private(set) var grabbedFrame: CGImage?
    @Published private(set) var grabbedAtSeconds: Double = 0
    @Published private(set) var titleCardPreview: CGImage?

    /// Format the title-card preview is rendered at — the framing preview when
    /// one is chosen, otherwise the first selected output format.
    var stillPreviewFormat: SocialFormat {
        player.previewFormat ?? project.export.formats.first ?? .portrait916
    }

    func grabStill() {
        guard let url = project.videoURL else {
            errorMessage = "Zuerst ein Video laden."
            return
        }
        let seconds = player.currentTime
        Task { [weak self] in
            do {
                let frame = try await StillExporter.grab(videoURL: url, at: seconds)
                guard let self else { return }
                // The film's name is nearly always the right headline, and an
                // empty title card is a poor thing to hand someone.
                if self.project.stills.headline.isEmpty {
                    self.project.stills.headline = self.project.name
                }
                self.grabbedFrame = frame
                self.grabbedAtSeconds = seconds
                self.status = "Standbild \(frame.width)×\(frame.height) bei \(Timecode.clockString(fromSeconds: seconds)) gegriffen."
                self.inspectorTab = .cover
                self.refreshTitleCardPreview()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func refreshTitleCardPreview() {
        guard let frame = grabbedFrame else {
            titleCardPreview = nil
            return
        }
        // Rendered small: the panel shows it at a couple of hundred points, and
        // a full-size blur per slider tick would not keep up with the gesture.
        let format = stillPreviewFormat
        titleCardPreview = StillExporter.titleCard(
            frame: frame,
            format: format,
            settings: project.stills,
            fitMode: project.export.fitMode,
            panX: selectedClip?.panX ?? 0,
            panY: selectedClip?.panY ?? 0,
            scale: min(1, 640 / format.size.height)
        )
    }

    /// Writes the full-resolution frame and a title card per selected format.
    func saveStills() {
        guard let frame = grabbedFrame else {
            errorMessage = "Zuerst ein Standbild greifen."
            return
        }
        guard let folder = project.export.outputFolderURL else {
            chooseOutputFolder()
            guard project.export.outputFolderURL != nil else { return }
            saveStills()
            return
        }

        let settings = project.stills
        let stamp = Timecode.string(
            fromSeconds: grabbedAtSeconds,
            rate: project.frameRate,
            dropFrame: project.dropFrame
        ).replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ";", with: "-")
        var written = 0

        do {
            if settings.saveFullFrame {
                let url = folder.appendingPathComponent(
                    "\(project.name)_\(stamp)_frame.\(settings.fileFormat.fileExtension)"
                )
                try StillExporter.write(frame, to: url, as: settings.fileFormat)
                written += 1
            }

            if settings.saveTitleCards {
                for format in project.export.formats {
                    guard let card = StillExporter.titleCard(
                        frame: frame,
                        format: format,
                        settings: settings,
                        fitMode: project.export.fitMode,
                        panX: selectedClip?.panX ?? 0,
                        panY: selectedClip?.panY ?? 0
                    ) else { continue }
                    let url = folder.appendingPathComponent(
                        "\(project.name)_\(stamp)_title_\(format.fileSuffix).\(settings.fileFormat.fileExtension)"
                    )
                    try StillExporter.write(card, to: url, as: settings.fileFormat)
                    written += 1
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard written > 0 else {
            errorMessage = "Es ist nichts zum Speichern ausgewählt."
            return
        }
        status = "\(written) Bild\(written == 1 ? "" : "er") in \(folder.lastPathComponent) geschrieben."
        exportQueue.revealInFinder(folder)
    }

    // MARK: - Export

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Zielordner für die Social-Clips wählen."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project.export.outputFolderPath = url.path
    }

    func startExport() {
        guard project.hasVideo else {
            errorMessage = "Zuerst ein Video laden."
            return
        }
        guard let folder = project.export.outputFolderURL else {
            chooseOutputFolder()
            guard project.export.outputFolderURL != nil else { return }
            startExport()
            return
        }
        exportQueue.clear()
        exportQueue.start(project: project, outputFolder: folder)
    }
}
