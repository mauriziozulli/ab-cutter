import Foundation

/// Which of the Sound Matters family carries a project.
///
/// The two lead colours come first because they are the printed versions of
/// the sticker and are meant to repeat — that repetition is what ties a
/// playout to the page. Rust and dust blue have stepped back on the website
/// and are here only for a series that needs telling apart.
///
/// The values themselves are in `Brand.swift`; this stays free of AppKit so it
/// can be checked alongside the rest of the model layer.
enum BrandAccent: String, Codable, CaseIterable, Identifiable, Sendable {
    case verdigris
    case ocker
    case knochen
    case rost
    case staubblau

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verdigris: return "Verdigris"
        case .ocker: return "Ocker"
        case .knochen: return "Knochen"
        case .rost: return "Rost"
        case .staubblau: return "Staubblau"
        }
    }

    /// What the colour is for, in the words of the website's `FARBEN.md`.
    var note: String {
        switch self {
        case .verdigris: return "Leitfarbe, Hauptfassung des Aufklebers"
        case .ocker: return "Leitfarbe, zweite Fassung — Film und Gear"
        case .knochen: return "zugleich die Textfarbe der Seite"
        case .rost: return "zurückgetreten"
        case .staubblau: return "zurückgetreten"
        }
    }
}
