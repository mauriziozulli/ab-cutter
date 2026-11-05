import CoreGraphics
import Foundation

// Everything stored here is real seconds on the recording's clock: t = 0 is
// the first frame of the screen recording. The film and both audio files are
// placed against that clock by an offset each, and nothing else.

/// The two posts a session is cut into. Recorded once, laid out twice.
enum OutputFormat: String, Codable, CaseIterable, Identifiable, Hashable {
    /// Instagram feed, 4:5. The layout is built for this one: film on top,
    /// Pro Tools underneath, edge to edge.
    case feed
    /// Story and reel, 9:16. The same two bands, centred, with the film
    /// softened behind them — less full, never recorded twice.
    case story

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .feed: CGSize(width: 1080, height: 1350)
        case .story: CGSize(width: 1080, height: 1920)
        }
    }

    var title: String {
        switch self {
        case .feed: "4:5 Feed"
        case .story: "9:16 Story"
        }
    }

    var fileSuffix: String {
        switch self {
        case .feed: "4x5"
        case .story: "9x16"
        }
    }
}

/// The capture frame's shape: the Pro Tools band of the 4:5 layout.
/// 1080 × 720 under a 1080 × 630 film band adds up to exactly 1080 × 1350.
enum PostLayout {
    static let screenAspect: CGFloat = 3.0 / 2.0
    static let filmBandHeight: CGFloat = 630
    static let screenBandHeight: CGFloat = 720
}

/// One take: the Pro Tools picture and the two mixes, as written by the
/// recorder. Paths are relative to the session folder, so a folder can be
/// moved or copied to another Mac whole.
struct Recording: Codable, Hashable {
    var screenFile: String = "screen.mov"
    var originalFile: String = "original.wav"
    var mixFile: String = "mix.wav"
    /// Length of the screen recording.
    var duration: Double = 0
    /// Where each audio file's first sample sits on the recording clock.
    /// A few milliseconds either way — the devices start when they start.
    var originalLead: Double = 0
    var mixLead: Double = 0
}

/// A point the stills are rendered from.
struct StillMarker: Codable, Hashable, Identifiable {
    var id = UUID()
    var time: Double
}

struct Session: Codable {
    var recording: Recording?

    /// The finished film, never copied — only read.
    var filmPath: String?
    /// Film time minus recording time. Found by matching the recorded
    /// original against the film's own sound; nudged by hand if needed.
    var filmOffset: Double = 0
    /// How sure the waveform match was, 0 … 1. nil until synced.
    var syncConfidence: Double?

    var title: String = ""
    var subtitle: String = ""
    var labelOriginal: String = "Original"
    var labelMix: String = "Final Mix"

    /// The stretch that is exported, on the recording clock.
    var inPoint: Double = 0
    var outPoint: Double = 0

    /// A/B switch points, recording clock. The post opens on the original
    /// and every switch flips to the other side.
    var switches: [Double] = []
    var stills: [StillMarker] = []

    var formats: Set<OutputFormat> = [.feed, .story]

    /// Per still: the composed post frame in every format, the film frame at
    /// full resolution, and a website JPEG of it.
    var stillLayout: Bool = true
    var stillFilmOriginal: Bool = true
    var stillWeb: Bool = true

    init() {}

    /// Lenient, key by key, so a session written by an earlier version keeps
    /// opening when a setting is added.
    init(from decoder: Decoder) throws {
        self = Session()
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? box.decode(Recording.self, forKey: .recording) { recording = v }
        if let v = try? box.decode(String.self, forKey: .filmPath) { filmPath = v }
        if let v = try? box.decode(Double.self, forKey: .filmOffset) { filmOffset = v }
        if let v = try? box.decode(Double.self, forKey: .syncConfidence) { syncConfidence = v }
        if let v = try? box.decode(String.self, forKey: .title) { title = v }
        if let v = try? box.decode(String.self, forKey: .subtitle) { subtitle = v }
        if let v = try? box.decode(String.self, forKey: .labelOriginal) { labelOriginal = v }
        if let v = try? box.decode(String.self, forKey: .labelMix) { labelMix = v }
        if let v = try? box.decode(Double.self, forKey: .inPoint) { inPoint = v }
        if let v = try? box.decode(Double.self, forKey: .outPoint) { outPoint = v }
        if let v = try? box.decode([Double].self, forKey: .switches) { switches = v }
        if let v = try? box.decode([StillMarker].self, forKey: .stills) { stills = v }
        if let v = try? box.decode(Set<OutputFormat>.self, forKey: .formats) { formats = v }
        if let v = try? box.decode(Bool.self, forKey: .stillLayout) { stillLayout = v }
        if let v = try? box.decode(Bool.self, forKey: .stillFilmOriginal) { stillFilmOriginal = v }
        if let v = try? box.decode(Bool.self, forKey: .stillWeb) { stillWeb = v }
    }

    var filmURL: URL? { filmPath.map { URL(fileURLWithPath: $0) } }

    var duration: Double { recording?.duration ?? 0 }

    var sortedSwitches: [Double] { switches.sorted() }
    var sortedStills: [StillMarker] { stills.sorted { $0.time < $1.time } }

    /// True where the mix plays, false where the original does.
    func isMix(at time: Double) -> Bool {
        switches.filter { $0 <= time }.count % 2 == 1
    }

    /// The exported range, made sane.
    var exportRange: ClosedRange<Double> {
        let end = outPoint > inPoint ? min(outPoint, duration) : duration
        let start = min(max(inPoint, 0), max(end - 0.1, 0))
        return start...max(end, start)
    }
}
