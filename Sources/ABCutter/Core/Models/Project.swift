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

/// How the picture is framed on each side of the A/B switch.
///
/// A scale change reads far faster than a colour change on a phone, and on an
/// audio A/B — where both halves show the identical picture — it is the only
/// treatment that carries real motion. The picture snapping out to full bleed
/// at the switch mirrors what the sound does.
enum FrameTreatment: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Before sits inset in a bordered frame, after fills the canvas.
    case insetBefore
    /// Both halves inset — tidier, but the switch loses its snap.
    case insetBoth
    /// Full bleed throughout; the grade alone marks the switch.
    case fullBleed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insetBefore: "Framed before → full bleed"
        case .insetBoth: "Framed throughout"
        case .fullBleed: "Full bleed"
        }
    }

    func isInset(before: Bool) -> Bool {
        switch self {
        case .insetBefore: before
        case .insetBoth: true
        case .fullBleed: false
        }
    }
}

/// What fills the canvas around an inset picture.
enum FrameBackdrop: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A blurred, darkened copy of the same frame.
    case blur
    /// A near-black card.
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blur: "Blurred frame"
        case .solid: "Near black"
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
    /// Muted rather than monochrome by default: the frame carries the switch,
    /// so the before half keeps its colour instead of going flat.
    var beforeLook: LookStyle = .desaturated
    var afterLook: LookStyle = .color
    var frameTreatment: FrameTreatment = .insetBefore
    var frameBackdrop: FrameBackdrop = .blur
    /// How much of the canvas an inset picture covers, 0.6 … 0.98.
    var insetScale: Double = 0.86
    var showFrameBorder: Bool = true
    var showLabels: Bool = true
    var beforeLabel: String = "VORHER"
    var afterLabel: String = "NACHHER"
    /// A quieter second line under the label — film title, direction, credits.
    var subtitleText: String = ""
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

// MARK: - Stills

enum StillTextPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case top
    case centre
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: "Top"
        case .centre: "Centre"
        case .bottom: "Bottom"
        }
    }
}

enum StillFileFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: "PNG (lossless)"
        case .jpeg: "JPEG"
        }
    }

    var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// The cover image of a post: one frame grabbed at full resolution, optionally
/// cropped to a social format and laid out as a title card.
struct StillSettings: Codable, Hashable {
    var headline: String = ""
    var subline: String = ""
    /// 0 … 100. Softens the picture so the type has somewhere to sit.
    var blurStrength: Double = 45
    /// 0 … 0.8. Darkens the picture under the type.
    var dimStrength: Double = 0.3
    var textPosition: StillTextPosition = .bottom
    /// Write the untouched frame at its native resolution as well.
    var saveFullFrame: Bool = true
    /// Write a title card per selected social format.
    var saveTitleCards: Bool = true
    var fileFormat: StillFileFormat = .png

    var hasText: Bool {
        !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !subline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    var stills = StillSettings()

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
