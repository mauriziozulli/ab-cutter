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
        case .fileStart: "Dateianfang"
        case .manual: "Manuell"
        }
    }
}

/// What to do with a source's channels before it is heard.
///
/// Production sound often carries the dialogue on one channel only. There is
/// no way to re-route channels per source inside an `AVAudioMix`, so anything
/// other than `.stereo` is realised by rendering a mono companion file once —
/// which has the useful property that the preview and the export are fed by
/// the identical audio rather than by two code paths that might disagree.
enum ChannelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Leave the channels as they are.
    case stereo
    /// Average every channel. Halves a signal that sits on one side only.
    case sumToMono
    /// Take the left channel alone and centre it — the right choice when the
    /// dialogue lives on the left, because it keeps the original level.
    case leftOnly
    case rightOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stereo: "Stereo (unverändert)"
        case .sumToMono: "Summe L+R → Mono"
        case .leftOnly: "Nur links → Mono"
        case .rightOnly: "Nur rechts → Mono"
        }
    }

    var foldsToMono: Bool { self != .stereo }
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
    var channelMode: ChannelMode = .stereo
    /// The rendered mono companion, when a fold is in force.
    var foldedPath: String?

    var isEmbedded: Bool { path == nil }

    var url: URL? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path)
    }

    var foldedURL: URL? {
        guard let foldedPath else { return nil }
        return URL(fileURLWithPath: foldedPath)
    }

    /// True when a fold is wanted but its file is not on disk — a temporary
    /// directory can be emptied between launches.
    var needsFold: Bool {
        guard channelMode.foldsToMono else { return false }
        guard let foldedURL else { return true }
        return !FileManager.default.fileExists(atPath: foldedURL.path)
    }

    var channelDescription: String {
        // Only claim the fold once its file is actually on disk, so the row
        // reports what is being heard rather than what was asked for.
        if channelMode.foldsToMono, !needsFold { return "Mono (gefaltet)" }
        switch channelCount {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channelCount) Kan."
        }
    }

    /// Range this source occupies on the project timeline.
    var timelineRange: ClosedRange<Double> {
        offsetSeconds...(offsetSeconds + max(durationSeconds, 0))
    }
}

// MARK: - Clips

/// A social-media excerpt with one or more A/B switches inside it.
///
/// The switches simply alternate: the clip opens on the "before" source, flips
/// to "after" at the first point, back at the second, and so on. That keeps a
/// rhythm of comparisons expressible as a plain list of times, with no per-
/// segment state to keep consistent.
struct Clip: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Project-timeline seconds. t = 0 is the first frame of the video.
    var start: Double
    var end: Double
    /// Absolute project seconds where the A/B alternates. Empty means a single
    /// switch at the exact midpoint.
    var switchPoints: [Double] = []
    /// Audio heard before the first switch. `nil` uses the project default.
    var beforeSourceID: UUID?
    /// Audio heard after it. `nil` uses the project default.
    var afterSourceID: UUID?
    /// Framing inside the crop, -1 … 1. 0 is centred.
    var panX: Double = 0
    var panY: Double = 0
    /// Included in a batch export.
    var isEnabled: Bool = true

    var duration: Double { max(end - start, 0) }

    /// The switches actually in force: sorted, de-duplicated and inside the
    /// clip. An empty list yields the midpoint, which is the common case.
    var switches: [Double] {
        guard duration > 0 else { return [] }
        guard !switchPoints.isEmpty else { return [start + duration / 2] }
        var seen: [Double] = []
        for point in switchPoints.map({ min(max($0, start), end) }).sorted() {
            // A hair apart is a duplicate as far as the eye and ear go.
            if let last = seen.last, abs(point - last) < 0.01 { continue }
            seen.append(point)
        }
        return seen
    }

    /// True when `time` falls in a segment fed by the "before" source.
    func isBeforeSegment(at time: Double) -> Bool {
        switches.reduce(0) { $0 + (time >= $1 ? 1 : 0) } % 2 == 0
    }

    /// The first switch — what the single-switch controls still edit.
    var splitTime: Double { switches.first ?? start + duration / 2 }

    /// Split expressed 0 … 1 within the clip.
    var splitFraction: Double {
        guard duration > 0 else { return 0.5 }
        return (splitTime - start) / duration
    }

    var usesDefaultSplit: Bool { switchPoints.isEmpty }

    mutating func addSwitch(at time: Double) {
        let clamped = min(max(time, start), end)
        // Materialise the implicit midpoint before adding to it, or the first
        // extra switch would silently delete it.
        var points = switchPoints.isEmpty ? [start + duration / 2] : switchPoints
        guard !points.contains(where: { abs($0 - clamped) < 0.01 }) else { return }
        points.append(clamped)
        switchPoints = points.sorted()
    }

    mutating func removeSwitch(nearest time: Double) {
        var points = switches
        guard !points.isEmpty else { return }
        guard let index = points.indices.min(by: {
            abs(points[$0] - time) < abs(points[$1] - time)
        }) else { return }
        points.remove(at: index)
        switchPoints = points
    }

    mutating func resetSwitchesToMiddle() {
        switchPoints = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, start, end, switchPoints
        case beforeSourceID, afterSourceID, panX, panY, isEnabled
    }

    /// Projects written before the switches became a list stored a single
    /// optional `splitOverride`. It lives in its own key set so that every
    /// `CodingKeys` case still maps to a stored property — otherwise Swift
    /// cannot synthesise `encode(to:)`.
    private enum LegacyCodingKeys: String, CodingKey {
        case splitOverride
    }

    init(
        id: UUID = UUID(),
        name: String,
        start: Double,
        end: Double,
        switchPoints: [Double] = [],
        beforeSourceID: UUID? = nil,
        afterSourceID: UUID? = nil,
        panX: Double = 0,
        panY: Double = 0,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.switchPoints = switchPoints
        self.beforeSourceID = beforeSourceID
        self.afterSourceID = afterSourceID
        self.panX = panX
        self.panY = panY
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        if let points = try container.decodeIfPresent([Double].self, forKey: .switchPoints) {
            switchPoints = points
        } else if let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self),
                  let split = try? legacy.decode(Double.self, forKey: .splitOverride) {
            switchPoints = [split]
        } else {
            switchPoints = []
        }
        beforeSourceID = try container.decodeIfPresent(UUID.self, forKey: .beforeSourceID)
        afterSourceID = try container.decodeIfPresent(UUID.self, forKey: .afterSourceID)
        panX = try container.decodeIfPresent(Double.self, forKey: .panX) ?? 0
        panY = try container.decodeIfPresent(Double.self, forKey: .panY) ?? 0
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
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
        case .color: "Farbe (Original)"
        case .blackAndWhite: "Schwarzweiss"
        case .desaturated: "Entsättigt"
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
        case .fill: "Füllen (beschneiden)"
        case .fit: "Einpassen (Balken)"
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
        case .insetBefore: "Rahmen → Vollformat"
        case .insetBoth: "Durchgehend gerahmt"
        case .fullBleed: "Immer Vollformat"
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
        case .blur: "Unscharfes Bild"
        case .solid: "Fast schwarz"
        }
    }
}

/// How the burnt-in before/after label is drawn.
enum LabelStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The sticker: the word in a field of the accent colour, set in ink,
    /// with a hard contour. Same arrangement as the second line of the
    /// wordmark, and the reason a playout is recognisable as the same brand.
    case balken
    /// The lead face in bone, no field. The quieter half of the house style.
    case knochen
    /// Bold plain type, tinted with the dominant hue of the cropped frame.
    case tinted
    /// White type on a translucent pill — safe on any footage.
    case pill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balken: "Balken (Haus)"
        case .knochen: "Knochen (Haus)"
        case .tinted: "Farbe aus dem Bild"
        case .pill: "Weiss auf Fläche"
        }
    }

    /// True for the two that take their colour from the palette rather than
    /// from the picture, so the sampler can be skipped entirely.
    var isHouse: Bool { self == .balken || self == .knochen }
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
        case .auto: "Automatisch"
        case .off: "Aus"
        case .always: "Immer"
        }
    }
}

enum LabelPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case top
    case bottom

    var id: String { rawValue }
    var title: String { self == .top ? "Oben" : "Unten" }
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

    /// True where the clip plays full screen with the platform's own controls
    /// drawn over it — a story or a reel. A feed post keeps its chrome outside
    /// the picture, so nothing there has to be kept clear.
    var hasPlayerChrome: Bool { self == .portrait916 }
}

/// Strips at the top and bottom of the canvas that the app keeps its own
/// furniture out of, as fractions of the canvas height.
///
/// A story plays full screen with the account name over the top of it and a
/// reply bar over the bottom, so anything drawn towards the canvas edge ends
/// up underneath them. Fractions rather than pixels, because the same layout
/// is measured at proxy sizes for the preview and for the label tint.
struct SafeArea: Codable, Hashable, Sendable {
    var top: Double = 0
    var bottom: Double = 0

    static let none = SafeArea()

    /// Past this there is no canvas left to compose in.
    static let maximum: Double = 0.25

    var isEmpty: Bool { top < 0.001 && bottom < 0.001 }

    var clamped: SafeArea {
        SafeArea(
            top: min(max(top, 0), Self.maximum),
            bottom: min(max(bottom, 0), Self.maximum)
        )
    }
}

enum VideoCodecChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: "H.264 (kompatibel)"
        case .hevc: "HEVC (kleiner)"
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
    var labelStyle: LabelStyle = .balken
    var labelShadow: LabelShadowMode = .auto
    /// Length of the audio crossfade centred on the split, in milliseconds.
    var audioCrossfadeMilliseconds: Double = 40
    /// Manual bitrate override in Mbit/s. `nil` uses the automatic estimate.
    var videoBitrateMbps: Double?
    /// Which of the Sound Matters family carries this project. Ochre by
    /// default: the website's film section runs in ochre, and an A/B out of a
    /// finished film belongs to that section.
    var accent: BrandAccent = .ocker
    /// The two mono strips with their hard rules, top and bottom — the frame
    /// of the sticker, unfolded. Off leaves the big label on its own.
    var showStrips: Bool = true
    /// Top left. Empty falls back to the film's name.
    var stripLeft: String = ""
    /// Bottom left. Empty leaves the corner clear.
    var stripNote: String = ""
    /// Bottom right. The address under the wordmark on the sticker.
    var stripAddress: String = "soundmatters.audio"
    /// Grain over the picture, `opacity: .26` on the site. Zero is off.
    var grainStrength: Double = 0.26
    /// The site's veil, a radial darkening towards the corners. Its outer stop
    /// is `.72`; a playout is dialled back because it puts type in the corners
    /// where the site puts none. Zero is off.
    var vignetteStrength: Double = 0.55
    /// Keep the frame and the burnt-in type out of the strips where a story
    /// player draws its own controls.
    var respectPlayerChrome: Bool = true
    /// Header: the account name and the progress bars.
    var chromeSafeTop: Double = 0.10
    /// Footer: the reply field.
    var chromeSafeBottom: Double = 0.06

    var outputFolderURL: URL? {
        guard let outputFolderPath else { return nil }
        return URL(fileURLWithPath: outputFolderPath)
    }

    /// Nothing is reserved on a format that plays inside a feed card.
    func safeArea(for format: SocialFormat) -> SafeArea {
        guard respectPlayerChrome, format.hasPlayerChrome else { return .none }
        return SafeArea(top: chromeSafeTop, bottom: chromeSafeBottom).clamped
    }

    init() {}

    /// Decoded key by key so a project written by an earlier version still
    /// opens. Swift's synthesised decoder treats a missing key as an error
    /// even where the property has a default, which would mean every release
    /// that adds a setting invalidates every saved project.
    init(from decoder: Decoder) throws {
        self = ExportSettings()
        guard let box = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let value = try? box.decode([SocialFormat].self, forKey: .formats) { formats = value }
        if let value = try? box.decode(String.self, forKey: .outputFolderPath) { outputFolderPath = value }
        if let value = try? box.decode(VideoCodecChoice.self, forKey: .codec) { codec = value }
        if let value = try? box.decode(FitMode.self, forKey: .fitMode) { fitMode = value }
        if let value = try? box.decode(LookStyle.self, forKey: .beforeLook) { beforeLook = value }
        if let value = try? box.decode(LookStyle.self, forKey: .afterLook) { afterLook = value }
        if let value = try? box.decode(FrameTreatment.self, forKey: .frameTreatment) { frameTreatment = value }
        if let value = try? box.decode(FrameBackdrop.self, forKey: .frameBackdrop) { frameBackdrop = value }
        if let value = try? box.decode(Double.self, forKey: .insetScale) { insetScale = value }
        if let value = try? box.decode(Bool.self, forKey: .showFrameBorder) { showFrameBorder = value }
        if let value = try? box.decode(Bool.self, forKey: .showLabels) { showLabels = value }
        if let value = try? box.decode(String.self, forKey: .beforeLabel) { beforeLabel = value }
        if let value = try? box.decode(String.self, forKey: .afterLabel) { afterLabel = value }
        if let value = try? box.decode(String.self, forKey: .subtitleText) { subtitleText = value }
        if let value = try? box.decode(LabelPosition.self, forKey: .labelPosition) { labelPosition = value }
        if let value = try? box.decode(LabelStyle.self, forKey: .labelStyle) { labelStyle = value }
        if let value = try? box.decode(LabelShadowMode.self, forKey: .labelShadow) { labelShadow = value }
        if let value = try? box.decode(Double.self, forKey: .audioCrossfadeMilliseconds) {
            audioCrossfadeMilliseconds = value
        }
        if let value = try? box.decode(Double.self, forKey: .videoBitrateMbps) { videoBitrateMbps = value }
        if let value = try? box.decode(BrandAccent.self, forKey: .accent) { accent = value }
        if let value = try? box.decode(Bool.self, forKey: .showStrips) { showStrips = value }
        if let value = try? box.decode(String.self, forKey: .stripLeft) { stripLeft = value }
        if let value = try? box.decode(String.self, forKey: .stripNote) { stripNote = value }
        if let value = try? box.decode(String.self, forKey: .stripAddress) { stripAddress = value }
        if let value = try? box.decode(Double.self, forKey: .grainStrength) { grainStrength = value }
        if let value = try? box.decode(Double.self, forKey: .vignetteStrength) { vignetteStrength = value }
        if let value = try? box.decode(Bool.self, forKey: .respectPlayerChrome) { respectPlayerChrome = value }
        if let value = try? box.decode(Double.self, forKey: .chromeSafeTop) { chromeSafeTop = value }
        if let value = try? box.decode(Double.self, forKey: .chromeSafeBottom) { chromeSafeBottom = value }
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
        case .top: "Oben"
        case .centre: "Mitte"
        case .bottom: "Unten"
        }
    }
}

enum StillFileFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: "PNG (verlustfrei)"
        case .jpeg: "JPEG"
        }
    }

    var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// What an end card is laid on.
enum EndCardGround: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Plain ink. Reads as the printed sticker rather than as another frame of
    /// the film, which is what a card whose job is the address wants.
    case tinte
    /// The grabbed frame, softened and darkened like the title card, so the
    /// last image still belongs to the post it closes.
    case frame

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tinte: "Tinte (wie der Aufkleber)"
        case .frame: "Standbild, weichgezeichnet"
        }
    }
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

    // MARK: - The end card

    /// Write a closing card per selected format — the last image of a post.
    var saveEndCard: Bool = true
    /// The wordmark, in two lines. The second sits in the bar, exactly as on
    /// the sticker: whoever has seen the sticker recognises the card.
    var endWordmarkTop: String = "Sound is what"
    var endWordmarkBar: String = "matters."
    /// The address under the wordmark.
    var endAddress: String = "soundmatters.audio"
    /// One quieter line under the address — a credit, or what the reel showed.
    var endNote: String = ""
    var endGround: EndCardGround = .tinte

    var hasText: Bool {
        !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !subline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {}

    /// Lenient for the same reason as `ExportSettings`.
    init(from decoder: Decoder) throws {
        self = StillSettings()
        guard let box = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let value = try? box.decode(String.self, forKey: .headline) { headline = value }
        if let value = try? box.decode(String.self, forKey: .subline) { subline = value }
        if let value = try? box.decode(Double.self, forKey: .blurStrength) { blurStrength = value }
        if let value = try? box.decode(Double.self, forKey: .dimStrength) { dimStrength = value }
        if let value = try? box.decode(StillTextPosition.self, forKey: .textPosition) { textPosition = value }
        if let value = try? box.decode(Bool.self, forKey: .saveFullFrame) { saveFullFrame = value }
        if let value = try? box.decode(Bool.self, forKey: .saveTitleCards) { saveTitleCards = value }
        if let value = try? box.decode(StillFileFormat.self, forKey: .fileFormat) { fileFormat = value }
        if let value = try? box.decode(Bool.self, forKey: .saveEndCard) { saveEndCard = value }
        if let value = try? box.decode(String.self, forKey: .endWordmarkTop) { endWordmarkTop = value }
        if let value = try? box.decode(String.self, forKey: .endWordmarkBar) { endWordmarkBar = value }
        if let value = try? box.decode(String.self, forKey: .endAddress) { endAddress = value }
        if let value = try? box.decode(String.self, forKey: .endNote) { endNote = value }
        if let value = try? box.decode(EndCardGround.self, forKey: .endGround) { endGround = value }
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

    init() {}

    /// Lenient for the same reason as `ExportSettings`. The document wrapper
    /// still decodes its version strictly, so a file that is not a project at
    /// all fails there rather than opening as an empty one.
    init(from decoder: Decoder) throws {
        self = ABProject()
        guard let box = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let value = try? box.decode(String.self, forKey: .videoPath) { videoPath = value }
        if let value = try? box.decode(Double.self, forKey: .videoDurationSeconds) { videoDurationSeconds = value }
        if let value = try? box.decode(Double.self, forKey: .videoNaturalWidth) { videoNaturalWidth = value }
        if let value = try? box.decode(Double.self, forKey: .videoNaturalHeight) { videoNaturalHeight = value }
        if let value = try? box.decode(Double.self, forKey: .videoTimecodeStartSeconds) {
            videoTimecodeStartSeconds = value
        }
        if let value = try? box.decode(FrameRate.self, forKey: .frameRate) { frameRate = value }
        if let value = try? box.decode(Bool.self, forKey: .dropFrame) { dropFrame = value }
        if let value = try? box.decode([AudioSource].self, forKey: .audioSources) { audioSources = value }
        if let value = try? box.decode([Clip].self, forKey: .clips) { clips = value }
        if let value = try? box.decode(Double.self, forKey: .defaultClipLengthSeconds) {
            defaultClipLengthSeconds = value
        }
        if let value = try? box.decode(Bool.self, forKey: .keepClipLengthFixed) { keepClipLengthFixed = value }
        if let value = try? box.decode(UUID.self, forKey: .defaultBeforeSourceID) { defaultBeforeSourceID = value }
        if let value = try? box.decode(UUID.self, forKey: .defaultAfterSourceID) { defaultAfterSourceID = value }
        if let value = try? box.decode(ExportSettings.self, forKey: .export) { export = value }
        if let value = try? box.decode(StillSettings.self, forKey: .stills) { stills = value }
    }

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
            if !clips[index].switchPoints.isEmpty {
                let lower = clips[index].start
                let upper = clips[index].end
                clips[index].switchPoints = clips[index].switchPoints
                    .map { min(max($0, lower), upper) }
            }
        }
    }
}
