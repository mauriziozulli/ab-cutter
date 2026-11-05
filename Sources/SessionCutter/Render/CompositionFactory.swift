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
        let overlays = OverlayFactory.overlays(for: format, session: session)
        let composition = AVMutableComposition()
        let length = max(range.upperBound - range.lowerBound, 0.04)

        // Film: film time is timeline time.
        var filmTrackID = kCMPersistentTrackID_Invalid
        var frameDuration = CMTime(value: 1, timescale: 25)
        if let filmURL = session.filmURL {
            let filmAsset = AVURLAsset(url: filmURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            if let filmSource = try? await filmAsset.loadTracks(withMediaType: .video).first,
               let filmTrack = composition.addMutableTrack(
                   withMediaType: .video,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                let filmDuration = (try? await filmAsset.load(.duration)).map(CMTimeGetSeconds) ?? 0
                try await place(
                    filmSource, into: filmTrack,
                    sourceFrom: range.lowerBound, sourceTo: min(range.upperBound, filmDuration),
                    at: 0
                )
                if filmTrack.segments.isEmpty {
                    composition.removeTrack(filmTrack)
                } else {
                    filmTrackID = filmTrack.trackID
                }
                if let minimum = try? await filmSource.load(.minFrameDuration), minimum.isValid, minimum.seconds > 0 {
                    frameDuration = minimum
                }
            }
        }

        // Takes: screen and both mixes, segment by segment, latest on top.
        let segments = session.segments().compactMap { segment -> TakeSegment? in
            var clipped = segment
            clipped.from = max(segment.from, range.lowerBound)
            clipped.to = min(segment.to, range.upperBound)
            return clipped.to - clipped.from > 0.001 ? clipped : nil
        }

        var screenTrackID = kCMPersistentTrackID_Invalid
        var parameters: [AVMutableAudioMixInputParameters] = []
        let startsOnMix = session.isMix(at: range.lowerBound)
        let switches = session.sortedSwitches
            .map { $0 - range.lowerBound }
            .filter { $0 > 0 && $0 < length }

        if !segments.isEmpty {
            guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let originalTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let mixTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw BuildError.trackFailed
            }

            var sources: [UUID: (screen: AVAssetTrack?, original: AVAssetTrack?, mix: AVAssetTrack?)] = [:]
            for segment in segments where sources[segment.take.id] == nil {
                let take = segment.take
                sources[take.id] = (
                    try? await firstTrack(take.url(take.screenFile, in: folder), .video),
                    try? await firstTrack(take.url(take.originalFile, in: folder), .audio),
                    try? await firstTrack(take.url(take.mixFile, in: folder), .audio)
                )
            }

            for segment in segments {
                let take = segment.take
                guard let source = sources[take.id] else { continue }
                let at = segment.from - range.lowerBound
                if let screen = source.screen {
                    try await place(screen, into: screenTrack,
                              sourceFrom: segment.from - take.start, sourceTo: segment.to - take.start, at: at)
                }
                if let original = source.original {
                    try await place(original, into: originalTrack,
                              sourceFrom: segment.from - take.start - take.originalLead,
                              sourceTo: segment.to - take.start - take.originalLead, at: at)
                }
                if let mix = source.mix {
                    try await place(mix, into: mixTrack,
                              sourceFrom: segment.from - take.start - take.mixLead,
                              sourceTo: segment.to - take.start - take.mixLead, at: at)
                }
            }

            if screenTrack.segments.isEmpty {
                composition.removeTrack(screenTrack)
            } else {
                screenTrackID = screenTrack.trackID
            }

            // An empty track is a reason for the exporter to give up.
            var audioTracks: [(AVMutableCompositionTrack, Bool)] = []
            for (track, isMix) in [(originalTrack, false), (mixTrack, true)] {
                if track.segments.isEmpty {
                    composition.removeTrack(track)
                } else {
                    audioTracks.append((track, isMix))
                }
            }

            for (track, isMix) in audioTracks {
                let parameter = AVMutableAudioMixInputParameters(track: track)
                var audible = isMix == startsOnMix
                parameter.setVolume(audible ? 1 : 0, at: .zero)
                for point in switches {
                    let from: Float = audible ? 1 : 0
                    audible.toggle()
                    parameter.setVolumeRamp(
                        fromStartVolume: from,
                        toEndVolume: audible ? 1 : 0,
                        timeRange: CMTimeRange(start: time(max(point - switchRamp / 2, 0)), duration: time(switchRamp))
                    )
                }
                parameters.append(parameter)
            }
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
            screenTrackID: screenTrackID
        )

        // The instruction covers the whole range even where no track has
        // media, so a gap renders as the empty layout instead of failing.
        if composition.tracks(withMediaType: .video).isEmpty {
            throw BuildError.noRecording
        }
        // The instruction covers the composition exactly: an instruction that
        // runs past the media makes AVFoundation refuse the whole item.
        let total = composition.duration
        Diagnostics.log(String(
            format: "Komposition %@: %.3f–%.3f s, Dauer %.3f s, Bild %@, Film %@, %ld Abschnitte",
            format.fileSuffix, range.lowerBound, range.upperBound, CMTimeGetSeconds(total),
            screenTrackID == kCMPersistentTrackID_Invalid ? "fehlt" : "ok",
            filmTrackID == kCMPersistentTrackID_Invalid ? "fehlt" : "ok",
            segments.count
        ))
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

    private static func firstTrack(_ url: URL, _ type: AVMediaType) async throws -> AVAssetTrack? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        return try await asset.loadTracks(withMediaType: type).first
    }

    /// Places source time `sourceFrom ..< sourceTo` at composition time `at`,
    /// clipped to what the source has, padding any gap before it with an
    /// empty edit.
    ///
    /// The clipping is done in CMTime, against the source's own range: a
    /// range converted from seconds can round a sample past the end of the
    /// file, and AVFoundation refuses that (-12780) — which used to take the
    /// whole preview down with it. A piece that still will not go in is
    /// logged and left out; the rest of the post is built regardless.
    private static func place(
        _ source: AVAssetTrack,
        into track: AVMutableCompositionTrack,
        sourceFrom: Double,
        sourceTo: Double,
        at: Double
    ) async throws {
        guard sourceFrom.isFinite, sourceTo.isFinite, at.isFinite else { return }
        guard let sourceRange = try? await source.load(.timeRange),
              sourceRange.isValid, !sourceRange.isEmpty else {
            Diagnostics.log("Spur ohne lesbare Länge übersprungen")
            return
        }

        // Exact CMTime arithmetic against the file's own edges.
        let start = CMTimeMaximum(time(max(sourceFrom, 0)), sourceRange.start)
        let end = CMTimeMinimum(time(sourceTo), sourceRange.end)
        guard CMTimeCompare(end, start) > 0,
              CMTimeGetSeconds(CMTimeSubtract(end, start)) > 0.001 else { return }

        let target = time(max(at + (CMTimeGetSeconds(start) - sourceFrom), 0))
        let trackEnd = track.timeRange.isValid ? track.timeRange.end : .zero
        if CMTimeCompare(target, trackEnd) > 0 {
            track.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: target))
        }
        let insertAt = CMTimeMaximum(target, trackEnd)
        do {
            try track.insertTimeRange(CMTimeRange(start: start, end: end), of: source, at: insertAt)
        } catch {
            Diagnostics.log(String(
                format: "Stück übersprungen (%@): Quelle %.4f–%.4f s von %.4f–%.4f s, an %.4f s — %@",
                source.mediaType.rawValue,
                CMTimeGetSeconds(start), CMTimeGetSeconds(end),
                CMTimeGetSeconds(sourceRange.start), CMTimeGetSeconds(sourceRange.end),
                CMTimeGetSeconds(insertAt),
                Diagnostics.describe(error)
            ))
        }
    }
}
