import XCTest
@testable import BindersKit

/// The team database's pure parts: the migration list, operation ids and calls, the changes feed's decoding, results,
/// the outbox, passwords and status. The Mac's `--selftest-teamdb-…` runs them against a real Postgres.
final class TeamDatabaseTests: XCTestCase {
    private var allSQL: String { TeamSchema.migrations.map(\.sql).joined(separator: "\n") }

    // MARK: The migration list

    func testMigrationsAreNumberedInOrderWithChecksums() {
        let versions = TeamSchema.migrations.map(\.version)
        XCTAssertEqual(versions, Array(1...versions.count), "numbered 1, 2, 3… with none skipped")
        XCTAssertEqual(TeamSchema.latest, versions.last)
        XCTAssertEqual(Set(TeamSchema.migrations.map(\.checksum)).count, versions.count)
        for migration in TeamSchema.migrations {
            XCTAssertEqual(migration.checksum.count, 64)
            XCTAssertEqual(migration.checksum, migration.checksum, "the same every time")
            XCTAssertFalse(migration.name.isEmpty)
            // Applied inside one transaction, as one block: no transaction control, nothing that can't run in one.
            for forbidden in ["BEGIN;", "COMMIT;", "ROLLBACK;", "CONCURRENTLY", "VACUUM"] {
                XCTAssertFalse(migration.sql.uppercased().contains(forbidden), "migration \(migration.version) has \(forbidden)")
            }
        }
    }

    func testThePlanAppliesWhatsMissingAndRefusesANewerOrChangedDatabase() {
        let known = TeamSchema.migrations
        let applied = known.map { TeamAppliedMigration(version: $0.version, checksum: $0.checksum) }
        XCTAssertEqual(TeamSchema.plan(applied: []), .apply(known.map(\.version)), "an empty database gets everything")
        XCTAssertEqual(TeamSchema.plan(applied: applied), .upToDate, "applied again, nothing")
        XCTAssertEqual(TeamSchema.plan(applied: Array(applied.prefix(2))), .apply(Array(known.map(\.version).dropFirst(2))))
        XCTAssertEqual(TeamSchema.plan(applied: applied.reversed()), .upToDate, "in any order")
        let newer = applied + [TeamAppliedMigration(version: TeamSchema.latest + 1, checksum: "later")]
        XCTAssertEqual(TeamSchema.plan(applied: newer), .newer(database: TeamSchema.latest + 1, known: TeamSchema.latest))
        XCTAssertNotNil(TeamSchema.plan(applied: newer).problem)
        var changed = applied
        changed[1] = TeamAppliedMigration(version: 2, checksum: "by hand")
        XCTAssertEqual(TeamSchema.plan(applied: changed), .changed(version: 2))
        XCTAssertEqual(TeamSchema.plan(applied: [applied[0], applied[2]]), .missing(version: 2), "a gap isn't filled in")
        XCTAssertNil(TeamSchema.plan(applied: applied).problem)
    }

    func testEveryTableIsMadeGuardedAndInTheFeed() {
        let sql = allSQL
        for table in TeamTable.allCases where table != .schemaMigrations {
            XCTAssertTrue(sql.contains("CREATE TABLE binders.\(table.rawValue) ("), "\(table) is made by a migration")
        }
        XCTAssertTrue(TeamSetupSQL.migrationsTable.contains("binders.schema_migrations"), "the setup makes the migrations' own table")
        // Row-level security on every table: binder tables through _guard, the rest by hand.
        for table in TeamTable.allCases {
            let guarded = table.scope == .binder
                ? sql.contains("_guard('\(table.rawValue)', '\(table.binderColumn ?? "")')") || sql.contains("'\(table.rawValue)'")
                : sql.contains("ALTER TABLE binders.\(table.rawValue) ENABLE ROW LEVEL SECURITY")
            XCTAssertTrue(guarded, "\(table) has row-level security")
        }
        // In the changes feed: every table but the bookkeeping ones.
        for table in TeamTable.allCases where table.inFeed {
            XCTAssertTrue(sql.contains("_track('\(table.rawValue)'") || sql.contains("'\(table.rawValue)'"), "\(table) is in the feed")
        }
        XCTAssertFalse(sql.contains("_track('changes'"), "the feed doesn't feed itself")
        XCTAssertFalse(sql.contains("_track('operations'"))
        XCTAssertEqual(TeamTable.binderTables.count, TeamTable.allCases.filter { $0.scope == .binder }.count)
    }

    func testFunctionsCheckWhoCallsAndTakeAnOperationID() throws {
        let sql = allSQL
        // Functions a later migration replaces are checked as their first versions are.
        let regex = try NSRegularExpression(pattern: #"CREATE (?:OR REPLACE )?FUNCTION binders\.([a-z_]+)\(([^)]*)\)"#)
        let matches = regex.matches(in: sql, range: NSRange(sql.startIndex..., in: sql))
        XCTAssertGreaterThan(matches.count, 60)
        let reads: Set<String> = ["me", "my_binder_ids", "whoami", "search_knowledge"]
        let types = Set(TeamTable.allCases.map(\.rawValue) + ["actor"])
        for match in matches {
            let name = String(sql[Range(match.range(at: 1), in: sql)!])
            let parameters = String(sql[Range(match.range(at: 2), in: sql)!])
            if name.hasPrefix("_") {
                // Never `_<type>`: every type has an array type of that name, and the call would read as a cast.
                XCTAssertFalse(types.contains(String(name.dropFirst())), "binders.\(name) would be a cast")
                continue
            }
            if reads.contains(name) { continue }
            XCTAssertTrue(parameters.hasPrefix("p_op uuid"), "binders.\(name) takes an operation id first")
        }
        // Every function that runs as the owner says where it looks names up.
        let definers = sql.components(separatedBy: "SECURITY DEFINER").dropFirst()
        XCTAssertGreaterThan(definers.count, 40)
        for part in definers { XCTAssertTrue(part.hasPrefix(" SET search_path = pg_catalog, binders"), String(part.prefix(80))) }
    }

    func testRoleNamesFollowTheDatabase() {
        XCTAssertTrue(TeamSchema.roleNames(database: "binders") == ("binders_owner", "binders_team"))
        XCTAssertTrue(TeamSchema.roleNames(database: "Harbor Team") == ("harbor_team_owner", "harbor_team_team"))
        XCTAssertTrue(TeamSchema.roleNames(database: "2026") == ("binders_2026_owner", "binders_2026_team"))
        let long = TeamSchema.roleNames(database: String(repeating: "a", count: 80))
        XCTAssertTrue(TeamSchema.isValidRoleName(long.owner) && TeamSchema.isValidRoleName(long.team))
        XCTAssertTrue(TeamSchema.isValidRoleName("sam"))
        XCTAssertFalse(TeamSchema.isValidRoleName("Sam"))
        XCTAssertFalse(TeamSchema.isValidRoleName("s"))
        XCTAssertFalse(TeamSchema.isValidRoleName("sam; drop"))
        XCTAssertTrue(TeamSchema.isReservedName("You") && TeamSchema.isReservedName("you two") && TeamSchema.isReservedName("Binders"))
        XCTAssertFalse(TeamSchema.isReservedName("Youssef"))
        XCTAssertNil(TeamSetupSQL.becomeOwner("x\"; RESET ROLE; --"), "only a plain role name goes into the statement")
        XCTAssertEqual(TeamSetupSQL.becomeOwner("binders_owner"), "SET LOCAL ROLE \"binders_owner\"")
        XCTAssertEqual(TeamEmbeddingPin.default, TeamEmbeddingPin(model: "embeddinggemma", dimension: 768))
        XCTAssertEqual(TeamEmbeddingPin.knownDimension(of: "mlx-community/embeddinggemma-300m-4bit"), 768)
    }

    // MARK: Operation ids and calls

    func testCallsRenderToOneStatementWithTheirOperationIDFirst() throws {
        let card = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
        let operation = UUID(uuidString: "10000000-0000-0000-0000-000000000007")!
        let call = TeamCall.claimCard(card, note: "Holding it for Agent A", operation: operation)
        let statement = try XCTUnwrap(call.statement)
        XCTAssertEqual(statement.sql, "SELECT binders.claim_card(p_op => $1::uuid, p_card => $2::uuid, p_agent => $3::uuid, p_note => $4::text)::text")
        XCTAssertEqual(statement.values, ["10000000-0000-0000-0000-000000000007", "d0000000-0000-0000-0000-000000000001", nil, "Holding it for Agent A"])
        let report = try XCTUnwrap(TeamCall.report(card, progress: "Done", links: ["https://example.com/a"], renewing: false).statement)
        XCTAssertTrue(report.sql.contains("p_links => $4::jsonb") && report.sql.contains("p_renewing => $6::boolean"), report.sql)
        XCTAssertEqual(report.values[3], #"["https://example.com/a"]"#)
        XCTAssertEqual(report.values[5], "false")
        // Nothing from a call can change the statement.
        XCTAssertNil(TeamCall(function: "claim_card(); DROP", arguments: []).statement)
        XCTAssertNil(TeamCall(function: "claim_card", arguments: [TeamArgument("p_card", "uuid); --", "x")]).statement)
        XCTAssertNil(TeamCall(function: "claim_card", arguments: [TeamArgument("p card", "uuid", "x")]).statement)
        // Kept in the outbox and read back, it's the same call, with the same operation id.
        let data = try JSONEncoder().encode(call)
        XCTAssertEqual(try JSONDecoder().decode(TeamCall.self, from: data), call)
        XCTAssertEqual(call.again(operation: card).operation, card)
        XCTAssertNotEqual(TeamCall.claimCard(card).operation, TeamCall.claimCard(card).operation, "a new change, a new id")
    }

    func testDerivedOperationIDsAreStableVersionFiveUUIDs() {
        let first = TeamOperationID.derived("import card D0000000")
        XCTAssertEqual(first, TeamOperationID.derived("import card D0000000"), "the same name, the same id")
        XCTAssertNotEqual(first, TeamOperationID.derived("import card D0000001"))
        let bytes = withUnsafeBytes(of: first.uuid) { Array($0) }
        XCTAssertEqual(bytes[6] >> 4, 5, "version 5")
        XCTAssertEqual(bytes[8] >> 6, 0b10, "the RFC 4122 variant")
        // RFC 4122's own example: the DNS namespace and "www.example.com".
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(TeamOperationID.derived("www.example.com", in: dns).uuidString.lowercased(), "2ed6657d-e927-568b-95e1-2665a8aea6a2")
    }

    func testPasswordsGoOnlyAsVerifiersAndNeverInTheOutbox() {
        let add = TeamCall.addMember(UUID(), login: "alex", name: "Alex", verifier: TeamPassword.verifier(for: "k7Rf-29xQ"))
        XCTAssertTrue(add.carriesPassword)
        var outbox = TeamOutbox()
        XCTAssertFalse(outbox.add(add), "a password call is sent at once, never kept on disk")
        XCTAssertTrue(outbox.isEmpty)
        XCTAssertFalse(add.statement?.values.contains("k7Rf-29xQ") ?? true, "the password itself isn't sent")
    }

    // MARK: The changes feed

    func testChangesDecodeFromTheFeedAndNotificationsCarryOnlyANumber() throws {
        let json = """
            [{"seq": 41, "binder_id": "b0000000-0000-0000-0000-000000000001", "table_name": "cards",
              "row_id": "d0000000-0000-0000-0000-000000000001", "kind": "update", "member_id": "00000000-0000-0000-0000-00000000000a",
              "at": "2026-10-21T10:42:00.123456+00:00"},
             {"seq": 42, "binder_id": null, "table_name": "members", "row_id": "a0000000-0000-0000-0000-00000000000b",
              "kind": "insert", "member_id": null, "at": "2026-10-21T10:42:01+01:00"},
             {"seq": 43, "binder_id": "b0000000-0000-0000-0000-000000000001", "table_name": "a_later_table",
              "row_id": "e0000000-0000-0000-0000-000000000001", "kind": "merged", "extra": true},
             {"seq": "not a number"}]
            """
        let changes = try XCTUnwrap(TeamChange.list(json: json))
        XCTAssertEqual(changes.count, 3, "an entry it can't read is skipped")
        XCTAssertEqual(changes[0].seq, 41)
        XCTAssertEqual(changes[0].table, .cards)
        XCTAssertEqual(changes[0].kind, .update)
        XCTAssertEqual(changes[0].at, Date(timeIntervalSince1970: 1_792_579_320.123456))
        XCTAssertNil(changes[1].binderID, "what the whole team sees")
        XCTAssertEqual(changes[1].at, Date(timeIntervalSince1970: 1_792_575_721))
        XCTAssertNil(changes[2].table, "a later Binders' table is kept by name")
        XCTAssertEqual(changes[2].kind, .other("merged"))
        XCTAssertNil(TeamChange.list(json: "{}"))
        XCTAssertEqual(TeamChange.notified("1234"), 1234)
        XCTAssertNil(TeamChange.notified("b0000000-0000:12"), "a payload that names a binder isn't one of ours")
        XCTAssertNil(TeamChange.notified(""))
    }

    func testABatchReadsEachChangedRowOnceAndKnowsWhatsGone() {
        let binder = UUID()
        let card = UUID(), other = UUID(), event = UUID()
        let batch = TeamChangeBatch([
            TeamChange(seq: 9, binderID: binder, tableName: "card_events", rowID: event, kind: .insert),
            TeamChange(seq: 7, binderID: binder, tableName: "cards", rowID: card, kind: .update),
            TeamChange(seq: 8, binderID: binder, tableName: "cards", rowID: card, kind: .update),
            TeamChange(seq: 10, binderID: binder, tableName: "cards", rowID: other, kind: .delete),
            TeamChange(seq: 11, binderID: binder, tableName: "a_later_table", rowID: UUID(), kind: .insert),
        ])
        XCTAssertEqual(batch.lastSeq, 11)
        XCTAssertEqual(batch.rowsToRead.map(\.table), [.cards, .cardEvents], "in the order they first changed")
        XCTAssertEqual(batch.rowsToRead.first?.ids, [card, other], "each row once")
        let gone = batch.gone(read: [.cards: [["id": TeamJSON(card)]], .cardEvents: [["id": TeamJSON(event)]]])
        XCTAssertEqual(gone.map(\.id), [other], "changed, and not there to read: deleted, or moved out of sight")
    }

    func testResultsAndRefusalsDecodeAndSpeakTheBoardsWords() throws {
        let applied = """
            {"ok": true, "unchanged": false, "replayed": true,
             "card": {"id": "d0000000-0000-0000-0000-000000000001", "binder_id": "b0000000-0000-0000-0000-000000000001",
                      "title": "Write the spec", "board_column": "in_progress", "holder_kind": "agent", "holder_name": "Agent A",
                      "holder_agent_id": "c0000000-0000-0000-0000-00000000000a", "lease_until": "2026-10-21T11:12:00+00:00",
                      "links": ["https://example.com/pull/1"], "version": 4, "something_new": 1},
             "events": [{"id": "e0000000-0000-0000-0000-000000000001", "number": 2, "binder_id": "b0000000-0000-0000-0000-000000000001",
                         "card_id": "d0000000-0000-0000-0000-000000000001", "kind": "claimed", "author_kind": "agent",
                         "author_name": "Agent A", "text": "", "from_column": "ready", "to_column": "in_progress"}]}
            """
        let result = try XCTUnwrap(TeamResult(json: applied))
        XCTAssertTrue(result.ok && result.replayed && !result.unchanged)
        let card = try XCTUnwrap(result.card)
        XCTAssertEqual(card.column, .inProgress)
        XCTAssertEqual(card.state, CardState(column: .inProgress, assignee: "Agent A", assigneeIsAgent: true,
                                             claimExpires: Date(timeIntervalSince1970: 1_792_581_120)))
        XCTAssertEqual(card.stateNow(Date(timeIntervalSince1970: 1_792_581_121)).column, .ready, "a lapsed card reads as Ready")
        XCTAssertEqual(card.links, ["https://example.com/pull/1"])
        XCTAssertEqual(result.events.first?.author, BoardActor(name: "Agent A", kind: .agent))
        XCTAssertEqual(result.events.first?.toColumn, "in_progress")

        let until = "2026-10-21T11:12:00+00:00"
        let refused = try XCTUnwrap(TeamResult(json: """
            {"ok": false, "refusal": {"code": "claimed_by", "message": "Agent A has this until 11:12 AM.", "holder": "Agent A", "until": "\(until)"}}
            """))
        XCTAssertFalse(refused.ok)
        let refusal = try XCTUnwrap(refused.refusal)
        XCTAssertEqual(refusal.boardError, .claimedBy("Agent A", until: TeamJSON.date(from: until)))
        XCTAssertEqual(refusal.errorDescription, BoardError.claimedBy("Agent A", until: TeamJSON.date(from: until)).errorDescription,
                       "the Mac says it in BoardError's words")
        let waits = try XCTUnwrap(TeamResult(json: """
            {"ok": false, "refusal": {"code": "waits_for", "message": "This card waits for “Set up”, which isn't done yet. Pick another card.",
             "waits_for": [{"id": "d0000000-0000-0000-0000-000000000009", "title": "Set up", "column": "review"}]}}
            """)?.refusal)
        XCTAssertEqual(waits.boardError, .waitsFor(["Set up"]))
        XCTAssertEqual(waits.waitsFor.first?.column, .review)
        XCTAssertEqual(waits.errorDescription, BoardError.waitsFor(["Set up"]).errorDescription,
                       "the wait rule is the Swift rules' too, so the Mac says it in BoardError's words")
        XCTAssertEqual(TeamRefusal(code: "not_found", message: "No such card.").errorDescription, "No such card.",
                       "a refusal the Swift rules don't have keeps the database's words")
        XCTAssertEqual(TeamRefusal(code: "not_yours", message: "", holder: "Agent B").boardError, .notYours("Agent B"))
        XCTAssertNil(TeamResult(json: "not json"))
        XCTAssertNil(TeamResult(json: #"{"ok": false}"#), "a refusal says why")
    }

    func testJSONValuesRoundTripDatesAndBytes() throws {
        let date = Date(timeIntervalSince1970: 1_792_579_320.123456)
        XCTAssertEqual(TeamJSON.text(of: date), "2026-10-21T10:42:00.123456+00:00")
        XCTAssertEqual(try XCTUnwrap(TeamJSON.date(from: TeamJSON.text(of: date))).timeIntervalSince1970, date.timeIntervalSince1970,
                       accuracy: 0.000001)
        XCTAssertEqual(TeamJSON.date(from: "2026-10-21T10:42:00Z"), Date(timeIntervalSince1970: 1_792_579_320))
        XCTAssertEqual(TeamJSON.date(from: "2026-10-21T06:42:00-04:00"), Date(timeIntervalSince1970: 1_792_579_320))
        XCTAssertEqual(TeamJSON.date(from: "2026-10-21 10:42:00+00"), Date(timeIntervalSince1970: 1_792_579_320))
        XCTAssertNil(TeamJSON.date(from: "yesterday"))
        let bytes = Data([0x00, 0x0a, 0xff])
        XCTAssertEqual(TeamJSON(bytes: bytes).string, "\\x000aff")
        XCTAssertEqual(TeamJSON(bytes: bytes).bytes, bytes)
        let row: TeamJSON = ["id": "x", "n": 3, "on": true, "list": ["a", nil]]
        XCTAssertEqual(TeamJSON(text: row.text), row)
        XCTAssertEqual(row["n"]?.int, 3)
        XCTAssertEqual(row.text, #"{"id":"x","list":["a",null],"n":3,"on":true}"#, "keys sorted, so a row's JSON is the same every time")
    }

    // MARK: The outbox

    func testTheOutboxSendsInOrderAndKeepsAnItemUntilItsAnswered() throws {
        let card = UUID()
        var outbox = TeamOutbox()
        let first = TeamCall.claimCard(card), second = TeamCall.report(card, progress: "Started"), third = TeamCall.finish(card, summary: "Done")
        for call in [first, second, third] { XCTAssertTrue(outbox.add(call)) }
        XCTAssertTrue(outbox.add(second), "queued again under the same id: once")
        XCTAssertEqual(outbox.items.map(\.id), [first.operation, second.operation, third.operation])
        XCTAssertEqual(outbox.next?.id, first.operation)
        outbox.attempted(first.operation, error: "The connection dropped")
        XCTAssertEqual(outbox.next?.id, first.operation, "no answer: it goes again, first")
        XCTAssertEqual(outbox.next?.attempts, 1)
        XCTAssertEqual(outbox.settle(first.operation)?.id, first.operation)
        XCTAssertNil(outbox.settle(first.operation), "an answer that arrives twice settles nothing more")
        XCTAssertEqual(outbox.next?.id, second.operation)
        // Saved and read back, as after a restart: the same items, in the same order, with the same ids.
        let read = try TeamOutbox(data: outbox.encoded())
        XCTAssertEqual(read, outbox)
        XCTAssertThrowsError(try TeamOutbox(data: Data("{".utf8)), "a file it can't read isn't taken for an empty outbox")
        // A later Binders' fields are ignored.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: outbox.encoded()) as? [String: Any])
        object["later"] = ["field": 1]
        XCTAssertEqual(try TeamOutbox(data: JSONSerialization.data(withJSONObject: object)).items.count, 2)
    }

    /// A connection that drops at the worst moments: before a change reaches the database, and after the database applied
    /// it but before its answer arrives. Resending with the same operation id, from a saved outbox each time, applies
    /// every change once, in order, and delivers every answer once.
    func testAnOutboxThatResumesAfterDropsLosesAndDoublesNothing() throws {
        struct Server {
            var applied: [UUID] = []
            var answers: [UUID: String] = [:]
            mutating func call(_ call: TeamCall) -> String {
                if let answer = answers[call.operation] { return answer + " (replayed)" }
                applied.append(call.operation)
                answers[call.operation] = "ok \(applied.count)"
                return answers[call.operation]!
            }
        }
        var server = Server()
        var saved = try TeamOutbox().encoded()
        let calls = (0..<40).map { TeamCall.report(UUID(), progress: "Step \($0)") }
        var outbox = try TeamOutbox(data: saved)
        for call in calls { outbox.add(call) }
        saved = try outbox.encoded()
        var delivered: [UUID] = []
        var drops = 0
        var round = 0
        while true {
            // The app may have quit: every round starts from what's on disk.
            var outbox = try TeamOutbox(data: saved)
            guard let item = outbox.next else { break }
            round += 1
            switch round % 5 {
            case 1:
                // Dropped before it reached the database.
                outbox.attempted(item.id, error: "dropped")
                drops += 1
            case 3:
                // Applied, and the answer lost on the way back.
                _ = server.call(item.call)
                outbox.attempted(item.id, error: "dropped")
                drops += 1
            default:
                _ = server.call(item.call)
                delivered.append(item.id)
                outbox.settle(item.id)
            }
            saved = try outbox.encoded()
            XCTAssertLessThan(round, 500)
        }
        XCTAssertGreaterThan(drops, 10)
        XCTAssertEqual(server.applied, calls.map(\.operation), "each change applied once, in the order it was made")
        XCTAssertEqual(delivered, calls.map(\.operation), "each answer delivered once, in order")
    }

    func testWhatsWorthSendingAgain() {
        XCTAssertTrue(TeamErrors.isRetryable(sqlState: nil), "a connection error: send it again")
        XCTAssertTrue(TeamErrors.isRetryable(sqlState: "40001"), "a serialization failure")
        XCTAssertTrue(TeamErrors.isRetryable(sqlState: "40P01"), "a deadlock")
        XCTAssertTrue(TeamErrors.isRetryable(sqlState: "57P01"), "the server shutting down")
        XCTAssertTrue(TeamErrors.isRetryable(sqlState: "08006"))
        XCTAssertFalse(TeamErrors.isRetryable(sqlState: "42501"), "not allowed: the answer")
        XCTAssertFalse(TeamErrors.isRetryable(sqlState: "22023"), "not valid: the answer")
        XCTAssertFalse(TeamErrors.isRetryable(sqlState: "BD002"))
        XCTAssertNotEqual(TeamErrors.describe(sqlState: "BD001", message: "x"), "x")
    }

    // MARK: Passwords

    func testPBKDF2MatchesTheRFCVectors() {
        // RFC 7914 section 11: PBKDF2-HMAC-SHA256.
        let one = TeamPassword.pbkdf2SHA256(password: Array("passwd".utf8), salt: Array("salt".utf8), iterations: 1, length: 64)
        XCTAssertEqual(hex(one), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
        let many = TeamPassword.pbkdf2SHA256(password: Array("Password".utf8), salt: Array("NaCl".utf8), iterations: 80000, length: 64)
        XCTAssertEqual(hex(many), "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d")
    }

    func testAVerifierIsPostgresShapedAndNeverThePassword() {
        let salt: [UInt8] = Array(repeating: 7, count: 16)
        let verifier = TeamPassword.verifier(for: "pencil", salt: salt)
        XCTAssertEqual(verifier, TeamPassword.verifier(for: "pencil", salt: salt))
        XCTAssertNotEqual(verifier, TeamPassword.verifier(for: "pencil"), "a new salt each time")
        XCTAssertTrue(verifier.range(of: #"^SCRAM-SHA-256\$4096:[A-Za-z0-9+/]+=*\$[A-Za-z0-9+/]+=*:[A-Za-z0-9+/]+=*$"#,
                                     options: .regularExpression) != nil, verifier)
        XCTAssertFalse(verifier.contains("pencil"))
        let password = TeamPassword.generate()
        XCTAssertEqual(password.count, 6 * 4 + 5)
        XCTAssertTrue(password.allSatisfy { $0 == "-" || TeamPassword.alphabet.contains($0) })
        XCTAssertNotEqual(password, TeamPassword.generate())
    }

    // MARK: Status

    func testTheStatusLineAndTheBackoff() {
        let now = Date(timeIntervalSince1970: 1_792_579_320)
        XCTAssertEqual(TeamDatabaseStatus.connected.summary(now: now), "Connected. Changes arrive as they're made.")
        let offline = TeamDatabaseStatus.offline(since: now.addingTimeInterval(-600), reason: "Binders can't reach the team database",
                                                 retrying: true).summary(now: now)
        XCTAssertTrue(offline.hasPrefix("Offline since "), offline)
        XCTAssertTrue(offline.contains("Binders can't reach the team database."))
        XCTAssertTrue(offline.hasSuffix("Binders tries again on its own, and your changes wait on this Mac."))
        XCTAssertFalse(TeamDatabaseStatus.offline(since: now, reason: "Update Binders to connect.", retrying: false).summary(now: now)
            .contains("tries again"), "a wait that needs someone says what, not that it retries")
        XCTAssertTrue(TeamDatabaseStatus.catchingUp.isConnected)
        XCTAssertEqual(TeamBackoff.delay(attempt: 0), 1)
        XCTAssertEqual(TeamBackoff.delay(attempt: 3), 8)
        XCTAssertEqual(TeamBackoff.delay(attempt: 30), 60, "at most a minute")
        XCTAssertEqual(TeamBackoff.delay(attempt: 30, jitter: 1), 72, accuracy: 0.001)
        XCTAssertEqual(TeamBackoff.delay(attempt: 2, jitter: -1), 3.2, accuracy: 0.001)
        let server = TeamDatabaseServer(host: "binders.postgres.example", database: "binders", login: "sam")
        XCTAssertEqual(server.key, TeamDatabaseServer(host: "BINDERS.postgres.example", database: "binders", login: "sam").key)
        XCTAssertNotEqual(server.key, TeamDatabaseServer(host: "binders.postgres.example", database: "binders", login: "alex").key)
        XCTAssertEqual(server.key.count, 12)
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
