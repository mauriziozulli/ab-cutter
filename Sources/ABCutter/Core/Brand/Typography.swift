import AppKit
import CoreText
import Foundation

/// The three Sound Matters faces, registered from the app bundle.
///
/// Two voices rather than five families, exactly as `tokens.css` puts it: a
/// heavy grotesque as the lead — the same one that is on the sticker — and a
/// didone as the counter-voice, plus a mono for everything small. The files
/// bundled here are the same ones the website serves, converted from woff2,
/// so a playout and a page cannot drift apart.
///
/// Registration is process-scoped: the faces never touch the user's font book.
/// If it fails the app keeps working on the fallbacks named in the same CSS —
/// Arial Black, Didot, Courier — which is why every lookup goes through here
/// rather than naming a family at the call site.
enum Typography {
    private static let archivoBlack = "Archivo Black"
    private static let bodoniModa = "Bodoni Moda"
    private static let spaceMono = "Space Mono"

    /// Main-actor state, like the registration it guards.
    @MainActor private static var registered = false

    /// Called once at launch. Safe to call again; the second call does nothing.
    @MainActor
    static func register() {
        guard !registered else { return }
        registered = true

        let names = ["ArchivoBlack-Regular", "BodoniModa-Bold", "SpaceMono-Bold"]
        for name in names {
            guard let url = Bundle.module.url(
                forResource: name,
                withExtension: "ttf",
                subdirectory: "Schriften"
            ) ?? Bundle.module.url(forResource: name, withExtension: "ttf") else { continue }

            var error: Unmanaged<CFError>?
            // Process scope: available to this app for as long as it runs, and
            // gone the moment it quits.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            error?.release()
        }
    }

    // MARK: - The three voices

    /// Lead: heavy grotesque, always set in capitals.
    static func fett(_ size: CGFloat) -> NSFont {
        font(archivoBlack, size: size)
            ?? font("Arial Black", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .black)
    }

    /// Counter-voice: a didone with strong stroke contrast. Deliberately mixed
    /// case — in capitals the hairlines break away.
    static func serif(_ size: CGFloat) -> NSFont {
        font(bodoniModa, size: size)
            ?? font("Didot", size: size)
            ?? font("Times New Roman", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .bold)
    }

    /// Small type: numbers, classification, footer — the address under the
    /// wordmark on the sticker.
    static func mono(_ size: CGFloat) -> NSFont {
        font(spaceMono, size: size)
            ?? font("Courier New", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
    }

    /// True once the real faces answered, so the interface can say so rather
    /// than letting a playout quietly go out in Arial Black.
    @MainActor
    static var housefacesAvailable: Bool {
        register()
        return NSFont(name: archivoBlack, size: 12) != nil
            && NSFont(name: bodoniModa, size: 12) != nil
            && NSFont(name: spaceMono, size: 12) != nil
    }

    private static func font(_ name: String, size: CGFloat) -> NSFont? {
        NSFont(name: name, size: size)
    }

    // MARK: - Measures

    /// Tracking as a fraction of the size, the way CSS states it. AppKit wants
    /// the kern in points, so every call site would otherwise repeat this
    /// multiplication and one of them would eventually get it wrong.
    static func kern(_ em: CGFloat, at size: CGFloat) -> CGFloat { em * size }

    /// `letter-spacing: -.04em` on the lead face.
    static let fettTracking: CGFloat = -0.04
    /// `letter-spacing: -.015em` on the counter-voice.
    static let serifTracking: CGFloat = -0.015
    /// `letter-spacing: .14em` on the small type.
    static let monoTracking: CGFloat = 0.14
}
