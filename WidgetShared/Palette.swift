import SwiftUI
import UIKit

/// The Binders palette on the iPhone, the widgets and the keyboard: the website's binder, dark first. One meaning per
/// colour: amber is something that needs you, red is a live microphone, lavender with a sparkle is an agent's work, and
/// green is done. Nothing else wears those four.
enum Palette {
    /// The screen behind everything, and the opaque cards and panels on it.
    static let ground = dynamic(dark: 0x0B0A17, light: 0xF6F5FB)
    static let surface = dynamic(dark: 0x16142B, light: 0xFFFFFF)
    /// A note's page follows the appearance: paper in the light, with its own ink, and in the dark the surface's colour,
    /// with the ink (BindersKit's NotePage holds the same values, for its contrast tests).
    static let paper = dynamic(dark: 0x16142B, light: 0xFBFBF8)
    static let paperInk = dynamic(dark: 0xEFEDFB, light: 0x1B1740)

    /// Text: primary, secondary and tertiary.
    static let ink = dynamic(dark: 0xEFEDFB, light: 0x16132E)
    static let muted = dynamic(dark: 0xA7A2C4, light: 0x57527A)
    static let faint = dynamic(dark: 0x767193, light: 0x8A85A8)
    /// Hairlines between rows and around cards.
    static let line = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(rgb: 0xBEB4FF, alpha: 0.12) : UIColor(rgb: 0x2D2282, alpha: 0.11)
    })

    /// The brand indigo for buttons, selection and links, and the same hue made readable as text on the ground.
    static let accent = Color(rgb: 0x604CF4)
    static let accentText = dynamic(dark: 0xAA9EFF, light: 0x4A39D6)

    /// The four meanings.
    static let needsYou = dynamic(dark: 0xF0A23A, light: 0xC9790F)
    static let live = dynamic(dark: 0xFF5A52, light: 0xD93A34)
    static let agent = dynamic(dark: 0xC7BFF6, light: 0x6F5FE0)
    static let done = dynamic(dark: 0x3CCF6A, light: 0x1F9D4A)

    /// A binder's colour washed over the ground, for the pages inside that binder: barely there in either appearance, so
    /// you can tell which binder you're in without the page wearing its colour (BinderShades.wash).
    static func wash(_ binder: Color) -> Color { binder.opacity(0.03) }

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
}

/// The type roles: rounded heavy for titles and counts, New York italic when Binders quotes your own words, and
/// monospaced digits for times. Body text is the system font.
enum Typeface {
    static func title(_ style: Font.TextStyle = .largeTitle) -> Font { .system(style, design: .rounded).weight(.heavy) }
    static func count(_ style: Font.TextStyle = .title2) -> Font { .system(style, design: .rounded).weight(.heavy).monospacedDigit() }
    static func quote(_ style: Font.TextStyle = .body) -> Font { .system(style, design: .serif).italic() }
    static func time(_ style: Font.TextStyle = .caption) -> Font { .system(style).monospacedDigit() }
}

/// Filing is the signature motion: a short spring as a new item drops in. Under Reduce Motion everything crossfades.
enum Motion {
    static func filing(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.72)
    }

    static func arrival(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}

extension Color {
    init(rgb: UInt32) { self.init(UIColor(rgb: rgb)) }
}

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

extension Palette {
    /// The ink as UIKit takes it, where SwiftUI's colours don't reach: the navigation bar's titles.
    static let inkUIColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xEFEDFB) : UIColor(rgb: 0x16132E) }
}

/// Something that went wrong, said the one way Binders says it everywhere: its words in ink, with the exclamation glyph.
/// Never red, which is the live microphone, and never amber, which is something waiting on you. Where the system
/// recolours a widget, wear `Problem.symbol` with the widget's own ink.
enum Problem {
    static let symbol = "exclamationmark.circle"
}

/// A problem as a line of its own: "Couldn't get the speech model: …".
struct ProblemLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: Problem.symbol).foregroundStyle(Palette.ink)
    }
}
