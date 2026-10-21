import Foundation

/// What the iPhone's widgets and its Control Center control read, written by the app into the folder it shares with them:
/// All-day capture's state, what waits on you, and today at a glance. States, counts and names: a card's title only when
/// you let the Lock Screen show what you said. Every field added after the first is Optional, so a snapshot an earlier
/// build wrote still reads, and keys a later build adds are ignored.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// off, listening, muted or paused.
    public var capture: String
    public var questions: Int
    public var reviews: Int
    public var handOffs: Int
    public var captures: Int
    public var filedToday: Int
    public var updated: Date
    /// Today at a glance, for the Today widget. Nil in a snapshot from before it.
    public var today: Today?
    /// Who is busiest on the boards. Nil while nobody is working on a card, and in a snapshot from before it.
    public var stream: Stream?
    /// Things you said to yourself that wait for your Add or Not Now (NeedsYou.moments). Nil in a snapshot from before
    /// it: none.
    public var moments: Int?

    public init(capture: String, questions: Int, reviews: Int, handOffs: Int, captures: Int, filedToday: Int, updated: Date,
                today: Today? = nil, stream: Stream? = nil, moments: Int? = nil) {
        self.capture = capture
        self.questions = questions
        self.reviews = reviews
        self.handOffs = handOffs
        self.captures = captures
        self.filedToday = filedToday
        self.updated = updated
        self.today = today
        self.stream = stream
        self.moments = moments
    }

    /// The snapshot the app writes, which the Live Activity shows too: capture's state, what waits on you as Today's Needs
    /// you counts it, and today's numbers from what was heard (when, and the outcome state of what became of it). Filed
    /// today is what Binders did with what it heard (`Today.acted`): a to-do added from "Binders, …", an idea put on a
    /// board or a note kept counts as much as a capture filed, as it counts as done on the Today widget.
    public init(capture: String, needs: NeedsYou, heard: [(at: Date, state: String?)], finished: Int?, stream: Stream?, now: Date,
                calendar: Calendar = .current) {
        let today = Today.counting(heard, finished: finished, now: now, calendar: calendar)
        self.init(capture: capture, questions: needs.questions, reviews: needs.reviews, handOffs: needs.handOffs, captures: needs.captures,
                  filedToday: today.acted, updated: now, today: today, stream: stream, moments: needs.moments)
    }

    public static let empty = WidgetSnapshot(capture: "off", questions: 0, reviews: 0, handOffs: 0, captures: 0, filedToday: 0, updated: .distantPast)

    /// Everything that waits on you, as Today's Needs you counts it.
    public var needsYou: Int { questions + reviews + handOffs + (moments ?? 0) + captures }

    /// Today's numbers on the day `now` falls on: nothing heard or done yet when the snapshot's are from an earlier day.
    public func today(at now: Date, calendar: Calendar = .current) -> Today {
        guard let today, calendar.isDate(today.day, inSameDayAs: now) else { return Today(day: calendar.startOfDay(for: now)) }
        return today
    }

    /// Heard and done today.
    public struct Today: Codable, Equatable, Sendable {
        /// The day these count, from its start.
        public var day: Date
        /// What you said to yourself or told Siri, and conversations captured.
        public var heard: Int
        /// Of those, what Binders did something with: a moment it added, kept or put on a board (its "Done"), and a capture
        /// it filed.
        public var acted: Int
        /// Cards finished on the boards today, as the Mac last said. Nil until it says, that day.
        public var finished: Int?

        public init(day: Date, heard: Int = 0, acted: Int = 0, finished: Int? = nil) {
            self.day = day
            self.heard = heard
            self.acted = acted
            self.finished = finished
        }

        /// Done today: what Binders did with what it heard, and the cards finished.
        public var done: Int { acted + (finished ?? 0) }

        /// The outcome words that count as done: a moment acted on, and a capture filed. Not offered, answered, taken back
        /// or not kept.
        public static let doneStates: Set<String> = ["acted", CaptureOutcome.States.filed]

        /// Today's numbers from what was heard (when, and the outcome state of what became of it) and the cards the Mac said
        /// were finished today. Only what was heard on the day `now` falls on counts.
        public static func counting(_ heard: [(at: Date, state: String?)], finished: Int?, now: Date, calendar: Calendar = .current) -> Today {
            let today = heard.filter { calendar.isDate($0.at, inSameDayAs: now) }
            return Today(day: calendar.startOfDay(for: now), heard: today.count,
                         acted: today.filter { $0.state.map(doneStates.contains) ?? false }.count, finished: finished)
        }
    }

    /// The busiest work stream: who, and how many cards they're on.
    public struct Stream: Codable, Equatable, Sendable {
        /// An agent or a person.
        public var who: String
        public var isAgent: Bool
        public var cards: Int
        /// The newest of those cards' titles, kept only when you let the Lock Screen show what you said: a card can be made
        /// from it.
        public var card: String?

        public init(who: String, isAgent: Bool, cards: Int, card: String? = nil) {
            self.who = who
            self.isAgent = isAgent
            self.cards = cards
            self.card = card
        }

        /// The top of the digest's work streams (agents first, then the busiest), naming its newest card only with `words`.
        /// Nil when nobody is working on a card.
        public init?(_ digest: WorkStreams.Digest, words: Bool) {
            guard let top = digest.streams.first, !top.working.isEmpty else { return nil }
            self.init(who: top.who, isAgent: top.isAgent, cards: top.working.count, card: words ? top.working.first : nil)
        }

        /// "Claude Code on 2 cards", "You're on 1 card". With `words` and a card kept: "Claude Code on “Fix the login bug”",
        /// and " and 1 more" when there are others.
        public func line(words: Bool) -> String {
            let on = who == BoardActor.you.name ? "You're on" : "\(who) on"
            if words, let card, !card.isEmpty {
                return "\(on) “\(WorkStreams.clip(card))”" + (cards > 1 ? " and \(cards - 1) more" : "")
            }
            return "\(on) \(cards == 1 ? "1 card" : "\(cards) cards")"
        }
    }
}
