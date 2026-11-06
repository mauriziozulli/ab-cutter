import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum ScreenRecordError: LocalizedError {
    case noPermission
    case noDisplay
    case writerFailed(String)
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .noPermission:
            "Session Cutter darf den Bildschirm nicht aufnehmen. Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme, dann die App neu starten."
        case .noDisplay:
            "Der Aufnahmerahmen liegt auf keinem Bildschirm."
        case .writerFailed(let detail):
            "Die Bildaufnahme konnte nicht geschrieben werden. \(detail)"
        case .nothingRecorded:
            "Es kam kein einziges Bild an."
        }
    }
}

/// Records one rectangle of the screen — whatever sits under the capture
/// frame — at the display's full backing resolution.
///
/// The frame window itself is excluded from the capture, so its border and
/// label never end up in the picture. ScreenCaptureKit only delivers a frame
/// when something changed; the writer takes variable frame timing, and the
/// last frame is held to the moment Stop was pressed.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let queue = DispatchQueue(label: "SessionCutter.screen")

    private var firstTime: CMTime?
    private var failure: Error?
    /// What the stream delivered, by frame status, and what was written.
    private var statusCounts: [Int: Int] = [:]
    private var appended = 0
    private var notReady = 0
    private static let maxLongSide: CGFloat = 2880

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// `rect` in global AppKit coordinates (origin bottom left of the main
    /// screen), as an NSWindow frame is given.
    func start(rect: CGRect, to url: URL) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenRecordError.noPermission
        }

        let centre = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
            throw ScreenRecordError.noDisplay
        }

        // Every window of this app is left out — the frame, and the main
        // window too should it sit over Pro Tools. What lies under them is
        // recorded as if they were not there.
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownProcess }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        // Display-local, top-left origin, in points.
        let local = CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        // The export shows Pro Tools in a 1080 px band, so the full backing
        // resolution (4634 px on a 5K display) buys nothing — but it breaks
        // the H.264 encoder's limits and starves Pro Tools of CPU, which
        // stutters the very sound being recorded. Cap the long side.
        let backing = screen.backingScaleFactor
        let shrink = min(1, Self.maxLongSide / (max(local.width, local.height) * backing))
        let scale = backing * shrink
        let width = Self.even(local.width * scale)
        let height = Self.even(local.height * scale)

        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 8
        config.showsCursor = true
        config.capturesAudio = false

        let writer: AVAssetWriter
        do {
            try? FileManager.default.removeItem(at: url)
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw ScreenRecordError.writerFailed(error.localizedDescription)
        }
        // Text and meters: a generous rate keeps the Pro Tools edit window
        // readable after the platform's own re-encode.
        let bitRate = Double(width * height) * 30 * 0.12
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw ScreenRecordError.writerFailed("Kein Videoeingang.") }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            throw ScreenRecordError.writerFailed(error.localizedDescription)
        }

        queue.sync {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.firstTime = nil
            self.failure = nil
            self.statusCounts = [:]
            self.appended = 0
            self.notReady = 0
        }
        Diagnostics.log(String(
            format: "Bildaufnahme: Display %u, Ausschnitt %.0f,%.0f %.0f×%.0f pt → %ld×%ld px, %ld eigene App(s) ausgeschlossen",
            display.displayID, local.minX, local.minY, local.width, local.height, width, height, ownApps.count
        ))
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            throw ScreenRecordError.noPermission
        }
    }

    /// Stops and finishes the file. Returns where the first frame sits in host
    /// seconds — the clock the audio is stamped with — and how long it runs.
    func stop() async throws -> (start: Double, duration: Double) {
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        let state: (AVAssetWriter?, AVAssetWriterInput?, CMTime?, Error?) = queue.sync {
            (writer, input, firstTime, failure)
        }
        let counts = queue.sync { (statusCounts, appended) }
        Diagnostics.log("Bildaufnahme gestoppt: Frame-Status \(counts.0) (0 = vollständig), \(counts.1) Bilder geschrieben, \(queue.sync { notReady }) verworfen (Encoder nicht bereit), Writer-Status \(state.0?.status.rawValue ?? -1)")
        if let error = state.3 { Diagnostics.log("Bildaufnahme Fehler: \(Diagnostics.describe(error))") }
        guard let writer = state.0, let input = state.1, let first = state.2 else {
            throw ScreenRecordError.nothingRecorded
        }
        if let error = state.3 { throw ScreenRecordError.writerFailed(error.localizedDescription) }

        input.markAsFinished()
        writer.endSession(atSourceTime: max(stopTime, first))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status == .failed {
            Diagnostics.log("Writer fehlgeschlagen: \(Diagnostics.describe(writer.error))")
            throw ScreenRecordError.writerFailed(writer.error?.localizedDescription ?? "")
        }
        queue.sync {
            self.writer = nil
            self.input = nil
            self.adaptor = nil
        }
        return (CMTimeGetSeconds(first), max(CMTimeGetSeconds(stopTime) - CMTimeGetSeconds(first), 0))
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int else { return }
        statusCounts[rawStatus, default: 0] += 1
        guard SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let writer, let input, let adaptor else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstTime == nil {
            guard writer.startWriting() else {
                failure = writer.error
                return
            }
            writer.startSession(atSourceTime: time)
            firstTime = time
        }
        guard writer.status == .writing else { return }
        guard input.isReadyForMoreMediaData else {
            notReady += 1
            return
        }
        if adaptor.append(pixels, withPresentationTime: time) {
            appended += 1
        } else {
            failure = writer.error
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Diagnostics.log("Bildaufnahme abgebrochen: \(Diagnostics.describe(error))")
        queue.async { self.failure = error }
    }

    private static func even(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        return max(rounded - rounded % 2, 2)
    }
}
