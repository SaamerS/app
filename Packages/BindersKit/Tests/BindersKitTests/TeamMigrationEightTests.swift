import XCTest
@testable import BindersKit

/// Lane DB5: migration 8 and what it brings to the Swift side. Migrations 1 to 7 shipped (a team's database was set up
/// with them), so they're pinned here by checksum; migration 8 replaces the board's functions with the same signatures,
/// so every Binders that calls them still does. The Mac's `--selftest-teamdb-update` brings a database made at 7 up to 8.
final class TeamMigrationEightTests: XCTestCase {
    /// Each shipped migration's SHA-256: a database set up with them records these, and refuses a Binders whose differ.
    private let shipped: [Int: String] = [
        1: "5e7ce489dec641ab818b511a998b3603045d63a0807e67a4573144f7157a0fc2",
        2: "17d1a2746e090111d817810414f56e40d1f30c092a67547977702eb0cd633171",
        3: "9eefaaa3c3d1a070e253e17bbbfb9ffaf2316229e6120a75414885cc89b9c264",
        4: "2c50d3f5365a3a5ff0c5b4a376185ec611207027ffcf32c912b20b0d15741375",
        5: "444f0834f4b2fa2e5e15e86535c60ed5a3355fa3e99d10fc0e2d71e2e689baf3",
        6: "27fda2a5b842706f4b2c843ecc630c9829f02169c89f152e728eed0b3cae6594",
        7: "458ce2868643f7747e4c2929120d2d122fb2e6c914212dbbb098c7e9b7e38606",
    ]

    func testMigrationsOneToSevenAreAsTheyShipped() {
        for migration in TeamSchema.migrations where migration.version <= 7 {
            XCTAssertEqual(migration.checksum, shipped[migration.version], "migration \(migration.version) changed after it shipped")
        }
        XCTAssertEqual(TeamSchema.migrations.count, 8)
        XCTAssertEqual(TeamSchema.latest, 8)
        // A database a Binders of 0.10.0 set up has 1 to 7: this one applies 8 to it, and nothing else.
        let seven = TeamSchema.migrations.prefix(7).map { TeamAppliedMigration(version: $0.version, checksum: $0.checksum) }
        XCTAssertEqual(TeamSchema.plan(applied: seven), .apply([8]))
        // Set up by this one, with migration 8: a Binders that knows only 1 to 7 is told to update.
        let eight = TeamSchema.migrations.map { TeamAppliedMigration(version: $0.version, checksum: $0.checksum) }
        let older = TeamSchema.plan(applied: eight, known: Array(TeamSchema.migrations.prefix(7)))
        XCTAssertEqual(older, .newer(database: 8, known: 7))
        XCTAssertEqual(older.problem, "The team's database was updated by a newer version of Binders. Update Binders on this Mac to connect.")
    }

    /// The words Settings → Team shows say an update to the team's database, never a schema or a migration.
    func testTheWordsSayAnUpdateNeverAMigration() {
        for plan in [TeamMigrationPlan.newer(database: 9, known: 8), .changed(version: 2), .missing(version: 3)] {
            let words = plan.problem ?? ""
            XCTAssertFalse(words.isEmpty, "\(plan) says what's wrong")
            for word in ["schema", "migration"] { XCTAssertFalse(words.lowercased().contains(word), "\(plan): “\(words)”") }
        }
    }

    // MARK: The SQL

    private func signatures(_ sql: String) throws -> [String: String] {
        let regex = try NSRegularExpression(pattern: #"CREATE (?:OR REPLACE )?FUNCTION binders\.([a-z_]+)\(([^)]*)\)"#)
        var found: [String: String] = [:]
        for match in regex.matches(in: sql, range: NSRange(sql.startIndex..., in: sql)) {
            let name = String(sql[Range(match.range(at: 1), in: sql)!])
            let parameters = String(sql[Range(match.range(at: 2), in: sql)!]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            found[name] = parameters
        }
        return found
    }

    func testMigrationEightReplacesTheBoardsFunctionsAsTheyWere() throws {
        let eight = TeamSchema.migration8.sql
        let before = try signatures(TeamSchema.migrations.prefix(7).map(\.sql).joined(separator: "\n"))
        let replaced = try signatures(eight)
        for function in ["claim_card", "move_card", "finish", "answer", "decide", "hand_agent_to"] {
            XCTAssertTrue(eight.contains("CREATE OR REPLACE FUNCTION binders.\(function)("), "\(function) is replaced")
            XCTAssertEqual(replaced[function], before[function], "\(function) keeps its parameters, so every Binders still calls it")
        }
        XCTAssertNil(before["set_agent_auto"])
        XCTAssertEqual(replaced["set_agent_auto"], "p_op uuid, p_agent uuid, p_on boolean")
        XCTAssertFalse(eight.contains("CREATE TABLE"), "a column and functions only")
        XCTAssertTrue(eight.contains("ALTER TABLE binders.agents ADD COLUMN auto boolean NOT NULL DEFAULT false"),
                      "Auto starts off, for headless agents listed before migration 8 too")
        // The wait rule reaches Review and Done, and finishing.
        XCTAssertTrue(eight.contains("p_column IN ('in_progress', 'review', 'done')"))
        XCTAssertTrue(eight.contains("binders._waits_refusal(v_card, v_actor));"), "finish checks the waits")
    }

    func testTheNewCallRendersWithItsOperationFirst() throws {
        let agent = UUID(uuidString: "C0000000-0000-0000-0000-00000000000A")!
        let statement = try XCTUnwrap(TeamCall.setAgentAuto(agent, on: true).statement)
        XCTAssertEqual(statement.sql, "SELECT binders.set_agent_auto(p_op => $1::uuid, p_agent => $2::uuid, p_on => $3::boolean)::text")
        XCTAssertEqual(Array(statement.values.dropFirst()), ["c0000000-0000-0000-0000-00000000000a", "true"])
    }

    // MARK: Who decides on an approval

    func testTheAgentsOwnerAndWhoTheCardIsForDecide() {
        XCTAssertEqual(BoardRules.deciders(askerOwner: "Sam", meantFor: "Robin", suggested: false), ["Sam", "Robin"])
        XCTAssertEqual(BoardRules.deciders(askerOwner: "Sam", meantFor: "Robin", suggested: true), ["Sam"], "a suggestion makes no one a decider")
        XCTAssertEqual(BoardRules.deciders(askerOwner: "Sam", meantFor: "Sam", suggested: false), ["Sam"], "once each")
        XCTAssertEqual(BoardRules.deciders(askerOwner: nil, meantFor: "Robin", suggested: false), ["Robin"])
        XCTAssertEqual(BoardRules.deciders(askerOwner: String?.none, meantFor: nil, suggested: false), [])
        XCTAssertEqual(BoardRules.onlyDeciders(owner: "Sam", meantFor: "Robin"),
                       "Only Sam, whose agent is asking, or Robin, who the card is for, can decide on this.")
        XCTAssertEqual(BoardRules.onlyDeciders(owner: "Sam", meantFor: nil), "Only Sam can decide on this: it's their agent asking.")
        XCTAssertEqual(BoardRules.onlyDeciders(owner: "Sam", meantFor: "sam"), "Only Sam can decide on this: it's their agent asking.")
        XCTAssertEqual(BoardRules.onlyDeciders(owner: nil, meantFor: "Robin"), "Only Robin can decide on this: the card is for them.")
        XCTAssertTrue(BoardRules.onlyDeciders(owner: nil, meantFor: nil).hasPrefix("No one in the team can decide on this now"))
        // Someone else's words on a card that waits for an approval leave it waiting.
        let waiting = CardState(column: .blocked, assignee: "Agent A", assigneeIsAgent: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(BoardRules.answered(waiting, by: BoardActor(name: "Alex", kind: .person), at: now, decides: false), waiting)
        XCTAssertEqual(BoardRules.answered(waiting, by: BoardActor(name: "Sam", kind: .person), at: now).column, .inProgress)
    }

    /// On a Mac, by member: Sam's own agents are Sam's, a teammate's agent is its owner's, and the card's meant for a person
    /// or the owner of the agent it's meant for.
    func testThisMacTellsWhoDecidesByMember() {
        let sam = UUID(), dana = UUID(), robin = UUID(), mine = UUID(), danas = UUID(), headless = UUID()
        let team = TeamDirectory(me: sam,
                                 members: [sam: .init(id: sam, name: "Sam"), dana: .init(id: dana, name: "Dana"), robin: .init(id: robin, name: "Robin")],
                                 agents: [mine: .init(id: mine, owner: sam, name: "Claude Code · app (Sam)"),
                                          danas: .init(id: danas, owner: dana, name: "Claude Code (Dana)"),
                                          headless: .init(id: headless, owner: dana, login: UUID(), name: "Build bot (Dana)", auto: true)],
                                 local: [mine: "Claude Code · app"])
        XCTAssertEqual(team.owner(ofAgentNamed: "Claude Code · app"), sam, "this Mac's own agent, by the name it goes by here")
        XCTAssertEqual(team.owner(ofAgentNamed: "Claude Code (Dana)"), dana)
        XCTAssertNil(team.owner(ofAgentNamed: "Someone's agent"))
        XCTAssertEqual(team.decides(askedBy: "Claude Code · app", meantFor: nil, suggested: false), true, "your own agent: yours to decide")
        XCTAssertEqual(team.decides(askedBy: "Claude Code (Dana)", meantFor: "Robin", suggested: false), false)
        XCTAssertEqual(team.decides(askedBy: "Claude Code (Dana)", meantFor: "You", suggested: false), true, "a card meant for you")
        XCTAssertEqual(team.decides(askedBy: "Claude Code (Dana)", meantFor: "Claude Code · app", suggested: false), true, "or for your agent")
        XCTAssertEqual(team.decides(askedBy: "Claude Code (Dana)", meantFor: "You", suggested: true), false, "not when an agent only suggested it")
        XCTAssertNil(team.decides(askedBy: "Someone's agent", meantFor: nil, suggested: false), "an agent this Mac doesn't know: the database decides")
        XCTAssertEqual(team.deciders(askedBy: "Build bot (Dana)", meantFor: "Robin", suggested: false), [dana, robin])
        XCTAssertEqual(team.onlyDeciders(askedBy: "Claude Code (Dana)", meantFor: "Robin", suggested: false),
                       "Only Dana, whose agent is asking, or Robin, who the card is for, can decide on this.")
        XCTAssertEqual(team.onlyDeciders(askedBy: "Claude Code (Dana)", meantFor: "Robin", suggested: true), "Only Dana can decide on this: it's their agent asking.")
    }

    // MARK: A headless agent's Auto

    func testAHeadlessAgentsAutoComesFromItsRowAndOlderSavedDirectoriesStillRead() throws {
        let owner = UUID()
        let row: TeamRow = ["id": TeamJSON(UUID()), "owner_id": TeamJSON(owner), "login_id": TeamJSON(UUID()), "name": "Build bot (Sam)",
                            "takes_team_cards": true, "auto": false]
        let off = try XCTUnwrap(TeamDirectory.Agent(row: row))
        XCTAssertEqual(off.auto, false)
        XCTAssertTrue(off.isHeadless)
        XCTAssertFalse(off.takesCardsOnItsOwn, "a headless agent takes cards on its own only once its Auto is on")
        XCTAssertFalse(off.takesTeamCards, "and that's what teammates are told, whatever its row says (no Mac publishes it)")
        var on = row
        on["auto"] = true
        XCTAssertTrue(try XCTUnwrap(TeamDirectory.Agent(row: on)).takesCardsOnItsOwn)
        var before = row
        before["auto"] = nil
        XCTAssertEqual(TeamDirectory.Agent(row: before)?.auto, false, "from a database before migration 8: off")
        let onAMac: TeamRow = ["id": TeamJSON(UUID()), "owner_id": TeamJSON(owner), "name": "Claude Code (Sam)", "takes_team_cards": true, "auto": false]
        let mac = try XCTUnwrap(TeamDirectory.Agent(row: onAMac))
        XCTAssertNil(mac.auto, "an agent on a Mac keeps its Auto on its owner's Mac")
        XCTAssertTrue(mac.takesCardsOnItsOwn, "as its owner's Mac says")

        // Who's who as an earlier Binders saved it (board.json), which has no Auto: it reads, as it was.
        var earlier = off
        earlier.auto = nil
        let saved = try JSONEncoder().encode(TeamDirectory(me: owner, agents: [earlier.id: earlier]))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("auto"), "the same JSON an earlier Binders wrote")
        let directory = try JSONDecoder().decode(TeamDirectory.self, from: saved)
        XCTAssertEqual(directory.agents[off.id]?.name, "Build bot (Sam)")
        XCTAssertNil(directory.agents[off.id]?.auto, "Auto unknown until who's who is read again: off meanwhile")
        XCTAssertEqual(directory.agents[off.id]?.takesCardsOnItsOwn, false)
    }

    // MARK: Refusals

    func testTheNewRefusalsSayWhoCan() throws {
        let deciding = try XCTUnwrap(TeamResult(json: """
            {"ok": false, "refusal": {"code": "not_yours_to_decide", "message": "Only Sam can decide on this: it's their agent asking.",
             "owner": "Sam", "meant_for": null, "deciders": [{"id": "a0000000-0000-0000-0000-000000000001", "name": "Sam", "owner": true}]}}
            """)?.refusal)
        XCTAssertEqual(deciding.deciders, ["Sam"])
        XCTAssertEqual(deciding.owner, "Sam")
        XCTAssertNil(deciding.meantFor)
        XCTAssertEqual(deciding.errorDescription, "Only Sam can decide on this: it's their agent asking.", "in the Swift rules' words")
        let auto = try XCTUnwrap(TeamResult(json: """
            {"ok": false, "refusal": {"code": "auto_off", "message": "Build bot (Sam) can't take cards until its owner, Sam, turns on its Auto in Binders' Settings → Team.",
             "owner": "Sam"}}
            """)?.refusal)
        XCTAssertEqual(auto.owner, "Sam")
        XCTAssertTrue(auto.errorDescription?.contains("its owner, Sam, turns on its Auto") == true, "the database's words, naming who can")
    }
}
