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
        case .noVideo: "No video has been loaded."
        case .noVideoTrack: "The video file has no readable video track."
        case .trackCreationFailed: "A composition track could not be created."
        case .emptyClip: "The clip has no length."
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

/// A composition trimmed to one clip, with the clip starting at t = 0.
struct ClipComposition {
    var composition: AVMutableComposition
    var audioMix: AVAudioMix?
    var duration: CMTime
    /// Where the picture and sound flip, measured from the start of the clip.
    var splitTime: CMTime
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

    /// Builds a composition holding exactly one clip, starting at t = 0, with
    /// an audio mix that crossfades from the "before" source to the "after"
    /// source at the split point.
    static func buildClip(project: ABProject, clip: Clip) async throws -> ClipComposition {
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
        try videoTrack.insertTimeRange(clipRange, of: sourceVideo, at: .zero)

        // The split is stored in project time; inside the clip it is relative.
        let splitRelative = CMTimeSubtract(time(clip.splitTime), clipStart)

        let beforeSource = project.beforeSource(for: clip)
        let afterSource = project.afterSource(for: clip)
        let usesSameSource = beforeSource?.id == afterSource?.id

        var parameters: [AVMutableAudioMixInputParameters] = []

        if usesSameSource {
            if let source = beforeSource,
               let track = try await placeAudio(
                   source: source,
                   videoAsset: videoAsset,
                   into: composition,
                   window: clipRange
               ) {
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(linearGain(source.gainDB), at: .zero)
                parameters.append(params)
            }
        } else {
            let fade = time(max(project.export.audioCrossfadeMilliseconds, 0) / 1000.0)
            let half = CMTimeMultiplyByFloat64(fade, multiplier: 0.5)
            var rampStart = CMTimeSubtract(splitRelative, half)
            if CMTimeCompare(rampStart, .zero) < 0 { rampStart = .zero }
            let rampRange = CMTimeRange(start: rampStart, duration: fade)
            let hasFade = CMTimeCompare(fade, .zero) > 0

            if let source = beforeSource,
               let track = try await placeAudio(
                   source: source,
                   videoAsset: videoAsset,
                   into: composition,
                   window: clipRange
               ) {
                let gain = linearGain(source.gainDB)
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(gain, at: .zero)
                if hasFade {
                    params.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0, timeRange: rampRange)
                } else {
                    params.setVolume(0, at: splitRelative)
                }
                parameters.append(params)
            }

            if let source = afterSource,
               let track = try await placeAudio(
                   source: source,
                   videoAsset: videoAsset,
                   into: composition,
                   window: clipRange
               ) {
                let gain = linearGain(source.gainDB)
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(0, at: .zero)
                if hasFade {
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain, timeRange: rampRange)
                } else {
                    params.setVolume(gain, at: splitRelative)
                }
                parameters.append(params)
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
            splitTime: splitRelative,
            videoNaturalSize: try await sourceVideo.load(.naturalSize),
            videoPreferredTransform: try await sourceVideo.load(.preferredTransform),
            frameDuration: try await frameDuration(of: sourceVideo)
        )
    }

    // MARK: - Audio placement

    /// Inserts one audio source into `composition`, honouring its sync offset.
    ///
    /// On the project timeline the source occupies
    /// `[offset, offset + duration]`. Only the overlap with `window` is
    /// inserted, shifted so that `window.start` lands at t = 0.
    @discardableResult
    private static func placeAudio(
        source: AudioSource,
        videoAsset: AVURLAsset,
        into composition: AVMutableComposition,
        window: CMTimeRange
    ) async throws -> AVMutableCompositionTrack? {
        let asset: AVURLAsset
        if let url = source.url {
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
        try track.insertTimeRange(assetRange, of: sourceTrack, at: CMTimeMaximum(insertionPoint, .zero))
        return track
    }

    // MARK: - Helpers

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
