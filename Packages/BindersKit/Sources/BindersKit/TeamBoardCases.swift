import Foundation

// The shared board cases: one table of cases (a card's state, who acts, what they do, and the result or the refusal),
// run against the Swift rules (BoardRules, as BoardService applies them) in a kit test and against the team database's
// SQL functions in a Mac self-test, so the two can't drift. The cases live in the kit's test fixtures
// (Fixtures/team/board-cases.json); this is how both read them.

public struct TeamBoardCases: Decodable, Sendable {
    /// Someone a case names: "A", "B" and "C" are agents, "P" and "Q" people.
    public struct Actor: Decodable, Sendable {
        public var name: String
        public var kind: BoardActor.Kind
        /// An agent's owner, an actor key: who decides on what it asks approval for. "A" and "B" are P's, "C" is Q's.
        public var owner: String?

        enum CodingKeys: String, CodingKey { case name, kind, owner }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            kind = BoardActor.Kind(rawValue: try container.decode(String.self, forKey: .kind)) ?? .person
            owner = try container.decodeIfPresent(String.self, forKey: .owner)
        }
    }

    public var schema: String
    public var actors: [String: Actor]
    public var cases: [TeamBoardCase]
    /// How long an agent's claim lasts in these cases, in seconds; it must be BoardRules.lease.
    public var lease: TimeInterval

    public static func load(_ url: URL) throws -> TeamBoardCases {
        try JSONDecoder().decode(TeamBoardCases.self, from: Data(contentsOf: url))
    }

    /// The actor a key names, as the board knows them; "Binders" is Binders itself.
    public func actor(_ key: String) -> BoardActor? {
        if key == "Binders" { return BoardActor(name: "Binders", kind: .person) }
        return actors[key].map { BoardActor(name: $0.name, kind: $0.kind) }
    }

    /// The key of the actor with this name, to read a result back in the cases' terms.
    public func key(named name: String) -> String? {
        if name == "Binders" { return "Binders" }
        return actors.first { $0.value.name == name }?.key
    }

    /// The person behind an actor key: a person themselves, an agent's owner.
    public func person(_ key: String?) -> String? {
        guard let key, let actor = actors[key] else { return nil }
        return actor.kind == .agent ? actor.owner : key
    }

    /// Who decides on the approval a card waits on (BoardRules.deciders), as actor keys: the asking agent's owner, and
    /// the person the card is meant for (or the owner of the agent it's meant for), unless that was only suggested.
    public func deciders(of card: TeamBoardCase.Card, askedBy asker: String) -> [String] {
        BoardRules.deciders(askerOwner: actors[asker]?.owner, meantFor: person(card.meantFor), suggested: card.suggested)
    }
}

public struct TeamBoardCase: Sendable {
    /// A card's state: its column, who holds it (an actor key), when their lease ends (seconds from the case's now;
    /// nil for none), the columns of the cards it waits for, lines already on its timeline, and who it's meant for (an
    /// actor key), `suggested` when an agent only suggested that.
    public struct Card: Decodable, Equatable, Sendable {
        public var column: BoardColumn
        public var holder: String?
        public var lease: TimeInterval?
        public var waitsFor: [BoardColumn]
        public var timeline: [Line]
        public var meantFor: String?
        public var suggested: Bool

        enum CodingKeys: String, CodingKey { case column, holder, lease, waitsFor, timeline, meantFor, suggested }

        public init(column: BoardColumn, holder: String? = nil, lease: TimeInterval? = nil, waitsFor: [BoardColumn] = [], timeline: [Line] = [],
                    meantFor: String? = nil, suggested: Bool = false) {
            self.column = column
            self.holder = holder
            self.lease = lease
            self.waitsFor = waitsFor
            self.timeline = timeline
            self.meantFor = meantFor
            self.suggested = suggested
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decode(String.self, forKey: .column)
            guard let column = BoardColumn(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .column, in: container, debugDescription: "No column \(raw)")
            }
            self.column = column
            holder = try container.decodeIfPresent(String.self, forKey: .holder)
            lease = try container.decodeIfPresent(TimeInterval.self, forKey: .lease)
            waitsFor = try (container.decodeIfPresent([String].self, forKey: .waitsFor) ?? []).map {
                guard let column = BoardColumn(rawValue: $0) else {
                    throw DecodingError.dataCorruptedError(forKey: .waitsFor, in: container, debugDescription: "No column \($0)")
                }
                return column
            }
            timeline = try container.decodeIfPresent([Line].self, forKey: .timeline) ?? []
            meantFor = try container.decodeIfPresent(String.self, forKey: .meantFor)
            suggested = try container.decodeIfPresent(Bool.self, forKey: .suggested) ?? false
        }
    }

    /// A line of a card's timeline, as TaskEvent writes it: its kind, who (an actor key, or "Binders"), the columns it
    /// moved between, and its text.
    public struct Line: Decodable, Equatable, Sendable, CustomStringConvertible {
        public var kind: String
        public var by: String
        public var from: String?
        public var to: String?
        public var text: String

        public init(kind: String, by: String, from: String? = nil, to: String? = nil, text: String = "") {
            self.kind = kind
            self.by = by
            self.from = from
            self.to = to
            self.text = text
        }

        enum CodingKeys: String, CodingKey { case kind, by, from, to, text }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            by = try container.decode(String.self, forKey: .by)
            from = try container.decodeIfPresent(String.self, forKey: .from)
            to = try container.decodeIfPresent(String.self, forKey: .to)
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        }

        public var description: String { "\(kind) by \(by) \(from ?? "-")→\(to ?? "-") “\(text)”" }
    }

    /// Which request a decision names: the one waiting, or another (stale).
    public enum ApprovalRef: String, Decodable, Sendable {
        case current, stale
    }

    public enum Action: Equatable, Sendable {
        case claim
        case move(BoardColumn)
        case report(text: String, links: [String], renewing: Bool)
        case keepAlive
        case ask(String)
        case answer(String)
        case requestApproval(String)
        case decide(approve: Bool, reason: String, approval: ApprovalRef?, receipt: String?)
        case release(String)
        case finish(String)
    }

    /// A refusal: its code (TeamRefusal.code), whose card it is (an actor key), when their lease ends (seconds from the
    /// case's now; nil for none), and for an approval someone else decides on, who does (actor keys, the owner first).
    public struct Refusal: Decodable, Equatable, Sendable {
        public var code: String
        public var holder: String?
        public var until: TimeInterval?
        public var deciders: [String]?

        public init(code: String, holder: String? = nil, until: TimeInterval? = nil, deciders: [String]? = nil) {
            self.code = code
            self.holder = holder
            self.until = until
            self.deciders = deciders
        }
    }

    public struct Expectation: Sendable {
        /// Refused: nothing changes, unless `card` says what a refusal still left (a lapse written before it).
        public var refused: Refusal?
        /// The card afterwards; nil with a refusal means as it was.
        public var card: Card?
        /// The lines the action adds to the timeline, in order.
        public var events: [Line]
    }

    public var name: String
    /// A case about the new rule, cards that wait for others (lane DS1 adds it to the Swift rules).
    public var waits: Bool
    public var card: Card
    /// Who acts: an actor key.
    public var by: String
    public var action: Action
    public var agentsMayFinish: Bool
    public var expect: Expectation
}

extension TeamBoardCase: Decodable {
    enum CodingKeys: String, CodingKey {
        case name, waits, card, by, agentsMayFinish, expect
        case action = "do", to, text, links, renewing, approve, reason, approval, receipt
    }

    enum ExpectKeys: String, CodingKey { case refused, card, events }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        waits = try container.decodeIfPresent(Bool.self, forKey: .waits) ?? false
        card = try container.decode(Card.self, forKey: .card)
        by = try container.decode(String.self, forKey: .by)
        agentsMayFinish = try container.decodeIfPresent(Bool.self, forKey: .agentsMayFinish) ?? false
        let text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        switch try container.decode(String.self, forKey: .action) {
        case "claim": action = .claim
        case "move":
            let raw = try container.decode(String.self, forKey: .to)
            guard let column = BoardColumn(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .to, in: container, debugDescription: "No column \(raw)")
            }
            action = .move(column)
        case "report":
            action = .report(text: text, links: try container.decodeIfPresent([String].self, forKey: .links) ?? [],
                             renewing: try container.decodeIfPresent(Bool.self, forKey: .renewing) ?? true)
        case "keep_alive": action = .keepAlive
        case "ask": action = .ask(text)
        case "answer": action = .answer(text)
        case "request_approval": action = .requestApproval(text)
        case "decide":
            action = .decide(approve: try container.decode(Bool.self, forKey: .approve),
                             reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "",
                             approval: try container.decodeIfPresent(ApprovalRef.self, forKey: .approval),
                             receipt: try container.decodeIfPresent(String.self, forKey: .receipt))
        case "release": action = .release(text)
        case "finish": action = .finish(text)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "No action \(other)")
        }
        let expect = try container.nestedContainer(keyedBy: ExpectKeys.self, forKey: .expect)
        self.expect = Expectation(refused: try expect.decodeIfPresent(Refusal.self, forKey: .refused),
                                  card: try expect.decodeIfPresent(Card.self, forKey: .card),
                                  events: try expect.decodeIfPresent([Line].self, forKey: .events) ?? [])
    }
}
