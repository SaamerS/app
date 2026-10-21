import Foundation

/// "What's happening with my work streams?", answered from the boards alone: who is working on what, what waits on you
/// (a question in Blocked, finished work in Review), what's meant for someone and not started, and what was finished
/// today. Deterministic, so it's the same every time it's asked and can be tested; a model may phrase it, never decide it.
public enum WorkStreams {
    /// A card as the digest needs it.
    public struct Card: Equatable, Sendable {
        public var title: String
        public var binder: String
        public var column: BoardColumn
        /// Who has it: an agent, a person, or nobody.
        public var assignee: String?
        public var assigneeIsAgent: Bool
        /// Who it's meant for before anyone takes it.
        public var meantFor: String?
        /// The question it waits on, when it's in Blocked, and who asked it: an agent may ask about a card nobody holds.
        public var question: String?
        public var asker: String?
        /// When it last changed, and when it reached Done.
        public var updated: Date
        public var finished: Date?
        /// What the agent holding it says it's doing, in its own words (`AgentDoing`): only while it's in progress in a run
        /// Binders started.
        public var doing: String?

        public init(title: String, binder: String, column: BoardColumn, assignee: String? = nil, assigneeIsAgent: Bool = false,
                    meantFor: String? = nil, question: String? = nil, asker: String? = nil, updated: Date, finished: Date? = nil,
                    doing: String? = nil) {
            self.title = title
            self.binder = binder
            self.column = column
            self.assignee = assignee
            self.assigneeIsAgent = assigneeIsAgent
            self.meantFor = meantFor
            self.question = question
            self.asker = asker
            self.updated = updated
            self.finished = finished
            self.doing = doing
        }
    }

    /// What an agent says it's doing on one of its cards, in its own words: the card's title and the line. As
    /// work_streams gives it, in each stream's `doing`.
    public struct Doing: Codable, Equatable, Sendable {
        public var card: String
        public var line: String

        public init(card: String, line: String) {
            self.card = card
            self.line = line
        }
    }

    public struct Stream: Equatable, Sendable {
        /// An agent or a person.
        public var who: String
        public var isAgent: Bool
        public var working: [String]
        /// What it says it's doing on some of those cards, in its own words, in the same order. Only runs Binders started
        /// say, so most streams have none.
        public var doing: [Doing] = []
    }

    /// One stream as work_streams gives it (`working`) and the iPhone reads it: who, whether it's an agent, its cards'
    /// titles, and what it says it's doing on some of them. `doing` is nil when it says nothing, and always from a Mac
    /// before 0.8.1.
    public struct Working: Codable, Equatable, Sendable {
        public let who: String
        public let agent: Bool
        public let cards: [String]
        public let doing: [Doing]?

        public init(who: String, agent: Bool, cards: [String], doing: [Doing]? = nil) {
            self.who = who
            self.agent = agent
            self.cards = cards
            self.doing = doing
        }
    }

    /// What one binder has going, in counts.
    public struct BinderCounts: Equatable, Sendable {
        public var binder: String
        public var working = 0, questions = 0, reviews = 0, waitingToStart = 0, doneToday = 0
    }

    public struct Digest: Equatable, Sendable {
        /// Who is working on what, agents first, busiest first.
        public var streams: [Stream]
        /// Questions waiting on you, with who asked.
        public var questions: [(card: String, who: String, question: String)]
        /// Finished work waiting for your review.
        public var reviews: [(card: String, who: String)]
        /// Meant for someone, not started yet.
        public var queued: [(card: String, who: String)]
        public var doneToday: [String]
        /// Each binder with anything going, busiest first.
        public var byBinder: [BinderCounts] = []

        public static func == (a: Digest, b: Digest) -> Bool {
            a.streams == b.streams && a.doneToday == b.doneToday && a.byBinder == b.byBinder
                && a.questions.map { "\($0.card)|\($0.who)|\($0.question)" } == b.questions.map { "\($0.card)|\($0.who)|\($0.question)" }
                && a.reviews.map { "\($0.card)|\($0.who)" } == b.reviews.map { "\($0.card)|\($0.who)" }
                && a.queued.map { "\($0.card)|\($0.who)" } == b.queued.map { "\($0.card)|\($0.who)" }
        }

        public var isQuiet: Bool { streams.isEmpty && questions.isEmpty && reviews.isEmpty && queued.isEmpty && doneToday.isEmpty }

        /// Whether a run says what it's doing on any of its cards.
        public var saysWhatRunsAreDoing: Bool { streams.contains { !$0.doing.isEmpty } }

        /// The same digest without what runs said they were doing, for a copy kept once nothing shows it: their words are
        /// shown only fresh.
        public var withoutDoing: Digest {
            var digest = self
            for index in digest.streams.indices { digest.streams[index].doing = [] }
            return digest
        }

        /// The digest in a sentence or two, short enough to hear or read in a notification (at most 240 characters):
        /// what needs you first, then who is on how many cards, then what was finished today.
        public var headline: String {
            guard !isQuiet else { return "Nothing is moving on your boards right now." }
            var parts: [String] = []
            if let first = questions.first {
                parts.append("\(first.who) asks about “\(WorkStreams.clip(first.card))”" + (questions.count > 1 ? ", and \(questions.count - 1) more \(questions.count == 2 ? "question" : "questions")" : ""))
            }
            if !reviews.isEmpty {
                parts.append(reviews.count == 1 ? "“\(WorkStreams.clip(reviews[0].card))” is ready for you to check" : "\(reviews.count) cards are ready for you to check")
            }
            let busy = streams.prefix(3).map { "\($0.who) on \($0.working.count == 1 ? "1 card" : "\($0.working.count) cards")" }
            if !busy.isEmpty { parts.append(WorkStreams.list(Array(busy)) + (streams.count > 3 ? ", and \(streams.count - 3) more" : "")) }
            if !doneToday.isEmpty { parts.append("\(doneToday.count) finished today") }
            var line = ""
            for part in parts {
                let next = line.isEmpty ? part : line + ". " + part
                if next.count + 1 > 240 { break }
                line = next
            }
            return line + "."
        }

        /// The digest in a few plain sentences, as it's said back: "Claude Code is working on 2 cards: … 1 question waits
        /// on you: …". What a run says it's doing goes here as its words ("… and says: …"), never in the headline, which
        /// notifications show and the history keeps.
        public var summary: String {
            guard !isQuiet else { return "Nothing is moving on your boards right now." }
            var sentences: [String] = []
            for stream in streams.prefix(4) {
                let what = stream.working.count == 1 ? "“\(stream.working[0])”" : "\(stream.working.count) cards: " + WorkStreams.list(stream.working.prefix(3).map { "“\($0)”" })
                let working = "\(stream.who) \(stream.who == BoardActor.you.name ? "are" : "is") working on \(what)"
                // What a run says it's doing, as its words: "… and says: Running the tests."
                if let doing = stream.doing.first {
                    sentences.append(stream.working.count == 1 ? "\(working) and says: \(WorkStreams.sentence(doing.line))"
                                     : "\(working). On “\(doing.card)”, it says: \(WorkStreams.sentence(doing.line))")
                } else {
                    sentences.append(working + ".")
                }
            }
            if streams.count > 4 { sentences.append("\(streams.count - 4) more are working on something.") }
            if let first = questions.first {
                let more = questions.count > 1 ? " \(questions.count - 1) more \(questions.count == 2 ? "question waits" : "questions wait") too." : ""
                sentences.append("\(first.who) asks about “\(first.card)”: \(first.question)\(more)")
            }
            if !reviews.isEmpty {
                sentences.append(reviews.count == 1 ? "“\(reviews[0].card)” is ready for you to check."
                                 : "\(reviews.count) cards are ready for you to check: " + WorkStreams.list(reviews.prefix(3).map { "“\($0.card)”" }) + ".")
            }
            if !queued.isEmpty {
                sentences.append(queued.count == 1 ? "“\(queued[0].card)” is waiting for \(queued[0].who) to pick it up."
                                 : "\(queued.count) cards are waiting to be picked up.")
            }
            if !doneToday.isEmpty { sentences.append(doneToday.count == 1 ? "1 card was finished today." : "\(doneToday.count) cards were finished today.") }
            return sentences.joined(separator: " ")
        }
    }

    /// Only what has to do with one agent or person: cards it holds, asked about, or is meant for. "Claude Code" also takes
    /// in "Claude Code · binders-io/app".
    public static func involving(_ who: String, in cards: [Card]) -> [Card] {
        cards.filter { card in
            [card.assignee, card.asker, card.meantFor].contains { name in
                name.map { BoardRules.isNamed($0, as: who) || BoardRules.isNamed(who, as: $0) } ?? false
            }
        }
    }

    /// The digest of these cards, today being the day `now` falls on.
    public static func digest(_ cards: [Card], now: Date = Date(), calendar: Calendar = .current) -> Digest {
        var working: [String: (isAgent: Bool, cards: [Card])] = [:]
        var questions: [(card: String, who: String, question: String)] = []
        var reviews: [(card: String, who: String)] = []
        var queued: [(card: String, who: String)] = []
        var doneToday: [String] = []
        var binders: [String: BinderCounts] = [:]
        func count(_ card: Card, _ change: (inout BinderCounts) -> Void) {
            guard !card.binder.isEmpty else { return }
            change(&binders[card.binder, default: BinderCounts(binder: card.binder)])
        }
        for card in cards.sorted(by: { $0.updated > $1.updated }) {
            switch card.column {
            case .inProgress:
                guard let who = card.assignee else { continue }
                working[who, default: (card.assigneeIsAgent, [])].cards.append(card)
                count(card) { $0.working += 1 }
            case .blocked:
                questions.append((card.title, card.asker ?? card.assignee ?? "Someone", card.question ?? "it waits for an answer."))
                count(card) { $0.questions += 1 }
            case .review:
                reviews.append((card.title, card.assignee ?? "Someone"))
                count(card) { $0.reviews += 1 }
            case .ready, .backlog:
                if let who = card.meantFor, card.assignee == nil {
                    queued.append((card.title, who))
                    count(card) { $0.waitingToStart += 1 }
                }
            case .done:
                if let finished = card.finished, calendar.isDate(finished, inSameDayAs: now) {
                    doneToday.append(card.title)
                    count(card) { $0.doneToday += 1 }
                }
            }
        }
        let streams = working.map { entry in
            Stream(who: entry.key, isAgent: entry.value.isAgent, working: entry.value.cards.map(\.title),
                   doing: entry.value.cards.compactMap { card in card.doing.map { Doing(card: card.title, line: $0) } })
        }
            .sorted { a, b in
                if a.isAgent != b.isAgent { return a.isAgent }
                if a.working.count != b.working.count { return a.working.count > b.working.count }
                return a.who.localizedCaseInsensitiveCompare(b.who) == .orderedAscending
            }
        let byBinder = binders.values.sorted { a, b in
            let busyA = a.working + a.questions + a.reviews + a.waitingToStart, busyB = b.working + b.questions + b.reviews + b.waitingToStart
            return busyA != busyB ? busyA > busyB : a.binder.localizedCaseInsensitiveCompare(b.binder) == .orderedAscending
        }
        return Digest(streams: streams, questions: questions, reviews: reviews, queued: queued, doneToday: doneToday, byBinder: byBinder)
    }

    /// A headline with each card's title taken out ("Claude Code asks about a card. A card is ready for you to check."),
    /// for a Lock Screen that shows previews: a card can be made from what you said, so its title is kept for the app as
    /// your words are. Counts and who stay. A headline from any Mac reads the same way, as every title in it is in “…”.
    /// A title may have quotes of its own (“Read “Dune” tonight”), even ones that don't pair up: none of it is left over.
    public static func withoutTitles(_ headline: String) -> String {
        var line = ""
        // Where the last "a card" went in, and how deep in quotes the scan is.
        var lastCard: String.Index?
        var depth = 0
        var inside = ""
        for character in headline {
            switch (character, depth) {
            case ("“", 0):
                depth = 1
                inside = ""
            case ("“", _):
                depth += 1
                inside.append(character)
            case ("”", 0):
                // A closing quote outside any title: the title before it went on to here.
                if let lastCard {
                    line = String(line[..<lastCard]) + "a card"
                } else {
                    line.append(character)
                }
            case ("”", 1):
                depth = 0
                lastCard = line.endIndex
                line += "a card"
            case ("”", _):
                depth -= 1
                inside.append(character)
            default:
                if depth > 0 { inside.append(character) } else { line.append(character) }
            }
        }
        // A title that never closed: it goes, up to its last closing quote if it has one, else to the end.
        if depth > 0 {
            line += "a card"
            if let close = inside.lastIndex(of: "”") { line += inside[inside.index(after: close)...] }
        }
        // At the start of a sentence: "A card is ready for you to check".
        if line.hasPrefix("a card") { line = "A" + line.dropFirst() }
        return line.replacingOccurrences(of: ". a card", with: ". A card")
    }

    /// A card's title, short enough to say: agents write some of them.
    static func clip(_ title: String) -> String {
        title.count <= 60 ? title : String(title.prefix(59)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A work_streams reply as the iPhone keeps it, to show at once the next time: without what runs said they were doing
    /// (each stream's `doing`, and the summary, which says it too), which is shown only fresh and never written down.
    public static func keepable(_ reply: String) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
              var working = object["working"] as? [[String: Any]], working.contains(where: { $0["doing"] != nil }) else { return reply }
        for index in working.indices { working[index]["doing"] = nil }
        object["working"] = working
        object["summary"] = nil
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return reply }
        return String(decoding: data, as: UTF8.self)
    }

    /// An agent's line as the end of a sentence: with a full stop, unless it has its own.
    static func sentence(_ line: String) -> String {
        guard let last = line.last, !".!?…".contains(last) else { return line }
        return line + "."
    }

    /// "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
