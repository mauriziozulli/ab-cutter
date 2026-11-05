import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

/// Which marker the timeline has in hand.
enum MarkerSelection: Equatable {
    case switchPoint(Int)
    case still(UUID)
}

/// Owns the session, the recorder and the player. Media is only ever read;
/// recordings and exports are always new files in the session folder.
@MainActor
final class Store: ObservableObject {
    // MARK: Session

    @Published var session = Session() {
        didSet { sessionChanged(from: oldValue) }
    }
    @Published private(set) var folder: URL?
    /// The record inspector on the left: frame, inputs, meters.
    @Published var showRecordPanel = true {
        didSet {
            guard oldValue != showRecordPanel, !isRecording else { return }
            if showRecordPanel { armAudio() } else { disarmAudio() }
        }
    }
    @Published var status = "Rahmen über Pro Tools legen, Ton wählen, Record."
    @Published var errorMessage: String?

    // MARK: Recording

    @Published private(set) var devices: [AudioInputDevice] = []
    @Published var originalRoute: AudioRoute? {
        didSet { routesChanged() }
    }
    @Published var mixRoute: AudioRoute? {
        didSet { routesChanged() }
    }
    @Published private(set) var levels: (original: Float, mix: Float) = (0, 0)
    /// Every channel of every open device, keyed by device UID — the check
    /// that sound arrives at all, and on which channel.
    @Published private(set) var channelLevels: [String: [Float]] = [:]
    @Published private(set) var micPermission = AudioRecorder.permission
    /// Seconds left before the take starts, while counting down.
    @Published private(set) var countdown: Int?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart: Date?
    @Published private(set) var frameVisible = false
    @Published private(set) var framePixels: CGSize = .zero
    @Published private(set) var hasScreenPermission = ScreenRecorder.hasPermission

    // MARK: Editing

    let player = AVPlayer()
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var previewFormat: OutputFormat = .feed {
        didSet { if oldValue != previewFormat { rebuildPreview() } }
    }
    @Published var zoom: Double = 1
    /// Out to a tenth (ten times the content, empty time to record into),
    /// in to sixty times.
    static let zoomRange: ClosedRange<Double> = 0.1...60
    @Published var selection: MarkerSelection?
    /// Envelopes of each take's two mixes, by take.
    @Published private(set) var waveforms: [UUID: (original: Waveform?, mix: Waveform?)] = [:]
    @Published private(set) var isSyncing = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0

    private let audio = AudioRecorder()
    private let screen = ScreenRecorder()
    private var frameWindow: CaptureFrameWindow?
    private var meterTimer: Timer?
    private var timeObserver: Any?
    private var saveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewOrigin: Double = 0
    private var frameObserver: NSObjectProtocol?

    private static let lastSessionKey = "lastSessionFolder"
    private static let originalRouteKey = "originalRoute"
    private static let mixRouteKey = "mixRoute"

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = self.player.rate != 0
                // Only playback moves the playhead. A paused seek sets it
                // itself — also into empty time past the end, where the
                // player has nothing to show and would report its last frame.
                if self.isPlaying {
                    self.currentTime = CMTimeGetSeconds(time) + self.previewOrigin
                }
            }
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: .captureFrameChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateFramePixels() }
        }

        originalRoute = Self.loadRoute(Self.originalRouteKey)
        mixRoute = Self.loadRoute(Self.mixRouteKey)
        refreshDevices()

        if let path = UserDefaults.standard.string(forKey: Self.lastSessionKey) {
            try? openSession(at: URL(fileURLWithPath: path))
        }
    }

    var sessionName: String {
        if !session.title.isEmpty { return session.title }
        return folder?.lastPathComponent ?? "Neue Session"
    }

    // MARK: - Session files

    private static var sessionsRoot: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("Session Cutter", isDirectory: true)
    }

    func openSession(at url: URL) throws {
        let file = url.appendingPathComponent("session.json")
        let data = try Data(contentsOf: file)
        let loaded = try JSONDecoder().decode(Session.self, from: data)
        folder = url
        session = loaded
        UserDefaults.standard.set(url.path, forKey: Self.lastSessionKey)
        selection = nil
        waveforms = [:]
        loadWaveforms()
        rebuildPreview(seekTo: loaded.inPoint)
    }

    func presentOpenSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Self.sessionsRoot
        panel.prompt = "Öffnen"
        panel.message = "Einen Session-Ordner wählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try openSession(at: url)
            status = "Session «\(url.lastPathComponent)» geöffnet."
        } catch {
            errorMessage = "In diesem Ordner liegt keine Session."
        }
    }

    func revealFolder() {
        guard let folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func sessionChanged(from old: Session) {
        scheduleSave()
        let layoutChanged = old.switches != session.switches
            || old.title != session.title
            || old.subtitle != session.subtitle
            || old.titleStyle != session.titleStyle
            || old.labelOriginal != session.labelOriginal
            || old.labelMix != session.labelMix
            || old.filmPath != session.filmPath
            || old.filmDuration != session.filmDuration
            || old.takes != session.takes
        if layoutChanged, dragDepth == 0 { rebuildPreview() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// ⌘S. Sessions save themselves as they change; this makes it explicit,
    /// and asks for a place when the session has none yet.
    func saveSession() {
        guard folder != nil else {
            saveSessionAs()
            return
        }
        save()
        status = "Session gesichert."
    }

    /// Writes the session — takes included — to a new folder of the user's
    /// choosing and carries on there. The old folder is left as it was.
    func saveSessionAs() {
        guard !isRecording else { return }
        let panel = NSSavePanel()
        panel.directoryURL = Self.sessionsRoot
        panel.nameFieldStringValue = session.title.isEmpty ? (folder?.lastPathComponent ?? "Session") : session.title
        panel.message = "Die Session wird als Ordner gesichert, mit allen Takes."
        panel.prompt = "Sichern"
        guard panel.runModal() == .OK, let target = panel.url else { return }

        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: target.path) {
                errorMessage = "Dort liegt schon etwas mit diesem Namen."
                return
            }
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            if let folder {
                for item in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    try manager.copyItem(at: item, to: target.appendingPathComponent(item.lastPathComponent))
                }
            }
            folder = target
            save()
            UserDefaults.standard.set(target.path, forKey: Self.lastSessionKey)
            status = "Session als «\(target.lastPathComponent)» gesichert."
        } catch {
            errorMessage = "Die Session konnte nicht gesichert werden. \(error.localizedDescription)"
        }
    }

    func save() {
        guard let folder else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(session) {
            try? data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        }
    }

    // MARK: - Devices and meters

    func refreshDevices() {
        devices = AudioDevices.inputs()
        // A first launch guesses: Audio Bridge if it is there, channels 1–2
        // for the original and 3–4 for the mix when it has four.
        if originalRoute == nil || mixRoute == nil {
            let bridge = devices.first { $0.name.localizedCaseInsensitiveContains("bridge") } ?? devices.first
            if let bridge {
                if originalRoute == nil { originalRoute = AudioRoute(deviceUID: bridge.uid, firstChannel: 0) }
                if mixRoute == nil {
                    mixRoute = AudioRoute(deviceUID: bridge.uid, firstChannel: bridge.channels >= 4 ? 2 : 0)
                }
            }
        }
    }

    func device(for route: AudioRoute?) -> AudioInputDevice? {
        guard let route else { return nil }
        return devices.first { $0.uid == route.deviceUID }
    }

    private func routesChanged() {
        Self.storeRoute(originalRoute, Self.originalRouteKey)
        Self.storeRoute(mixRoute, Self.mixRouteKey)
        if showRecordPanel, !isRecording { armAudio() }
    }

    /// Opens the devices so the meters move before anything is recorded.
    func armAudio() {
        guard !isRecording, let originalRoute, let mixRoute else { return }
        micPermission = AudioRecorder.permission
        if micPermission == .notDetermined {
            Task {
                _ = await AudioRecorder.requestPermission()
                micPermission = AudioRecorder.permission
                if micPermission == .authorized { armAudio() }
            }
            return
        }
        do {
            try audio.arm(original: originalRoute, mix: mixRoute)
            startMeters()
        } catch {
            stopMeters()
            status = error.localizedDescription
        }
    }

    func disarmAudio() {
        guard !isRecording else { return }
        audio.disarm()
        stopMeters()
    }

    private func startMeters() {
        guard meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let fresh = self.audio.takeChannelPeaks()
                // A meter that falls slowly reads better than one that flickers.
                var merged: [String: [Float]] = [:]
                for (uid, peaks) in fresh {
                    let previous = self.channelLevels[uid] ?? []
                    merged[uid] = peaks.enumerated().map { index, peak in
                        max(peak, (index < previous.count ? previous[index] : 0) * 0.82)
                    }
                }
                self.channelLevels = merged
                self.levels = (self.pairLevel(self.originalRoute), self.pairLevel(self.mixRoute))
            }
        }
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        levels = (0, 0)
        channelLevels = [:]
    }

    private func pairLevel(_ route: AudioRoute?) -> Float {
        guard let route, let channels = channelLevels[route.deviceUID], !channels.isEmpty else { return 0 }
        let left = min(route.firstChannel, channels.count - 1)
        let right = min(route.firstChannel + 1, channels.count - 1)
        return max(channels[left], channels[right])
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func loadRoute(_ key: String) -> AudioRoute? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AudioRoute.self, from: data)
    }

    private static func storeRoute(_ route: AudioRoute?, _ key: String) {
        guard let route, let data = try? JSONEncoder().encode(route) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - Capture frame

    func toggleFrame() {
        frameVisible ? hideFrame() : showFrame()
    }

    func showFrame() {
        if frameWindow == nil { frameWindow = CaptureFrameWindow() }
        frameWindow?.orderFrontRegardless()
        frameVisible = true
        updateFramePixels()
    }

    func hideFrame() {
        guard !isRecording else { return }
        frameWindow?.orderOut(nil)
        frameVisible = false
    }

    private func updateFramePixels() {
        framePixels = frameWindow?.capturePixels ?? .zero
    }

    func requestScreenPermission() {
        hasScreenPermission = ScreenRecorder.requestPermission() || ScreenRecorder.hasPermission
    }

    // MARK: - Recording

    func toggleRecording() {
        if countdownTask != nil {
            cancelCountdown()
        } else if isRecording {
            stopRecording()
        } else {
            startCountdown()
        }
    }

    private var countdownTask: Task<Void, Never>?

    /// Five seconds to get to Pro Tools and press play. Record again, or
    /// Escape, calls it off.
    func startCountdown() {
        guard !isRecording, countdownTask == nil else { return }
        guard checkReadyToRecord() else { return }
        showFrame()
        countdownTask = Task {
            for remaining in stride(from: 5, through: 1, by: -1) {
                countdown = remaining
                frameWindow?.countdown = remaining
                status = "Aufnahme beginnt in \(remaining) …"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            countdown = nil
            frameWindow?.countdown = nil
            countdownTask = nil
            startRecording()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        frameWindow?.countdown = nil
        status = "Countdown abgebrochen."
    }

    private func checkReadyToRecord() -> Bool {
        guard ScreenRecorder.hasPermission else {
            requestScreenPermission()
            errorMessage = ScreenRecordError.noPermission.localizedDescription
            return false
        }
        guard micPermission == .authorized else {
            errorMessage = AudioRecordError.noPermission.localizedDescription
            return false
        }
        guard originalRoute != nil, mixRoute != nil else {
            errorMessage = "Zuerst für Original und Final Mix je einen Toneingang wählen."
            return false
        }
        if !audio.isArmed { armAudio() }
        guard audio.isArmed else {
            errorMessage = status
            return false
        }
        return true
    }

    func startRecording() {
        guard !isRecording, checkReadyToRecord() else { return }
        showFrame()
        guard let frameWindow else { return }

        // The first take makes the session folder; every take gets its own
        // subfolder in it.
        let root: URL
        if let folder {
            root = folder
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            root = Self.sessionsRoot.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        }
        var take = Take()
        take.folder = String(format: "take-%02d", (session.takes.count) + 1)
        // Placed at the playhead until the sound says better.
        take.start = (session.hasTakes || session.filmURL != nil) ? currentTime : 0
        let target = root.appendingPathComponent(take.folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Der Session-Ordner konnte nicht angelegt werden. \(error.localizedDescription)"
            return
        }
        if folder == nil {
            folder = root
            UserDefaults.standard.set(root.path, forKey: Self.lastSessionKey)
        }

        let recording = take
        player.pause()
        frameWindow.isRecording = true
        isRecording = true
        recordingStart = Date()
        status = "Aufnahme läuft — in Pro Tools abspielen."

        let rect = frameWindow.captureRect
        pendingTake = recording
        status = "Bildschirmaufnahme startet …"
        recordStartTask = Task {
            do {
                try audio.startWriting(
                    originalURL: target.appendingPathComponent(recording.originalFile),
                    mixURL: target.appendingPathComponent(recording.mixFile)
                )
                try await screen.start(
                    rect: rect,
                    to: target.appendingPathComponent(recording.screenFile)
                )
                if isRecording { status = "Aufnahme läuft — in Pro Tools abspielen. Stop mit ⌘R." }
                return true
            } catch {
                pendingTake = nil
                _ = audio.stopWriting()
                finishRecordingUI()
                errorMessage = error.localizedDescription
                return false
            }
        }
    }

    private var pendingTake: Take?
    /// The start of the capture, which takes a moment. Stop waits for it, so
    /// a quick second press still ends the take instead of being ignored.
    private var recordStartTask: Task<Bool, Never>?

    func stopRecording() {
        guard isRecording, let pending = pendingTake else { return }
        pendingTake = nil
        status = "Aufnahme wird abgeschlossen …"
        let starting = recordStartTask
        recordStartTask = nil
        Task {
            var take = pending
            guard await starting?.value ?? true else { return }
            do {
                let picture = try await screen.stop()
                let starts = audio.stopWriting()
                finishRecordingUI()

                take.duration = picture.duration
                take.originalLead = (starts.original ?? picture.start) - picture.start
                take.mixLead = (starts.mix ?? picture.start) - picture.start

                session.takes.append(take)
                if session.takes.count == 1, session.outPoint <= session.inPoint {
                    session.inPoint = take.start
                }
                save()
                selection = nil
                loadWaveforms()
                rebuildPreview(seekTo: take.start)
                status = String(format: "Take %d: %.1f s aufgenommen.", session.takes.count, take.duration)
                if session.filmURL != nil { syncTake(take.id) }
            } catch {
                _ = audio.stopWriting()
                finishRecordingUI()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishRecordingUI() {
        isRecording = false
        recordingStart = nil
        frameWindow?.isRecording = false
    }

    func toggleRecordPanel() {
        showRecordPanel.toggle()
        if showRecordPanel {
            refreshDevices()
            if hasScreenPermission { showFrame() }
        } else {
            hideFrame()
        }
    }

    /// A fresh session for the same film: film, titles, labels and output
    /// choices stay, takes and markers go. The next Record makes its folder.
    func newSession() {
        guard !isRecording else { return }
        var next = Session()
        next.filmPath = session.filmPath
        next.filmDuration = session.filmDuration
        next.title = session.title
        next.subtitle = session.subtitle
        next.titleStyle = session.titleStyle
        next.labelOriginal = session.labelOriginal
        next.labelMix = session.labelMix
        next.formats = session.formats
        next.stillLayout = session.stillLayout
        next.stillFilmOriginal = session.stillFilmOriginal
        next.stillWeb = session.stillWeb
        folder = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSessionKey)
        session = next
        selection = nil
        waveforms = [:]
        rebuildPreview(seekTo: 0)
        status = "Neue Session — Record legt den Ordner an."
    }

    // MARK: - Film and sync

    func presentFilmPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.message = "Den fertigen Film wählen — er wird nur gelesen."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            session.filmPath = url.path
            session.filmDuration = duration.isFinite ? duration : 0
            syncAllTakes()
        }
    }

    /// The film's own title design. A PNG with transparency sits on the
    /// picture; anything else is laid on as it is.
    func presentTitleImagePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .tiff, .image]
        panel.message = "Das Titeldesign des Films wählen — am besten ein PNG mit transparentem Grund."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.titleStyle.imagePath = url.path
        session.titleStyle.mode = .image
    }

    func syncAllTakes() {
        for take in session.takes { syncTake(take.id) }
    }

    /// Places a take on the film by matching its recorded original against
    /// the film's own sound.
    func syncTake(_ id: UUID) {
        guard let filmURL = session.filmURL, let folder,
              let take = session.takes.first(where: { $0.id == id }) else { return }
        let originalURL = take.url(take.originalFile, in: folder)
        isSyncing = true
        status = "Synchronisiere am Originalton …"
        Task {
            defer { isSyncing = false }
            do {
                let result = try await AudioAligner.align(sourceURL: originalURL, videoURL: filmURL)
                guard let index = session.takes.firstIndex(where: { $0.id == id }) else { return }
                // The original's first sample lands at film time `offset`, and
                // sits `originalLead` after the take's first frame.
                session.takes[index].start = result.offsetSeconds - take.originalLead
                session.takes[index].syncConfidence = result.confidence
                status = String(format: "Take synchron (Übereinstimmung %.0f %%).", result.confidence * 100)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The take under the playhead — the one the nudge and sync buttons mean.
    var currentTake: Take? {
        session.segments().first { $0.from <= currentTime && $0.to >= currentTime }?.take
            ?? session.takes.last
    }

    /// Moves the take under the playhead by whole frames.
    func nudgeTake(frames: Int) {
        guard let id = currentTake?.id,
              let index = session.takes.firstIndex(where: { $0.id == id }) else { return }
        session.takes[index].start += Double(frames) / 25
    }

    /// Takes the take out, and with it every switch and still that only it
    /// was carrying — what lay under another take stays.
    func deleteTake(_ id: UUID) {
        guard let take = session.takes.first(where: { $0.id == id }) else { return }
        var next = session
        next.takes.removeAll { $0.id == id }
        let remaining = next.takes
        func orphaned(_ time: Double) -> Bool {
            time >= take.start - 0.001 && time <= take.end + 0.001
                && !remaining.contains { time >= $0.start && time <= $0.end }
        }
        next.switches.removeAll(where: orphaned)
        next.stills.removeAll { orphaned($0.time) }
        if remaining.isEmpty {
            next.inPoint = 0
            next.outPoint = 0
        }
        selection = nil
        session = next
        waveforms[id] = nil
        status = "Take entfernt, mit seinen Wechseln und Stills. Die Dateien bleiben im Session-Ordner."
    }

    // MARK: - Preview

    func rebuildPreview(seekTo target: Double? = nil) {
        guard session.hasTakes || session.filmURL != nil else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let folder = self.folder ?? FileManager.default.temporaryDirectory
        let resume = target ?? currentTime
        let wasPlaying = player.rate != 0
        let snapshot = session
        let format = previewFormat
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            do {
                let post = try await CompositionFactory.build(
                    session: snapshot,
                    folder: folder,
                    format: format,
                    range: 0...max(snapshot.duration, 0.1)
                )
                guard !Task.isCancelled else { return }
                previewOrigin = post.origin
                player.replaceCurrentItem(with: post.playerItem())
                seek(to: resume)
                if wasPlaying { player.play() }
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= session.duration - 0.05 { seek(to: 0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(to seconds: Double) {
        currentTime = max(seconds, 0)
        let playable = min(currentTime, max(session.duration, 0))
        player.seek(
            to: CMTime(seconds: playable - previewOrigin, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func step(frames: Int) {
        player.pause()
        seek(to: currentTime + Double(frames) / 25)
    }

    private func loadWaveforms() {
        guard let folder else {
            waveforms = [:]
            return
        }
        for take in session.takes where waveforms[take.id] == nil {
            let original = take.url(take.originalFile, in: folder)
            let mix = take.url(take.mixFile, in: folder)
            waveforms[take.id] = (nil, nil)
            Task {
                async let a = WaveformExtractor.waveform(url: original)
                async let b = WaveformExtractor.waveform(url: mix)
                let result = await (a, b)
                waveforms[take.id] = (original: result.0, mix: result.1)
            }
        }
    }

    // MARK: - Markers

    /// While a marker is being dragged, the preview is rebuilt once at the
    /// end rather than on every pixel.
    private(set) var dragDepth = 0

    func beginDrag() { dragDepth += 1 }

    func endDrag() {
        dragDepth = max(dragDepth - 1, 0)
        if dragDepth == 0 { rebuildPreview() }
    }

    private func snapped(_ seconds: Double) -> Double {
        let frame = 1.0 / 25
        return min(max((seconds / frame).rounded() * frame, 0), session.duration)
    }

    func addSwitchAtPlayhead() {
        let time = snapped(currentTime)
        guard !session.switches.contains(where: { abs($0 - time) < 0.02 }) else { return }
        session.switches.append(time)
        selection = .switchPoint(session.switches.count - 1)
    }

    func addStillAtPlayhead() {
        let time = snapped(currentTime)
        guard !session.stills.contains(where: { abs($0.time - time) < 0.02 }) else { return }
        let marker = StillMarker(time: time)
        session.stills.append(marker)
        selection = .still(marker.id)
    }

    func moveSwitch(_ index: Int, to seconds: Double) {
        guard session.switches.indices.contains(index) else { return }
        session.switches[index] = snapped(seconds)
    }

    func moveStill(_ id: UUID, to seconds: Double) {
        guard let index = session.stills.firstIndex(where: { $0.id == id }) else { return }
        session.stills[index].time = snapped(seconds)
    }

    func deleteSelection() {
        switch selection {
        case .switchPoint(let index):
            if session.switches.indices.contains(index) { session.switches.remove(at: index) }
        case .still(let id):
            session.stills.removeAll { $0.id == id }
        case nil:
            return
        }
        selection = nil
    }

    func markIn() {
        setIn(currentTime)
    }

    func markOut() {
        setOut(currentTime)
    }

    func setIn(_ seconds: Double) {
        session.inPoint = snapped(min(seconds, session.exportRange.upperBound - 0.5))
    }

    func setOut(_ seconds: Double) {
        session.outPoint = snapped(max(seconds, session.exportRange.lowerBound + 0.5))
    }

    func clearInOut() {
        session.inPoint = session.takes.map(\.start).min() ?? 0
        session.outPoint = 0
    }

    // MARK: - Export

    private var exportBaseName: String {
        let raw = session.title.isEmpty ? (folder?.lastPathComponent ?? "Session") : session.title
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    func export() {
        guard let folder, session.hasTakes, !isExporting else {
            if !session.hasTakes { errorMessage = "Es gibt noch keine Aufnahme zum Exportieren." }
            return
        }
        let formats = OutputFormat.allCases.filter { session.formats.contains($0) }
        guard !formats.isEmpty else {
            errorMessage = "Kein Format gewählt."
            return
        }
        let snapshot = session
        let target = folder.appendingPathComponent("Export", isDirectory: true)
        let base = exportBaseName
        player.pause()
        isExporting = true
        exportProgress = 0
        status = "Exportiere …"

        Task {
            defer { isExporting = false }
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let stillCount = snapshot.stills.count
                let steps = Double(formats.count) + (stillCount > 0 ? 1 : 0)
                var written = 0

                for (index, format) in formats.enumerated() {
                    let post = try await CompositionFactory.build(
                        session: snapshot, folder: folder, format: format, range: snapshot.exportRange
                    )
                    let url = target.appendingPathComponent("\(base)_\(format.fileSuffix).mp4")
                    try await Exporter.exportVideo(post, to: url) { fraction in
                        Task { @MainActor [weak self] in
                            self?.exportProgress = (Double(index) + fraction) / steps
                        }
                    }
                    written += 1
                }

                if stillCount > 0 {
                    written += try await exportStills(snapshot, folder: folder, target: target, base: base, formats: formats)
                }

                exportProgress = 1
                status = "\(written) Datei\(written == 1 ? "" : "en") in «Export» geschrieben."
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportStills(
        _ snapshot: Session,
        folder: URL,
        target: URL,
        base: String,
        formats: [OutputFormat]
    ) async throws -> Int {
        var written = 0
        let stills = snapshot.sortedStills
        let full = 0...max(snapshot.duration, 0.1)

        if snapshot.stillLayout {
            for format in formats {
                let post = try await CompositionFactory.build(
                    session: snapshot, folder: folder, format: format, range: full
                )
                for (index, still) in stills.enumerated() {
                    let image = try await Exporter.postFrame(post, atRecordingTime: still.time)
                    try Exporter.write(
                        image,
                        to: target.appendingPathComponent("\(base)_still-\(Self.number(index))_\(format.fileSuffix).jpg"),
                        jpeg: true
                    )
                    written += 1
                }
            }
        }

        if let filmURL = snapshot.filmURL, snapshot.stillFilmOriginal || snapshot.stillWeb {
            for (index, still) in stills.enumerated() {
                let filmTime = still.time
                guard filmTime >= 0, let frame = try? await Exporter.filmFrame(url: filmURL, at: filmTime) else { continue }
                if snapshot.stillFilmOriginal {
                    try Exporter.write(
                        frame,
                        to: target.appendingPathComponent("\(base)_still-\(Self.number(index))_film.png"),
                        jpeg: false
                    )
                    written += 1
                }
                if snapshot.stillWeb, let web = Exporter.resized(frame, longEdge: 2560) {
                    try Exporter.write(
                        web,
                        to: target.appendingPathComponent("\(base)_still-\(Self.number(index))_web.jpg"),
                        jpeg: true
                    )
                    written += 1
                }
            }
        }
        return written
    }

    private static func number(_ index: Int) -> String {
        String(format: "%02d", index + 1)
    }
}
