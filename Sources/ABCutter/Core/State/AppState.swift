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
    @Published private(set) var waveforms: [UUID: Waveform] = [:]

    /// Timeline zoom: 1 shows the whole film, higher values zoom in.
    @Published var zoom: Double = 1
    /// Coloured crop outlines over the full picture, one per delivery format.
    @Published var showFormatGuides = true
    /// Which inspector the right-hand column is showing.
    @Published var inspectorTab: InspectorTab = .clips

    let player = PlayerController()
    let exportQueue = ExportQueue()

    private var projectURL: URL?
    private var waveformTasks: [UUID: Task<Void, Never>] = [:]
    private var reloadTask: Task<Void, Never>?
    private var labelTask: Task<Void, Never>?
    private var clipPreviewTask: Task<Void, Never>?
    private var foldTasks: [UUID: Task<Void, Never>] = [:]
    /// True while any channel fold is rendering.
    @Published private(set) var isFolding = false

    var selectedClip: Clip? {
        guard let selectedClipID else { return nil }
        return project.clips.first { $0.id == selectedClipID }
    }

    /// The pair the monitor actually plays right now: the selected clip's A
    /// and B — clip-level overrides included — or the project defaults when
    /// no clip is selected. The timeline lanes and the sources list both
    /// colour by this, so the two views can never disagree.
    var monitoredPair: (before: UUID?, after: UUID?) {
        guard let clip = selectedClip else {
            return (project.defaultBeforeSourceID, project.defaultAfterSourceID)
        }
        return (project.beforeSource(for: clip)?.id, project.afterSource(for: clip)?.id)
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
        panel.allowedContentTypes = [.audio, .wav, .aiff, .mp3, .mpeg4Audio, .movie, .quickTimeMovie, .mpeg4Movie]
        panel.message = "Mixe, Stems — oder frühere Videofassungen: von einem Video wird nur die Tonspur übernommen."
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
        foldTasks[source.id]?.cancel()
        foldTasks[source.id] = nil
        AudioFolder.discard(source.foldedURL)
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
        var strays: [String] = []
        for index in project.audioSources.indices {
            guard !project.audioSources[index].isEmbedded else {
                project.audioSources[index].offsetSeconds = 0
                continue
            }
            guard let audioStart = project.audioSources[index].timecodeStartSeconds else { continue }
            let offset = audioStart - videoStart
            project.audioSources[index].offsetSeconds = offset
            project.audioSources[index].syncMode = .timecode
            synced += 1

            // A stamp on the wrong base — hour one against a zero start, or
            // the other way round — lands the file entirely outside the
            // picture, which plays as silence and reads as a failed sync.
            let duration = project.audioSources[index].durationSeconds
            if offset >= project.videoDurationSeconds || offset + duration <= 0 {
                strays.append(project.audioSources[index].name)
            }
        }

        status = synced > 0
            ? "\(synced) Spur\(synced == 1 ? "" : "en") per Timecode synchronisiert."
            : "Keine Tonspur trägt einen Timecode."
        if !strays.isEmpty {
            errorMessage = "Ganz ausserhalb des Bilds gelandet: \(strays.joined(separator: ", ")). "
                + "Die Timecode-Basis passt vermutlich nicht — beim Film «Erstes Bild bei» prüfen (Stunde 1 gegen 00:00?)."
        }
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

    /// Switches a source's channel handling. Anything but stereo has to be
    /// rendered out first, which is why this reports progress rather than
    /// simply setting a flag.
    func setChannelMode(_ mode: ChannelMode, for source: AudioSource) {
        guard let index = project.audioSources.firstIndex(where: { $0.id == source.id }) else { return }
        guard project.audioSources[index].channelMode != mode else { return }

        AudioFolder.discard(project.audioSources[index].foldedURL)
        project.audioSources[index].channelMode = mode
        project.audioSources[index].foldedPath = nil

        guard mode.foldsToMono else {
            status = "\(source.name): Stereo wiederhergestellt."
            waveforms[source.id] = nil
            reloadPlayer()
            refreshWaveforms()
            return
        }
        renderFold(forSourceID: source.id)
    }

    /// Renders the mono companion for one source. Also used after opening a
    /// project, because the cache lives in the temporary directory.
    func renderFold(forSourceID id: UUID) {
        guard let index = project.audioSources.firstIndex(where: { $0.id == id }) else { return }
        let source = project.audioSources[index]
        guard source.channelMode.foldsToMono else { return }
        guard let assetURL = source.url ?? project.videoURL else { return }

        foldTasks[id]?.cancel()
        isFolding = true
        status = "\(source.name): \(source.channelMode.title) wird gerechnet …"

        let mode = source.channelMode
        let name = source.name
        foldTasks[id] = Task { [weak self] in
            do {
                let folded = try await AudioFolder.fold(assetURL: assetURL, mode: mode) { _ in }
                guard let self, !Task.isCancelled else {
                    AudioFolder.discard(folded)
                    return
                }
                self.foldTasks[id] = nil
                self.isFolding = !self.foldTasks.isEmpty
                guard let slot = self.project.audioSources.firstIndex(where: { $0.id == id }),
                      self.project.audioSources[slot].channelMode == mode else {
                    // The choice moved on while this was rendering.
                    AudioFolder.discard(folded)
                    return
                }
                self.project.audioSources[slot].foldedPath = folded.path
                self.status = "\(name): \(mode.title) fertig."
                // The envelope was drawn from the stereo file; redraw it.
                self.waveforms[id] = nil
                self.reloadPlayer()
                self.refreshWaveforms()
            } catch is CancellationError {
                self?.foldTasks[id] = nil
                self?.isFolding = !(self?.foldTasks.isEmpty ?? true)
            } catch {
                guard let self else { return }
                self.foldTasks[id] = nil
                self.isFolding = !self.foldTasks.isEmpty
                self.errorMessage = error.localizedDescription
                if let slot = self.project.audioSources.firstIndex(where: { $0.id == id }) {
                    self.project.audioSources[slot].channelMode = .stereo
                }
            }
        }
    }

    /// Re-renders any fold whose cached file has gone — the temporary
    /// directory is not guaranteed to survive between launches.
    func restoreMissingFolds() {
        for source in project.audioSources where source.needsFold {
            renderFold(forSourceID: source.id)
        }
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
        return updated
    }

    func addDefaultClip() {
        addClipAtPlayhead()
    }

    /// A new clip starts from fresh defaults on purpose: independent settings
    /// are the point of planning several different playouts in one project.
    func addClipAtPlayhead(kind: ClipKind = .ab) {
        guard project.videoDurationSeconds > 0 else { return }
        let range = fittedRange(start: player.currentTime, length: project.defaultClipLengthSeconds)
        let count = project.clips.filter { $0.kind == kind }.count + 1
        let clip = Clip(
            name: kind == .loop ? "Loop \(count)" : "Clip \(count)",
            start: range.start,
            end: range.end,
            kind: kind
        )
        project.clips.append(clip)
        selectedClipID = clip.id
        applyPlayerSettings()
        inspectorTab = .clips
    }

    func addLoopClipAtPlayhead() {
        addClipAtPlayhead(kind: .loop)
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
        // While the clip preview is live, an edit rebuilds it; the timeline
        // path would style the preview item with the wrong composition.
        if player.isClipPreview {
            reloadClipPreview()
        } else {
            player.apply(project: project, selectedClip: selectedClip)
        }
    }

    func selectClip(_ clip: Clip) {
        selectedClipID = clip.id
        inspectorTab = .clips
        if player.isClipPreview {
            reloadClipPreview()
        } else {
            player.seek(to: clip.start)
            player.apply(project: project, selectedClip: clip)
        }
        refreshPreviewLabels()
    }

    /// Trims the selected clip's in point to the playhead. The switches stay
    /// where they are in the film — an edge is not a reason to move the cut.
    func markIn() {
        guard var clip = selectedClip else { return }
        clip.start = min(player.currentTime, clip.end - project.frameDuration)
        updateClip(clip)
    }

    /// Trims the out point to the playhead.
    func markOut() {
        guard var clip = selectedClip else { return }
        clip.end = max(player.currentTime, clip.start + project.frameDuration)
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
        if player.isClipPreview {
            reloadClipPreview()
        } else {
            player.apply(project: project, selectedClip: selectedClip)
        }
        refreshPreviewLabels()
        // A cover is cropped and laid out with the clip's look too, so the
        // accent and the fit mode have to reach its preview as well.
        refreshTitleCardPreview()
    }

    // MARK: - Clip preview

    /// Plays the selected clip exactly as the export will build it — loop
    /// passes, A/B mix and look included. The raw timeline cannot show a loop
    /// at all, so this is the only honest preview a loop clip has.
    func toggleClipPreview() {
        if player.isClipPreview {
            let snapshot = project
            let clip = selectedClip
            clipPreviewTask?.cancel()
            clipPreviewTask = Task { [weak self] in
                await self?.player.exitClipPreview(project: snapshot, selectedClip: clip)
            }
        } else {
            reloadClipPreview()
        }
    }

    func reloadClipPreview() {
        guard let clip = selectedClip else { return }
        let snapshot = project
        clipPreviewTask?.cancel()
        clipPreviewTask = Task { [weak self] in
            await self?.player.loadClipPreview(project: snapshot, clip: clip)
        }
    }

    /// Re-samples the burnt-in labels for the selected clip so the preview
    /// shows the colours the export will use. Coalesced, because a tinted
    /// label decodes two frames and the controls driving it are sliders.
    func refreshPreviewLabels() {
        labelTask?.cancel()

        let fallback: SocialFormat? = player.isClipPreview ? .portrait916 : nil
        guard let format = player.previewFormat ?? fallback, let clip = selectedClip else {
            guard player.previewOverlays.before != nil || player.previewOverlays.after != nil else { return }
            player.previewOverlays = .empty
            player.apply(project: project, selectedClip: selectedClip)
            return
        }

        let snapshot = project
        labelTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            // Guides on: the preview is the only place the reserved strips can
            // be judged against the picture before anything is delivered.
            let overlays = await LabelFactory.overlays(
                project: snapshot,
                clip: clip,
                format: format,
                guides: true
            )
            guard let self, !Task.isCancelled else { return }
            self.player.previewOverlays = overlays
            self.player.apply(project: self.project, selectedClip: self.selectedClip)
        }
    }

    /// Places one stamped source by timecode: the file's own stamp minus the
    /// film's «Erstes Bild bei». Deterministic where the waveform match is
    /// statistical — when both sides carry a stamp, this is the better tool.
    func syncByTimecode(_ source: AudioSource) {
        guard let videoStart = project.videoTimecodeStartSeconds else {
            errorMessage = "Zuerst beim Film «Erstes Bild bei» setzen — ohne Basis sagt ein Stempel nichts."
            return
        }
        guard let stamp = source.timecodeStartSeconds else {
            errorMessage = "\(source.name) trägt keinen Timecode-Stempel — per Wellenform syncen."
            return
        }
        guard var updated = project.audioSources.first(where: { $0.id == source.id }) else { return }
        let offset = stamp - videoStart
        updated.offsetSeconds = offset
        updated.syncMode = .timecode

        // Same courtesy as the waveform sync: a track synced into place
        // should be hearable, so it takes the free B side.
        let embeddedID = project.audioSources.first(where: { $0.isEmbedded })?.id
        let afterIsFree = project.defaultAfterSourceID == nil
            || project.defaultAfterSourceID == embeddedID
        let becameAfter = afterIsFree && updated.id != project.defaultBeforeSourceID
        if becameAfter { project.defaultAfterSourceID = updated.id }

        updateSource(updated)
        if offset >= project.videoDurationSeconds || offset + updated.durationSeconds <= 0 {
            errorMessage = "\(source.name) liegt damit ganz ausserhalb des Bilds — die Timecode-Basis passt vermutlich nicht («Erstes Bild bei» prüfen)."
        }
        status = String(
            format: "%@ per Timecode gelegt: %+.3f s%@",
            source.name, offset, becameAfter ? " · als B gewählt" : ""
        )
    }

    // MARK: - Waveform sync

    /// Syncs one mix against the film's own embedded track, by the sound
    /// itself. This is what replaces the two-pop: the dialogue in the mix and
    /// the dialogue in the video are the same events, and the correlation
    /// finds the offset between them.
    func alignByWaveform(_ source: AudioSource) {
        guard let sourceURL = source.url else {
            errorMessage = "Die Spur im Video ist die Referenz — sie braucht keinen Sync."
            return
        }
        guard let videoURL = project.videoURL else { return }

        status = "Vergleiche \(source.name) mit dem Originalton …"
        Task { [weak self] in
            do {
                let result = try await AudioAligner.align(sourceURL: sourceURL, videoURL: videoURL)
                guard let self else { return }
                guard var updated = self.project.audioSources.first(where: { $0.id == source.id }) else { return }
                updated.offsetSeconds = result.offsetSeconds
                updated.syncMode = .waveform

                // Nobody syncs a track to leave it silent. As long as no
                // external B has been chosen, the freshly synced mix becomes
                // the B side — otherwise it would sit grey in the timeline
                // and mute in the monitor, which reads as a failed sync.
                let embeddedID = self.project.audioSources.first(where: { $0.isEmbedded })?.id
                let afterIsFree = self.project.defaultAfterSourceID == nil
                    || self.project.defaultAfterSourceID == embeddedID
                let becameAfter = afterIsFree && updated.id != self.project.defaultBeforeSourceID
                if becameAfter {
                    self.project.defaultAfterSourceID = updated.id
                }

                self.updateSource(updated)
                self.status = String(
                    format: "%@ per Wellenform gelegt: %+.3f s · Übereinstimmung %.0f %%%@",
                    source.name, result.offsetSeconds, result.confidence * 100,
                    becameAfter ? " · als B gewählt" : ""
                )
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.status = "Wellenform-Sync für \(source.name) fehlgeschlagen."
            }
        }
    }

    /// Every external, enabled source in one go.
    func alignAllByWaveform() {
        let candidates = project.audioSources.filter { !$0.isEmbedded && $0.isEnabled }
        guard !candidates.isEmpty else {
            errorMessage = "Keine externe Tonspur zum Syncen."
            return
        }
        for source in candidates {
            alignByWaveform(source)
        }
    }

    // MARK: - Waveforms

    func refreshWaveforms() {
        for source in project.audioSources {
            guard waveforms[source.id] == nil, waveformTasks[source.id] == nil else { continue }
            let url = source.foldedURL ?? source.url ?? project.videoURL
            guard let url else { continue }
            let id = source.id
            waveformTasks[id] = Task { [weak self] in
                let waveform = await WaveformExtractor.waveform(url: url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.waveformTasks[id] = nil
                    guard let waveform, !waveform.fine.isEmpty else { return }
                    self.waveforms[id] = waveform
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
            restoreMissingFolds()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Stills

    /// The frame currently held for the cover image, at full resolution.
    @Published private(set) var grabbedFrame: CGImage?
    @Published private(set) var grabbedAtSeconds: Double = 0
    @Published private(set) var titleCardPreview: CGImage?
    @Published private(set) var endCardPreview: CGImage?

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
        // Rendered small: the panel shows these at a couple of hundred points,
        // and a full-size blur per slider tick would not keep up with a gesture.
        let format = stillPreviewFormat
        let proxy = min(1, 640 / format.size.height)

        // The end card stands on ink when asked to, so it is the one card that
        // can be previewed before a frame has been grabbed at all.
        endCardPreview = project.stills.saveEndCard
            ? StillExporter.endCard(
                frame: grabbedFrame,
                format: format,
                settings: project.stills,
                fitMode: activeLook.fitMode,
                panX: selectedClip?.panX ?? 0,
                panY: selectedClip?.panY ?? 0,
                safeArea: project.export.safeArea(for: format),
                scale: proxy
            )
            : nil

        guard let frame = grabbedFrame else {
            titleCardPreview = nil
            return
        }
        titleCardPreview = StillExporter.titleCard(
            frame: frame,
            format: format,
            settings: project.stills,
            fitMode: activeLook.fitMode,
            panX: selectedClip?.panX ?? 0,
            panY: selectedClip?.panY ?? 0,
            safeArea: project.export.safeArea(for: format),
            scale: proxy
        )
    }

    /// The look the still cards are composed with: the selected clip's, or the
    /// first clip's, or plain defaults when the project has no clips yet.
    var activeLook: ClipLook {
        selectedClip?.look ?? project.clips.first?.look ?? ClipLook()
    }

    /// Writes the full-resolution frame, a title card and an end card per
    /// selected format.
    func saveStills() {
        let settings = project.stills
        // The end card on ink stands on its own, so a grab is only needed for
        // the outputs that are actually made out of the picture.
        let needsFrame = settings.saveFullFrame
            || settings.saveTitleCards
            || (settings.saveEndCard && settings.endGround == .frame)
        if needsFrame, grabbedFrame == nil {
            errorMessage = "Zuerst ein Standbild greifen."
            return
        }
        guard let folder = project.export.outputFolderURL else {
            chooseOutputFolder()
            guard project.export.outputFolderURL != nil else { return }
            saveStills()
            return
        }

        let stamp = Timecode.string(
            fromSeconds: grabbedAtSeconds,
            rate: project.frameRate,
            dropFrame: project.dropFrame
        ).replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ";", with: "-")
        var written = 0

        func name(_ part: String, _ format: SocialFormat?) -> URL {
            let suffix = format.map { "_\($0.fileSuffix)" } ?? ""
            return folder.appendingPathComponent(
                "\(project.name)_\(stamp)_\(part)\(suffix).\(settings.fileFormat.fileExtension)"
            )
        }

        do {
            if settings.saveFullFrame, let frame = grabbedFrame {
                try StillExporter.write(frame, to: name("frame", nil), as: settings.fileFormat)
                written += 1
            }

            for format in project.export.formats {
                let safeArea = project.export.safeArea(for: format)

                if settings.saveTitleCards, let frame = grabbedFrame,
                   let card = StillExporter.titleCard(
                       frame: frame,
                       format: format,
                       settings: settings,
                       fitMode: activeLook.fitMode,
                       panX: selectedClip?.panX ?? 0,
                       panY: selectedClip?.panY ?? 0,
                       safeArea: safeArea
                   ) {
                    try StillExporter.write(card, to: name("title", format), as: settings.fileFormat)
                    written += 1
                }

                if settings.saveEndCard,
                   let card = StillExporter.endCard(
                       frame: grabbedFrame,
                       format: format,
                       settings: settings,
                       fitMode: activeLook.fitMode,
                       panX: selectedClip?.panX ?? 0,
                       panY: selectedClip?.panY ?? 0,
                       safeArea: safeArea
                   ) {
                    try StillExporter.write(card, to: name("abspann", format), as: settings.fileFormat)
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

        // The one mistake no meter catches in time: an A/B whose two sides
        // carry the same sound. The file renders fine, the switch ramps
        // fire — and nothing audible happens. Said out loud before the
        // encode, not discovered on Instagram.
        let warnings = silentSwitchWarnings()
        if !warnings.isEmpty {
            errorMessage = "Der Export läuft — aber bei diesen Clips wird am Wechsel nichts zu hören sein:\n\n"
                + warnings.joined(separator: "\n")
        }

        exportQueue.clear()
        exportQueue.start(project: project, outputFolder: folder)
    }

    // MARK: - Pre-flight

    /// Clips whose A/B pair cannot produce an audible switch: both sides are
    /// the same track, or the two tracks sound practically the same across
    /// the clip. The second case is the classic trap — the film's embedded
    /// track of a finished delivery IS the mix, so «Original (im Video)»
    /// against that same mix as a file switches between two copies of one
    /// sound, and all that is left to hear is their level difference.
    private func silentSwitchWarnings() -> [String] {
        var warnings: [String] = []
        for clip in project.clips where clip.isEnabled {
            guard let before = project.beforeSource(for: clip),
                  let after = project.afterSource(for: clip) else { continue }

            if before.id == after.id {
                warnings.append("«\(clip.name)»: A und B sind dieselbe Spur (\(before.name)).")
                continue
            }

            // Envelopes may still be extracting; no data, no verdict.
            guard let waveBefore = waveforms[before.id],
                  let waveAfter = waveforms[after.id] else { continue }
            let similarity = pairSimilarity(
                clip: clip,
                before: before, waveBefore: waveBefore,
                after: after, waveAfter: waveAfter
            )
            if similarity > 0.97 {
                warnings.append(String(
                    format: "«%@»: A (%@) und B (%@) klingen hier praktisch identisch (%.0f %%) — vermutlich derselbe Mix auf beiden Seiten.",
                    clip.name, before.name, after.name, similarity * 100
                ))
            }
        }
        return warnings
    }

    /// Scale-invariant correlation of the two sides' loudness envelopes over
    /// the clip window, each read at its own sync offset. Identical audio at
    /// different levels still correlates near 1; a production track against
    /// a finished mix — same dialogue, different everything else — does not.
    private func pairSimilarity(
        clip: Clip,
        before: AudioSource, waveBefore: Waveform,
        after: AudioSource, waveAfter: Waveform
    ) -> Double {
        let step = 0.05
        var a: [Double] = []
        var b: [Double] = []
        var t = clip.start
        while t < clip.end {
            a.append(Double(waveBefore.peak(from: t - before.offsetSeconds, to: t - before.offsetSeconds + step)))
            b.append(Double(waveAfter.peak(from: t - after.offsetSeconds, to: t - after.offsetSeconds + step)))
            t += step
        }
        guard a.count >= 40 else { return 0 }

        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)
        var dot = 0.0
        var energyA = 0.0
        var energyB = 0.0
        for index in a.indices {
            let x = a[index] - meanA
            let y = b[index] - meanB
            dot += x * y
            energyA += x * x
            energyB += y * y
        }
        let denominator = (energyA * energyB).squareRoot()
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }
}
