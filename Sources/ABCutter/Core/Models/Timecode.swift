import Foundation

/// Frame rates the app can display and step with. `fps` is the true rate used
/// for maths; `base` is the number of frame buckets used in the FF field.
enum FrameRate: String, Codable, CaseIterable, Identifiable, Sendable {
    case fps23976
    case fps24
    case fps25
    case fps2997
    case fps30
    case fps50
    case fps5994
    case fps60

    var id: String { rawValue }

    var fps: Double {
        switch self {
        case .fps23976: 24.0 * 1000.0 / 1001.0
        case .fps24: 24
        case .fps25: 25
        case .fps2997: 30.0 * 1000.0 / 1001.0
        case .fps30: 30
        case .fps50: 50
        case .fps5994: 60.0 * 1000.0 / 1001.0
        case .fps60: 60
        }
    }

    /// Frame buckets used for the FF field of a timecode.
    var base: Int {
        switch self {
        case .fps23976, .fps24: 24
        case .fps25: 25
        case .fps2997, .fps30: 30
        case .fps50: 50
        case .fps5994, .fps60: 60
        }
    }

    /// True for the pulled-down rates where SMPTE drop-frame counting exists.
    var supportsDropFrame: Bool {
        self == .fps2997 || self == .fps5994
    }

    var title: String {
        switch self {
        case .fps23976: "23.976 fps"
        case .fps24: "24 fps"
        case .fps25: "25 fps"
        case .fps2997: "29.97 fps"
        case .fps30: "30 fps"
        case .fps50: "50 fps"
        case .fps5994: "59.94 fps"
        case .fps60: "60 fps"
        }
    }

    /// Picks the closest supported rate for a measured/nominal frame rate.
    static func closest(to measured: Double) -> FrameRate {
        guard measured.isFinite, measured > 0 else { return .fps25 }
        return allCases.min { abs($0.fps - measured) < abs($1.fps - measured) } ?? .fps25
    }
}

/// SMPTE timecode helpers. Everything the app stores internally is *real
/// seconds*; timecode only exists at the display and entry boundary.
///
/// The drop-frame conversions follow the standard SMPTE 12M counting rule:
/// two frame numbers (four at 59.94) are skipped at the top of every minute
/// except every tenth minute, so that the label tracks wall-clock time.
enum Timecode {
    /// Frame numbers skipped per dropping minute: 2 at 29.97, 4 at 59.94.
    private static func dropCount(for rate: FrameRate) -> Int {
        rate.base / 15
    }

    /// Formats real seconds (since timecode midnight, or since the start of a
    /// clip) as `HH:MM:SS:FF` — `HH:MM:SS;FF` when drop-frame is in effect.
    static func string(fromSeconds seconds: Double, rate: FrameRate, dropFrame: Bool = false) -> String {
        guard seconds.isFinite else { return "--:--:--:--" }
        let negative = seconds < 0
        let magnitude = abs(seconds)

        let base = rate.base
        // Frames actually elapsed — drop-frame skips *labels*, never frames.
        var frameNumber = Int((magnitude * rate.fps).rounded())
        let isDrop = dropFrame && rate.supportsDropFrame

        if isDrop {
            let drop = dropCount(for: rate)
            let framesPer10Minutes = Int((rate.fps * 600.0).rounded())
            let framesPerMinute = base * 60 - drop
            let tenMinuteBlocks = frameNumber / framesPer10Minutes
            let withinBlock = frameNumber % framesPer10Minutes
            frameNumber += drop * 9 * tenMinuteBlocks
            if withinBlock > drop {
                frameNumber += drop * ((withinBlock - drop) / framesPerMinute)
            }
        }

        let frames = frameNumber % base
        let totalSeconds = frameNumber / base
        let secondsField = totalSeconds % 60
        let minutesField = (totalSeconds / 60) % 60
        let hoursField = (totalSeconds / 3_600) % 24

        return String(
            format: "%@%02d:%02d:%02d%@%02d",
            negative ? "-" : "",
            hoursField, minutesField, secondsField, isDrop ? ";" : ":", frames
        )
    }

    /// Parses `HH:MM:SS:FF`, `HH:MM:SS;FF`, `MM:SS:FF` or plain seconds into
    /// real seconds. Returns nil when the text cannot be read. A `;` separator
    /// in the text forces drop-frame interpretation even if `dropFrame` is off.
    static func seconds(fromString text: String, rate: FrameRate, dropFrame: Bool = false) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let negative = trimmed.hasPrefix("-")
        let body = negative ? String(trimmed.dropFirst()) : trimmed

        let parts = body.split(whereSeparator: { $0 == ":" || $0 == ";" }).map(String.init)
        guard parts.count > 1 else {
            guard let plain = Double(body) else { return nil }
            return negative ? -plain : plain
        }
        guard parts.count <= 4, let frames = Int(parts[parts.count - 1]) else { return nil }

        var hours = 0
        var minutes = 0
        var secs = 0
        if parts.count == 4 {
            guard let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) else { return nil }
            (hours, minutes, secs) = (h, m, s)
        } else if parts.count == 3 {
            guard let m = Int(parts[0]), let s = Int(parts[1]) else { return nil }
            (minutes, secs) = (m, s)
        } else {
            guard let s = Int(parts[0]) else { return nil }
            secs = s
        }

        let isDrop = (dropFrame || body.contains(";")) && rate.supportsDropFrame
        let base = rate.base
        var frameNumber = ((hours * 60 + minutes) * 60 + secs) * base + frames
        if isDrop {
            // Undo the skipped labels to get back to elapsed frames.
            let totalMinutes = hours * 60 + minutes
            frameNumber -= dropCount(for: rate) * (totalMinutes - totalMinutes / 10)
        }

        let value = Double(frameNumber) / rate.fps
        return negative ? -value : value
    }

    /// `HH:MM:SS.mmm` — used where sub-frame precision matters (sync offsets).
    static func clockString(fromSeconds seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--:--.---" }
        let negative = seconds < 0
        let magnitude = abs(seconds)
        let whole = Int(magnitude)
        let milliseconds = Int(((magnitude - Double(whole)) * 1000).rounded())
        return String(
            format: "%@%02d:%02d:%02d.%03d",
            negative ? "-" : "",
            whole / 3_600, (whole / 60) % 60, whole % 60, min(milliseconds, 999)
        )
    }
}
