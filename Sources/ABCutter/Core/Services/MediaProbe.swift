import AVFoundation
import CoreMedia
import Foundation

enum MediaProbeError: LocalizedError {
    case noVideoTrack(URL)
    case noAudioTrack(URL)
    case unreadable(URL)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack(let url):
            "\(url.lastPathComponent) enthält keine Bildspur."
        case .noAudioTrack(let url):
            "\(url.lastPathComponent) enthält keine Tonspur."
        case .unreadable(let url):
            "\(url.lastPathComponent) konnte nicht gelesen werden."
        }
    }
}

struct VideoProbe: Sendable {
    var url: URL
    var duration: Double
    var naturalSize: CGSize
    var preferredTransform: CGAffineTransform
    var nominalFrameRate: Double
    var timecode: StartTimecode?
    var hasAudio: Bool
    var audioChannelCount: Int
    var audioSampleRate: Double
}

struct AudioProbe: Sendable {
    var url: URL
    var duration: Double
    var channelCount: Int
    var sampleRate: Double
    var timecode: StartTimecode?
}

/// Loads the handful of properties the app needs from a media file, without
/// touching or rewriting the original.
enum MediaProbe {
    static func probeVideo(url: URL) async throws -> VideoProbe {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            throw MediaProbeError.noVideoTrack(url)
        }

        let duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let nominal = Double((try? await videoTrack.load(.nominalFrameRate)) ?? 0)

        // nominalFrameRate can be 0 on some containers; fall back to the
        // reciprocal of the minimum frame duration.
        var frameRate = nominal
        if !(frameRate > 0), let minFrameDuration = try? await videoTrack.load(.minFrameDuration) {
            let seconds = CMTimeGetSeconds(minFrameDuration)
            if seconds.isFinite, seconds > 0 { frameRate = 1.0 / seconds }
        }
        if !(frameRate > 0) { frameRate = 25 }

        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        var channels = 0
        var sampleRate: Double = 0
        if let audioTrack {
            (channels, sampleRate) = await audioFormat(of: audioTrack)
        }

        return VideoProbe(
            url: url,
            duration: duration.isFinite ? duration : 0,
            naturalSize: naturalSize,
            preferredTransform: transform,
            nominalFrameRate: frameRate,
            timecode: await TimecodeReader.startTimecode(for: url, asset: asset),
            hasAudio: audioTrack != nil,
            audioChannelCount: max(channels, audioTrack == nil ? 0 : 2),
            audioSampleRate: sampleRate > 0 ? sampleRate : 48_000
        )
    }

    static func probeAudio(url: URL) async throws -> AudioProbe {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaProbeError.noAudioTrack(url)
        }

        let duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        let (channels, sampleRate) = await audioFormat(of: audioTrack)

        return AudioProbe(
            url: url,
            duration: duration.isFinite ? duration : 0,
            channelCount: max(channels, 1),
            sampleRate: sampleRate > 0 ? sampleRate : 48_000,
            timecode: await TimecodeReader.startTimecode(for: url, asset: asset)
        )
    }

    private static func audioFormat(of track: AVAssetTrack) async -> (channels: Int, sampleRate: Double) {
        guard let descriptions = try? await track.load(.formatDescriptions) else { return (0, 0) }
        for description in descriptions {
            guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { continue }
            return (Int(basic.pointee.mChannelsPerFrame), basic.pointee.mSampleRate)
        }
        return (0, 0)
    }
}
