import AVFoundation
import CoreMedia
import Foundation

enum CompositionError: LocalizedError {
    case noVideo
    case noVideoTrack
    case trackCreationFailed
    case emptyClip

    var errorDescription: String? {
        switch self {
        case .noVideo: "Es ist kein Video geladen."
        case .noVideoTrack: "Die Videodatei hat keine lesbare Bildspur."
        case .trackCreationFailed: "Eine Spur konnte nicht angelegt werden."
        case .emptyClip: "Der Clip hat keine Länge."
        }
    }
}

/// A composition covering the whole project, used for preview playback.
struct TimelineComposition {
    var composition: AVMutableComposition
    /// Every audio track in the composition, keyed by the source it came from.
    var audioTracks: [UUID: AVMutableCompositionTrack]
    var videoNaturalSize: CGSize
    var videoPreferredTransform: CGAffineTransform
    var frameDuration: CMTime
    var duration: CMTime
}

/// A composition trimmed to one clip, with the clip starting after whatever
/// hold the title card was given — at t = 0 when there is none.
struct ClipComposition {
    var composition: AVMutableComposition
    var audioMix: AVAudioMix?
    var duration: CMTime
    /// Where the picture and sound flip, in the composition's own time, so
    /// already shifted past the lead. They alternate, so an odd index is a
    /// flip back to the before source.
    var switchTimes: [CMTime]
    /// The stretch the film itself occupies. Anything before it belongs to the
    /// title card, anything after it to the end card.
    var pictureRange: CMTimeRange
    var videoNaturalSize: CGSize
    var videoPreferredTransform: CGAffineTransform
    var frameDuration: CMTime
}

enum CompositionBuilder {
    private static let timescale: CMTimeScale = 90_000

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(seconds, 0), preferredTimescale: timescale)
    }

    private static func linearGain(_ decibels: Double) -> Float {
        Float(pow(10.0, decibels / 20.0))
    }

    // MARK: - Preview timeline

    /// Builds the full project timeline: picture from t = 0, every enabled
    /// audio source placed at its sync offset on its own track.
    static func buildTimeline(project: ABProject) async throws -> TimelineComposition {
        guard let videoURL = project.videoURL else { throw CompositionError.noVideo }

        let videoAsset = AVURLAsset(url: videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw CompositionError.noVideoTrack
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw CompositionError.trackCreationFailed }

        let videoDuration = try await videoAsset.load(.duration)
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: sourceVideo, at: .zero)

        let window = CMTimeRange(start: .zero, duration: videoDuration)
        var audioTracks: [UUID: AVMutableCompositionTrack] = [:]
        for source in project.audioSources where source.isEnabled {
            if let track = try await placeAudio(
                source: source,
                videoAsset: videoAsset,
                into: composition,
                window: window
            ) {
                audioTracks[source.id] = track
            }
        }

        return TimelineComposition(
            composition: composition,
            audioTracks: audioTracks,
            videoNaturalSize: try await sourceVideo.load(.naturalSize),
            videoPreferredTransform: try await sourceVideo.load(.preferredTransform),
            frameDuration: try await frameDuration(of: sourceVideo),
            duration: composition.duration
        )
    }

    // MARK: - Clip composition

    /// Builds a composition holding exactly one clip, with an audio mix that
    /// crossfades from the "before" source to the "after" source at each
    /// switch.
    ///
    /// `lead` and `tail` are the holds for the title and end cards. The cards
    /// themselves are drawn by the renderer; what is needed here is time on
    /// the video track for them to occupy, because a Core Image handler is
    /// only asked for frames where the composition actually has some.
    static func buildClip(
        project: ABProject,
        clip: Clip,
        lead: Double = 0,
        tail: Double = 0
    ) async throws -> ClipComposition {
        guard let videoURL = project.videoURL else { throw CompositionError.noVideo }
        guard clip.duration > 0 else { throw CompositionError.emptyClip }

        let videoAsset = AVURLAsset(url: videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw CompositionError.noVideoTrack
        }

        let assetDuration = try await videoAsset.load(.duration)
        let clipStart = time(clip.start)
        let clipEnd = CMTimeMinimum(time(clip.end), assetDuration)
        guard CMTimeCompare(clipEnd, clipStart) > 0 else { throw CompositionError.emptyClip }
        let clipRange = CMTimeRange(start: clipStart, end: clipEnd)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw CompositionError.trackCreationFailed }

        // A hold is a short seed of the film slowed to fill it. A single frame
        // stretched sixty times is asking a lot of the compositor, so the seed
        // is up to half a second and the slowdown stays modest. What it looks
        // like does not matter: the card is opaque and covers all of it.
        let leadHold = time(lead)
        let tailHold = time(tail)

        if CMTimeCompare(leadHold, .zero) > 0 {
            let seed = seedRange(at: clipRange.start, within: clipRange)
            try videoTrack.insertTimeRange(seed, of: sourceVideo, at: .zero)
            videoTrack.scaleTimeRange(
                CMTimeRange(start: .zero, duration: seed.duration),
                toDuration: leadHold
            )
        }

        // A loop clip's picture is the selection played once per pass — the
        // repetition is the point, so it lives on the video track rather than
        // in a player setting anyone could miss.
        let passes = clip.kind == .loop ? 1 + min(max(clip.loopPasses, 1), 4) : 1

        let pictureStart = videoTrack.timeRange.duration
        for pass in 0..<passes {
            let at = CMTimeAdd(
                pictureStart,
                CMTimeMultiply(clipRange.duration, multiplier: Int32(pass))
            )
            try videoTrack.insertTimeRange(clipRange, of: sourceVideo, at: at)
        }
        let pictureRange = CMTimeRange(
            start: pictureStart,
            duration: CMTimeMultiply(clipRange.duration, multiplier: Int32(passes))
        )

        if CMTimeCompare(tailHold, .zero) > 0 {
            let seed = seedRange(endingAt: clipRange.end, within: clipRange)
            try videoTrack.insertTimeRange(seed, of: sourceVideo, at: pictureRange.end)
            videoTrack.scaleTimeRange(
                CMTimeRange(start: pictureRange.end, duration: seed.duration),
                toDuration: tailHold
            )
        }

        // Switches for an A/B are stored in project time; inside the
        // composition they are relative to the clip and pushed past the title
        // card's hold. A loop has exactly one switch — the seam between the
        // first pass and the repeats.
        let switchTimes: [CMTime]
        switch clip.kind {
        case .ab:
            switchTimes = clip.switches.map {
                CMTimeAdd(CMTimeSubtract(time($0), clipStart), pictureStart)
            }
        case .loop:
            switchTimes = [CMTimeAdd(pictureStart, clipRange.duration)]
        }

        let beforeSource = project.beforeSource(for: clip)
        let afterSource = project.afterSource(for: clip)
        let usesSameSource = beforeSource?.id == afterSource?.id
        let fade = time(max(clip.look.audioCrossfadeMilliseconds, 0) / 1000.0)

        var parameters: [AVMutableAudioMixInputParameters] = []

        if clip.kind == .loop {
            // Pass 1 carries the A source, every further pass the B source.
            // Each placement's media ends at its own seam, so no side ever
            // bleeds into the other — the ramps only soften the cut edges.
            if let source = beforeSource,
               let track = try await placeAudio(
                   source: source,
                   videoAsset: videoAsset,
                   into: composition,
                   window: clipRange,
                   shift: pictureStart
               ) {
                parameters.append(edgeParameters(
                    track: track,
                    gain: linearGain(source.gainDB),
                    from: pictureStart,
                    to: CMTimeAdd(pictureStart, clipRange.duration),
                    fade: fade
                ))
            }
            let loopSource = afterSource ?? beforeSource
            if let source = loopSource {
                for pass in 1..<passes {
                    let passStart = CMTimeAdd(
                        pictureStart,
                        CMTimeMultiply(clipRange.duration, multiplier: Int32(pass))
                    )
                    if let track = try await placeAudio(
                        source: source,
                        videoAsset: videoAsset,
                        into: composition,
                        window: clipRange,
                        shift: passStart
                    ) {
                        parameters.append(edgeParameters(
                            track: track,
                            gain: linearGain(source.gainDB),
                            from: passStart,
                            to: CMTimeAdd(passStart, clipRange.duration),
                            fade: fade
                        ))
                    }
                }
            }
        } else if usesSameSource {
            if let source = beforeSource,
               let track = try await placeAudio(
                   source: source,
                   videoAsset: videoAsset,
                   into: composition,
                   window: clipRange,
                   shift: pictureStart
               ) {
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(linearGain(source.gainDB), at: .zero)
                parameters.append(params)
            }
        } else {
            if let source = beforeSource,
               let track = try await placeAudio(
                   source: source,
                   videoAsset: videoAsset,
                   into: composition,
                   window: clipRange,
                   shift: pictureStart
               ) {
                parameters.append(
                    alternatingParameters(
                        track: track,
                        gain: linearGain(source.gainDB),
                        switchTimes: switchTimes,
                        fade: fade,
                        startsAudible: true
                    )
                )
            }

            if let source = afterSource,
               let track = try await placeAudio(
                   source: source,
                   videoAsset: videoAsset,
                   into: composition,
                   window: clipRange,
                   shift: pictureStart
               ) {
                parameters.append(
                    alternatingParameters(
                        track: track,
                        gain: linearGain(source.gainDB),
                        switchTimes: switchTimes,
                        fade: fade,
                        startsAudible: false
                    )
                )
            }
        }

        var audioMix: AVAudioMix?
        if !parameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters
            audioMix = mix
        }

        return ClipComposition(
            composition: composition,
            audioMix: audioMix,
            duration: composition.duration,
            switchTimes: switchTimes,
            pictureRange: pictureRange,
            videoNaturalSize: try await sourceVideo.load(.naturalSize),
            videoPreferredTransform: try await sourceVideo.load(.preferredTransform),
            frameDuration: try await frameDuration(of: sourceVideo)
        )
    }

    /// A short ramp in at `from` and out at `to`, so every seam of a looped
    /// placement lands without a click. The media itself already ends at the
    /// seam; these only soften its edges.
    static func edgeParameters(
        track: AVAssetTrack,
        gain: Float,
        from: CMTime,
        to: CMTime,
        fade: CMTime
    ) -> AVMutableAudioMixInputParameters {
        let params = AVMutableAudioMixInputParameters(track: track)
        guard CMTimeCompare(fade, .zero) > 0 else {
            params.setVolume(gain, at: .zero)
            return params
        }
        let half = CMTimeMultiplyByFloat64(fade, multiplier: 0.5)
        params.setVolume(0, at: .zero)
        params.setVolumeRamp(
            fromStartVolume: 0, toEndVolume: gain,
            timeRange: CMTimeRange(start: from, duration: half)
        )
        params.setVolumeRamp(
            fromStartVolume: gain, toEndVolume: 0,
            timeRange: CMTimeRange(start: CMTimeSubtract(to, half), duration: half)
        )
        return params
    }

    /// Volume automation for one side of the A/B across any number of
    /// switches. The two sides are exact mirrors, so a crossfade at each point
    /// sums to roughly constant loudness.
    static func alternatingParameters(
        track: AVAssetTrack,
        gain: Float,
        switchTimes: [CMTime],
        fade: CMTime,
        startsAudible: Bool
    ) -> AVMutableAudioMixInputParameters {
        let params = AVMutableAudioMixInputParameters(track: track)
        let hasFade = CMTimeCompare(fade, .zero) > 0
        let half = CMTimeMultiplyByFloat64(fade, multiplier: 0.5)

        var audible = startsAudible
        params.setVolume(audible ? gain : 0, at: .zero)

        for point in switchTimes {
            let target: Float = audible ? 0 : gain
            let from: Float = audible ? gain : 0
            if hasFade {
                var rampStart = CMTimeSubtract(point, half)
                if CMTimeCompare(rampStart, .zero) < 0 { rampStart = .zero }
                params.setVolumeRamp(
                    fromStartVolume: from,
                    toEndVolume: target,
                    timeRange: CMTimeRange(start: rampStart, duration: fade)
                )
            } else {
                params.setVolume(target, at: point)
            }
            audible.toggle()
        }
        return params
    }

    // MARK: - Audio placement

    /// Inserts one audio source into `composition`, honouring its sync offset.
    ///
    /// On the project timeline the source occupies
    /// `[offset, offset + duration]`. Only the overlap with `window` is
    /// inserted, shifted so that `window.start` lands at t = 0.
    @discardableResult
    /// `shift` moves the placement later in the composition, which is what a
    /// title card's hold needs: the sound belongs to the film, not to the card
    /// in front of it.
    private static func placeAudio(
        source: AudioSource,
        videoAsset: AVURLAsset,
        into composition: AVMutableComposition,
        window: CMTimeRange,
        shift: CMTime = .zero
    ) async throws -> AVMutableCompositionTrack? {
        // A folded source reads from its mono companion, so the preview and
        // the export are fed by the identical audio.
        let asset: AVURLAsset
        if let folded = source.foldedURL, FileManager.default.fileExists(atPath: folded.path) {
            asset = AVURLAsset(url: folded, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        } else if let url = source.url {
            asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        } else {
            asset = videoAsset
        }

        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { return nil }

        let assetDuration = try await asset.load(.duration)
        let offset = CMTime(seconds: source.offsetSeconds, preferredTimescale: timescale)
        // Where this source sits on the project timeline.
        let placedStart = offset
        let placedEnd = CMTimeAdd(offset, assetDuration)

        let overlapStart = CMTimeMaximum(placedStart, window.start)
        let overlapEnd = CMTimeMinimum(placedEnd, window.end)
        guard CMTimeCompare(overlapEnd, overlapStart) > 0 else { return nil }

        // Translate the overlap back into the audio asset's own timeline.
        let assetStart = CMTimeSubtract(overlapStart, offset)
        let assetRange = CMTimeRange(start: CMTimeMaximum(assetStart, .zero), end: CMTimeSubtract(overlapEnd, offset))
        guard CMTimeCompare(assetRange.duration, .zero) > 0 else { return nil }

        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw CompositionError.trackCreationFailed }

        let insertionPoint = CMTimeSubtract(overlapStart, window.start)
        try track.insertTimeRange(
            assetRange,
            of: sourceTrack,
            at: CMTimeAdd(CMTimeMaximum(insertionPoint, .zero), shift)
        )
        return track
    }

    // MARK: - Helpers

    /// The longest hold of the film a card may be built on top of.
    private static let seedLimit = CMTime(value: 45_000, timescale: timescale)   // 0.5 s

    private static func seedRange(at start: CMTime, within range: CMTimeRange) -> CMTimeRange {
        CMTimeRange(start: start, duration: CMTimeMinimum(seedLimit, range.duration))
    }

    private static func seedRange(endingAt end: CMTime, within range: CMTimeRange) -> CMTimeRange {
        let duration = CMTimeMinimum(seedLimit, range.duration)
        return CMTimeRange(start: CMTimeSubtract(end, duration), duration: duration)
    }

    private static func frameDuration(of track: AVAssetTrack) async throws -> CMTime {
        if let minimum = try? await track.load(.minFrameDuration),
           CMTIME_IS_NUMERIC(minimum), CMTimeGetSeconds(minimum) > 0 {
            return minimum
        }
        let nominal = Double((try? await track.load(.nominalFrameRate)) ?? 25)
        let rate = nominal > 0 ? nominal : 25
        return CMTime(seconds: 1.0 / rate, preferredTimescale: timescale)
    }
}
