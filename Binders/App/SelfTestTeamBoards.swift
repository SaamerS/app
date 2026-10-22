import Foundation
import SwiftData
import PostgresNIO
import BindersKit

/// Lane DB2's self-tests, on TeamDBTestBed's throwaway Postgres: this Mac is Sam, the app itself (its BoardService,
/// dispatcher and TeamBoard, connected as Sam); a teammate is Alex, a second login acting through a TeamDatabase client of
/// its own, as another Mac would.
///
///     Binders --selftest-teamdb-boards   a teammate's changes here within a second, named; a local binder shared once, with
///                                        its waits; races; an offline change refused and put back; MCP; pruning
///     Binders --selftest-teamdb-agents   agents' public rows; teammates' cards and the switches; questions ring; Agents may
///                                        place work items
///     Binders --selftest-teamdb-team     setup and join, invites, members, Settings → Team's lines
@MainActor
final class TeamMac {
    let bed: TeamDBTestBed
    let controller: DictationController
    /// Each wake a web hook agent here got: its name and the card.
    private(set) var woke: [(agent: String, card: UUID)] = []

    var team: TeamBoard { controller.teamBoard }
    var board: BoardService { controller.board }

    private init(bed: TeamDBTestBed, controller: DictationController) {
        self.bed = bed
        self.controller = controller
    }

    /// The app as Sam, with these agents set up (a web hook's post stands in for each wake), connected and caught up.
    /// `server`: as another member, connected (no binder of its own yet).
    static func start(_ bed: TeamDBTestBed, agents: [AgentProfile] = [], as server: TeamDatabaseServer? = nil) async throws -> TeamMac {
        let controller = DictationController()
        let mac = TeamMac(bed: bed, controller: controller)
        for agent in agents {
            if let problem = AgentRegistry.shared.upsert(agent, startsOnItsOwn: agent.autoStart == true) {
                throw TeamDatabase.Problem.refused("couldn't set up \(agent.name): \(problem)")
            }
        }
        controller.agents.standIn = { [weak mac] agent, data in
            let card = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["card"] as? String
            mac?.woke.append((agent.name, card.flatMap(UUID.init(uuidString:)) ?? UUID()))
        }
        _ = controller.board
        let team = controller.teamBoard
        team.trust = bed.postgres.trust
        team.folderOverride = AppPaths.support.appendingPathComponent("board-sam", isDirectory: true)
        team.prepare = { $0.testHooks.reconnectDelay = 0.2 }
        team.editDelay = .milliseconds(150)
        TeamBoard.save(server ?? bed.sam)
        team.run(server ?? bed.sam)
        let ready = await bed.eventually(30) {
            if server != nil { return team.isConnected && team.directory.me != nil }
            return team.isConnected && Store.shared.binder(bed.shared)?.teamDatabaseKey == bed.sam.key && team.directory.myName == "Sam"
        }
        guard ready else { throw TeamDatabase.Problem.refused("this Mac didn't catch up: \(team.status)") }
        return mac
    }

    func stop() async {
        await team.stop()
    }

    func card(_ id: UUID) -> TaskCard? { board.card(id) }

    func wakes(of card: UUID) -> [String] { woke.filter { $0.card == card }.map(\.agent) }

    /// A tool call as `actor`, as an agent's MCP server or the iPhone makes it.
    func mcp(_ tool: String, _ arguments: [String: Any], as actor: BoardActor) async -> (ok: Bool, text: String) {
        do {
            return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller),
                                                   actor: actor))
        } catch {
            return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription)
        }
    }

    /// An agent's claim over MCP.
    func claim(_ card: UUID, as agent: String) async -> (ok: Bool, text: String) {
        await mcp("claim_task", ["id": card.uuidString], as: BoardActor(name: agent, kind: .agent))
    }

    /// Until nothing waits in the outbox.
    func drained(_ timeout: TimeInterval = 15) async -> Bool {
        await bed.eventually(timeout) { (self.team.database?.waiting ?? 1) == 0 }
    }

    static func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:] }
    static func list(_ text: String) -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? [] }
}

extension TeamDBTestBed {
    /// Alex's own client, connected: a teammate's Mac.
    func teammate() async throws -> TeamDatabase {
        let alex = client(alex, folder: "alex")
        try await waitConnected(alex)
        return alex
    }

    /// A card made by a teammate on the Shared board, in Ready.
    func made(_ title: String, by teammate: TeamDatabase, meantFor: String? = nil) async throws -> UUID {
        let id = UUID()
        let made = try await teammate.call(.createCard(id, binder: shared, title: title, fields: ["column": "ready"]))
        guard made.ok else { throw TeamDatabase.Problem.refused("create_card: \(made.refusal?.message ?? "")") }
        if let meantFor {
            let meant = try await teammate.call(.assignCard(id, to: meantFor))
            guard meant.ok else { throw TeamDatabase.Problem.refused("assign_card: \(meant.refusal?.message ?? "")") }
        }
        return id
    }
}

extension SelfTest {
    // MARK: Boards

    @MainActor
    static func teamBoardChecks(_ bed: TeamDBTestBed) async throws {
        let agentA = AgentProfile(id: bed.agentA, name: "Agent A", wake: .webhook(url: "https://example.invalid/agent-a"), report: .mcp)
        let mac = try await TeamMac.start(bed, agents: [agentA])
        let alex = try await bed.teammate()
        func ms(_ seconds: TimeInterval) -> String { "\(Int(seconds * 1000)) ms" }

        // MARK: A teammate's create, claim, move and comment, here within a second, named as this Mac names them.
        var started = Date()
        let draft = try await bed.made("Draft the launch post", by: alex)
        var arrived = await bed.eventually(5) { mac.card(draft) != nil }
        var took = Date().timeIntervalSince(started)
        bed.check(arrived && took < 1, "a teammate's new card shows here in \(ms(took))")
        bed.check(mac.card(draft)?.createdBy == "Alex" && mac.card(draft)?.column == .ready, "made by Alex, in Ready: \(mac.card(draft)?.createdBy ?? "-")")
        started = Date()
        _ = try await alex.call(.claimCard(draft))
        arrived = await bed.eventually(5) { mac.card(draft)?.assignee == "Alex" }
        took = Date().timeIntervalSince(started)
        bed.check(arrived && took < 1 && mac.card(draft)?.column == .inProgress && mac.card(draft)?.assigneeIsAgent == false,
                  "Alex takes it: here in \(ms(took)), Alex has it, In progress")
        started = Date()
        _ = try await alex.call(.moveCard(draft, to: .review))
        arrived = await bed.eventually(5) { mac.card(draft)?.column == .review }
        took = Date().timeIntervalSince(started)
        bed.check(arrived && took < 1, "Alex moves it to Review: here in \(ms(took))")
        started = Date()
        _ = try await alex.call(.answer(draft, text: "Looks good to me."))
        arrived = await bed.eventually(5) { mac.board.timeline(draft).contains { $0.kind == .comment && $0.author == "Alex" && $0.text == "Looks good to me." } }
        took = Date().timeIntervalSince(started)
        bed.check(arrived && took < 1, "Alex's comment, by Alex: here in \(ms(took))")
        let kinds = mac.board.timeline(draft).map(\.kindRaw)
        bed.check(kinds == ["created", "claimed", "moved", "comment"], "its timeline, in order, once each: \(kinds)")
        let theirs = try await bed.made("Check the screenshots", by: alex)
        _ = try await alex.call(.claimCard(theirs, agent: bed.agentC))
        arrived = await bed.eventually(5) { mac.card(theirs)?.assignee == "Agent C (Alex)" && mac.card(theirs)?.assigneeIsAgent == true }
        bed.check(arrived, "a teammate's agent holds it with its owner: \(mac.card(theirs)?.assignee ?? "-")")
        // Yours: You here, Sam there.
        let mine = try await bed.made("Proofread the post", by: alex)
        _ = await bed.eventually(5) { mac.card(mine) != nil }
        if let card = mac.card(mine) {
            try mac.board.claim(card, by: .you)
            bed.check(card.assignee == "You" && card.column == .inProgress, "you take one: it shows at once")
            _ = await mac.drained()
            let row = try await alex.rows(.cards, ids: [mine]).first
            bed.check(row?["holder_name"]?.string == "Sam" && row?["holder_member_id"]?.uuid == bed.samID, "the team sees Sam has it")
            bed.check(card.assignee == "You" && !mac.board.timeline(mine).contains { $0.teamOperation != nil },
                      "and here it's still You, the line the database wrote in place of the one written here")
            bed.check(mac.board.timeline(mine).filter { $0.kind == .claimed }.count == 1, "one claim line, not two")
        }

        // MARK: Sharing a local binder brings its board in once, with its waits.
        let launch = BinderRecord(name: "Launch", colorIndex: 3)
        Store.shared.insert(launch)
        let notes = mac.board.create(title: "Write the release notes", binderID: launch.id, column: .ready, by: .you)
        let site = mac.board.create(title: "Update the site", binderID: launch.id, column: .backlog, by: .you)
        try mac.board.setWaits(site, to: [notes.id], by: .you)
        let tag = mac.board.create(title: "Tag the build", binderID: launch.id, column: .ready, by: .you)
        try mac.board.complete(tag, summary: "Tagged.", by: .you)
        try mac.board.claim(notes, by: .you)
        bed.check(mac.team.database?.waiting == 0, "a local binder's board changes nothing in the database")
        mac.team.share(launch, everyone: false, with: [bed.alexID])
        bed.check(await mac.drained(), "shared: its binder, its member and its board went")
        var rows = try await alex.rows(.cards, binder: launch.id)
        func row(_ id: UUID) -> TeamRow? { rows.first { $0.rowID == id } }
        bed.check(rows.count == 3, "Alex sees its 3 cards: \(rows.count)")
        bed.check(row(tag.id)?["board_column"]?.string == "done", "Done stays Done")
        bed.check(row(notes.id)?["board_column"]?.string == "in_progress" && row(notes.id)?["holder_member_id"]?.uuid == bed.samID,
                  "what you hold stays yours")
        var waits = try await alex.rows(.cardDependencies, binder: launch.id)
        bed.check(waits.count == 1 && waits.first?["card_id"]?.uuid == site.id && waits.first?["waits_for_id"]?.uuid == notes.id,
                  "and what waits for what: \(waits.count)")
        // Again: nothing twice.
        for card in [notes, site, tag] { mac.team.database?.send(mac.team.bringCall(card)) }
        mac.team.database?.send(.bringWait(site.id, waitsFor: notes.id))
        _ = await mac.drained()
        rows = try await alex.rows(.cards, binder: launch.id)
        waits = try await alex.rows(.cardDependencies, binder: launch.id)
        let brought = try await alex.rows(.cardEvents, binder: launch.id).filter { ($0["text"]?.string ?? "").hasPrefix("Brought onto the team's board") }
        bed.check(rows.count == 3 && waits.count == 1 && brought.count == 3, "brought in again: still 3 cards, 1 wait, 1 line each (\(rows.count), \(waits.count), \(brought.count))")
        bed.check(mac.board.cards(in: launch.id).count == 3, "and this Mac has each card once")
        let siteRow = await bed.eventually(5) { site.waitsFor == [notes.id.uuidString] && TeamCardShadow(site.teamShadow) != nil }
        bed.check(siteRow, "the card that waits still waits here, as the database has it")

        // MARK: Races: this Mac's agent and a teammate's agent take the same card. One wins; the other side is told who did.
        var here = 0, there = 0, both = 0
        for round in 1...10 {
            let id = try await bed.made("Race \(round)", by: alex)
            _ = await bed.eventually(5) { mac.card(id) != nil }
            // Every other round, Alex's agent is a moment late: this Mac's agent's claim goes further to get there.
            let late = round % 2 == 1 ? 0 : 40
            async let mineClaim = mac.claim(id, as: "Agent A")
            async let theirClaim = { () async throws -> TeamResult in
                try await Task.sleep(for: .milliseconds(late))
                return try await alex.call(.claimCard(id, agent: bed.agentC))
            }()
            let ours = await mineClaim
            let them = try await theirClaim
            let holder = try await alex.rows(.cards, ids: [id]).first?["holder_agent_id"]?.uuid
            if ours.ok && them.ok { both += 1 }
            if holder == bed.agentA {
                here += 1
                bed.check(!them.ok && them.refusal?.code == "claimed_by" && them.refusal?.holder == "Agent A (Sam)",
                          "race \(round): this Mac's agent won, and Alex's side was told Agent A (Sam) has it")
            } else if holder == bed.agentC {
                there += 1
                let shown = await bed.eventually(5) { mac.card(id)?.assignee == "Agent C (Alex)" }
                bed.check(!ours.ok && ours.text.contains("Agent C (Alex)") && shown,
                          "race \(round): Alex's agent won; this Mac's agent heard so (\(ours.text.prefix(70))) and this Mac shows it")
            } else {
                bed.check(false, "race \(round): someone holds the card")
            }
        }
        bed.check(both == 0 && here + there == 10, "10 races, one winner each (here \(here), there \(there))")

        // MARK: Offline: taking a card waits for the database (lane DB8); a question kept here that the database refuses
        // once it's back is put back, with a line that says why.
        let venue = try await bed.made("Book the venue", by: alex)
        _ = await bed.eventually(5) { mac.card(venue) != nil }
        await mac.team.database?.stop()
        if let card = mac.card(venue) {
            var refused = ""
            do { try mac.board.claim(card, by: .you) } catch { refused = error.localizedDescription }
            bed.check(refused == TeamBoardWrites.refusal(.claim, .unreachable, agent: false) && card.column == .ready && card.assignee == nil
                        && mac.team.database?.waiting == 0,
                      "offline, your claim is refused at once, and nothing changed or waits: \(refused.prefix(60))")
            let refusedHere = await mac.claim(venue, as: "Agent A")
            bed.check(!refusedHere.ok && refusedHere.text == TeamBoardWrites.refusal(.claim, .unreachable, agent: true),
                      "an agent's claim is refused at once while the board is out of reach")
            let asked = await mac.mcp("ask_on_task", ["id": venue.uuidString, "question": "Which hall?"], as: BoardActor(name: "Agent A", kind: .agent))
            bed.check(asked.ok && asked.text.contains(TeamBoardWrites.kept(.unreachable)) && card.column == .blocked && mac.team.database?.waiting == 1,
                      "an agent's question is kept here, and waits: \(asked.text.prefix(60))")
            _ = try await alex.call(.claimCard(venue, agent: bed.agentC))
            mac.team.database?.start()
            let putBack = await bed.eventually(20) {
                card.column == .inProgress && card.assignee == "Agent C (Alex)" && mac.board.timeline(venue).contains {
                    $0.author == "Binders" && $0.text.hasPrefix("Agent A's question didn't go through on the team's board:")
                }
            }
            bed.check(putBack, "back online, the database refused it (Alex's agent took the card meanwhile): put back, with why: \(mac.board.timeline(venue).last?.text ?? "-")")
            bed.check(!mac.board.timeline(venue).contains { $0.teamOperation != nil }, "as the database has it, no line left waiting")
        }
        _ = await bed.eventually(20) { mac.team.isConnected }

        // MARK: MCP: the board tools work through the database, as this Mac's agent, named with its owner there.
        let agent = BoardActor(name: "Agent A", kind: .agent)
        let made = await mac.mcp("create_task", ["title": "Write the FAQ", "binder": "Shared", "column": "ready"], as: agent)
        let faq = (TeamMac.object(made.text)["id"] as? String).flatMap(UUID.init(uuidString:))
        bed.check(made.ok && faq != nil, "create_task on a shared board: \(made.text.prefix(80))")
        if let faq {
            _ = await mac.drained()
            var faqRow = try await alex.rows(.cards, ids: [faq]).first
            bed.check(faqRow?["created_by_agent"]?.uuid == bed.agentA && faqRow?["created_by_name"]?.string == "Agent A (Sam)",
                      "made by Agent A (Sam) in the team's board")
            let claimed = await mac.claim(faq, as: "Agent A")
            faqRow = try await alex.rows(.cards, ids: [faq]).first
            bed.check(claimed.ok && faqRow?["holder_agent_id"]?.uuid == bed.agentA, "claim_task: the database says Agent A has it (\(claimed.text.prefix(60)))")
            let reported = await mac.mcp("update_task", ["id": faq.uuidString, "progress": "Drafted six questions"], as: agent)
            _ = await mac.drained()
            let lines = try await alex.rows(.cardEvents, binder: bed.shared).filter { $0["card_id"]?.uuid == faq }
            bed.check(reported.ok && lines.contains { $0["kind"]?.string == "progress" && $0["author_name"]?.string == "Agent A (Sam)" && $0["author_agent_id"]?.uuid == bed.agentA },
                      "update_task: its report is in the team's timeline, by Agent A (Sam)")
            let asked = await mac.mcp("ask_on_task", ["id": faq.uuidString, "question": "Should it cover refunds?"], as: agent)
            bed.check(asked.ok && mac.card(faq)?.column == .blocked, "ask_on_task: Blocked")
            _ = try await alex.call(.answer(faq, text: "Yes, briefly."))
            let answered = await bed.eventually(5) { mac.card(faq)?.column == .inProgress }
            bed.check(answered, "Alex answers: back to In progress here")
            let finished = await mac.mcp("complete_task", ["id": faq.uuidString, "summary": "FAQ written."], as: agent)
            faqRow = try await alex.rows(.cards, ids: [faq]).first
            bed.check(finished.ok && faqRow?["board_column"]?.string == "review", "complete_task: Review, in the database")
            let listed = TeamMac.list((await mac.mcp("list_tasks", ["binder": "Shared"], as: agent)).text)
            bed.check(listed.contains { $0["title"] as? String == "Check the screenshots" && $0["assignee"] as? String == "Agent C (Alex)" },
                      "list_tasks shows a teammate's card and who has it")
            let task = TeamMac.object((await mac.mcp("get_task", ["id": draft.uuidString], as: agent)).text)
            let timeline = task["timeline"] as? [[String: Any]] ?? []
            bed.check(timeline.contains { $0["who"] as? String == "Alex" && $0["kind"] as? String == "comment" }, "get_task shows Alex's comment, by Alex")
            let agents = TeamMac.object((await mac.mcp("list_agents", [:], as: agent)).text)["agents"] as? [[String: Any]] ?? []
            let teammate = agents.first { $0["name"] as? String == "Agent C (Alex)" }
            bed.check(teammate?["teammate"] as? Bool == true && teammate?["wakes"] as? String == "teammate" && teammate?["owner"] as? String == "Alex",
                      "list_agents adds Agent C (Alex), a teammate's, which this Mac can't wake")
            bed.check(agents.first { $0["name"] as? String == "Agent A" }?["wakes"] as? String == "webhook", "yours keep their keys: \(agents.count) agents")
        }

        // MARK: Pruning keeps what a Mac still needs.
        try await pruning(bed, mac: mac, alex: alex)
        await mac.stop()
    }

    /// Alex's other Mac reads the feed, says how far it read and goes quiet; more changes come; everything is made older than
    /// the 30 days kept; a prune deletes only what every recently seen Mac has read, and a Mac that read less than what
    /// was pruned reads its binders whole again.
    @MainActor
    private static func pruning(_ bed: TeamDBTestBed, mac: TeamMac, alex: TeamDatabase) async throws {
        let root = try await bed.root()
        let alexMac = bed.client(bed.alex, folder: "alex-mac")
        let reading = Task { @MainActor in for await update in alexMac.updates { alexMac.acknowledge(update) } }
        try await bed.waitConnected(alexMac)
        let last = try await root.value("SELECT max(seq) FROM binders.changes", as: Int64.self) ?? 0
        _ = await bed.eventually(10) { alexMac.acknowledgedSeq >= last }
        let read = alexMac.acknowledgedSeq
        _ = try await alexMac.call(.seen(seq: read, agents: []))
        await alexMac.stop()
        reading.cancel()
        _ = try await bed.made("Order the banners", by: alex)
        _ = try await bed.made("Print the badges", by: alex)
        _ = await bed.eventually(5) { mac.board.cards(in: bed.shared).contains { $0.title == "Print the badges" } }
        if let database = mac.team.database {
            _ = await bed.eventually(5) { database.acknowledgedSeq >= read + 2 }
            _ = try await database.call(.seen(seq: database.acknowledgedSeq, agents: []))
        }
        let after = try await root.value("SELECT count(*) FROM binders.changes WHERE seq > $1::bigint", [String(read)], as: Int64.self) ?? 0
        try await root.execute("UPDATE binders.changes SET at = now() - interval '40 days'")
        try await root.execute("UPDATE binders.operations SET created_at = now() - interval '40 days'")
        let pruned = try await mac.team.database?.call(.prune())
        bed.check(pruned?.ok == true && (pruned?.body["changes"]?.int ?? 0) > 0, "prune: \(pruned?.body["changes"]?.int ?? -1) changes and \(pruned?.body["operations"]?.int ?? -1) operation records went")
        let oldest = try await root.value("SELECT min(seq) FROM binders.changes", as: Int64.self) ?? 0
        let kept = try await root.value("SELECT count(*) FROM binders.changes WHERE seq > $1::bigint", [String(read)], as: Int64.self) ?? 0
        bed.check(oldest > read && kept >= after, "what Alex's quiet Mac still needs is kept (from \(oldest), after \(read): \(kept) of \(after))")
        let operations = try await root.value("SELECT count(*) FROM binders.operations WHERE created_at < now() - interval '30 days'", as: Int64.self) ?? -1
        bed.check(operations == 0, "operation records older than 30 days went")
        let through = try await root.value("SELECT changes_pruned_through FROM binders.team_settings", as: Int64.self) ?? 0
        bed.check(through == read, "the team knows how far it was pruned: \(through)")
        // A Mac that read less than that reads its binders whole again, so nothing it missed is lost.
        let folder = AppPaths.support.appendingPathComponent("team-alex-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"acknowledgedSeq":1,"binders":["\#(bed.shared.uuidString)"]}"#.utf8).write(to: folder.appendingPathComponent("state.json"))
        let stale = bed.client(bed.alex, folder: "alex-stale")
        var whole = false
        let staleReading = Task { @MainActor in
            for await update in stale.updates {
                if update.bindersAdded.contains(bed.shared) { whole = true }
                stale.acknowledge(update)
            }
        }
        try await bed.waitConnected(stale)
        bed.check(await bed.eventually(10) { whole }, "a Mac whose last number was pruned reads its binders whole again")
        await stale.stop()
        staleReading.cancel()
    }
}
