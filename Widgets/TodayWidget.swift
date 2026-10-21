import BindersKit
import SwiftUI
import WidgetKit

/// Today at a glance: what Binders heard today, what got done, and who is busiest on the boards. On the Home Screen and the
/// Lock Screen, in counts and names; the busiest work stream names its card only when you let the Lock Screen show what
/// you said. A tap opens Today.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.binders.app.today", provider: TodayTimeline()) { entry in
            TodayView(entry: entry)
                .containerBackground(Palette.surface, for: .widget)
                .widgetURL(URL(string: "binders://today"))
        }
        .configurationDisplayName("Today")
        .description("What Binders heard today, what got done, and who's working on what.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    /// You let the Lock Screen show what you said, so the work stream may name its card.
    let words: Bool
}

/// What the app last wrote, now and again from midnight, when today's numbers start over. The app reloads it when they
/// change; this only reads.
struct TodayTimeline: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        let today = WidgetSnapshot.Today(day: Calendar.current.startOfDay(for: .now), heard: 6, acted: 3, finished: 2)
        return TodayEntry(date: .now, snapshot: WidgetSnapshot(capture: "listening", questions: 0, reviews: 1, handOffs: 0, captures: 0, filedToday: 2,
                                                               updated: .now, today: today, stream: .init(who: "Claude Code", isAgent: true, cards: 2)),
                          words: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : TodayEntry(date: .now, snapshot: .read(), words: LockScreenWords.allowed))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let snapshot = WidgetSnapshot.read(), words = LockScreenWords.allowed
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now.addingTimeInterval(86_400)
        completion(Timeline(entries: [TodayEntry(date: .now, snapshot: snapshot, words: words),
                                      TodayEntry(date: midnight, snapshot: snapshot, words: words)], policy: .atEnd))
    }
}

/// The heading in the accent, today's two numbers large and rounded (done in green once anything is), and the busiest
/// work stream with its glyph (lavender with a sparkle when it's an agent's). On the Lock Screen, the system's own levels
/// with the heading accented.
private struct TodayView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    private var today: WidgetSnapshot.Today { entry.snapshot.today(at: entry.date) }
    private var stream: String { entry.snapshot.stream?.line(words: entry.words) ?? "Nothing moving on your boards" }
    private var streamSymbol: String {
        guard let stream = entry.snapshot.stream else { return "rectangle.split.3x1" }
        return stream.isAgent ? "sparkles" : "person"
    }
    /// An agent's work wears the agent's lavender; anyone else's, and nobody's, stays muted.
    private var streamTint: Color { entry.snapshot.stream?.isAgent == true ? Palette.agent : Palette.muted }
    private var counts: String { "\(today.heard) heard · \(today.done) done" }
    private var spoken: String { "Today: \(today.heard) heard, \(today.done) done" }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(counts, systemImage: "sun.max")
                .accessibilityLabel(spoken)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "checkmark").font(.caption2.weight(.heavy)).widgetAccentable()
                    Text("\(today.done)").font(Typeface.count(.title3)).minimumScaleFactor(0.6).rollingCount(today.done)
                    Text("done").font(.caption2)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Today", systemImage: "sun.max").font(Typeface.title(.headline)).widgetAccentable()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Tally(value: today.heard, label: "heard", number: .subheadline, words: .caption)
                    Tally(value: today.done, label: "done", number: .subheadline, words: .caption)
                }
                Text(stream).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Label("Today", systemImage: "sun.max")
                    .font(Typeface.title(.headline))
                    .widgetInk(Palette.accentText)
                    .widgetAccentable()
                HStack(alignment: .firstTextBaseline, spacing: family == .systemSmall ? 18 : 36) {
                    Count(value: today.heard, label: "heard")
                    Count(value: today.done, label: "done", tint: today.done > 0 ? Palette.done : Palette.ink)
                }
                Spacer(minLength: 0)
                Label {
                    Text(stream)
                } icon: {
                    Image(systemName: streamSymbol).widgetInk(streamTint, or: .secondary)
                }
                .font(.caption)
                .widgetInk(Palette.muted, or: .secondary)
                .lineLimit(family == .systemSmall ? 2 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

/// One of today's numbers, large, rounded and heavy with digits that roll, with what it counts under it.
private struct Count: View {
    let value: Int
    let label: String
    var tint: Color = Palette.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(Typeface.count(.title)).widgetInk(tint).rollingCount(value)
            Text(label).font(.caption).widgetInk(Palette.muted, or: .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
