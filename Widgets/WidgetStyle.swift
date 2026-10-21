import SwiftUI
import WidgetKit

/// The palette (WidgetShared/Palette.swift) as the widgets and the Live Activity wear it. In full colour a token shows as
/// itself. Where the system recolours a widget (vibrant on the Lock Screen and in StandBy at night, tinted or clear on the
/// Home Screen) a hue carries nothing and a dark ink fades, so text takes the system's own levels there and the meaning
/// rides on the glyph beside it.
extension View {
    /// The token in full colour; `level` where the system recolours the widget.
    func widgetInk(_ token: Color, or level: HierarchicalShapeStyle = .primary) -> some View {
        modifier(WidgetInk(token: token, level: level))
    }

    /// A count whose digits roll as it changes, and crossfade under Reduce Motion.
    func rollingCount(_ value: Int) -> some View {
        modifier(RollingCount(value: value))
    }
}

private struct WidgetInk: ViewModifier {
    @Environment(\.widgetRenderingMode) private var mode
    let token: Color
    let level: HierarchicalShapeStyle

    func body(content: Content) -> some View {
        if mode == .fullColor {
            content.foregroundStyle(token)
        } else {
            content.foregroundStyle(level)
        }
    }
}

private struct RollingCount: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Int

    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .opacity : .numericText(value: Double(value)))
    }
}

/// A count and what it counts, side by side: the number rounded and heavy with monospaced digits, the words after it.
struct Tally: View {
    let value: Int
    let label: String
    /// The number's colour: ink, or what the count means (amber for what needs you).
    var tint: Color = Palette.ink
    var number: Font.TextStyle = .title3
    var words: Font = .subheadline

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(value)").font(Typeface.count(number)).widgetInk(tint).rollingCount(value)
            Text(label).font(words).widgetInk(Palette.muted, or: .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// All-day capture's state as everything in the extension shows it: its glyph and word, red only while the microphone is
/// live, muted or paused in muted, and one iOS stopped hearing from shown as a problem (ink, with its glyph), never red.
struct CaptureLook {
    /// The microphone is on: the only time anything here is red.
    let live: Bool
    let symbol: String
    let word: String
    /// The glyph's colour and the word's.
    let tint: Color

    /// `phase` is listening, muted, paused or off; `stale`, the Live Activity hasn't heard from Binders in a while.
    init(phase: String, stale: Bool = false) {
        switch phase {
        case _ where stale:
            (live, symbol, word, tint) = (false, "exclamationmark.circle", "May have stopped", Palette.ink)
        case "listening":
            (live, symbol, word, tint) = (true, "waveform", "Listening", Palette.live)
        case "muted":
            (live, symbol, word, tint) = (false, "mic.slash", "Muted", Palette.muted)
        case "off":
            (live, symbol, word, tint) = (false, "mic.slash", "Off", Palette.muted)
        default:
            (live, symbol, word, tint) = (false, "pause.circle", "Paused", Palette.muted)
        }
    }
}
