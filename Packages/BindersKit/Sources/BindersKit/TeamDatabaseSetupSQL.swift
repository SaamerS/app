import Foundation

/// What Set up a team database runs with an admin login, used once and never kept: the checks first, then one
/// transaction that makes the team's two roles and its schema, applies the migrations the database lacks, and, the first
/// time, records the team, pins its embedding model and admits the first person. Running it again applies only what's
/// new, so updating a team to a newer Binders is the same step. The Mac's TeamDatabaseSetup runs these in order.
public enum TeamSetupSQL {
    /// Held for the whole setup, so two admins setting up at once take turns.
    public static let lockKey: Int64 = 7_311_960_516_743_086_922

    // MARK: Checks, before anything changes

    /// The server's version, as a number: 170004 for 17.4.
    public static let serverVersion = "SELECT current_setting('server_version_num')::integer"

    /// Whether pgvector can be turned on in this database (on Azure: listed in `azure.extensions`).
    public static let vectorAvailable = "SELECT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'vector')"

    /// Whether the admin login may make roles.
    public static let mayMakeRoles = "SELECT rolsuper OR rolcreaterole FROM pg_roles WHERE rolname = current_user"

    /// The migrations a database applied, as JSON: `[{"version": 1, "checksum": "…"}]`. Fails with 42P01 when the
    /// database was never set up.
    public static let applied = """
        SELECT coalesce(json_agg(json_build_object('version', version, 'checksum', checksum) ORDER BY version), '[]')::text \
        FROM binders.schema_migrations
        """

    // MARK: The transaction

    public static let begin = "BEGIN"
    public static let lock = "SELECT pg_advisory_xact_lock(\(lockKey))"
    public static let createExtension = "CREATE EXTENSION IF NOT EXISTS vector"

    /// The schema pgvector lives in, which the migrations' search path includes.
    public static let vectorSchema = """
        SELECT n.nspname::text FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'vector'
        """

    /// The two role names, for the blocks that follow ($1 owner, $2 team).
    public static let names = "SELECT set_config('binders.setup_owner', $1, true), set_config('binders.setup_team', $2, true)"

    /// As the admin: the owner role (NOLOGIN, CREATEROLE), granted to the admin so it can act as it, and the schema it
    /// owns. A role of that name made by someone else, that the admin can't grant itself, stops the setup here.
    public static let ownerRole = """
        DO $setup$
        DECLARE
            v_owner text := current_setting('binders.setup_owner');
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_owner) THEN
                EXECUTE format('CREATE ROLE %I NOLOGIN CREATEROLE', v_owner);
            END IF;
            EXECUTE format('GRANT %I TO %I', v_owner, current_user);
            EXECUTE format('CREATE SCHEMA IF NOT EXISTS binders AUTHORIZATION %I', v_owner);
        END $setup$
        """

    /// From here on as the owner, so what the migrations make is the owner's.
    public static func becomeOwner(_ owner: String) -> String? {
        TeamSchema.isValidRoleName(owner) ? "SET LOCAL ROLE \"\(owner)\"" : nil
    }

    /// As the owner: the team's group role, made by the owner so it may add logins to it (Postgres 16 and later ask
    /// that of whoever adds them).
    public static let teamRole = """
        DO $setup$
        DECLARE
            v_team text := current_setting('binders.setup_team');
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_team) THEN
                EXECUTE format('CREATE ROLE %I NOLOGIN', v_team);
            END IF;
        END $setup$
        """

    /// The record of what was applied, made before the first migration.
    public static let migrationsTable = """
        CREATE TABLE IF NOT EXISTS binders.schema_migrations (
            version integer PRIMARY KEY,
            name text NOT NULL,
            checksum text NOT NULL,
            applied_at timestamptz NOT NULL DEFAULT now(),
            applied_by text NOT NULL DEFAULT session_user
        )
        """

    /// The migrations' search path: the catalog, the schema, and wherever pgvector lives.
    public static func searchPath(vectorSchema: String) -> String {
        "SET LOCAL search_path = pg_catalog, binders, \"\(vectorSchema.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// A migration's SQL goes in a setting ($1), then runs inside a block: the server takes many statements at once only
    /// that way, and the SQL never has to be quoted.
    public static let loadMigration = "SELECT set_config('binders.migration', $1, true) IS NOT NULL"
    public static let runMigration = "DO $setup$ BEGIN EXECUTE current_setting('binders.migration'); END $setup$"
    public static let recordMigration = "INSERT INTO binders.schema_migrations (version, name, checksum) VALUES ($1::integer, $2, $3)"

    /// Whether the team was already recorded: a setup run again only updates.
    public static let teamExists = "SELECT EXISTS (SELECT 1 FROM binders.team_settings)"

    /// The first time: the team ($1 name, $2 team role, $3 owner role, $4 embedding model, $5 its dimension), the vector
    /// column for that dimension, and the first person ($1 id, $2 login, $3 name, $4 SCRAM verifier).
    public static let setupTeam = "SELECT binders._setup_team($1, $2, $3, $4, $5::integer)"
    public static let pinEmbedding = "SELECT binders._pin_embedding($1, $2::integer, false)"
    public static let firstMember = "SELECT binders._add_first_member($1::uuid, $2, $3, $4)"

    /// Every time: what the team role may do, for everything the migrations made.
    public static let grant = "SELECT binders._grant_team()"

    public static let commit = "COMMIT"
    public static let rollback = "ROLLBACK"
}

/// The embedding model a team pins when its database is set up, and how many numbers it gives: the knowledge vector
/// column's dimension. Binders embeds with EmbeddingGemma 300M today, which gives 768 (Ollama's `embeddinggemma`, the
/// default, and MLX's `mlx-community/embeddinggemma-300m-4bit`).
public struct TeamEmbeddingPin: Equatable, Sendable, Codable {
    public var model: String
    public var dimension: Int

    public init(model: String, dimension: Int) {
        self.model = model
        self.dimension = dimension
    }

    public static let `default` = TeamEmbeddingPin(model: "embeddinggemma", dimension: 768)

    /// The dimension of the embedding models Binders offers, by the name its settings give them; nil for another
    /// model, whose dimension whoever sets up the team says.
    public static func knownDimension(of model: String) -> Int? {
        let name = model.lowercased()
        return name.contains("embeddinggemma") ? 768 : nil
    }
}
