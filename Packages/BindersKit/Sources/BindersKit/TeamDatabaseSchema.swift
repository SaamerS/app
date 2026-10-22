import CryptoKit
import Foundation

// The team database's shape, the same on every Mac: its tables, the numbered migrations Binders applies itself (on any
// Postgres 15 or later), and the statements a setup runs with an admin login. The Mac's TeamDatabaseSetup runs them;
// everything here is pure, so it's tested without a database.

/// A table of the team database (schema `binders`).
public enum TeamTable: String, CaseIterable, Codable, Sendable {
    case teamSettings = "team_settings"
    case members
    case binders
    case binderMembers = "binder_members"
    case agents
    case folders
    case cards
    case cardDependencies = "card_dependencies"
    case cardEvents = "card_events"
    case notes
    case noteChanges = "note_changes"
    case noteVersions = "note_versions"
    /// Who is in a note now (migration 6).
    case notePresence = "note_presence"
    case meetings
    case meetingSegments = "meeting_segments"
    case captures
    case captureSegments = "capture_segments"
    case knowledgeChunks = "knowledge_chunks"
    case entities
    case relations
    case corrections
    case distills
    case distillItems = "distill_items"
    case todos
    case changes
    case operations
    case schemaMigrations = "schema_migrations"

    /// Whose rows these are, which is what row-level security reads.
    public enum Scope: Sendable {
        /// Each row belongs to a binder (`binder_id`; a binder's own row is its binder), and only that binder's members
        /// see it.
        case binder
        /// The whole team sees every row: the team's settings, its members and its agents.
        case team
        /// The database's own records: the feed, operation ids, migrations.
        case bookkeeping
    }

    public var scope: Scope {
        switch self {
        case .teamSettings, .members, .agents: .team
        case .changes, .operations, .schemaMigrations: .bookkeeping
        default: .binder
        }
    }

    /// The column holding a row's binder, for binder tables.
    public var binderColumn: String? {
        switch scope {
        case .binder: self == .binders ? "id" : "binder_id"
        case .team, .bookkeeping: nil
        }
    }

    /// Rows that are only ever added to.
    public var onlyAdded: Bool { [.cardEvents, .noteChanges, .meetingSegments, .captureSegments].contains(self) }

    /// Tables written through put_row / put_rows / delete_row. The rest have functions of their own (the board's
    /// actions, binders, members, agents) or aren't written by callers at all.
    public var writtenByRows: Bool {
        [.folders, .notes, .noteChanges, .noteVersions, .meetings, .meetingSegments, .captures, .captureSegments, .knowledgeChunks,
         .entities, .relations, .corrections, .distills, .distillItems, .todos].contains(self)
    }

    /// Whether a change to its rows shows in the feed.
    public var inFeed: Bool { scope != .bookkeeping }

    /// The binder tables, in the order a full read takes them: what other rows point at first.
    public static let binderTables: [TeamTable] = [.binders, .binderMembers, .folders, .cards, .cardDependencies, .cardEvents, .notes,
                                                   .noteChanges, .noteVersions, .notePresence, .meetings, .meetingSegments, .captures, .captureSegments,
                                                   .knowledgeChunks, .entities, .relations, .corrections, .distills, .distillItems, .todos]
}

/// One numbered migration: SQL that Binders applies once, in order, and never changes after it has shipped.
public struct TeamMigration: Equatable, Sendable {
    public let version: Int
    public let name: String
    public let sql: String

    public init(version: Int, name: String, sql: String) {
        self.version = version
        self.name = name
        self.sql = sql
    }

    /// SHA-256 of its SQL, in hex: kept with it in `schema_migrations`, so a database whose migration was changed by
    /// hand is noticed.
    public var checksum: String {
        SHA256.hash(data: Data(sql.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A migration a database says it has applied.
public struct TeamAppliedMigration: Equatable, Sendable, Decodable {
    public let version: Int
    public let checksum: String

    public init(version: Int, checksum: String) {
        self.version = version
        self.checksum = checksum
    }
}

/// What to do with a database, given the migrations it has applied.
public enum TeamMigrationPlan: Equatable, Sendable {
    /// It has every migration this Binders knows, and no others.
    case upToDate
    /// These still need applying, in this order.
    case apply([Int])
    /// It was updated by a newer Binders: this one refuses to touch it, or work with it.
    case newer(database: Int, known: Int)
    /// A migration it applied isn't the one this Binders has under that number (changed by hand, or a test build's).
    case changed(version: Int)
    /// It skips a number, which no Binders does.
    case missing(version: Int)

    /// What's wrong, in words for Settings → Team; nil when there's nothing to refuse. Plain words: an update to the
    /// team's database, never a schema or a migration.
    public var problem: String? {
        switch self {
        case .upToDate, .apply: nil
        case .newer:
            "The team's database was updated by a newer version of Binders. Update Binders on this Mac to connect."
        case .changed(let version):
            "Update \(version) to the team's database isn't the one this version of Binders has, so Binders leaves the database alone. An admin can compare it with Binders' own."
        case .missing(let version):
            "The team's database is missing update \(version), so Binders leaves it alone."
        }
    }
}

public enum TeamSchema {
    /// Every migration, in order.
    public static let migrations: [TeamMigration] = [migration1, migration2, migration3, migration4, migration5, migration6, migration7,
                                                      migration8]

    /// The schema this Binders knows: the last migration's number.
    public static var latest: Int { migrations.last?.version ?? 0 }

    /// The oldest Postgres the migrations run on: 15 (`UNIQUE NULLS NOT DISTINCT`, and CREATEROLE as it works there).
    public static let oldestServer = 150_000

    /// The channel the database notifies on, after every transaction that changed something, with only a number.
    public static let channel = "binders_changes"

    /// What a database needs, given the migrations it applied (`applied`, any order): refuses a newer database, one
    /// whose migrations differ from these, or one that skips a number.
    public static func plan(applied: [TeamAppliedMigration], known: [TeamMigration] = migrations) -> TeamMigrationPlan {
        let byVersion = Dictionary(applied.map { ($0.version, $0.checksum) }, uniquingKeysWith: { first, _ in first })
        let knownLatest = known.last?.version ?? 0
        if let newest = byVersion.keys.max(), newest > knownLatest { return .newer(database: newest, known: knownLatest) }
        var pending: [Int] = []
        for migration in known {
            if let checksum = byVersion[migration.version] {
                if checksum != migration.checksum { return .changed(version: migration.version) }
                if let first = pending.first { return .missing(version: first) }
            } else {
                pending.append(migration.version)
            }
        }
        return pending.isEmpty ? .upToDate : .apply(pending)
    }

    // MARK: Names

    /// A role or login name Binders makes: 2 to 63 lower-case letters, digits or underscores, starting with a letter.
    /// The database checks it again.
    public static func isValidRoleName(_ name: String) -> Bool {
        name.range(of: "^[a-z][a-z0-9_]{1,62}$", options: .regularExpression) != nil
    }

    /// The team's two roles, named after its database: `<database>_owner` owns everything, `<database>_team` holds
    /// every member's login. Roles belong to the whole server, so two teams' databases on one server don't share them.
    public static func roleNames(database: String) -> (owner: String, team: String) {
        var base = database.lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
        while base.contains("__") { base = base.replacingOccurrences(of: "__", with: "_") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if base.first.map({ !$0.isLetter }) ?? true { base = "binders_" + base }
        base = String(base.prefix(56)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return (base + "_owner", base + "_team")
    }

    /// A name no member may have: the user's own on the board ("You", BoardRules.isReserved) or Binders'.
    public static func isReservedName(_ name: String) -> Bool {
        BoardRules.isReserved(name) || name.trimmingCharacters(in: .whitespaces).lowercased() == "binders"
    }
}
