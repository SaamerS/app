import BindersKit
import SwiftUI
import UIKit

// The Binders look on the iPhone, from the tokens in WidgetShared/Palette.swift: pages on the ground, content on opaque
// cards, a note on its page (paper in the light, dark in the dark), Liquid Glass only on what floats over content, and
// inside a binder its colour in place of the accent on what you tap, with a faint wash of it on the ground.

// MARK: - Appearance

/// How Binders looks on this iPhone, as on the Mac: dark unless you choose Light or to match the system. Kept as the Mac
/// keeps it: "dark", "light" or "system".
enum AppAppearance {
    static let key = "appearance"
    static let options: [(tag: String, title: String)] = [("dark", "Dark"), ("light", "Light"), ("system", "Match System")]

    /// The colour scheme a setting asks for; nil follows the system.
    static func scheme(_ setting: String) -> ColorScheme? {
        switch setting {
        case "light": .light
        case "system": nil
        default: .dark
        }
    }

    static func style(_ setting: String) -> UIUserInterfaceStyle {
        switch setting {
        case "light": .light
        case "system": .unspecified
        default: .dark
        }
    }

    /// The setting now; dark until you choose.
    static var current: String { UserDefaults.standard.string(forKey: key) ?? "dark" }

    /// Every window Binders shows wears it, the keyboard's listening window too, and going back to Match System takes
    /// effect at once.
    @MainActor
    static func apply(_ setting: String = current) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style(setting) }
        }
    }
}

/// The Appearance setting: Dark, Light or Match System.
struct AppearancePicker: View {
    @AppStorage(AppAppearance.key) private var appearance = "dark"

    var body: some View {
        Picker("Appearance", selection: $appearance) {
            ForEach(AppAppearance.options, id: \.tag) { Text($0.title).tag($0.tag) }
        }
        .accessibilityIdentifier("appearancePicker")
    }
}

/// What SwiftUI's own modifiers don't reach.
@MainActor
enum PhoneTheme {
    /// Navigation titles in SF Pro Rounded heavy and in ink, sized from the text size; the bars keep the system's own
    /// backgrounds (glass from iOS 26), as with no scroll edge appearance of their own UIKit takes the standard one's titles.
    static func configureBars() {
        let bar = UINavigationBarAppearance()
        bar.largeTitleTextAttributes = [.font: rounded(.largeTitle, size: 34), .foregroundColor: Palette.inkUIColor]
        bar.titleTextAttributes = [.font: rounded(.headline, size: 17), .foregroundColor: Palette.inkUIColor]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
    }

    private static func rounded(_ style: UIFont.TextStyle, size: CGFloat) -> UIFont {
        let heavy = UIFont.systemFont(ofSize: size, weight: .heavy)
        let font = heavy.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? heavy
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }
}

// MARK: - A binder's colour

/// A binder's colour as the pages inside it wear it (BinderShades): itself for its chip and the faint wash on the ground,
/// a shade that reads as words in each appearance for what you tap (links, text buttons, the controls the accent would
/// colour), and one behind white words (primary buttons, swipe actions). Headers and other words on its pages stay ink
/// and muted, and semantic colours stay semantic.
struct BinderTint {
    let base: Color
    let text: Color
    let fill: Color

    private init(_ shades: BinderShades) {
        base = Color(uiColor: UIColor(shades.base))
        let dark = UIColor(shades.darkText), light = UIColor(shades.lightText)
        text = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        fill = Color(uiColor: UIColor(shades.fill))
    }

    private static let all = BinderShades.all.map(BinderTint.init)

    /// Binder colour `index`, as the Mac numbers them.
    static func binder(_ index: Int) -> BinderTint { all[abs(index) % all.count] }
}

/// The eight colours binders have on the Mac, as a binder's chip shows them.
enum BinderPalette {
    static func color(_ index: Int) -> Color { BinderTint.binder(index).base }
}

/// Binders' colours by name, from the list this iPhone last had, for a page that knows only its binder's name: a card, a
/// note, a meeting.
@MainActor
enum BinderColors {
    private static var byName: [String: Int] = [:]
    private static var read: Date?

    /// The binders as the Mac just listed them.
    static func remember(_ binders: [BinderInfo]) {
        byName = Dictionary(binders.map { ($0.name, $0.color ?? 0) }, uniquingKeysWith: { first, _ in first })
        read = .now
    }

    /// The tint of the binder called `name`; nil for none, or for one this iPhone hasn't heard of.
    static func tint(_ name: String?, connection: MacConnection) -> BinderTint? {
        guard let name, !name.isEmpty else { return nil }
        if byName[name] == nil, read.map({ Date.now.timeIntervalSince($0) > 30 }) ?? true {
            remember(connection.cached("binders", as: [BinderInfo].self) ?? [])
        }
        return byName[name].map(BinderTint.binder)
    }

    /// The binder a capture's outcome says it was filed in ("Filed in Events: Ignite booth plan · 2 to-dos"), for its
    /// chip on Today: only one this iPhone knows. One it hasn't heard of sends it back to its copy of the list, at most
    /// every half minute.
    static func filed(in line: String?, connection: MacConnection) -> String? {
        guard let line else { return nil }
        if let known = CaptureOutcome.filedBinder(in: line, among: byName.keys) { return known }
        guard read.map({ Date.now.timeIntervalSince($0) > 30 }) ?? true else { return nil }
        remember(connection.cached("binders", as: [BinderInfo].self) ?? [])
        return CaptureOutcome.filedBinder(in: line, among: byName.keys)
    }
}

private struct BinderTintKey: EnvironmentKey {
    static let defaultValue: BinderTint? = nil
}

extension EnvironmentValues {
    /// The binder whose pages these are, if any.
    var binderTint: BinderTint? {
        get { self[BinderTintKey.self] }
        set { self[BinderTintKey.self] = newValue }
    }
}

private struct BinderTinting: ViewModifier {
    @Environment(\.binderTint) private var inherited
    let tint: BinderTint?

    func body(content: Content) -> some View {
        let tint = tint ?? inherited
        content
            .environment(\.binderTint, tint)
            .tint(tint?.text ?? Palette.accentText)
    }
}

// MARK: - Grounds, cards and glass

private struct Ground: ViewModifier {
    @Environment(\.binderTint) private var binder

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                Palette.ground
                if let binder { Palette.wash(binder.base) }
            }
            .ignoresSafeArea()
        }
    }
}

private struct SurfaceCardStyle: ViewModifier {
    let padding: CGFloat
    let radius: CGFloat
    /// Over the surface, for something waiting on you.
    var wash: Color? = nil
    var edge: Color = Palette.line

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(Palette.surface)
                    if let wash { shape.fill(wash) }
                }
            }
            .overlay { shape.strokeBorder(edge, lineWidth: 1) }
    }
}

private struct FloatingGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(.bar, in: shape)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }
}

private struct PrimaryButton: ViewModifier {
    @Environment(\.binderTint) private var binder

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .tint(binder?.fill ?? Palette.accent)
    }
}

extension View {
    /// Inside a binder: its colour in place of the accent on what you tap (links, text buttons, primary buttons, swipe
    /// actions), and a faint wash of it on the ground. Headers and words stay ink and muted. Nil keeps what the page is
    /// already inside.
    func binderTint(_ tint: BinderTint?) -> some View {
        modifier(BinderTinting(tint: tint))
    }

    /// A page on the ground, with a faint wash of its binder's colour inside one.
    func screenGround() -> some View {
        modifier(Ground())
    }

    /// A list on the ground; its sections take `surfaceRows()`.
    func listGround() -> some View {
        scrollContentBackground(.hidden).modifier(Ground())
    }

    /// A list section's rows (or a row's) on opaque cards, with hairlines between them.
    func surfaceRows() -> some View {
        listRowBackground(Palette.surface).listRowSeparatorTint(Palette.line)
    }

    /// Content on an opaque card, on the ground.
    func surfaceCard(padding: CGFloat = 14, radius: CGFloat = 14) -> some View {
        modifier(SurfaceCardStyle(padding: padding, radius: radius))
    }

    /// Something waiting on you, on its card: a touch of amber over the surface, and an amber edge.
    func needsYouCard(padding: CGFloat = 14, radius: CGFloat = 14) -> some View {
        modifier(SurfaceCardStyle(padding: padding, radius: radius, wash: Palette.needsYou.opacity(0.10), edge: Palette.needsYou.opacity(0.45)))
    }

    /// A note's page, with its own ink. It follows the app's appearance: paper in the light, and a dark page in the dark.
    func paperPage(padding: CGFloat = 18) -> some View {
        self
            .foregroundStyle(Palette.paperInk)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.line, lineWidth: 1) }
    }

    /// A control that floats over content (a toast, the status pill, a composer): Liquid Glass from iOS 26, the bar
    /// material before. Content never wears it.
    func floatingGlass<S: Shape>(in shape: S) -> some View {
        modifier(FloatingGlass(shape: shape))
    }

    /// The screen's primary button: filled with the brand's indigo, or with the binder's colour inside a binder.
    func primaryButton() -> some View {
        modifier(PrimaryButton())
    }
}

// MARK: - Pieces

/// A list section's header, as the system has it, inside a binder too: a binder's colour is for what you tap.
struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
    }
}

/// A list section's header for what waits on you: amber, with the bell, as the widget's is.
struct NeedsYouTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "bell.fill")
            .labelStyle(StateLabelStyle())
            .fontWeight(.semibold)
            .foregroundStyle(Palette.needsYou)
    }
}

/// What a screen says while it has nothing to show: its title rounded and heavy, its glyph, and what to expect.
struct EmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    var description: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label { Text(title).font(Typeface.title(.title2)) } icon: { Image(systemName: symbol) }
        } description: {
            if let description { Text(description) }
        } actions: {
            actions()
        }
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: String, symbol: String, description: String? = nil) {
        self.init(title: title, symbol: symbol, description: description) { EmptyView() }
    }
}

/// A glyph and its word close together, as a state reads; a Label in a list row sets its icon apart.
struct StateLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// All-day capture's state as the app shows it: its glyph and colour. Red only while the microphone is live; muted and
/// paused in muted, starting and off in faint, each with its glyph.
struct CaptureStatusLook {
    let symbol: String
    let tint: Color

    init(_ status: CaptureSession.Status) {
        switch status {
        case .listening: (symbol, tint) = ("waveform", Palette.live)
        case .muted: (symbol, tint) = ("mic.slash", Palette.muted)
        case .paused: (symbol, tint) = ("pause.circle", Palette.muted)
        case .starting: (symbol, tint) = ("ellipsis.circle", Palette.faint)
        case .off: (symbol, tint) = ("mic.slash", Palette.faint)
        }
    }
}

extension UIColor {
    convenience init(_ color: PaletteColor) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}
