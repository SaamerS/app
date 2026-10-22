import Foundation

/// A function's answer: applied (with the card, its new timeline lines, the row…), or refused with its reason. A retry
/// of the same operation gets the same answer, marked replayed.
public struct TeamResult: Equatable, Sendable {
    public var ok: Bool
    public var refusal: TeamRefusal?
    /// The first answer, given again to a retry of the same operation.
    public var replayed: Bool
    /// Applied, but nothing changed (a move to the column it's in, a suggestion that didn't replace your choice…).
    public var unchanged: Bool
    /// Everything it said, as JSON: `card`, `events`, `row`, `binder`, `member`, `agent`, `ids`, `message`…
    public var body: TeamRow

    public init(ok: Bool, refusal: TeamRefusal? = nil, replayed: Bool = false, unchanged: Bool = false, body: TeamRow = [:]) {
        self.ok = ok
        self.refusal = refusal
        self.replayed = replayed
        self.unchanged = unchanged
        self.body = body
    }

    /// From the function's JSON. Nil for anything that isn't one of its answers.
    public init?(json text: String) {
        guard let object = TeamJSON(text: text)?.object, let ok = object["ok"]?.bool else { return nil }
        self.ok = ok
        replayed = object["replayed"]?.bool ?? false
        unchanged = object["unchanged"]?.bool ?? false
        body = object
        refusal = ok ? nil : object["refusal"]?.object.map(TeamRefusal.init(json:))
        if !ok, refusal == nil { return nil }
    }

    /// The card as the change left it.
    public var card: TeamCard? { body["card"]?.object.flatMap(TeamCard.init(row:)) }
    /// The lines the change added to its timeline, in order.
    public var events: [TeamCardEvent] { body["events"]?.array?.compactMap { $0.object.flatMap(TeamCardEvent.init(row:)) } ?? [] }
    /// The row a row write left.
    public var row: TeamRow? { body["row"]?.object }
    /// What it says for whoever made it, when it says something (a decision's "Approved. … can go ahead").
    public var message: String? { body["message"]?.string }
}

/// Why the database refused a change, in the words the board uses.
public struct TeamRefusal: Error, Equatable, Sendable, LocalizedError {
    /// `claimed_by`, `agents_cannot_finish`, `not_yours`, `finished`, `waits_for`, `not_found`, `not_an_agent`,
    /// `nothing_waits`, `changed`, `not_you`, `cycle`, `other_board`, `exists`, `deleted`, `only_added`, …
    public var code: String
    /// The database's own words, for headless agents. The Mac says a board refusal in BoardError's words instead.
    public var message: String
    /// Who has the card, for `claimed_by` and `not_yours`.
    public var holder: String?
    /// When their claim lapses, for `claimed_by` on work in progress.
    public var until: Date?
    /// The cards it waits for that aren't Done, for `waits_for`.
    public var waitsFor: [TeamWaitingCard]
    /// The agent's owner, by name: who turns on a headless agent's Auto (`auto_off`, migration 8), or whose agent asked
    /// for the approval (`not_yours_to_decide`).
    public var owner: String?
    /// For `not_yours_to_decide`: the person the card is for, by name, when a person meant it for them.
    public var meantFor: String?
    /// For `not_yours_to_decide`: everyone who decides on it, by name, the owner first.
    public var deciders: [String]

    public init(code: String, message: String, holder: String? = nil, until: Date? = nil, waitsFor: [TeamWaitingCard] = [],
                owner: String? = nil, meantFor: String? = nil, deciders: [String] = []) {
        self.code = code
        self.message = message
        self.holder = holder
        self.until = until
        self.waitsFor = waitsFor
        self.owner = owner
        self.meantFor = meantFor
        self.deciders = deciders
    }

    init(json: TeamRow) {
        code = json["code"]?.string ?? "refused"
        message = json["message"]?.string ?? "The team database refused it."
        holder = json["holder"]?.string
        until = json["until"]?.date
        waitsFor = json["waits_for"]?.array?.compactMap { item in
            guard let id = item["id"]?.uuid else { return nil }
            return TeamWaitingCard(id: id, title: item["title"]?.string ?? "", column: item["column"]?.string.flatMap(BoardColumn.init(rawValue:)))
        } ?? []
        owner = json["owner"]?.string
        meantFor = json["meant_for"]?.string
        deciders = json["deciders"]?.array?.compactMap { $0["name"]?.string ?? $0.string } ?? []
    }

    /// The same refusal as the Swift rules give it, when it's one of theirs: so its words, and the time in it, are this
    /// Mac's.
    public var boardError: BoardError? {
        switch code {
        case "claimed_by": .claimedBy(holder ?? "Someone", until: until)
        case "agents_cannot_finish": .agentsCannotFinish
        case "not_yours": .notYours(holder ?? "Someone")
        case "finished": .finished
        case "waits_for": .waitsFor(waitsFor.map(\.title))
        default: nil
        }
    }

    public var errorDescription: String? {
        if let boardError { return boardError.errorDescription }
        // Who decides on an approval is the Swift rules' too: the same words on the Mac.
        if code == "not_yours_to_decide" { return BoardRules.onlyDeciders(owner: owner, meantFor: meantFor) }
        return message
    }
}

/// A card another waits for, in a `waits_for` refusal.
public struct TeamWaitingCard: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var column: BoardColumn?

    public init(id: UUID, title: String, column: BoardColumn?) {
        self.id = id
        self.title = title
        self.column = column
    }
}

/// A card as the team database keeps it (`binders.cards`).
public struct TeamCard: Equatable, Sendable {
    public var id: UUID
    public var binderID: UUID
    public var title: String
    public var details: String
    public var column: BoardColumn
    public var position: Double
    public var holderKind: BoardActor.Kind?
    public var holderMemberID: UUID?
    public var holderAgentID: UUID?
    public var holderName: String?
    public var leaseUntil: Date?
    public var meantFor: String?
    public var meantForByAgent: Bool
    public var dueAt: Date?
    public var links: [String]
    public var sourceKind: String?
    public var sourceID: String?
    public var sourceTitle: String?
    public var todoID: UUID?
    public var distillItemID: UUID?
    public var noteSection: String?
    public var noteVersionID: UUID?
    public var createdByName: String
    public var createdByMember: UUID?
    public var createdByAgent: UUID?
    public var externalKey: String?
    public var externalURL: String?
    /// Distill's part of the card the team shares (migration 5's `distilled`), as JSON; nil for any other card, and from a
    /// database before migration 5.
    public var distilled: TeamJSON?
    public var version: Int
    public var createdAt: Date?
    public var updatedAt: Date?
    public var deletedAt: Date?

    public init?(row: TeamRow) {
        guard let id = row["id"]?.uuid, let binderID = row["binder_id"]?.uuid, let title = row["title"]?.string else { return nil }
        self.id = id
        self.binderID = binderID
        self.title = title
        details = row["details"]?.string ?? ""
        // A column a later Binders adds reads as Backlog, as a TaskCard's does.
        column = row["board_column"]?.string.flatMap(BoardColumn.init(rawValue:)) ?? .backlog
        position = row["position"]?.double ?? 0
        holderKind = row["holder_kind"]?.string.flatMap(BoardActor.Kind.init(rawValue:))
        holderMemberID = row["holder_member_id"]?.uuid
        holderAgentID = row["holder_agent_id"]?.uuid
        holderName = row["holder_name"]?.string
        leaseUntil = row["lease_until"]?.date
        meantFor = row["meant_for"]?.string
        meantForByAgent = row["meant_for_by_agent"]?.bool ?? false
        dueAt = row["due_at"]?.date
        links = row["links"]?.strings ?? []
        sourceKind = row["source_kind"]?.string
        sourceID = row["source_id"]?.string
        sourceTitle = row["source_title"]?.string
        todoID = row["todo_id"]?.uuid
        distillItemID = row["distill_item_id"]?.uuid
        noteSection = row["note_section"]?.string
        noteVersionID = row["note_version_id"]?.uuid
        createdByName = row["created_by_name"]?.string ?? ""
        createdByMember = row["created_by_member"]?.uuid
        createdByAgent = row["created_by_agent"]?.uuid
        externalKey = row["external_key"]?.string
        externalURL = row["external_url"]?.string
        distilled = row["distilled"].flatMap { $0.object == nil ? nil : $0 }
        version = row["version"]?.int ?? 1
        createdAt = row["created_at"]?.date
        updatedAt = row["updated_at"]?.date
        deletedAt = row["deleted_at"]?.date
    }

    /// The part of it the board's rules read, with the holder by name as the Swift rules compare them.
    public var state: CardState {
        CardState(column: column, assignee: holderKind == nil ? nil : holderName, assigneeIsAgent: holderKind == .agent, claimExpires: leaseUntil)
    }

    /// As it reads now: a card whose agent went quiet reads as Ready (BoardRules.expire), though the database writes the
    /// lapse only when someone next acts on it.
    public func stateNow(_ now: Date = Date()) -> CardState {
        BoardRules.expire(state, at: now) ?? state
    }
}

/// One line of a card's timeline as the team database keeps it (`binders.card_events`): TaskEvent's fields, with who
/// wrote it.
public struct TeamCardEvent: Equatable, Sendable {
    public var id: UUID
    public var number: Int64
    public var binderID: UUID
    public var cardID: UUID
    /// As TaskEvent.Kind's raw values: claimed, moved, progress, question, answer, comment, approval, decision…
    public var kind: String
    public var author: BoardActor
    public var authorMemberID: UUID?
    public var authorAgentID: UUID?
    /// The member whose login wrote it.
    public var writtenBy: UUID?
    public var text: String
    public var fromColumn: String?
    public var toColumn: String?
    public var createdAt: Date?

    public init?(row: TeamRow) {
        guard let id = row["id"]?.uuid, let binderID = row["binder_id"]?.uuid, let cardID = row["card_id"]?.uuid,
              let kind = row["kind"]?.string else { return nil }
        self.id = id
        self.binderID = binderID
        self.cardID = cardID
        self.kind = kind
        number = row["number"]?.int64 ?? 0
        author = BoardActor(name: row["author_name"]?.string ?? "", kind: row["author_kind"]?.string.flatMap(BoardActor.Kind.init(rawValue:)) ?? .person)
        authorMemberID = row["author_member_id"]?.uuid
        authorAgentID = row["author_agent_id"]?.uuid
        writtenBy = row["written_by"]?.uuid
        text = row["text"]?.string ?? ""
        fromColumn = row["from_column"]?.string
        toColumn = row["to_column"]?.string
        createdAt = row["created_at"]?.date
    }
}

// MARK: The changes feed

/// One change in the feed: which row of which table changed, in which binder (nil for what the whole team sees), and
/// how. It never says what changed: read the row.
public struct TeamChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case insert, update, delete
        /// A kind a later Binders writes: read the row, as for an update.
        case other(String)

        init(_ text: String) {
            switch text {
            case "insert": self = .insert
            case "update": self = .update
            case "delete": self = .delete
            default: self = .other(text)
            }
        }
    }

    public var seq: Int64
    public var binderID: UUID?
    /// The table's name as the database gives it; `table` when it's one this Binders knows.
    public var tableName: String
    public var rowID: UUID
    public var kind: Kind
    public var memberID: UUID?
    public var at: Date?

    public var table: TeamTable? { TeamTable(rawValue: tableName) }

    public init(seq: Int64, binderID: UUID?, tableName: String, rowID: UUID, kind: Kind, memberID: UUID? = nil, at: Date? = nil) {
        self.seq = seq
        self.binderID = binderID
        self.tableName = tableName
        self.rowID = rowID
        self.kind = kind
        self.memberID = memberID
        self.at = at
    }

    public init?(row: TeamRow) {
        guard let seq = row["seq"]?.int64, let tableName = row["table_name"]?.string, let rowID = row["row_id"]?.uuid else { return nil }
        self.init(seq: seq, binderID: row["binder_id"]?.uuid, tableName: tableName, rowID: rowID,
                  kind: Kind(row["kind"]?.string ?? "update"), memberID: row["member_id"]?.uuid, at: row["at"]?.date)
    }

    /// A page of the feed as the database gives it: a JSON array of changes, oldest first. Entries it can't read are
    /// skipped; nil when it isn't an array at all.
    public static func list(json text: String) -> [TeamChange]? {
        TeamJSON(text: text)?.array?.compactMap { $0.object.flatMap(TeamChange.init(row:)) }
    }

    /// The number a `NOTIFY` on TeamSchema.channel carries: a change was committed at least this far along. Nil for a
    /// payload that isn't one, which a listener ignores.
    public static func notified(_ payload: String) -> Int64? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy(\.isNumber) else { return nil }
        return Int64(text)
    }
}

/// What a batch of changes needs read: the changed rows of each table, each once, in the order they changed.
public struct TeamChangeBatch: Equatable, Sendable {
    public var changes: [TeamChange]

    public init(_ changes: [TeamChange]) {
        self.changes = changes.sorted { $0.seq < $1.seq }
    }

    /// The last number in it; nil when it's empty.
    public var lastSeq: Int64? { changes.last?.seq }

    /// Each table's changed rows, in the order they first changed. Tables this Binders doesn't know are left out: a
    /// later Binders' tables are its own.
    public var rowsToRead: [(table: TeamTable, ids: [UUID])] {
        var order: [TeamTable] = []
        var ids: [TeamTable: [UUID]] = [:]
        var seen: Set<String> = []
        for change in changes {
            guard let table = change.table, seen.insert(table.rawValue + "|" + change.rowID.uuidString).inserted else { continue }
            if ids[table] == nil { order.append(table) }
            ids[table, default: []].append(change.rowID)
        }
        return order.map { ($0, ids[$0] ?? []) }
    }

    /// The changed rows not among those read back: deleted for good, or no longer in a binder this member sees (moved to
    /// one they're not in). The Mac drops them.
    public func gone(read: [TeamTable: [TeamRow]]) -> [(table: TeamTable, id: UUID)] {
        rowsToRead.flatMap { table, ids -> [(table: TeamTable, id: UUID)] in
            let found = Set((read[table] ?? []).compactMap(\.rowID))
            return ids.filter { !found.contains($0) }.map { (table, $0) }
        }
    }
}

/// What the Mac hands DB2 and DB3 after each catch-up: the changes, the rows they touched as they are now, the ids gone,
/// and the binders this member started or stopped seeing (read a new one in full: rows changed before it was shared
/// aren't in the feed after this Mac's last number).
public struct TeamUpdate: Sendable {
    public var changes: [TeamChange]
    public var rows: [TeamTable: [TeamRow]]
    public var gone: [(table: TeamTable, id: UUID)]
    public var bindersAdded: Set<UUID>
    public var bindersRemoved: Set<UUID>
    /// Every binder this member saw when the update was read.
    public var binders: Set<UUID>
    /// The feed's number this update reaches; acknowledge it once applied.
    public var lastSeq: Int64

    public init(changes: [TeamChange], rows: [TeamTable: [TeamRow]], gone: [(table: TeamTable, id: UUID)], bindersAdded: Set<UUID>,
                bindersRemoved: Set<UUID>, binders: Set<UUID>, lastSeq: Int64) {
        self.changes = changes
        self.rows = rows
        self.gone = gone
        self.bindersAdded = bindersAdded
        self.bindersRemoved = bindersRemoved
        self.binders = binders
        self.lastSeq = lastSeq
    }

    public var isEmpty: Bool { changes.isEmpty && bindersAdded.isEmpty && bindersRemoved.isEmpty }
}
