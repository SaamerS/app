import Foundation

/// The reads a Mac sends, each answered as one JSON text, so the Mac reads every table the same way. Row-level security
/// filters every one of them: a member reads only binders shared with them. Values are bound as text, as calls' are.
public enum TeamQueries {
    /// A page of the feed after `seq`, oldest first ($1 seq, $2 how many).
    public static let changesAfter = """
        SELECT coalesce(json_agg(c ORDER BY c.seq), '[]')::text FROM (\
        SELECT seq, binder_id, table_name, row_id, kind, member_id, at FROM binders.changes \
        WHERE seq > $1::bigint ORDER BY seq LIMIT $2::integer) c
        """

    /// The last number of the feed this member sees, or 0.
    public static let lastSeq = "SELECT coalesce(max(seq), 0)::bigint FROM binders.changes"

    /// The binders this member sees, as a JSON array of ids.
    public static let visibleBinders = "SELECT array_to_json(binders.my_binder_ids())::text"

    /// Who this login is: its member (and agent, for a headless agent's login), the team, the schema, its binders.
    public static let whoami = "SELECT binders.whoami()::text"

    /// The team's admins other than this login's member, by name: who can update the team's database. Read on any
    /// database Binders set up, whatever its migrations.
    public static let otherAdmins = """
        SELECT coalesce(json_agg(name ORDER BY lower(name), name), '[]')::text FROM binders.members \
        WHERE kind = 'person' AND is_admin AND deleted_at IS NULL AND login <> session_user
        """

    /// A page of a binder's rows in `table`, by id ($1 binder, $2 after this id or null, $3 how many).
    public static func rows(_ table: TeamTable) -> String? {
        guard let column = table.binderColumn else { return nil }
        return """
            SELECT coalesce(json_agg(r ORDER BY r ->> 'id'), '[]')::text FROM (\
            SELECT to_jsonb(t) - 'tsv' AS r FROM binders.\(table.rawValue) t \
            WHERE t.\(column) = $1::uuid AND ($2::uuid IS NULL OR t.id > $2::uuid) ORDER BY t.id LIMIT $3::integer) page
            """
    }

    /// Rows of `table` by id ($1, a JSON array of ids): what a batch of changes reads. Rows the member can't see aren't
    /// in the answer.
    public static func rows(byID table: TeamTable) -> String {
        rows(byID: table, leaving: [])
    }

    /// Rows by id, without these columns (lane DB10: a note's row without its document and body, which a Mac that
    /// already has the note doesn't need).
    public static func rows(byID table: TeamTable, leaving columns: [String]) -> String {
        let leaving = (["tsv"] + columns).map { " - '\($0)'" }.joined()
        return """
            SELECT coalesce(json_agg(to_jsonb(t)\(leaving)), '[]')::text FROM binders.\(table.rawValue) t \
            WHERE t.id = ANY (ARRAY(SELECT jsonb_array_elements_text($1::jsonb)::uuid))
            """
    }

    /// What a feed read leaves out of a note's row (lane DB10): its document and its words, read only when this Mac makes
    /// the note's document from the row (`TeamNoteRow.isWhole`).
    public static let noteRowHeavyColumns = ["document", "body"]

    /// Every row of a team table (members, agents, the team's settings): small, read whole.
    public static func all(_ table: TeamTable) -> String? {
        guard table.scope == .team else { return nil }
        return "SELECT coalesce(json_agg(to_jsonb(t)), '[]')::text FROM binders.\(table.rawValue) t"
    }

    /// How many rows a page holds.
    public static let pageSize = 500

    /// A snapshot is read in one transaction that sees one moment: the feed's number first, then every table.
    public static let beginSnapshot = "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY"
    public static let endSnapshot = "COMMIT"

    /// The session every Mac connection starts with: times in UTC, so they read back the same everywhere; and (lane DB8) a
    /// transaction this Mac leaves open without a word for 30 seconds is ended by the server, and the server checks that a
    /// quiet connection is still there as the Mac does (after 30 s, every 10 s, 3 times), so a Mac that dropped off the
    /// network in the middle of a change never holds a card's row locked for long.
    public static let sessionSetup = """
        SELECT set_config('TimeZone', 'UTC', false), set_config('idle_in_transaction_session_timeout', '30s', false), \
        set_config('tcp_keepalives_idle', '30', false), set_config('tcp_keepalives_interval', '10', false), \
        set_config('tcp_keepalives_count', '3', false)
        """

    /// Whether the database has an answer for one of this member's operation ids (RLS shows each member only their own):
    /// a change the database decides, left in the outbox past its time, goes again only then (lane DB8).
    public static let operationKnown = "SELECT EXISTS (SELECT 1 FROM binders.operations WHERE op_id = $1::uuid)"

    /// Whether the connection is encrypted, as the server sees it.
    public static let usesTLS = "SELECT coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false)"

    /// A ping: the connection is alive.
    public static let ping = "SELECT 1"
}
