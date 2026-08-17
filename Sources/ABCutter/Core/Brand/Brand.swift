import AppKit
import CoreImage
import Foundation

/// The Sound Matters palette, taken from `tokens.css` in the website repo.
///
/// The reasoning lives in that repo's `FARBEN.md` and is worth repeating,
/// because it decides what may be changed here: the round sticker on cases and
/// racks is the entry point to the brand, so the sticker sets the palette and
/// everything else follows it. Every value is desaturated and pulled warm —
/// that is the whole difference between "loud" and "neon". Red becomes rust,
/// white becomes bone.
///
/// A playout is one more printed surface, so it obeys the same rules:
/// contrast through lightness rather than hue, never tone on tone, at most
/// three colours at once, and no white as a field.
enum Brand {
    // MARK: - The family

    /// `--knochen`. Bone: the text colour of everything, and a field of its own.
    static let knochen = Colour(0xEF, 0xE6, 0xD2)
    /// `--ocker`. The second printed version of the sticker.
    static let ocker = Colour(0xD9, 0x96, 0x2B)
    /// `--staubblau`. Stepped back — only the colour climate of one photo.
    static let staubblau = Colour(0x6E, 0x93, 0xA6)
    /// `--rost`. Stepped back as well.
    static let rost = Colour(0xB4, 0x56, 0x2E)
    /// `--verdigris`. The lead colour, the sticker's main version.
    static let verdigris = Colour(0x2F, 0x8F, 0x7A)
    /// `--tinte`. Ink: the ground, and the type on any coloured field.
    static let tinte = Colour(0x10, 0x10, 0x14)

    /// `--leise`. Bone at two thirds, for the small type in the strips.
    static let leise = knochen.withAlpha(0.66)

    /// The weight of the rules above and below a section, `2px` at the site's
    /// scale, as a fraction of the canvas height.
    static let ruleFraction: CGFloat = 0.0016
    /// Bone at three tenths — `rgba(239, 230, 210, .3)` in `global.css`.
    static let ruleAlpha: CGFloat = 0.3

    // MARK: - A colour

    /// Kept as plain components so the same value can be handed to AppKit for
    /// type and to Core Image for a field without a colour-space round trip.
    struct Colour: Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double = 1

        init(_ red: Int, _ green: Int, _ blue: Int, alpha: Double = 1) {
            self.red = Double(red) / 255
            self.green = Double(green) / 255
            self.blue = Double(blue) / 255
            self.alpha = alpha
        }

        init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// A stored project colour, ready to draw.
        init(_ colour: RGBColor) {
            self.init(red: colour.red, green: colour.green, blue: colour.blue)
        }

        func withAlpha(_ value: Double) -> Colour {
            Colour(red: red, green: green, blue: blue, alpha: value)
        }

        var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }

        var ciColor: CIColor {
            CIColor(red: red, green: green, blue: blue, alpha: alpha)
        }

        /// What type sitting on this colour has to be drawn in. Always ink:
        /// "auf farbigen Flächen steht immer Tinte" is the rule in
        /// `FARBEN.md`, and `global.css` sets the bar the same way — every
        /// field in the family is light enough that ink wins.
        ///
        /// The printed sticker uses deep green on its ochre and bone
        /// versions, but that is a two-colour press constraint. A playout is
        /// a screen and follows the screen rule.
        var onAccent: Colour { Brand.tinte }
    }
}

/// The values behind `BrandAccent`, which itself stays in the model layer so
/// it can be checked away from AppKit.
extension BrandAccent {
    var colour: Brand.Colour {
        switch self {
        case .verdigris: return Brand.verdigris
        case .ocker: return Brand.ocker
        case .knochen: return Brand.knochen
        case .rost: return Brand.rost
        case .staubblau: return Brand.staubblau
        }
    }
}
