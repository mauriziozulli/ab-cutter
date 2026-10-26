import SwiftUI

/// The one type scale, restated from Paranoid Projects so both apps set a
/// sentence the same size. Nothing in the app is smaller than `small`.
enum AppType {
    /// A surface's own name.
    static let title: CGFloat = 16
    /// Anything meant to be read as a sentence.
    static let body: CGFloat = 13
    /// Timecodes, file names, offsets — the monospaced middle.
    static let meta: CGFloat = 12
    /// Column labels, counts, section headings. The floor.
    static let small: CGFloat = 11
    /// The letter-spacing on a surface's own name.
    static let titleTracking: CGFloat = 2.4
}
