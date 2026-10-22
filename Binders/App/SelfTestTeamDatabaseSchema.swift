import Foundation
import PostgresNIO
import BindersKit

extension SelfTest {
    /// The migrations on an empty database and again (nothing to do); what the roles may do; TLS and SCRAM; and a
    /// database newer than this Binders, or with a changed migration, left alone.
    @MainActor
    static func teamDatabaseSchemaChecks(_ bed: TeamDBTestBed) async throws {
        let check = bed.check
        // The setup ran in TeamDBTestBed.start, as Azure's admin login: every migration, the team, its first person.
        check(bed.setupOutcome.applied == TeamSchema.migrations.map(\.version), "the migrations apply to an empty database: \(bed.setupOutcome.applied)")
        check(bed.setupOutcome.madeTeam && bed.sam != nil, "the first setup records the team and admits its first person")
        let again = try await TeamDatabaseSetup.run(bed.setupRequest())
        check(again.applied.isEmpty && !again.madeTeam && again.member == nil, "setting up again applies nothing and adds no one")

        let root = try await bed.root()
        let recorded = try await root.json("""
            SELECT json_agg(json_build_object('version', version, 'checksum', checksum, 'by', applied_by) ORDER BY version)::text
            FROM binders.schema_migrations
            """).array ?? []
        check(recorded.map { $0["version"]?.int ?? 0 } == TeamSchema.migrations.map(\.version)
                && recorded.map { $0["checksum"]?.string ?? "" } == TeamSchema.migrations.map(\.checksum),
              "schema_migrations holds each migration once, with its checksum")
        check(recorded.allSatisfy { $0["by"]?.string == bed.adminLogin }, "applied by the admin login")

        // Every table: row-level security on, and in the feed.
        let tables = try await root.json("""
            SELECT json_agg(json_build_object('name', c.relname, 'rls', c.relrowsecurity, 'owner', pg_get_userbyid(c.relowner),
                'feed', EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid AND t.tgname = c.relname || '_changes')))::text
            FROM pg_class c WHERE c.relnamespace = 'binders'::regnamespace AND c.relkind = 'r'
            """).array ?? []
        let byName = Dictionary(tables.compactMap { row in row["name"]?.string.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        check(Set(byName.keys) == Set(TeamTable.allCases.map(\.rawValue)), "the schema has exactly the tables Binders knows: \(byName.keys.sorted())")
        check(TeamTable.allCases.allSatisfy { byName[$0.rawValue]?["rls"]?.bool == true }, "row-level security is on for every table")
        check(TeamTable.allCases.allSatisfy { ($0.inFeed) == (byName[$0.rawValue]?["feed"]?.bool == true) },
              "every table but the feed's own bookkeeping writes to the changes feed")
        let roles = TeamSchema.roleNames(database: bed.database)
        check(tables.allSatisfy { $0["owner"]?.string == roles.owner }, "the owner role owns every table")

        // What the team role may do: read, and run the public functions; never write a table.
        let privileges = try await root.json("""
            SELECT json_build_object(
                'writes', (SELECT count(*) FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
                           WHERE c.relnamespace = 'binders'::regnamespace AND c.relkind = 'r' AND has_table_privilege($1, c.oid, p)),
                'reads', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'binders'::regnamespace AND c.relkind = 'r'
                          AND has_table_privilege($1, c.oid, 'SELECT')),
                'public_functions', (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'binders'::regnamespace AND left(p.proname, 1) <> '_'),
                'runs_public', (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'binders'::regnamespace AND left(p.proname, 1) <> '_'
                                AND has_function_privilege($1, p.oid, 'EXECUTE')),
                'runs_internal', (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'binders'::regnamespace AND left(p.proname, 1) = '_'
                                  AND p.prokind = 'f' AND has_function_privilege($1, p.oid, 'EXECUTE')),
                'public_may', (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'binders'::regnamespace
                               AND has_function_privilege('public', p.oid, 'EXECUTE')),
                'member_of_owner', pg_has_role('sam', $2, 'MEMBER'),
                'definers_pinned', (SELECT bool_and(p.proconfig IS NOT NULL) FROM pg_proc p
                                    WHERE p.pronamespace = 'binders'::regnamespace AND p.prosecdef))::text
            """, [roles.team, roles.owner])
        check(privileges["writes"]?.int == 0, "the team role can't insert, update, delete or truncate any table")
        check(privileges["reads"]?.int == TeamTable.allCases.count, "the team role reads every table (row-level security filters)")
        check(privileges["runs_public"]?.int == privileges["public_functions"]?.int && (privileges["public_functions"]?.int ?? 0) > 30,
              "the team role runs every public function (\(privileges["public_functions"]?.int ?? 0))")
        check(privileges["runs_internal"]?.int == 0, "and none of the internal ones")
        check(privileges["public_may"]?.int == 0, "PUBLIC runs nothing")
        check(privileges["member_of_owner"]?.bool == false, "a member can't act as the owner")
        check(privileges["definers_pinned"]?.bool == true, "every function that runs as the owner pins its search_path")

        // Connecting: TLS with the certificate and its name checked, and logins checked with SCRAM-SHA-256.
        let password = Keychain.read(TeamDatabase.passwordKey(bed.sam)) ?? ""
        check(!password.isEmpty, "the first person's password is in the Keychain, under AgentRegistry's naming")
        let hba = try await root.json("""
            SELECT json_agg(json_build_object('type', type, 'method', auth_method))::text FROM pg_hba_file_rules WHERE error IS NULL
            """).array ?? []
        check(!hba.isEmpty && hba.allSatisfy { $0["type"]?.string == "hostssl" && $0["method"]?.string == "scram-sha-256" },
              "the server takes only encrypted connections, checked with SCRAM-SHA-256")
        let stored = try await root.value("SELECT rolpassword FROM pg_authid WHERE rolname = 'sam'", as: String.self) ?? ""
        check(stored.hasPrefix("SCRAM-SHA-256$4096:") && !stored.contains(password), "a member's password is stored only as a SCRAM verifier")
        let plain = await bed.failure {
            var configuration = PostgresConnection.Configuration(host: "127.0.0.1", port: bed.postgres.port, username: "sam",
                                                                 password: password, database: bed.database, tls: .disable)
            configuration.options.connectTimeout = .seconds(5)
            let connection = try await PostgresConnection.connect(configuration: configuration, id: 1, logger: Logging.Logger(label: "selftest"))
            try? await connection.close()
        }
        check(plain != nil, "an unencrypted connection is turned away (\(plain ?? "connected"))")
        let untrusted = await bed.failure {
            let link = try await TeamDatabaseLink.connect(to: bed.sam, password: password, trust: .system)
            await link.close()
        }
        check(untrusted != nil, "a certificate the Mac's trust store doesn't vouch for is refused")
        var elsewhere = bed.sam!
        elsewhere.serverName = "elsewhere.example"
        let wrongName = await bed.failure {
            let link = try await TeamDatabaseLink.connect(to: elsewhere, password: password, trust: bed.postgres.trust)
            await link.close()
        }
        check(wrongName != nil, "a certificate for another name is refused")
        let wrongPassword = await bed.failure {
            let link = try await TeamDatabaseLink.connect(to: bed.sam, password: "not-it", trust: bed.postgres.trust)
            await link.close()
        }
        check(wrongPassword == "28P01", "a wrong password is turned down (\(wrongPassword ?? "accepted"))")

        let client = bed.client(bed.sam)
        try await bed.waitConnected(client)
        check(client.status == .connected && client.member?["name"]?.string == "Sam", "TeamDatabase connects with the Keychain's password")
        check(client.team?["embedding_dimension"]?.int == 768 && client.team?["team_role"] == nil,
              "it knows the team's pinned model, and not its role names")
        await client.stop()

        // A database newer than this Binders, or with a migration changed, is left alone, by the setup and by a member's Mac.
        try await root.execute("INSERT INTO binders.schema_migrations (version, name, checksum) VALUES (\(TeamSchema.latest + 1), 'later', 'x')")
        let newer = await bed.failure { _ = try await TeamDatabaseSetup.run(bed.setupRequest()) }
        check(newer?.contains("updated by a newer version of Binders") == true, "the setup refuses a database a newer Binders updated")
        let refusing = bed.client(bed.sam, folder: "sam-newer")
        refusing.start()
        let refused = await bed.eventually(10) {
            if case .offline(_, let reason, false) = refusing.status { return reason.contains("Update Binders on this Mac to connect") }
            return false
        }
        check(refused, "a member's Mac won't work against it, and says to update Binders: \(refusing.status.summary())")
        await refusing.stop()
        try await root.execute("DELETE FROM binders.schema_migrations WHERE version = \(TeamSchema.latest + 1)")
        try await root.execute("UPDATE binders.schema_migrations SET checksum = 'by hand' WHERE version = 2")
        let changed = await bed.failure { _ = try await TeamDatabaseSetup.run(bed.setupRequest()) }
        check(changed?.contains("Update 2 to the team") == true, "the setup refuses a database whose migration 2 was changed")
        try await root.execute("UPDATE binders.schema_migrations SET checksum = '\(TeamSchema.migrations[1].checksum)' WHERE version = 2")
        let applied = try await TeamDatabaseSetup.run(bed.setupRequest())
        check(applied.applied.isEmpty, "put back, it's up to date again")

        // A server older than 15, or one without the right to make roles, is turned down before anything changes.
        let weak = "weak_admin"
        let weakPassword = TeamPassword.generate()
        try await root.execute("CREATE ROLE \(weak) LOGIN PASSWORD '\(TeamPassword.verifier(for: weakPassword))'")
        var request = bed.setupRequest()
        request.adminLogin = weak
        request.adminPassword = weakPassword
        let noRoles = await bed.failure { _ = try await TeamDatabaseSetup.run(request) }
        check(noRoles?.contains("mayNotMakeRoles") == true, "a login that can't make roles can't set up a team (\(noRoles ?? "set up"))")
    }
}
