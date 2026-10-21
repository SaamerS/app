import BindersKit
import SwiftUI

/// What waits on you, at the top of Home: agents' questions, finished work to check, agents' suggestions of who should
/// take a card, things you said to yourself that Binders offers to add (Add / Not Now), and captures with something to
/// look at. Nothing at all when nothing waits. A kind that joins while it shows drops in, with the filing spring, and its
/// count rolls.
struct NeedsYouSection: View {
    let cards: [Card]
    let captures: [CaptureEntry]
    let offers: [ConversationSuggestion]
    /// What you said to yourself, as this iPhone keeps it: those offered and not answered wait on you.
    let moments: [CapturedMoment]
    /// When the screen it's on first showed: a kind that joins after drops in. Nil: whatever it first shows was there.
    var since: Date? = nil
    /// Where a tap goes: one card, the board across binders, the capture screen, one capture, one thing you said, or
    /// the things you said that wait on you.
    let go: (Destination) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The kinds it held as its screen opened, until each has shown: only one that joins after drops in.
    @State private var atOpening: Set<NeedsYou.Kind>? = nil

    enum Destination {
        case card(String), board, capture, conversation(UUID), moment(UUID), moments
    }

    var body: some View {
        let needs = needs
        let kinds = NeedsYou.Kind.allCases.filter { needs.count($0) > 0 }
        let held = held
        if !needs.isEmpty || !held.isEmpty {
            Section {
                ForEach(kinds, id: \.self) { kind in
                    let count = needs.count(kind)
                    Button { go(destination(kind)) } label: {
                        HStack {
                            // Amber: all of it waits on you; the glyph says what.
                            Label {
                                Text(kind.line(count)).foregroundStyle(Palette.ink).rollingCount(count)
                            } icon: {
                                Image(systemName: kind.symbol).foregroundStyle(Palette.needsYou)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.faint)
                        }
                    }
                    .accessibilityIdentifier("needsYou-\(kind.rawValue)")
                    .arrival(kind, present: $atOpening, showing: { Set(kinds) }, since: since)
                }
                // What you said that waits on your Give to, or on Wake Now on your Mac (a card Auto made ready and couldn't
                // wake): amber, with its own words. On this iPhone only, beside the counts the widgets share.
                if !held.isEmpty {
                    Button { go(held.count == 1 ? .moment(held[0]) : .moments) } label: {
                        HStack {
                            Label {
                                Text(AutoPhoneText.waitsRow(held.count)).foregroundStyle(Palette.ink).rollingCount(held.count)
                            } icon: {
                                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Palette.needsYou)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.faint)
                        }
                    }
                    .accessibilityIdentifier("needsYou-held")
                }
            } header: {
                NeedsYouTitle("Needs you")
            }
            .surfaceRows()
            .animation(Motion.filing(reduceMotion: reduceMotion), value: kinds)
        }
    }

    private var questions: [Card] { cards.filter { $0.board == .blocked } }
    private var reviews: [Card] { cards.filter { $0.board == .review } }
    /// An agent's suggestion of who should take it, with nobody on it yet.
    private var handOffs: [Card] {
        cards.filter { !($0.meantFor ?? "").isEmpty && $0.meantForConfirmed == false && $0.assignee.isEmpty && $0.board != .done }
    }
    /// Things you said to yourself that your Mac offered ("Add to Personal?") and you haven't answered, newest first.
    private var said: [UUID] { Self.offered(moments) }
    /// Things you said that wait on your Give to, or on Wake Now on your Mac, newest first.
    private var held: [UUID] { Self.held(moments) }

    /// Of what you said, what waits on you elsewhere than Add and Not Now (CapturedMoment.isHeldForYou), heard or decided
    /// in the last three days, newest first.
    static func held(_ moments: [CapturedMoment], now: Date = Date()) -> [UUID] {
        let since = now.addingTimeInterval(-NeedsYou.waitsFor)
        return moments.filter { $0.isHeldForYou && max($0.heard, $0.decided ?? $0.heard) > since }.sorted { $0.heard > $1.heard }.map(\.id)
    }
    /// Captures with a card or an idea offered and not answered, or that the Mac couldn't write up.
    private var waiting: [UUID] {
        let offered = Set(offers.filter { $0.kind != .answer && $0.status == .offered }.map(\.conversation))
        let since = Date().addingTimeInterval(-NeedsYou.waitsFor)
        let failed = captures.filter { $0.ended > since && $0.outcomeState == CaptureOutcome.States.failed }.map(\.id)
        return Array(offered.union(failed))
    }

    private var needs: NeedsYou {
        NeedsYou(questions: questions.count, reviews: reviews.count, handOffs: handOffs.count, moments: said.count, captures: waiting.count)
    }

    /// The things you said that wait on your Add or Not Now (NeedsYou.offered), but for one you said wasn't you: the
    /// count, and the list a tap on several opens, go by the same rule.
    static func offered(_ moments: [CapturedMoment], now: Date = Date()) -> [UUID] {
        NeedsYou.offered(moments.filter { $0.notMe == nil }.map { (id: $0.id, heard: $0.heard, state: $0.outcomeState, actions: $0.actions) },
                         now: now)
    }

    /// Each thing that waits on you, by what it is and which one: what the warning by touch compares, so something new
    /// joining warns even when something else just left.
    private var items: Set<String> {
        Set(questions.map { "question|\($0.id)" } + reviews.map { "review|\($0.id)" } + handOffs.map { "give|\($0.id)" }
            + said.map { "moment|\($0.uuidString)" } + held.map { "held|\($0.uuidString)" } + waiting.map { "capture|\($0.uuidString)" })
    }

    /// The same counts from the copies this iPhone keeps, for the widgets and the Live Activity, and what waits by name
    /// for `Haptics` (nil while there's no copy of the boards, yet or since an unpairing: nothing to compare).
    @MainActor
    static func fromCopies() -> (needs: NeedsYou, items: Set<String>?) {
        let copy = Cache.load("tasks-all").flatMap { try? MacConnection.decode([Card].self, from: $0) }
        let section = NeedsYouSection(cards: copy ?? [], captures: CaptureStore.shared.conversations, offers: SuggestionCenter.shared.suggestions,
                                      moments: MomentCenter.shared.moments) { _ in }
        return (section.needs, copy == nil ? nil : section.items)
    }

    private func destination(_ kind: NeedsYou.Kind) -> Destination {
        switch kind {
        case .questions: questions.count == 1 ? .card(questions[0].id) : .board
        case .reviews: reviews.count == 1 ? .card(reviews[0].id) : .board
        case .handOffs: handOffs.count == 1 ? .card(handOffs[0].id) : .board
        case .moments: said.count == 1 ? .moment(said[0]) : .moments
        case .captures: waiting.count == 1 ? .conversation(waiting[0]) : .capture
        }
    }
}
