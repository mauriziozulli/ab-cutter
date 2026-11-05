import AppKit
import AVFoundation
import Combine
import Foundation

enum Phase: String, CaseIterable, Identifiable {
    case record
    case edit

    var id: String { rawValue }
    var title: String { self == .record ? "Aufnahme" : "Schnitt" }
}

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
    @Published var phase: Phase = .record
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
    @Published var selection: MarkerSelection?
    @Published private(set) var waveforms: (original: Waveform?, mix: Waveform?) = (nil, nil)
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
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = CMTimeGetSeconds(time) + self.previewOrigin
                self.isPlaying = self.player.rate != 0
            }
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: .captureFrameChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateFramePixels() }
        }

        originalRoute = Self.loadRoute(Self.originalRouteKey)
        mixRoute = Self.loadRoute(Self.mixRouteKey)
        refreshDevices()

        if let path = UserDefaults.standard.string(forKey: Self.lastSessionKey) {
            let url = URL(fileURLWithPath: path)
            if (try? openSession(at: url)) != nil, session.recording != nil {
                phase = .edit
            }
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
            phase = session.recording == nil ? .record : .edit
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
            || old.labelOriginal != session.labelOriginal
            || old.labelMix != session.labelMix
            || old.filmPath != session.filmPath
            || old.filmOffset != session.filmOffset
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
        if phase == .record, !isRecording { armAudio() }
    }

    /// Opens the devices so the meters move before anything is recorded.
    func armAudio() {
        guard !isRecording, let originalRoute, let mixRoute else { return }
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
            Task { @MainActor in
                guard let self else { return }
                let peaks = self.audio.takePeaks()
                // A meter that falls slowly reads better than one that flickers.
                self.levels = (
                    max(peaks.original, self.levels.original * 0.82),
                    max(peaks.mix, self.levels.mix * 0.82)
                )
            }
        }
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        levels = (0, 0)
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
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        guard ScreenRecorder.hasPermission else {
            requestScreenPermission()
            errorMessage = ScreenRecordError.noPermission.localizedDescription
            return
        }
        guard originalRoute != nil, mixRoute != nil else {
            errorMessage = "Zuerst für Original und Final Mix je einen Toneingang wählen."
            return
        }
        if !audio.isArmed { armAudio() }
        guard audio.isArmed else {
            errorMessage = status
            return
        }
        showFrame()
        guard let frameWindow else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let target = Self.sessionsRoot.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Der Session-Ordner konnte nicht angelegt werden. \(error.localizedDescription)"
            return
        }

        let recording = Recording()
        player.pause()
        frameWindow.isRecording = true
        isRecording = true
        recordingStart = Date()
        status = "Aufnahme läuft — in Pro Tools abspielen."

        let rect = frameWindow.captureRect
        let windowNumber = frameWindow.windowNumber
        Task {
            do {
                try audio.startWriting(
                    originalURL: target.appendingPathComponent(recording.originalFile),
                    mixURL: target.appendingPathComponent(recording.mixFile)
                )
                try await screen.start(
                    rect: rect,
                    excludingWindowNumber: windowNumber,
                    to: target.appendingPathComponent(recording.screenFile)
                )
                pendingFolder = target
            } catch {
                _ = audio.stopWriting()
                finishRecordingUI()
                errorMessage = error.localizedDescription
            }
        }
    }

    private var pendingFolder: URL?

    func stopRecording() {
        guard isRecording, let target = pendingFolder else { return }
        pendingFolder = nil
        status = "Aufnahme wird abgeschlossen …"
        Task {
            do {
                let picture = try await screen.stop()
                let starts = audio.stopWriting()
                finishRecordingUI()

                var recording = Recording()
                recording.duration = picture.duration
                recording.originalLead = (starts.original ?? picture.start) - picture.start
                recording.mixLead = (starts.mix ?? picture.start) - picture.start

                // A new take keeps what belongs to the film, not to the take:
                // the film, its titles, the labels, the output choices.
                var next = Session()
                next.recording = recording
                next.filmPath = session.filmPath
                next.title = session.title
                next.subtitle = session.subtitle
                next.labelOriginal = session.labelOriginal
                next.labelMix = session.labelMix
                next.formats = session.formats
                next.stillLayout = session.stillLayout
                next.stillFilmOriginal = session.stillFilmOriginal
                next.stillWeb = session.stillWeb
                next.outPoint = recording.duration

                folder = target
                session = next
                save()
                UserDefaults.standard.set(target.path, forKey: Self.lastSessionKey)
                selection = nil
                phase = .edit
                disarmAudio()
                hideFrame()
                loadWaveforms()
                rebuildPreview(seekTo: 0)
                status = String(format: "%.1f s aufgenommen.", recording.duration)
                if session.filmURL != nil { syncFilm() }
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

    func enterRecordPhase() {
        player.pause()
        phase = .record
        refreshDevices()
        armAudio()
        if hasScreenPermission { showFrame() }
    }

    func enterEditPhase() {
        guard session.recording != nil else { return }
        disarmAudio()
        hideFrame()
        phase = .edit
    }

    // MARK: - Film and sync

    func presentFilmPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.message = "Den fertigen Film wählen — er wird nur gelesen."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.filmPath = url.path
        session.syncConfidence = nil
        if session.recording != nil { syncFilm() }
    }

    /// Matches the recorded original against the film's own sound.
    func syncFilm() {
        guard let filmURL = session.filmURL, let folder, let recording = session.recording else { return }
        let originalURL = folder.appendingPathComponent(recording.originalFile)
        isSyncing = true
        status = "Synchronisiere den Film am Originalton …"
        Task {
            defer { isSyncing = false }
            do {
                let result = try await AudioAligner.align(sourceURL: originalURL, videoURL: filmURL)
                // The original's first sample lands at film time `offset`, and
                // sits at recording time `originalLead`.
                session.filmOffset = result.offsetSeconds - recording.originalLead
                session.syncConfidence = result.confidence
                status = String(format: "Film synchron (Übereinstimmung %.0f %%).", result.confidence * 100)
            } catch {
                session.syncConfidence = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// One frame of the film, by hand.
    func nudgeFilm(frames: Int) {
        session.filmOffset += Double(frames) / 25
    }

    // MARK: - Preview

    func rebuildPreview(seekTo target: Double? = nil) {
        guard let folder, session.recording != nil else {
            player.replaceCurrentItem(with: nil)
            return
        }
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
        let clamped = min(max(seconds, 0), max(session.duration, 0))
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped - previewOrigin, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func step(frames: Int) {
        player.pause()
        seek(to: currentTime + Double(frames) / 25)
    }

    private func loadWaveforms() {
        waveforms = (nil, nil)
        guard let folder, let recording = session.recording else { return }
        let original = folder.appendingPathComponent(recording.originalFile)
        let mix = folder.appendingPathComponent(recording.mixFile)
        Task {
            async let a = WaveformExtractor.waveform(url: original)
            async let b = WaveformExtractor.waveform(url: mix)
            let result = await (a, b)
            waveforms = (original: result.0, mix: result.1)
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
        session.inPoint = snapped(min(currentTime, session.exportRange.upperBound - 0.5))
    }

    func markOut() {
        session.outPoint = snapped(max(currentTime, session.inPoint + 0.5))
    }

    func clearInOut() {
        session.inPoint = 0
        session.outPoint = session.duration
    }

    // MARK: - Export

    private var exportBaseName: String {
        let raw = session.title.isEmpty ? (folder?.lastPathComponent ?? "Session") : session.title
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    func export() {
        guard let folder, session.recording != nil, !isExporting else { return }
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
                let filmTime = still.time + snapshot.filmOffset
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
