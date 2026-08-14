import CoreGraphics
import Foundation

// MARK: - Audio sources

/// How an audio source found its place on the project timeline.
enum SyncMode: String, Codable, Sendable {
    /// Offset derived from embedded timecode (BWF `bext` or QuickTime `tmcd`).
    case timecode
    /// Both files simply start together.
    case fileStart
    /// The user moved it by hand.
    case manual

    var title: String {
        switch self {
        case .timecode: "Timecode"
        case .fileStart: "File start"
        case .manual: "Manual"
        }
    }
}

/// One audio layer under the picture: the original production mix, the final
/// mix, or a stem such as SFX-only.
struct AudioSource: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Absolute path. `nil` means the audio that lives inside the video file.
    var path: String?
    var offsetSeconds: Double = 0
    var gainDB: Double = 0
    var syncMode: SyncMode = .fileStart
    /// Start of media as seconds since timecode midnight, when known.
    var timecodeStartSeconds: Double?
    var durationSeconds: Double = 0
    var channelCount: Int = 2
    var sampleRate: Double = 48_000
    /// Included when building the preview timeline.
    var isEnabled: Bool = true

    var isEmbedded: Bool { path == nil }

    var url: URL? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path)
    }

    var channelDescription: String {
        switch channelCount {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channelCount) ch"
        }
    }

    /// Range this source occupies on the project timeline.
    var timelineRange: ClosedRange<Double> {
        offsetSeconds...(offsetSeconds + max(durationSeconds, 0))
    }
}

// MARK: - Clips

/// A social-media excerpt with an A/B switch inside it.
struct Clip: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Project-timeline seconds. t = 0 is the first frame of the video.
    var start: Double
    var end: Double
    /// Absolute project seconds. `nil` keeps the split at the exact midpoint.
    var splitOverride: Double?
    /// Audio heard before the switch. `nil` falls back to the project default.
    var beforeSourceID: UUID?
    /// Audio heard after the switch. `nil` falls back to the project default.
    var afterSourceID: UUID?
    /// Framing inside the crop, -1 … 1. 0 is centred.
    var panX: Double = 0
    var panY: Double = 0
    /// Included in a batch export.
    var isEnabled: Bool = true

    var duration: Double { max(end - start, 0) }

    /// Where the picture flips from before-look to after-look.
    var splitTime: Double {
        guard let splitOverride else { return start + duration / 2 }
        return min(max(splitOverride, start), end)
    }

    /// Split expressed 0 … 1 within the clip.
    var splitFraction: Double {
        guard duration > 0 else { return 0.5 }
        return (splitTime - start) / duration
    }

    /// A filesystem-safe version of the clip name.
    var safeName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let collapsed = cleaned
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .joined(separator: "-")
        return collapsed.isEmpty ? "clip" : collapsed
    }
}

// MARK: - Look and framing

/// Grade applied to one half of the A/B split.
enum LookStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case color
    case blackAndWhite
    case desaturated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: "Colour (original)"
        case .blackAndWhite: "Black & white"
        case .desaturated: "Desaturated"
        }
    }
}

/// How the source frame is fitted into the social aspect ratio.
enum FitMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Fill the frame and crop the overflow.
    case fill
    /// Fit the whole frame and letterbox with black.
    case fit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: "Fill (crop)"
        case .fit: "Fit (bars)"
        }
    }
}

/// How the burnt-in before/after label is drawn.
enum LabelStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Bold plain type, tinted with the dominant hue of the cropped frame.
    case tinted
    /// White type on a translucent pill — safe on any footage.
    case pill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tinted: "Tinted from the frame"
        case .pill: "White on a pill"
        }
    }
}

/// A drop shadow is the only thing that keeps plain type readable over
/// mid-tone footage, so it can be left to the contrast measurement.
enum LabelShadowMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Only when the measured contrast against the frame is too low.
    case auto
    case off
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .off: "Off"
        case .always: "Always"
        }
    }
}

enum LabelPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case top
    case bottom

    var id: String { rawValue }
    var title: String { self == .top ? "Top" : "Bottom" }
}

/// Delivery aspect ratios. All portrait formats render at 1080 wide, which is
/// what Instagram, TikTok and YouTube Shorts expect.
enum SocialFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait45
    case portrait916
    case square11
    case landscape169

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .portrait45: CGSize(width: 1080, height: 1350)
        case .portrait916: CGSize(width: 1080, height: 1920)
        case .square11: CGSize(width: 1080, height: 1080)
        case .landscape169: CGSize(width: 1920, height: 1080)
        }
    }

    var title: String {
        switch self {
        case .portrait45: "4:5"
        case .portrait916: "9:16"
        case .square11: "1:1"
        case .landscape169: "16:9"
        }
    }

    var subtitle: String {
        let size = size
        return "\(Int(size.width))×\(Int(size.height))"
    }

    var fileSuffix: String {
        switch self {
        case .portrait45: "4x5"
        case .portrait916: "9x16"
        case .square11: "1x1"
        case .landscape169: "16x9"
        }
    }
}

enum VideoCodecChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: "H.264 (most compatible)"
        case .hevc: "HEVC (smaller files)"
        }
    }
}

// MARK: - Export settings

struct ExportSettings: Codable, Hashable {
    var formats: [SocialFormat] = [.portrait45, .portrait916]
    var outputFolderPath: String?
    var codec: VideoCodecChoice = .h264
    var fitMode: FitMode = .fill
    var beforeLook: LookStyle = .blackAndWhite
    var afterLook: LookStyle = .color
    var showLabels: Bool = true
    var beforeLabel: String = "VORHER"
    var afterLabel: String = "NACHHER"
    var labelPosition: LabelPosition = .bottom
    var labelStyle: LabelStyle = .tinted
    var labelShadow: LabelShadowMode = .auto
    /// Length of the audio crossfade centred on the split, in milliseconds.
    var audioCrossfadeMilliseconds: Double = 40
    /// Manual bitrate override in Mbit/s. `nil` uses the automatic estimate.
    var videoBitrateMbps: Double?

    var outputFolderURL: URL? {
        guard let outputFolderPath else { return nil }
        return URL(fileURLWithPath: outputFolderPath)
    }
}

// MARK: - Project

struct ABProject: Codable {
    var videoPath: String?
    var videoDurationSeconds: Double = 0
    var videoNaturalWidth: Double = 0
    var videoNaturalHeight: Double = 0
    /// Start of picture as seconds since timecode midnight, when known.
    var videoTimecodeStartSeconds: Double?
    var frameRate: FrameRate = .fps25
    var dropFrame: Bool = false
    var audioSources: [AudioSource] = []
    var clips: [Clip] = []
    /// House length for a social cut. New clips are created at this length.
    var defaultClipLengthSeconds: Double = 20
    /// When set, in and out points slide a fixed-length window instead of
    /// trimming one edge, so every clip stays exactly the house length.
    var keepClipLengthFixed: Bool = true
    /// Default "before" audio when a clip does not override it.
    var defaultBeforeSourceID: UUID?
    /// Default "after" audio when a clip does not override it.
    var defaultAfterSourceID: UUID?
    var export = ExportSettings()

    var videoURL: URL? {
        guard let videoPath else { return nil }
        return URL(fileURLWithPath: videoPath)
    }

    var hasVideo: Bool { videoPath != nil }

    var videoNaturalSize: CGSize {
        CGSize(width: videoNaturalWidth, height: videoNaturalHeight)
    }

    var name: String {
        videoURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// Longest thing on the timeline — the picture, or audio that runs past it.
    var timelineDuration: Double {
        let audioEnd = audioSources.map { $0.offsetSeconds + $0.durationSeconds }.max() ?? 0
        return max(videoDurationSeconds, max(audioEnd, 1))
    }

    func source(withID id: UUID?) -> AudioSource? {
        guard let id else { return nil }
        return audioSources.first { $0.id == id }
    }

    /// The audio a clip uses before the switch, falling back to the project
    /// default and then to the first available source.
    func beforeSource(for clip: Clip) -> AudioSource? {
        source(withID: clip.beforeSourceID)
            ?? source(withID: defaultBeforeSourceID)
            ?? audioSources.first
    }

    /// The audio a clip uses after the switch.
    func afterSource(for clip: Clip) -> AudioSource? {
        source(withID: clip.afterSourceID)
            ?? source(withID: defaultAfterSourceID)
            ?? beforeSource(for: clip)
    }

    /// Nudges one frame at the project frame rate.
    var frameDuration: Double { 1.0 / frameRate.fps }

    mutating func clampClips() {
        let limit = max(videoDurationSeconds, 0)
        guard limit > 0 else { return }
        for index in clips.indices {
            clips[index].start = min(max(clips[index].start, 0), limit)
            clips[index].end = min(max(clips[index].end, clips[index].start), limit)
            if let override = clips[index].splitOverride {
                clips[index].splitOverride = min(max(override, clips[index].start), clips[index].end)
            }
        }
    }
}
