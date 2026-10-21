import BindersKit
import SwiftUI
import WidgetKit

/// What waits on you, in counts, as Today's Needs you counts it: questions from agents, work to check, cards to give,
/// things you said to add, captures to look at. On the Home Screen and the Lock Screen; never what's in them.
struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.binders.app.needs-you", provider: NeedsYouTimeline()) { entry in
            NeedsYouView(snapshot: entry.snapshot)
                .containerBackground(Palette.surface, for: .widget)
                .widgetURL(URL(string: "binders://needs-you"))
        }
        .configurationDisplayName("Needs You")
        .description("Questions from your agents, work to check, things you said to add, and captures to look at.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct NeedsYouEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// What the app last wrote. The app reloads the timeline when it changes; this only reads.
struct NeedsYouTimeline: TimelineProvider {
    func placeholder(in context: Context) -> NeedsYouEntry {
        NeedsYouEntry(date: .now, snapshot: WidgetSnapshot(capture: "listening", questions: 1, reviews: 2, handOffs: 0, captures: 1, filedToday: 3, updated: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (NeedsYouEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NeedsYouEntry(date: .now, snapshot: .read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NeedsYouEntry>) -> Void) {
        completion(Timeline(entries: [NeedsYouEntry(date: .now, snapshot: .read())], policy: .never))
    }
}

/// The heading in amber while anything waits on you, each kind with its glyph and a rounded count, and capture's state at
/// the foot (red only while it listens). On the Lock Screen, the system's own levels with the heading accented.
private struct NeedsYouView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    private var lines: [(symbol: String, label: String, count: Int)] {
        [("questionmark.bubble", snapshot.questions == 1 ? "question" : "questions", snapshot.questions),
         ("eye", "to check", snapshot.reviews),
         ("arrow.forward.circle", "to give", snapshot.handOffs),
         // Things you said to yourself, offered with Add and Not Now (none in a snapshot from before them).
         ("text.bubble", "to add", snapshot.moments ?? 0),
         ("waveform", snapshot.captures == 1 ? "capture" : "captures", snapshot.captures)].filter { $0.count > 0 }
    }

    private var waiting: Bool { snapshot.needsYou > 0 }
    private var bell: String { waiting ? "bell.badge" : "bell" }

    /// "1 question · 2 to check", or with commas for VoiceOver.
    private func summary(_ separator: String) -> String {
        lines.isEmpty ? "Nothing right now" : lines.map { "\($0.count) \($0.label)" }.joined(separator: separator)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(waiting ? "\(snapshot.needsYou) \(snapshot.needsYou == 1 ? "thing needs" : "things need") you" : "Nothing needs you",
                  systemImage: bell)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Needs you", systemImage: bell).font(Typeface.title(.headline)).widgetAccentable()
                Text(summary(" · "))
                    .font(.caption)
                    .monospacedDigit()
                    .accessibilityLabel(summary(", "))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Label("Needs you", systemImage: bell)
                    .font(Typeface.title(.headline))
                    .widgetInk(waiting ? Palette.needsYou : Palette.muted)
                    .widgetAccentable()
                if lines.isEmpty {
                    Text("Nothing right now").font(.subheadline).widgetInk(Palette.muted, or: .secondary)
                } else {
                    ForEach(lines.prefix(family == .systemSmall ? 3 : 4), id: \.label) { line in
                        Label {
                            Tally(value: line.count, label: line.label, number: .subheadline, words: .subheadline)
                        } icon: {
                            // One width for every glyph, so the counts line up.
                            Image(systemName: line.symbol).font(.subheadline).widgetInk(Palette.muted, or: .secondary)
                                .frame(width: 22)
                        }
                    }
                }
                Spacer(minLength: 0)
                CaptureFooter(capture: snapshot.capture, filed: snapshot.filedToday, short: family == .systemSmall)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Capture's state at the foot of the widget, with its glyph: red only while it listens.
private struct CaptureFooter: View {
    let capture: String
    let filed: Int
    /// The small widget has room for "Listening · 3 filed", not "today" too.
    var short = false

    var body: some View {
        if capture != "off" {
            let look = CaptureLook(phase: capture)
            Label {
                Text(look.live ? "Listening · \(filed) filed\(short ? "" : " today")" : "Capture \(look.word.lowercased())")
                    .monospacedDigit()
            } icon: {
                Image(systemName: look.symbol).widgetInk(look.tint, or: .secondary)
            }
            .font(.caption)
            .widgetInk(Palette.muted, or: .secondary)
            .accessibilityLabel(look.live ? "Listening, \(filed) filed today" : "Capture \(look.word.lowercased())")
        }
    }
}
