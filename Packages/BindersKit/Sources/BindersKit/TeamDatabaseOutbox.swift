import Foundation

// The Mac's changes to the team database wait here, saved on disk, and go in the order they were made, each with its
// operation id. An item leaves only with a definite answer (applied, refused, or an error a retry wouldn't change); a
// dropped connection keeps it first, and it's sent again, with the same id, once connected: the database applies it at
// most once and gives its first answer back. These are the outbox's rules; the Mac keeps the file.

/// One change waiting to go.
public struct TeamOutboxItem: Codable, Equatable, Sendable, Identifiable {
    public var call: TeamCall
    public var added: Date
    /// How many times it was sent without a definite answer.
    public var attempts: Int
    /// What went wrong the last time, for Settings → Team.
    public var lastError: String?
    /// For a change the database decides (TeamBoardWrites.decides): it goes by then, or later only if the database already
    /// has it (lane DB8). Nil for every other change, and in an outbox an earlier Binders saved.
    public var sendBy: Date?

    public var id: UUID { call.operation }

    public init(call: TeamCall, added: Date, attempts: Int = 0, lastError: String? = nil, sendBy: Date? = nil) {
        self.call = call
        self.added = added
        self.attempts = attempts
        self.lastError = lastError
        self.sendBy = sendBy
    }
}

/// What became of a change sent from the outbox.
public enum TeamOutcome: Equatable, Sendable {
    /// The database applied it: its answer.
    case applied(TeamResult)
    /// The database refused it, with its reason: the change didn't happen (a teammate's agent took the card meanwhile).
    case refused(TeamRefusal)
    /// The database turned it down with an error a retry wouldn't change: not allowed, or not valid.
    case failed(String)

    /// The reason, for a change that didn't happen.
    public var reason: String? {
        switch self {
        case .applied: nil
        case .refused(let refusal): refusal.errorDescription
        case .failed(let message): message
        }
    }
}

/// An outbox item's outcome, for whoever made the change (they may have been waiting, or the app may have restarted
/// since).
public struct TeamOutboxOutcome: Equatable, Sendable {
    public var operation: UUID
    public var call: TeamCall
    public var outcome: TeamOutcome

    public init(operation: UUID, call: TeamCall, outcome: TeamOutcome) {
        self.operation = operation
        self.call = call
        self.outcome = outcome
    }
}

public struct TeamOutbox: Equatable, Sendable {
    /// What waits, oldest first.
    public private(set) var items: [TeamOutboxItem]

    public init(items: [TeamOutboxItem] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// What goes next: always the oldest. Nothing goes past an item still waiting for its answer, so changes arrive in
    /// the order they were made.
    public var next: TeamOutboxItem? { items.first }

    /// Queues a change. One already queued under the same operation id isn't queued again; calls that carry a password
    /// are never queued (false), as the file would keep them.
    /// `sendBy`: when a change the database decides stops being worth sending (TeamOutboxItem.sendBy).
    @discardableResult
    public mutating func add(_ call: TeamCall, at date: Date = Date(), sendBy: Date? = nil) -> Bool {
        guard !call.carriesPassword else { return false }
        guard !items.contains(where: { $0.id == call.operation }) else { return true }
        items.append(TeamOutboxItem(call: call, added: date, sendBy: sendBy))
        return true
    }

    /// A definite answer came for `operation`: it leaves the outbox. Returns the item, or nil when it wasn't there (an
    /// answer that arrived twice).
    @discardableResult
    public mutating func settle(_ operation: UUID) -> TeamOutboxItem? {
        guard let index = items.firstIndex(where: { $0.id == operation }) else { return nil }
        return items.remove(at: index)
    }

    /// It was sent and no definite answer came (the connection dropped, or the server asked to try again): it stays
    /// where it is, to go again first.
    public mutating func attempted(_ operation: UUID, error: String?) {
        guard let index = items.firstIndex(where: { $0.id == operation }) else { return }
        items[index].attempts += 1
        items[index].lastError = error
    }

    // MARK: On disk

    private struct File: Codable {
        var version: Int
        var items: [TeamOutboxItem]
        /// The first journal written after it (lane DB10); nil in a file an earlier Binders wrote, which has none.
        var journal: Int?
    }

    /// The outbox as it's saved: JSON, with a version. `journal`: the first journal that goes on from it (lane DB10).
    public func encoded(journal: Int? = nil) throws -> Data {
        // Dates as Date keeps them (seconds since 2001): exactly as they were when read back.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(File(version: 1, items: items, journal: journal))
    }

    /// The outbox as it was saved. Fields a later Binders adds are ignored; a file that can't be read throws, so the
    /// caller keeps it aside rather than lose what was in it.
    public init(data: Data) throws {
        items = try JSONDecoder().decode(File.self, from: data).items
    }

    /// The first journal that goes on from a saved outbox: 0 for one an earlier Binders saved.
    public static func journal(after data: Data) -> Int {
        (try? JSONDecoder().decode(File.self, from: data))?.journal ?? 0
    }

    // MARK: The journal (lane DB10)

    /// What happened to the outbox, one entry at a time: replayed in order on top of the file it goes on from, it gives
    /// the outbox as it was. A Mac appends one line per change instead of writing the whole outbox each time.
    public mutating func apply(_ entry: TeamOutboxEntry) {
        switch entry {
        case .add(let item):
            guard !item.call.carriesPassword, !items.contains(where: { $0.id == item.id }) else { return }
            items.append(item)
        case .settle(let operation):
            settle(operation)
        case .attempted(let operation, let error):
            attempted(operation, error: error)
        }
    }

    /// The entry as one line of the journal: JSON, then a line break.
    public static func line(_ entry: TeamOutboxEntry) throws -> Data {
        var data = try JSONEncoder().encode(entry)
        data.append(0x0A)
        return data
    }

    /// The entries in a journal, in order. A line that can't be read (the last one, cut short by a crash) is skipped and
    /// counted.
    public static func entries(in journal: Data) -> (entries: [TeamOutboxEntry], unread: Int) {
        var entries: [TeamOutboxEntry] = []
        var unread = 0
        let decoder = JSONDecoder()
        for line in journal.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = try? decoder.decode(TeamOutboxEntry.self, from: Data(line)) { entries.append(entry) } else { unread += 1 }
        }
        return (entries, unread)
    }
}

/// One line of the outbox's journal (lane DB10): a change queued, answered, or sent without an answer.
public enum TeamOutboxEntry: Codable, Equatable, Sendable {
    case add(TeamOutboxItem)
    case settle(UUID)
    case attempted(UUID, error: String?)

    private enum Key: String, CodingKey { case add, settle, attempted, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if let item = try container.decodeIfPresent(TeamOutboxItem.self, forKey: .add) {
            self = .add(item)
        } else if let operation = try container.decodeIfPresent(UUID.self, forKey: .settle) {
            self = .settle(operation)
        } else if let operation = try container.decodeIfPresent(UUID.self, forKey: .attempted) {
            self = .attempted(operation, error: try container.decodeIfPresent(String.self, forKey: .error))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an outbox entry"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .add(let item): try container.encode(item, forKey: .add)
        case .settle(let operation): try container.encode(operation, forKey: .settle)
        case .attempted(let operation, let error):
            try container.encode(operation, forKey: .attempted)
            try container.encodeIfPresent(error, forKey: .error)
        }
    }
}

/// Which errors are worth sending a change again for. A server error's SQLSTATE says: a connection, a rollback (a
/// serialization failure or a deadlock), resources, or the server shutting down are; anything else (not allowed, not
/// valid) is the answer, and a retry would get it again.
public enum TeamErrors {
    public static func isRetryable(sqlState: String?) -> Bool {
        guard let state = sqlState, state.count == 5 else { return true }
        return ["08", "40", "53", "57", "58"].contains(String(state.prefix(2)))
    }

    /// What a server error means to whoever made the change, in plain words where Binders knows them.
    public static func describe(sqlState: String?, message: String) -> String {
        switch sqlState {
        case "BD001": "Binders needs to change its one-time password for the team database before it can do anything there."
        case "28P01", "28000": "The team database didn't accept this Mac's login. An admin can give you a new one-time password."
        default: message
        }
    }
}
