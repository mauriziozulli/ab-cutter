import CoreGraphics
import Foundation

// Everything stored here is real seconds on the session timeline, which runs
// on the film's clock when there is a film. Takes sit on it at their start,
// and every marker is a time on it.

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

/// What a session written before takes existed stored: one recording at
/// the folder's root, placed by a single film offset. Read, never written.
struct LegacyRecording: Codable {
    var screenFile: String = "screen.mov"
    var originalFile: String = "original.wav"
    var mixFile: String = "mix.wav"
    var duration: Double = 0
    var originalLead: Double = 0
    var mixLead: Double = 0
}

/// One recording pass: the Pro Tools picture and both mixes, in a subfolder
/// of the session. A take sits on the session timeline at `start`; where
/// takes overlap, the later one wins — recording again from the playhead
/// replaces what was there, the way a punch-in does.
struct Take: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Relative to the session folder; empty for a legacy take at the root.
    var folder: String = ""
    var screenFile: String = "screen.mov"
    var originalFile: String = "original.wav"
    var mixFile: String = "mix.wav"
    var duration: Double = 0
    /// Where each audio file's first sample sits on the take's own clock
    /// (0 = its first screen frame). A few milliseconds either way.
    var originalLead: Double = 0
    var mixLead: Double = 0
    /// Session time of the take's first screen frame. With a film this is
    /// film time, found by matching the take's original against the film.
    var start: Double = 0
    /// How sure that match was; nil when the take was placed by hand.
    var syncConfidence: Double?

    var end: Double { start + duration }

    func url(_ file: String, in root: URL) -> URL {
        folder.isEmpty ? root.appendingPathComponent(file)
            : root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(file)
    }
}

/// A stretch of the timeline and the take that plays there.
struct TakeSegment {
    var take: Take
    var from: Double
    var to: Double
}

/// How the film's title is set in the film band.
struct TitleStyle: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        /// Typed, in the house faces.
        case text
        /// The film's own title design, as a transparent PNG.
        case image

        var id: String { rawValue }
        var title: String { self == .text ? "Text" : "Titel-PNG" }
    }

    enum Face: String, Codable, CaseIterable, Identifiable {
        /// Archivo Black — the lead face, set in capitals.
        case fett
        /// Bodoni Moda — the counter-voice, mixed case.
        case serif

        var id: String { rawValue }
        var title: String { self == .fett ? "Archivo Black" : "Bodoni Moda" }
    }

    enum Position: String, Codable, CaseIterable, Identifiable {
        case bottom
        case centre

        var id: String { rawValue }
        var title: String { self == .bottom ? "Unten" : "Mitte" }
    }

    var mode: Mode = .text
    var face: Face = .fett
    /// The PNG, read where it lies — never copied, never changed.
    var imagePath: String?
    /// Width of the PNG as a share of the band, 0.2 … 1.
    var imageScale: Double = 0.7
    var position: Position = .bottom

    init() {}

    init(from decoder: Decoder) throws {
        self = TitleStyle()
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? box.decode(Mode.self, forKey: .mode) { mode = v }
        if let v = try? box.decode(Face.self, forKey: .face) { face = v }
        if let v = try? box.decode(String.self, forKey: .imagePath) { imagePath = v }
        if let v = try? box.decode(Double.self, forKey: .imageScale) { imageScale = v }
        if let v = try? box.decode(Position.self, forKey: .position) { position = v }
    }
}

/// A point the stills are rendered from.
struct StillMarker: Codable, Hashable, Identifiable {
    var id = UUID()
    var time: Double
}

struct Session: Codable {
    /// In the order they were recorded; later ones lie on top.
    var takes: [Take] = []

    /// The finished film, never copied — only read. The timeline runs on its
    /// clock: film time 0 is timeline 0.
    var filmPath: String?
    var filmDuration: Double = 0

    var title: String = ""
    var subtitle: String = ""
    var titleStyle = TitleStyle()
    var labelOriginal: String = "Original"
    var labelMix: String = "Final Mix"

    /// The stretch that is exported, on the timeline.
    var inPoint: Double = 0
    var outPoint: Double = 0

    /// A/B switch points. The post opens on the original and every switch
    /// flips to the other side.
    var switches: [Double] = []
    var stills: [StillMarker] = []

    var formats: Set<OutputFormat> = [.feed, .story]

    /// Per still: the composed post frame in every format, the film frame at
    /// full resolution, and a website JPEG of it.
    var stillLayout: Bool = true
    var stillFilmOriginal: Bool = true
    var stillWeb: Bool = true

    init() {}

    private enum LegacyKeys: String, CodingKey {
        case recording
        case filmOffset
        case syncConfidence
    }

    /// Lenient, key by key, so a session written by an earlier version keeps
    /// opening when a setting is added.
    init(from decoder: Decoder) throws {
        self = Session()
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? box.decode([Take].self, forKey: .takes) { takes = v }
        if let v = try? box.decode(String.self, forKey: .filmPath) { filmPath = v }
        if let v = try? box.decode(Double.self, forKey: .filmDuration) { filmDuration = v }
        if let v = try? box.decode(String.self, forKey: .title) { title = v }
        if let v = try? box.decode(String.self, forKey: .subtitle) { subtitle = v }
        if let v = try? box.decode(TitleStyle.self, forKey: .titleStyle) { titleStyle = v }
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

        // A session from before takes: one recording at the root, placed by
        // `filmOffset` (film time minus recording time). Its markers were on
        // the recording clock and move by the same amount.
        if takes.isEmpty, let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
           let recording = try? legacy.decode(LegacyRecording.self, forKey: .recording) {
            let offset = (try? legacy.decode(Double.self, forKey: .filmOffset)) ?? 0
            var take = Take()
            take.screenFile = recording.screenFile
            take.originalFile = recording.originalFile
            take.mixFile = recording.mixFile
            take.duration = recording.duration
            take.originalLead = recording.originalLead
            take.mixLead = recording.mixLead
            take.start = offset
            take.syncConfidence = try? legacy.decode(Double.self, forKey: .syncConfidence)
            takes = [take]
            switches = switches.map { $0 + offset }
            stills = stills.map { StillMarker(id: $0.id, time: $0.time + offset) }
            inPoint += offset
            outPoint += offset
        }
    }

    var filmURL: URL? { filmPath.map { URL(fileURLWithPath: $0) } }

    var hasTakes: Bool { !takes.isEmpty }

    /// Everything there is: the film, and any take running past it.
    var duration: Double {
        max(filmDuration, takes.map(\.end).max() ?? 0)
    }

    var sortedSwitches: [Double] { switches.sorted() }
    var sortedStills: [StillMarker] { stills.sorted { $0.time < $1.time } }

    /// True where the mix plays, false where the original does.
    func isMix(at time: Double) -> Bool {
        switches.filter { $0 <= time }.count % 2 == 1
    }

    /// The exported range, made sane. Without an Out point it ends where the
    /// takes end, not where the film does.
    var exportRange: ClosedRange<Double> {
        let takeEnd = takes.map(\.end).max() ?? duration
        let end = outPoint > inPoint ? min(outPoint, duration) : takeEnd
        let start = min(max(inPoint, 0), max(end - 0.1, 0))
        return start...max(end, start)
    }

    /// Which take plays where, later takes over earlier ones, in time order.
    func segments() -> [TakeSegment] {
        let bounds = Set(takes.flatMap { [$0.start, $0.end] }).sorted()
        guard bounds.count > 1 else { return [] }
        var result: [TakeSegment] = []
        for index in 0..<(bounds.count - 1) {
            let from = bounds[index]
            let to = bounds[index + 1]
            let middle = (from + to) / 2
            guard let take = takes.last(where: { $0.start <= middle && $0.end >= middle }) else { continue }
            if let last = result.last, last.take.id == take.id, abs(last.to - from) < 0.0001 {
                result[result.count - 1].to = to
            } else {
                result.append(TakeSegment(take: take, from: from, to: to))
            }
        }
        return result
    }
}
