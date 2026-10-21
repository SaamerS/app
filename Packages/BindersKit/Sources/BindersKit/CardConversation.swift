import Foundation

/// A card's timeline as its conversation shows it on the Mac: what an agent said and what you said as messages, Binders'
/// own notes apart from both, and the board's own events (added, moved, picked up, woken…) as quiet lines. And what became
/// of your words: which wake took them to the agent, worked out from the timeline alone, so it holds after a relaunch,
/// and the same way the dispatcher works out what a wake carries (`wakeWords`), so the two can't disagree.
public enum CardConversation {
    /// Whose words a message is: an agent's (with its sparkle), yours, or Binders' own note.
    public enum Side: Equatable, Hashable, Sendable {
        case agent, you, binders
    }

    /// One event of a card's timeline, as the app keeps it.
    public struct Event: Equatable, Sendable {
        /// The timeline's kind: created, moved, claimed, comment, answer, woke…
        public var kind: String
        public var author: String
        public var byAgent: Bool
        public var text: String
        /// The columns it moved between, as their raw values; nil or "" when it didn't move.
        public var from: String?
        public var to: String?
        public var at: Date

        public init(kind: String, author: String, byAgent: Bool, text: String = "", from: String? = nil, to: String? = nil, at: Date) {
            self.kind = kind
            self.author = author
            self.byAgent = byAgent
            self.text = text
            self.from = from
            self.to = to
            self.at = at
        }
    }

    /// One row of the conversation. Indexes are into the events it was made from.
    public enum Entry: Equatable, Hashable, Sendable {
        /// Before the first entry of each day: its start.
        case day(Date)
        /// Words: an agent's, yours or Binders'. `waiting`: what the card waits on you for now (an agent's question or
        /// request for approval in Blocked, its finished work in Review).
        case message(index: Int, side: Side, waiting: Bool)
        /// A board event, on one quiet line: created, moved, picked up, let go, went quiet, edited, who it's for, woken,
        /// the receipt for a decision, and any kind added later.
        case line(index: Int)
        /// "From your binders", while it has anything in it.
        case context(index: Int)
    }

    /// What became of one of your answers or comments, once the card has gone to the agent. Indexes are into the events.
    public enum Delivery: Equatable, Sendable {
        /// The last wake that carried it: its receipt, which the conversation folds into the line under your words.
        case sent(receipt: Int)
        /// That wake's receipt was followed by its failure line (its web hook didn't take the card) before its next receipt.
        case didntArrive(receipt: Int, failure: Int)
        /// No wake carried it, and the agent finished the card after it.
        case finishedFirst
        /// No wake carried it.
        case notSent
    }

    /// The rows, oldest first, with a day's heading before each new day. A note by Binders is one by `binders` that isn't by
    /// an agent: an agent may call itself "Binders", and its words are then that agent's. An agent's move or release with a
    /// note is its message; without one, a quiet line. `column` is where the card is now, for what still waits on you.
    /// `folded`: receipts (and their failure lines) shown under the words they carried instead, which get no row.
    public static func entries(_ events: [Event], column: BoardColumn, binders: String = "Binders", calendar: Calendar = .current,
                               folded: Set<Int> = []) -> [Entry] {
        let asked = column == .blocked ? BoardRules.waitingAsk(in: events.map { (kind: $0.kind, to: $0.to ?? "") }) : nil
        let finished = column == .review ? events.lastIndex { $0.kind == "completed" && $0.byAgent } : nil
        var entries: [Entry] = []
        var day: Date?
        for (index, event) in events.enumerated() where !folded.contains(index) {
            guard let entry = entry(index, event, binders: binders, waiting: index == asked || index == finished) else { continue }
            let start = calendar.startOfDay(for: event.at)
            if day != start {
                entries.append(.day(start))
                day = start
            }
            entries.append(entry)
        }
        return entries
    }

    private static func entry(_ index: Int, _ event: Event, binders: String, waiting: Bool) -> Entry? {
        switch event.kind {
        case "context":
            return event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .context(index: index)
        case "progress", "question", "approval", "completed", "answer":
            return .message(index: index, side: event.byAgent ? .agent : .you, waiting: waiting && event.byAgent)
        case "comment":
            if event.byAgent { return .message(index: index, side: .agent, waiting: false) }
            return .message(index: index, side: event.author == binders ? .binders : .you, waiting: false)
        case "moved", "released":
            let said = !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return event.byAgent && said ? .message(index: index, side: .agent, waiting: false) : .line(index: index)
        default:
            return .line(index: index)
        }
    }

    /// Your words: an answer or a comment by a person, never a note by Binders itself (`binders`).
    public static func isYours(_ event: Event, binders: String = "Binders") -> Bool {
        (event.kind == "answer" || event.kind == "comment") && !event.byAgent && event.author != binders
    }

    /// Whether a board name is this agent's, exactly, whatever the case: as the Mac matches the holder to an agent.
    static func same(_ name: String, _ agent: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare(agent.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// Which of your words the agent hasn't had, for a wake for `agent` after `events` (`wakeWords` says which go):
    /// - `new`: your answers, and your comments made while the agent held the card, since it last got the card (its last
    ///   receipt that arrived, the card's last move to Done, or the last change of who it's meant for), oldest first;
    /// - `latest`: your newest words anywhere.
    ///
    /// Never a note by Binders (`binders`). `failureLines` are the openings of the dispatcher's failure lines that follow a
    /// wake's receipt ("Its web hook didn't take the card"): a receipt followed by one before the agent's next receipt
    /// didn't arrive, so the words it carried count as not had yet.
    public static func carried(_ events: [Event], agent: String, failureLines: [String], binders: String = "Binders") -> (new: [Int], latest: Int?) {
        func failed(_ event: Event) -> Bool { failureLines.contains { event.text.hasPrefix($0) } }
        // The agent's own wake lines: its receipts, and the failure lines that follow some of them.
        let wakes = events.indices.filter { events[$0].kind == "woke" && same(events[$0].author, agent) }
        var since = -1
        for (position, index) in wakes.enumerated() where !failed(events[index]) {
            let next = wakes.dropFirst(position + 1).first
            if next.map({ !failed(events[$0]) }) ?? true { since = max(since, index) }
        }
        if let done = events.lastIndex(where: { $0.to == BoardColumn.done.rawValue }) { since = max(since, done) }
        if let assigned = events.lastIndex(where: { $0.kind == "assigned" }) { since = max(since, assigned) }
        let holds = holders(events)
        var new: [Int] = []
        var latest: Int?
        for (index, event) in events.enumerated() where isYours(event, binders: binders) {
            latest = index
            guard index > since else { continue }
            let holder = holds[index]
            if event.kind == "answer" || (holder.agent && same(holder.name ?? "", agent)) { new.append(index) }
        }
        return (new, latest)
    }

    /// Your comments a comment's wake is for that the agent hasn't had: made while it held the card in In progress, since it
    /// last got the card (those of `carried`'s `new`), oldest first.
    public static func unheardComments(_ events: [Event], agent: String, failureLines: [String], binders: String = "Binders") -> [Int] {
        let columns = columns(events)
        return carried(events, agent: agent, failureLines: failureLines, binders: binders).new.filter {
            events[$0].kind == "comment" && columns[$0] == BoardColumn.inProgress.rawValue
        }
    }

    /// The words a wake for `agent` after `events` puts in its `answer`, by index, oldest first. As every wake always has:
    /// the newest answer or comment not by an agent (a note by Binders, when that's the newest). While comments of yours a
    /// comment's wake is for haven't reached the agent (`unheardComments`: gathered with an answer or Send Back, held back
    /// by the cap or a run, or carried by a wake that failed), every word of yours it hasn't had (`carried`'s `new`), then
    /// your latest if it isn't among them, never a note by Binders: `joined`, for `AgentWakePayload.answer(_:)`.
    public static func wakeWords(_ events: [Event], agent: String, failureLines: [String], binders: String = "Binders") -> (words: [Int], joined: Bool) {
        let carried = carried(events, agent: agent, failureLines: failureLines, binders: binders)
        let columns = columns(events)
        guard carried.new.contains(where: { events[$0].kind == "comment" && columns[$0] == BoardColumn.inProgress.rawValue }) else {
            return (events.lastIndex { !$0.byAgent && ($0.kind == "answer" || $0.kind == "comment") }.map { [$0] } ?? [], false)
        }
        return (carried.new + (carried.latest.map { carried.new.contains($0) ? [] : [$0] } ?? []), true)
    }

    /// The column each event happened in, as the timeline tells it (raw values): where the last event before it that moved
    /// the card took it, or nil before any did.
    static func columns(_ events: [Event]) -> [String?] {
        var column: String?
        var columns: [String?] = []
        for event in events {
            columns.append(column)
            if let to = event.to, !to.isEmpty { column = to }
        }
        return columns
    }

    /// Who held the card when each event happened, as its timeline tells it: taken by a claim (Binders holding a card for
    /// an agent is that agent's claim), let go by a release, a lapse or a move back to Backlog or Ready, and taken by
    /// whoever starts work on a card nobody holds.
    static func holders(_ events: [Event]) -> [(name: String?, agent: Bool)] {
        var name: String?
        var agent = false
        var held: [(name: String?, agent: Bool)] = []
        for event in events {
            held.append((name, agent))
            switch event.kind {
            case "created", "released", "lapsed":
                name = nil
                agent = false
            case "claimed":
                name = event.author
                agent = event.byAgent
            case "moved":
                if event.to == BoardColumn.ready.rawValue || event.to == BoardColumn.backlog.rawValue {
                    name = nil
                    agent = false
                } else if event.to == BoardColumn.inProgress.rawValue, name == nil {
                    name = event.author
                    agent = event.byAgent
                }
            case "completed":
                if name == nil {
                    name = event.author
                    agent = event.byAgent
                }
            case "answer":
                if event.to == BoardColumn.ready.rawValue {
                    name = nil
                    agent = false
                }
            default:
                break
            }
        }
        return held
    }

    /// What became of each of your answers and comments (by index) made after the card first went to `agent` (its first
    /// receipt or claim): the last receipt whose wake carried it (`wakeWords` over the events before that receipt), that
    /// receipt's failure line when one followed before the agent's next receipt, finished first, or not sent. Words from
    /// before the card first went to the agent have none: the composer said then what Give to does with them. A failure
    /// line is its receipt's because Binders sends a wake that carries your comments only once the card's last one has
    /// settled, so no other receipt comes between them.
    public static func delivery(_ events: [Event], agent: String, failureLines: [String], binders: String = "Binders") -> [Int: Delivery] {
        func failed(_ event: Event) -> Bool { failureLines.contains { event.text.hasPrefix($0) } }
        let wakes = events.indices.filter { events[$0].kind == "woke" && same(events[$0].author, agent) }
        let receipts = wakes.filter { !failed(events[$0]) }
        let claimed = events.firstIndex { $0.kind == "claimed" && same($0.author, agent) }
        guard let contact = [receipts.first, claimed].compactMap({ $0 }).min() else { return [:] }
        var carriedBy: [Int: Int] = [:]
        for receipt in receipts {
            for index in wakeWords(Array(events[..<receipt]), agent: agent, failureLines: failureLines, binders: binders).words { carriedBy[index] = receipt }
        }
        var result: [Int: Delivery] = [:]
        for (index, event) in events.enumerated() where index > contact && isYours(event, binders: binders) {
            if let receipt = carriedBy[index] {
                let next = receipts.first { $0 > receipt } ?? events.count
                if let failure = wakes.first(where: { $0 > receipt && $0 < next && failed(events[$0]) }) {
                    result[index] = .didntArrive(receipt: receipt, failure: failure)
                } else {
                    result[index] = .sent(receipt: receipt)
                }
            } else if events[(index + 1)...].contains(where: { $0.kind == "completed" && $0.byAgent && same($0.author, agent) }) {
                result[index] = .finishedFirst
            } else {
                result[index] = .notSent
            }
        }
        return result
    }

    /// The receipts, and their failure lines, that the line under your words shows instead of a row of their own.
    public static func folded(_ deliveries: [Int: Delivery]) -> Set<Int> {
        var folded: Set<Int> = []
        for delivery in deliveries.values {
            switch delivery {
            case .sent(let receipt): folded.insert(receipt)
            case .didntArrive(let receipt, let failure): folded.formUnion([receipt, failure])
            case .finishedFirst, .notSent: break
            }
        }
        return folded
    }
}
