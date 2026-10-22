import XCTest
@testable import BindersKit

/// Boards and agents on the team database (lane DB2), the pure parts: migration 5, names on each Mac, the agents' public
/// rows, invites, a teammate's agent's yes, the dispatcher's rule for teammates' cards, who a question rings for, the line
/// a refused change leaves, and Distill's shared part of a card. The Mac's `--selftest-teamdb-team`, `-boards` and
/// `-agents` run them against a real Postgres.
final class TeamBoardsTests: XCTestCase {
    private let sam = UUID(uuidString: "5A000000-0000-0000-0000-000000000001")!
    private let dana = UUID(uuidString: "DA000000-0000-0000-0000-000000000002")!
    private let mine = UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!
    private let danas = UUID(uuidString: "C3000000-0000-0000-0000-000000000004")!
    private let headless = UUID(uuidString: "B0000000-0000-0000-0000-000000000005")!
    private let headlessLogin = UUID(uuidString: "B1000000-0000-0000-0000-000000000006")!

    /// Sam's Mac: Sam, Dana, Sam's "Claude Code · app" (set up on this Mac), Dana's "Claude Code (Dana)", and a headless
    /// agent of Sam's with a login of its own.
    private var directory: TeamDirectory {
        TeamDirectory(me: sam,
                      members: [sam: .init(id: sam, name: "Sam", login: "sam", isAdmin: true),
                                dana: .init(id: dana, name: "Dana", login: "dana", isAdmin: true),
                                headlessLogin: .init(id: headlessLogin, name: "Helper Bot", login: "helper_bot", kind: "agent")],
                      agents: [mine: .init(id: mine, owner: sam, name: "Claude Code · app (Sam)", kind: "claudeCode"),
                               danas: .init(id: danas, owner: dana, name: "Claude Code (Dana)", kind: "claudeCode", sendsTo: "Anthropic"),
                               headless: .init(id: headless, owner: sam, login: headlessLogin, name: "Helper Bot")],
                      local: [mine: "Claude Code · app"])
    }

    // MARK: Migration 5

    func testMigrationFiveAddsTheBoardsRulesAndKeepsTheConventions() throws {
        // Later migrations come after it (lanes DB3 and DB4); migration 5 itself never changes.
        XCTAssertGreaterThanOrEqual(TeamSchema.latest, 5)
        let five = try XCTUnwrap(TeamSchema.migrations.first { $0.version == 5 })
        XCTAssertEqual(five.version, 5)
        for function in ["move_card_to_binder", "bring_card", "place_work_items", "set_card_distilled", "seen", "prune", "hand_agent_to"] {
            XCTAssertTrue(five.sql.contains("CREATE FUNCTION binders.\(function)(p_op uuid"), "\(function) takes an operation id first")
        }
        XCTAssertTrue(five.sql.contains("CREATE OR REPLACE FUNCTION binders.put_agent(p_op uuid, p_agent uuid, p_fields jsonb)"),
                      "put_agent keeps its signature")
        XCTAssertTrue(five.sql.contains("'sends_to') THEN"), "and takes who it sends cards to")
        for column in ["agents ADD COLUMN sends_to", "members ADD COLUMN seen_at", "members ADD COLUMN seen_seq", "cards ADD COLUMN distilled",
                       "team_settings ADD COLUMN changes_pruned_through"] {
            XCTAssertTrue(five.sql.contains("ALTER TABLE binders.\(column)"), column)
        }
        XCTAssertTrue(five.sql.contains("agents_may_not_place"), "an agent places only where the binder lets it")
        XCTAssertTrue(five.sql.contains("CREATE TRIGGER cards_todo"), "a card's to-do follows it to Done")
        XCTAssertTrue(five.sql.contains("greatest(coalesce(p_keep_days, 30), 30)"), "pruning keeps at least 30 days")
        // Nothing earlier changes: migrations 1 to 4 keep their numbers and differ from 5.
        XCTAssertEqual(Array(TeamSchema.migrations.map(\.version).prefix(5)), [1, 2, 3, 4, 5])
        XCTAssertFalse(TeamSchema.migrations.filter { $0.version < 5 }.contains { $0.sql.contains("place_work_items") })
    }

    func testTheNewCallsRenderAndBringingInIsDerived() throws {
        let card = UUID(uuidString: "D0000000-0000-0000-0000-0000000000AA")!
        let binder = UUID(uuidString: "B2000000-0000-0000-0000-0000000000BB")!
        let seen = try XCTUnwrap(TeamCall.seen(seq: 42, agents: [mine, danas]).statement)
        XCTAssertTrue(seen.sql.contains("p_seq => $2::bigint") && seen.sql.contains("p_agents => $3::uuid[]"), seen.sql)
        XCTAssertEqual(seen.values[1], "42")
        XCTAssertEqual(seen.values[2], "{\(mine.uuidString.lowercased()),\(danas.uuidString.lowercased())}")
        let bring = TeamCall.bringCard(card, binder: binder, title: "Write the notes", fields: ["column": "done"])
        XCTAssertEqual(bring.operation, TeamCall.bringCard(card, binder: binder, title: "Other words", fields: [:]).operation,
                       "bringing a card in again is the same change")
        XCTAssertNotEqual(bring.operation, TeamCall.bringCard(binder, binder: binder, title: "x", fields: [:]).operation)
        XCTAssertEqual(TeamCall.bringWait(card, waitsFor: binder).operation, TeamCall.bringWait(card, waitsFor: binder).operation)
        XCTAssertNotNil(bring.statement)
        XCTAssertEqual(bring.card, card)
        let move = try XCTUnwrap(TeamCall.moveCardToBinder(card, to: binder, keepSuggestion: true).statement)
        XCTAssertTrue(move.sql.hasPrefix("SELECT binders.move_card_to_binder(p_op => $1::uuid, p_card => $2::uuid"), move.sql)
        let item = TeamPlacing.item(card: card, title: "A", details: "", position: 1, note: binder, noteTitle: "Spec", item: card, section: "Auth",
                                    distilled: nil, waitsFor: [binder], meantFor: "Claude Code (Dana)")
        let place = try XCTUnwrap(TeamCall.placeWorkItems(binder: binder, items: [item], column: .ready).statement)
        XCTAssertTrue(place.sql.contains("p_items => $3::jsonb") && place.values[3] == "ready", place.sql)
        XCTAssertNotNil(TeamCall.prune().statement)
        XCTAssertNotNil(TeamCall.handAgent(headless, to: dana).statement)
        XCTAssertNotNil(TeamCall.setCardDistilled(card, nil).statement)
    }

    // MARK: Names

    func testAnAgentsNameInTheTeamCarriesItsOwner() {
        XCTAssertEqual(TeamNames.published("Claude Code · app", owner: "Sam"), "Claude Code · app (Sam)")
        XCTAssertEqual(TeamNames.published("Claude Code · app (Sam)", owner: "Sam"), "Claude Code · app (Sam)", "never twice")
        XCTAssertEqual(TeamNames.local("Claude Code · app (Sam)", owner: "Sam"), "Claude Code · app")
        XCTAssertEqual(TeamNames.local("Claude Code (Dana)", owner: "Sam"), "Claude Code (Dana)")
        XCTAssertEqual(TeamNames.sessionAgentID(member: sam, name: "Claude Code"), TeamNames.sessionAgentID(member: sam, name: " claude code"))
        XCTAssertNotEqual(TeamNames.sessionAgentID(member: sam, name: "Claude Code"), TeamNames.sessionAgentID(member: dana, name: "Claude Code"))
        XCTAssertEqual(TeamNames.login(for: "Sam Lee"), "sam_lee")
        XCTAssertEqual(TeamNames.login(for: "Zoë", taken: ["zoe"]), "zoe_2")
        XCTAssertEqual(TeamNames.login(for: "2nd shift"), "member_2nd_shift")
        XCTAssertTrue(TeamSchema.isValidRoleName(TeamNames.login(for: "!")))
    }

    func testThisMacNamesEveryoneByIdNotByWhatARowSaid() {
        let team = directory
        XCTAssertEqual(team.actor(kind: "person", member: sam, agent: nil, stored: "Sam"), .you, "this Mac's member is You")
        XCTAssertEqual(team.actor(kind: "person", member: dana, agent: nil, stored: "Dana (old name)").name, "Dana")
        XCTAssertEqual(team.actor(kind: "agent", member: sam, agent: mine, stored: "whatever"), BoardActor(name: "Claude Code · app", kind: .agent),
                       "this Mac's agent goes by its own name here")
        XCTAssertEqual(team.actor(kind: "agent", member: dana, agent: danas, stored: nil).name, "Claude Code (Dana)")
        XCTAssertEqual(team.actor(kind: "agent", member: headlessLogin, agent: headless, stored: nil).name, "Helper Bot (Sam)",
                       "a headless agent with its owner")
        XCTAssertEqual(team.actor(kind: "person", member: nil, agent: nil, stored: "Binders").name, "Binders")
        XCTAssertEqual(team.actor(kind: "agent", member: nil, agent: UUID(), stored: "Someone's Bot").name, "Someone's Bot",
                       "an agent this Mac doesn't know yet keeps the name it stored")
        // An MCP session of Sam's, not set up here, published as "Claude Code (Sam)": its own name again.
        var withSession = team
        let session = TeamNames.sessionAgentID(member: sam, name: "Claude Code")
        withSession.agents[session] = .init(id: session, owner: sam, name: "Claude Code (Sam)", kind: "session")
        XCTAssertEqual(withSession.actor(kind: "agent", member: sam, agent: session, stored: nil).name, "Claude Code")
        XCTAssertEqual(withSession.agentID(named: "claude code"), session)
        XCTAssertEqual(withSession.teamName("Claude Code"), "Claude Code (Sam)")
    }

    func testWhoACardIsMeantForTravelsBothWays() {
        let team = directory
        XCTAssertEqual(team.localName("Sam"), "You")
        XCTAssertEqual(team.localName("Claude Code · app (Sam)"), "Claude Code · app")
        XCTAssertEqual(team.localName("Claude Code (Dana)"), "Claude Code (Dana)")
        XCTAssertEqual(team.localName("Dana"), "Dana")
        XCTAssertNil(team.localName("  "))
        XCTAssertEqual(team.teamName("You"), "Sam")
        XCTAssertEqual(team.teamName("Claude Code · app"), "Claude Code · app (Sam)")
        XCTAssertEqual(team.teamName("Claude Code (Dana)"), "Claude Code (Dana)")
        XCTAssertEqual(team.teamName("Pennant"), "Pennant", "anyone else stays as named")
        XCTAssertEqual(team.agentID(named: "claude code · APP"), mine)
        XCTAssertNil(team.agentID(named: "Claude Code (Dana)"), "a teammate's agent isn't this Mac's")
        XCTAssertEqual(team.teammatesAgents.map(\.id), [danas])
        XCTAssertEqual(team.teammates.map(\.name), ["Dana"], "people only, not you, not a headless agent's login")
    }

    func testQuestionsRingForTheAgentsOwnerAndWhoeverTheCardIsFor() {
        let team = directory
        XCTAssertTrue(team.rings(askedBy: headless, meantFor: "Dana"), "Sam's own headless agent asks: it rings for Sam")
        XCTAssertTrue(team.rings(askedBy: danas, meantFor: "You"), "Dana's agent asks on a card meant for Sam")
        XCTAssertTrue(team.rings(askedBy: danas, meantFor: "Claude Code · app"), "or for one of Sam's agents")
        XCTAssertFalse(team.rings(askedBy: danas, meantFor: "Dana"), "Dana's agent on Dana's card rings on Dana's Mac, not here")
        XCTAssertFalse(team.rings(askedBy: danas, meantFor: nil))
        XCTAssertFalse(TeamDirectory().rings(askedBy: danas, meantFor: "You"), "a Mac that doesn't know who it is rings nothing")
    }

    // MARK: What the team sees of an agent

    func testAgentRowsCarryNothingAboutHowAnAgentRuns() {
        let secrets = ["/Users/sam/Code/secret-repo", "secret-repo", "https://hooks.example.com/abc?token=s3cr3t", "hooks.example.com", "s3cr3t",
                       "zsh -c 'deploy --token s3cr3t'", "claude-opus-model-x", "Morning Shortcut", "sam@build-box.local", "acceptEdits"]
        var claude = ClaudeCodeWake(repository: "/Users/sam/Code/secret-repo")
        claude.model = "claude-opus-model-x"
        let agents: [AgentProfile] = [
            AgentProfile(name: "Claude Code · app", wake: .claudeCode(claude), purpose: nil),
            AgentProfile(name: "Deployer", wake: .command(command: "zsh -c 'deploy --token s3cr3t'", folder: "/Users/sam/Code/secret-repo"),
                         report: .ssh(host: "sam@build-box.local"), vendor: "hooks.example.com"),
            AgentProfile(name: "Hook", wake: .webhook(url: "https://hooks.example.com/abc?token=s3cr3t"),
                         report: .status(url: "https://hooks.example.com/status"), vendor: "Acme Robots", purpose: "Books meeting rooms"),
            AgentProfile(name: "Morning", wake: .shortcut(name: "Morning Shortcut")),
        ]
        for agent in agents {
            let row = TeamAgentRow.fields(for: agent, owner: "Sam", binders: [mine], startsOnTeammatesCards: true, status: "ready",
                                          runningCard: nil, online: Date())
            XCTAssertTrue(Set(row.keys).isSubset(of: TeamAgentRow.fields), "\(agent.name): only the team's fields: \(row.keys.sorted())")
            let text = TeamJSON.object(row).text
            for secret in secrets { XCTAssertFalse(text.contains(secret), "\(agent.name)'s row says “\(secret)”: \(text)") }
            XCTAssertEqual(row["name"]?.string, agent.name + " (Sam)")
        }
        XCTAssertEqual(TeamAgentRow.fields(for: agents[0], owner: "Sam", binders: [], startsOnTeammatesCards: false, status: "", runningCard: nil,
                                           online: nil)["purpose"]?.string, "Kinds of work: coding.", "never the repository it works in")
        XCTAssertEqual(TeamAgentRow.sendsTo(agents[0]), "Anthropic")
        XCTAssertEqual(TeamAgentRow.sendsTo(agents[1]), "", "an address isn't who it sends cards to")
        XCTAssertEqual(TeamAgentRow.sendsTo(agents[2]), "Acme Robots")
        XCTAssertEqual(TeamAgentRow.purpose(agents[2]), "Books meeting rooms")
        for address in ["https://x.example", "10.0.0.5", "build.local:8080", "me@host", "[::1]:5432"] {
            XCTAssertTrue(TeamAgentRow.looksLikeAddress(address), address)
        }
        for name in ["Anthropic", "OpenAI", "GitHub (Microsoft)", "the openai provider, as set up in your OpenCode"] {
            XCTAssertFalse(TeamAgentRow.looksLikeAddress(name), name)
        }
        XCTAssertTrue(Set(TeamAgentRow.session(name: "Claude Code", owner: "Sam").keys).isSubset(of: TeamAgentRow.fields))
    }

    func testATeammatesAgentIsAskedAboutOnceAndAgainWhenItChanges() {
        XCTAssertEqual(TeamAgentConsent.question("Claude Code (Dana)"), "Give cards to Claude Code (Dana)?")
        XCTAssertEqual(TeamAgentConsent.message(owner: "Dana", sendsTo: "Anthropic"), "It sends them to Anthropic. It runs on Dana's Mac.")
        XCTAssertEqual(TeamAgentConsent.message(owner: "Dana", sendsTo: ""), "Dana hasn't said where it sends them. It runs on Dana's Mac.")
        XCTAssertTrue(TeamAgentConsent.message(owner: "Dana", sendsTo: "xAI", headless: true).hasSuffix("It runs on its own, as Dana's agent."))
        let first = TeamAgentConsent.fingerprint(name: "Claude Code (Dana)", owner: "Dana", sendsTo: "Anthropic")
        XCTAssertEqual(first, TeamAgentConsent.fingerprint(name: "claude code (dana) ", owner: "Dana", sendsTo: "Anthropic"))
        XCTAssertNotEqual(first, TeamAgentConsent.fingerprint(name: "Claude Code (Dana)", owner: "Dana", sendsTo: "OpenAI"),
                          "where it sends cards changed: asked again")
        XCTAssertNotEqual(first, TeamAgentConsent.fingerprint(name: "Claude Code (Dana)", owner: "Robin", sendsTo: "Anthropic"))
        XCTAssertTrue(first.hasPrefix("team-") && first.count == 21)
    }

    // MARK: Invites

    func testAnInviteGoesAsALinkOrAFileAndSaysToSendItPrivately() throws {
        let invite = TeamInvite(server: TeamDatabaseServer(host: "10.20.0.4", port: 6432, database: "binders_team", login: "robin",
                                                           serverName: "team.postgres.example"),
                                oneTimePassword: "ab12-CD34+ef/56=&?", teamName: "Design & Ops")
        let link = try XCTUnwrap(invite.link)
        XCTAssertTrue(link.absoluteString.hasPrefix("binders://team/join?v=1&team=Design%20%26%20Ops"), link.absoluteString)
        XCTAssertEqual(TeamInvite(link: link), invite, "the link reads back as the invite, every character of the password too")
        let file = invite.fileData()
        XCTAssertEqual(TeamInvite(fileData: file), invite)
        let text = String(data: file, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains(TeamInvite.sendPrivately) && TeamInvite.sendPrivately.contains("privately"), text)
        XCTAssertEqual(invite.fileName, "Design & Ops invite for robin.binders-invite")
        // Keys it doesn't know are ignored; one that lacks what it needs isn't an invite.
        let later = URL(string: link.absoluteString + "&color=blue&v2=yes")!
        XCTAssertEqual(TeamInvite(link: later), invite)
        let noPassword = URL(string: "binders://team/join?host=h&database=d&login=robin")!
        XCTAssertNil(TeamInvite(link: noPassword))
        XCTAssertNil(TeamInvite(link: URL(string: "binders://team/join?host=h&database=d&login=Robin&password=x")!), "not a login Binders makes")
        XCTAssertNil(TeamInvite(link: URL(string: "binders://card/join?host=h&database=d&login=robin&password=x")!))
        XCTAssertNil(TeamInvite(fileData: Data("{\"team\": \"x\"}".utf8)), "a file that doesn't say it's an invite")
        let plain = TeamInvite(server: TeamDatabaseServer(host: "db.example", database: "team", login: "sam"), oneTimePassword: "p", teamName: "")
        XCTAssertFalse(plain.link?.absoluteString.contains("tls=") ?? true, "no certificate name when the host is one")
        XCTAssertEqual(TeamInvite(link: plain.link!)?.server.port, 5432)
    }

    // MARK: The dispatcher's rule

    func testATeammatesCardStartsAnAgentOnlyWithBothSwitches() {
        let agent = "Claude Code · app"
        XCTAssertEqual(TeamWakeRule.verdict(.yours, agent: agent, takesTeammatesCards: false, startsOnItsOwn: false), .wake,
                       "your own tap wakes as it always did")
        XCTAssertEqual(TeamWakeRule.verdict(.teammate, agent: agent, takesTeammatesCards: true, startsOnItsOwn: true), .wake)
        guard case .waits(let off) = TeamWakeRule.verdict(.teammate, agent: agent, takesTeammatesCards: false, startsOnItsOwn: true),
              case .waits(let noStart) = TeamWakeRule.verdict(.teammate, agent: agent, takesTeammatesCards: true, startsOnItsOwn: false) else {
            return XCTFail("a teammate's card waits without either switch")
        }
        XCTAssertTrue(off.hasPrefix("Waits for your Give to: Claude Code · app takes teammates' cards only when you give them"), off)
        XCTAssertTrue(noStart.contains("start on cards on its own"), noStart)
        XCTAssertEqual(TeamWakeRule.verdict(.placedByAgent(fromTeammate: false), agent: agent, takesTeammatesCards: false, startsOnItsOwn: true), .wake,
                       "your own agent's placing needs only the start switch")
        XCTAssertNotEqual(TeamWakeRule.verdict(.placedByAgent(fromTeammate: false), agent: agent, takesTeammatesCards: true, startsOnItsOwn: false), .wake)
        XCTAssertNotEqual(TeamWakeRule.verdict(.placedByAgent(fromTeammate: true), agent: agent, takesTeammatesCards: false, startsOnItsOwn: true), .wake)
    }

    // MARK: Refusals

    func testARefusedChangeSaysWhatDidntGoThrough() {
        let card = UUID()
        let move = TeamCall.moveCard(card, to: .done)
        XCTAssertEqual(TeamRefusalLine.line(move, by: "You", reason: BoardError.finished.localizedDescription),
                       "Your move to Done didn't go through on the team's board: This card is done. Move it back to Ready first to work on it again.")
        XCTAssertEqual(TeamRefusalLine.line(.claimCard(card), by: "Claude Code · app", reason: "Claude Code (Dana) has this."),
                       "Claude Code · app's claim didn't go through on the team's board: Claude Code (Dana) has this.")
        XCTAssertEqual(TeamRefusalLine.what(.answer(card, text: "x")), "comment")
        XCTAssertEqual(TeamRefusalLine.what(.bringCard(card, binder: card, title: "x", fields: [:])), "share")
        XCTAssertTrue(TeamRefusalLine.line(.deleteCard(card), by: "You", reason: "").hasSuffix("board."))
    }

    // MARK: Distill's part

    func testDistillsSharedPartLeavesWhatThisMacNoticedHere() {
        let note = UUID(), distill = UUID(), item = UUID()
        let notice = DistilledFrom.Notice(by: "you", byAgent: false, at: Date(timeIntervalSince1970: 1_800_000_000), added: 3, removed: 1, gone: false)
        let here = DistilledFrom(note: note, distill: distill, item: item, section: "Auth flow", sectionHash: "abcd", version: "1760000000000",
                                 noticedHash: "ef01", held: true, change: notice, closed: Date(timeIntervalSince1970: 1_800_000_100))
        let shared = here.teamJSON
        let text = shared.text
        XCTAssertFalse(text.contains("ef01") || text.contains("held") || text.contains("change"), "what this Mac noticed stays here: \(text)")
        let back = DistilledFrom(team: shared, keeping: here)
        XCTAssertEqual(back, here, "read back on the same Mac, nothing is lost")
        let elsewhere = DistilledFrom(team: shared)
        XCTAssertEqual(elsewhere?.section, "Auth flow")
        XCTAssertEqual(elsewhere?.sectionHash, "abcd")
        XCTAssertEqual(elsewhere?.closed, here.closed)
        XCTAssertNil(elsewhere?.noticedHash)
        XCTAssertNil(elsewhere?.held)
        XCTAssertNil(DistilledFrom(team: .string("x")))
        XCTAssertNil(DistilledFrom(team: nil))
        // A card from a database before migration 5, or any other card, has none.
        XCTAssertNil(TeamCard(row: ["id": TeamJSON(UUID()), "binder_id": TeamJSON(UUID()), "title": "A"])?.distilled)
        XCTAssertNotNil(TeamCard(row: ["id": TeamJSON(UUID()), "binder_id": TeamJSON(UUID()), "title": "A", "distilled": shared])?.distilled)
    }

    // MARK: The status line and the link

    func testOfflineSaysWhatToCheck() {
        XCTAssertNil(TeamDatabaseStatus.connected.check)
        XCTAssertNil(TeamDatabaseStatus.offline(since: Date(), reason: "The login was refused", retrying: false).check,
                     "when someone has to act first, the reason says what")
        XCTAssertEqual(TeamDatabaseStatus.offline(since: Date(), reason: "", retrying: true).check,
                       "Check that your VPN (such as Covee) is connected and that the team database is one of its destinations.")
    }

    func testTeammatesAgentsAreAnnouncedBothWays() {
        XCTAssertEqual(LinkFeatures.teamAgents, "teamAgents")
        XCTAssertTrue(LinkFeatures.thisPhone.contains(LinkFeatures.teamAgents))
        XCTAssertFalse(LinkFeatures.firstPhone.contains(LinkFeatures.teamAgents))
        XCTAssertFalse(LinkFeatures.phone(nil).contains(LinkFeatures.teamAgents))
    }

    // MARK: Rows into the directory

    func testMembersAndAgentsComeFromTheirRows() {
        var team = TeamDirectory(me: sam)
        team.take(member: ["id": TeamJSON(sam), "name": "Sam", "login": "sam", "kind": "person", "is_admin": true,
                           "seen_at": .string("2026-10-21T10:42:00.123456+00:00")])
        team.take(member: ["id": TeamJSON(dana), "name": "Dana", "login": "dana", "deleted_at": .string("2026-10-21T10:00:00+00:00")])
        team.take(agent: ["id": TeamJSON(danas), "owner_id": TeamJSON(dana), "name": "Claude Code (Dana)", "binder_ids": TeamJSON([mine]),
                          "takes_team_cards": false, "sends_to": "Anthropic", "online_at": .string("2026-10-21T10:40:00+00:00")])
        XCTAssertEqual(team.myName, "Sam")
        XCTAssertTrue(team.members[sam]?.isAdmin == true && team.members[sam]?.seenAt != nil)
        XCTAssertEqual(team.members[dana]?.removed, true)
        XCTAssertEqual(team.agents[danas]?.binders, [mine])
        XCTAssertEqual(team.agents[danas]?.takesTeamCards, false)
        XCTAssertEqual(team.agents[danas]?.takes(binder: mine), true)
        XCTAssertEqual(team.agents[danas]?.takes(binder: nil), false)
        XCTAssertEqual(team.agents[danas]?.isOnline(at: TeamJSON.date(from: "2026-10-21T10:45:00+00:00")!), true)
        XCTAssertEqual(team.agents[danas]?.isOnline(at: TeamJSON.date(from: "2026-10-21T11:45:00+00:00")!), false)
        XCTAssertTrue(team.teammates.isEmpty, "a removed member isn't a teammate")
        // Kept on disk as JSON, read back the same.
        let data = try? JSONEncoder().encode(team)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(TeamDirectory.self, from: $0) }, team)
    }
}
