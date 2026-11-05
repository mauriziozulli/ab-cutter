import AVFoundation
import CoreMedia
import Foundation

enum BuildError: LocalizedError {
    case noRecording
    case unreadable(String)
    case trackFailed

    var errorDescription: String? {
        switch self {
        case .noRecording: "Diese Session hat noch keine Aufnahme."
        case .unreadable(let name): "«\(name)» konnte nicht gelesen werden."
        case .trackFailed: "Eine Spur konnte nicht angelegt werden."
        }
    }
}

/// A post, ready to play, export or grab from.
struct BuiltPost {
    var composition: AVMutableComposition
    var videoComposition: AVMutableVideoComposition
    var audioMix: AVMutableAudioMix
    /// Recording time at composition time 0.
    var origin: Double

    func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

/// Puts one stretch of a session together: the screen recording, the film at
/// its sync offset, both mixes, and an audio mix that flips between them at
/// every switch.
enum CompositionFactory {
    private static let timescale: CMTimeScale = 48_000
    /// Long enough to keep a switch from clicking, short enough to be a cut.
    private static let switchRamp = 0.012

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    @MainActor
    static func build(
        session: Session,
        folder: URL,
        format: OutputFormat,
        range: ClosedRange<Double>
    ) async throws -> BuiltPost {
        guard let recording = session.recording else { throw BuildError.noRecording }
        let overlays = OverlayFactory.overlays(for: format, session: session)

        let composition = AVMutableComposition()
        let length = range.upperBound - range.lowerBound

        // Screen.
        let screenURL = folder.appendingPathComponent(recording.screenFile)
        let screenAsset = AVURLAsset(url: screenURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let screenSource = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw BuildError.unreadable(recording.screenFile)
        }
        guard let screenTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw BuildError.trackFailed }
        let screenDuration = CMTimeGetSeconds(try await screenAsset.load(.duration))
        try insert(
            screenSource, into: screenTrack,
            sourceStart: range.lowerBound, sourceDuration: screenDuration,
            lead: 0, range: range
        )

        // Film, at its offset.
        var filmTrackID = kCMPersistentTrackID_Invalid
        var frameDuration = CMTime(value: 1, timescale: 30)
        if let filmURL = session.filmURL {
            let filmAsset = AVURLAsset(url: filmURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            if let filmSource = try? await filmAsset.loadTracks(withMediaType: .video).first,
               let filmTrack = composition.addMutableTrack(
                   withMediaType: .video,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                let filmDuration = CMTimeGetSeconds(try await filmAsset.load(.duration))
                // Film time f sits at recording time f - offset.
                try insert(
                    filmSource, into: filmTrack,
                    sourceStart: range.lowerBound + session.filmOffset, sourceDuration: filmDuration,
                    lead: -session.filmOffset, range: range
                )
                if filmTrack.segments.isEmpty {
                    // The range lies outside the film: no picture to show.
                    composition.removeTrack(filmTrack)
                } else {
                    filmTrackID = filmTrack.trackID
                }
                if let minimum = try? await filmSource.load(.minFrameDuration), minimum.isValid, minimum.seconds > 0 {
                    frameDuration = minimum
                }
            }
        }

        // Both mixes.
        var parameters: [AVMutableAudioMixInputParameters] = []
        let sides: [(file: String, lead: Double, isMix: Bool)] = [
            (recording.originalFile, recording.originalLead, false),
            (recording.mixFile, recording.mixLead, true)
        ]
        let startsOnMix = session.isMix(at: range.lowerBound)
        let switches = session.sortedSwitches
            .map { $0 - range.lowerBound }
            .filter { $0 > 0 && $0 < length }

        for side in sides {
            let asset = AVURLAsset(url: folder.appendingPathComponent(side.file))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(
                      withMediaType: .audio,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            try insert(
                source, into: track,
                sourceStart: range.lowerBound - side.lead, sourceDuration: duration,
                lead: side.lead, range: range
            )

            let parameter = AVMutableAudioMixInputParameters(track: track)
            var audible = side.isMix == startsOnMix
            parameter.setVolume(audible ? 1 : 0, at: .zero)
            for point in switches {
                let from: Float = audible ? 1 : 0
                audible.toggle()
                let start = max(point - switchRamp / 2, 0)
                parameter.setVolumeRamp(
                    fromStartVolume: from,
                    toEndVolume: audible ? 1 : 0,
                    timeRange: CMTimeRange(start: time(start), duration: time(switchRamp))
                )
            }
            parameters.append(parameter)
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters

        let rects = LayoutPlan.rects(for: format)
        let plan = LayoutPlan(
            renderSize: format.size,
            filmRect: rects.film,
            screenRect: rects.screen,
            softBackdrop: format == .story,
            title: overlays.title,
            labelOriginal: overlays.labelOriginal,
            labelMix: overlays.labelMix,
            switches: switches,
            startsOnMix: startsOnMix,
            filmTrackID: filmTrackID,
            screenTrackID: screenTrack.trackID
        )

        let total = time(length)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = SessionCompositor.self
        videoComposition.renderSize = format.size
        videoComposition.frameDuration = frameDuration
        videoComposition.instructions = [
            LayoutInstruction(timeRange: CMTimeRange(start: .zero, duration: total), plan: plan)
        ]

        return BuiltPost(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            origin: range.lowerBound
        )
    }

    /// Inserts the part of `source` that falls inside `range`.
    ///
    /// - `sourceStart`: source time at the start of the range.
    /// - `lead`: recording time of the source's own zero, so source time s
    ///   plays at recording time s + lead.
    private static func insert(
        _ source: AVAssetTrack,
        into track: AVMutableCompositionTrack,
        sourceStart: Double,
        sourceDuration: Double,
        lead: Double,
        range: ClosedRange<Double>
    ) throws {
        let length = range.upperBound - range.lowerBound
        let from = max(sourceStart, 0)
        let to = min(sourceStart + length, sourceDuration)
        guard to - from > 0.001 else { return }
        let at = from + lead - range.lowerBound
        try track.insertTimeRange(
            CMTimeRange(start: time(from), duration: time(to - from)),
            of: source,
            at: time(max(at, 0))
        )
    }
}
