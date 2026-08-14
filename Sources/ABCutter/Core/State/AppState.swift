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
    @Published var status: String = "Load a video to begin."
    @Published var errorMessage: String?
    @Published private(set) var isLoadingMedia = false
    /// Peak envelopes for the timeline, keyed by audio source.
    @Published private(set) var waveforms: [UUID: [Float]] = [:]

    /// Timeline zoom: 1 shows the whole film, higher values zoom in.
    @Published var zoom: Double = 1

    let player = PlayerController()
    let exportQueue = ExportQueue()

    private var projectURL: URL?
    private var waveformTasks: [UUID: Task<Void, Never>] = [:]
    private var reloadTask: Task<Void, Never>?

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
        panel.message = "Choose the finished film."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await loadVideo(url: url) }
    }

    func presentAudioPicker() {
        guard project.hasVideo else {
            errorMessage = "Load the video first, then add audio to sit under it."
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .wav, .aiff, .mp3, .mpeg4Audio, .movie]
        panel.message = "Choose mixes or stems to lay under the picture."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addAudio(urls: urls) }
    }

    func loadVideo(url: URL) async {
        isLoadingMedia = true
        status = "Reading \(url.lastPathComponent)…"
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
            fresh.export = project.export

            if probe.hasAudio {
                var embedded = AudioSource(
                    name: "Original (in video)",
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
                timecodeNote = "start \(Timecode.string(fromSeconds: timecode.seconds, rate: project.frameRate, dropFrame: project.dropFrame)) from \(timecode.origin.title.lowercased())"
            } else {
                timecodeNote = "no timecode — audio will sync from the file start"
            }
            status = "\(url.lastPathComponent) · \(Int(probe.naturalSize.width))×\(Int(probe.naturalSize.height)) · \(project.frameRate.title) · \(timecodeNote)"

            await player.reload(project: project, selectedClip: selectedClip)
            refreshWaveforms()
        } catch {
            errorMessage = error.localizedDescription
            status = "The video could not be read."
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
            ? "Added \(added) source\(added == 1 ? "" : "s") — \(syncedByTimecode) synced by timecode."
            : "Added \(added) source\(added == 1 ? "" : "s") — no timecode match, sync by hand."

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
            errorMessage = "The video carries no timecode, so there is nothing to sync against. Line the audio up by hand."
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
            ? "Synced \(synced) source\(synced == 1 ? "" : "s") by timecode."
            : "No audio source carries a timecode stamp."
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

    func addDefaultClip() {
        let duration = project.videoDurationSeconds
        guard duration > 0 else { return }
        let length = min(20, duration)
        let start = max(0, min(player.currentTime, duration - length))
        addClip(start: start, end: start + length)
    }

    func addClipAtPlayhead(length: Double = 20) {
        let duration = project.videoDurationSeconds
        guard duration > 0 else { return }
        let start = min(player.currentTime, max(duration - 1, 0))
        addClip(start: start, end: min(start + length, duration))
    }

    private func addClip(start: Double, end: Double) {
        let index = project.clips.count + 1
        let clip = Clip(name: "Clip \(index)", start: start, end: end)
        project.clips.append(clip)
        selectedClipID = clip.id
        player.apply(project: project, selectedClip: clip)
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
    }

    /// Sets the selected clip's in or out point to the playhead.
    func markIn() {
        guard var clip = selectedClip else { return }
        clip.start = min(player.currentTime, clip.end - project.frameDuration)
        updateClip(clip)
    }

    func markOut() {
        guard var clip = selectedClip else { return }
        clip.end = max(player.currentTime, clip.start + project.frameDuration)
        updateClip(clip)
    }

    func setSplitToPlayhead() {
        guard var clip = selectedClip else { return }
        clip.splitOverride = min(max(player.currentTime, clip.start), clip.end)
        updateClip(clip)
    }

    func resetSplitToMiddle() {
        guard var clip = selectedClip else { return }
        clip.splitOverride = nil
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
        }
    }

    func applyPlayerSettings() {
        player.apply(project: project, selectedClip: selectedClip)
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
            status = "Saved \(url.lastPathComponent)."
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
            status = "Opened \(url.lastPathComponent)."
            reloadPlayer()
            refreshWaveforms()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose where the social cuts should land."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project.export.outputFolderPath = url.path
    }

    func startExport() {
        guard project.hasVideo else {
            errorMessage = "Load a video first."
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
