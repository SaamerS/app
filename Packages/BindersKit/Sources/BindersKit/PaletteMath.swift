import Foundation

/// A colour as sRGB components from 0 to 1, for the arithmetic the palette needs: how light it is, how well two read
/// against each other (WCAG 2), and a binder's colour moved just far enough to read as words or behind white words.
public struct PaletteColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 0x604CF4 and the like, as the palette writes its tokens.
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    public static let white = PaletteColor(red: 1, green: 1, blue: 1)
    public static let black = PaletteColor(red: 0, green: 0, blue: 0)

    /// Relative luminance, from 0 for black to 1 for white.
    public var luminance: Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// How well the two read against each other, from 1 (not at all) to 21 (black on white). Words want 4.5, bold words
    /// and glyphs 3.
    public func contrast(with other: PaletteColor) -> Double {
        let (light, dark) = luminance > other.luminance ? (luminance, other.luminance) : (other.luminance, luminance)
        return (light + 0.05) / (dark + 0.05)
    }

    /// This colour moved `amount` of the way to `other`.
    public func mixed(with other: PaletteColor, by amount: Double) -> PaletteColor {
        let t = min(max(amount, 0), 1)
        return PaletteColor(red: red + (other.red - red) * t, green: green + (other.green - green) * t, blue: blue + (other.blue - blue) * t)
    }

    /// The colour moved toward `toward` in 5% steps until it reads at `ratio` on every one of `grounds`: unchanged when it
    /// already does, all the way when nothing short of that does. A binder's colour as words: toward white on the dark
    /// grounds, toward black on the light ones; behind white words: toward black.
    public func readable(on grounds: [PaletteColor], toward: PaletteColor, ratio: Double) -> PaletteColor {
        for step in 0...20 {
            let candidate = mixed(with: toward, by: Double(step) / 20)
            if grounds.allSatisfy({ candidate.contrast(with: $0) >= ratio }) { return candidate }
        }
        return toward
    }
}

/// A binder's colour as it tints the pages inside that binder: itself for its chip and the faint wash on the ground; as
/// words on what you tap (links, text buttons), moved just far enough to read on the ground, on cards and on a note's page
/// in each appearance; and behind white words (primary buttons, swipe actions), deepened until those read. Headers and
/// other words inside a binder stay ink and muted. Indigo, the brand, wears the brand's own text and button colours.
public struct BinderShades: Equatable, Sendable {
    public let base: PaletteColor
    public let darkText: PaletteColor
    public let lightText: PaletteColor
    public let fill: PaletteColor

    public init(base: PaletteColor, darkText: PaletteColor, lightText: PaletteColor, fill: PaletteColor) {
        self.base = base
        self.darkText = darkText
        self.lightText = lightText
        self.fill = fill
    }

    /// Shades worked out from `base`: words at 4.5:1 on every ground they sit on, white words at 3:1 on the fill.
    public init(base: PaletteColor) {
        self.init(base: base,
                  darkText: base.readable(on: Self.darkGrounds + [Self.darkGrounds[0].mixed(with: base, by: Self.wash)], toward: .white, ratio: 4.5),
                  lightText: base.readable(on: Self.lightGrounds + [Self.lightGrounds[0].mixed(with: base, by: Self.wash)], toward: .black, ratio: 4.5),
                  fill: base.readable(on: [.white], toward: .black, ratio: 3))
    }

    /// The grounds a binder's words sit on, as WidgetShared/Palette.swift has them: the screen, then its cards. A note's
    /// page (NotePage) is the cards' colour in the dark and lies between the screen and white in the light, so words that
    /// read on these read on it too.
    public static let darkGrounds = [PaletteColor(hex: 0x0B0A17), PaletteColor(hex: 0x16142B)]
    public static let lightGrounds = [PaletteColor(hex: 0xF6F5FB), PaletteColor(hex: 0xFFFFFF)]
    /// How much of the binder's colour washes over the ground inside it, in either appearance (Palette.wash): barely any,
    /// enough to tell which binder you're in.
    public static let wash = 0.03

    /// The eight colours binders have on the Mac, in its order.
    public static let names = ["Indigo", "Teal", "Orange", "Pink", "Green", "Sky", "Amber", "Slate"]
    public static let all: [BinderShades] = [
        BinderShades(base: PaletteColor(hex: 0x604CF4), darkText: PaletteColor(hex: 0xAA9EFF), lightText: PaletteColor(hex: 0x4A39D6),
                     fill: PaletteColor(hex: 0x604CF4)),
        BinderShades(base: PaletteColor(red: 0.16, green: 0.62, blue: 0.62)),
        BinderShades(base: PaletteColor(red: 0.93, green: 0.52, blue: 0.20)),
        BinderShades(base: PaletteColor(red: 0.90, green: 0.36, blue: 0.58)),
        BinderShades(base: PaletteColor(red: 0.30, green: 0.66, blue: 0.36)),
        BinderShades(base: PaletteColor(red: 0.26, green: 0.60, blue: 0.90)),
        BinderShades(base: PaletteColor(red: 0.85, green: 0.68, blue: 0.20)),
        BinderShades(base: PaletteColor(red: 0.50, green: 0.54, blue: 0.62)),
    ]

    /// Binder colour `index`, as the Mac numbers them; any number lands on one of the eight.
    public static func binder(_ index: Int) -> BinderShades { all[abs(index) % all.count] }
}

/// A note's page and its words, as WidgetShared/Palette.swift has them (Palette.paper and paperInk). The page follows the
/// appearance: in the dark it's the surface's colour with the ink, in the light paper with its own ink.
public enum NotePage {
    public static let dark = PaletteColor(hex: 0x16142B)
    public static let darkInk = PaletteColor(hex: 0xEFEDFB)
    public static let light = PaletteColor(hex: 0xFBFBF8)
    public static let lightInk = PaletteColor(hex: 0x1B1740)
}
