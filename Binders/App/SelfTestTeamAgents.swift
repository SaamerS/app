import Foundation
import SwiftData
import BindersKit

/// Lane DB2's agents on the team database (`--selftest-teamdb-agents`): what the team sees of this Mac's agents and never
/// sees, a teammate's card starting your agent only as its switches say, questions ringing for the asking agent's owner
/// and whoever the card is for, and Agents may place work items. A web hook's post stands in for each wake.
extension SelfTest {
    @MainActor
    static func teamAgentChecks(_ bed: TeamDBTestBed) async throws {
        // Agent A: a web hook with a token in its address, its start switch on (with its yes). Agent B: a command with a
        // token and a folder, reporting over SSH, its Sends cards to an address: nothing of how either runs reaches the team.
        var agentA = AgentProfile(id: bed.agentA, name: "Agent A", wake: .webhook(url: "https://hooks.example.invalid/a?token=s3cr3t"),
                                  report: .mcp, vendor: "Anthropic", purpose: "writes release notes", autoStart: true)
        let agentB = AgentProfile(id: bed.agentB, name: "Agent B", wake: .command(command: "deploy --token s3cr3t", folder: "/Users/sam/secret-repo"),
                                  report: .ssh(host: "sam@build-box.local"), vendor: "hooks.example.invalid", purpose: "reads specs")
        let mac = try await TeamMac.start(bed, agents: [agentA, agentB])
        let alex = try await bed.teammate()
        let check = bed.check

        // MARK: What the team sees of this Mac's agents
        _ = await mac.drained()
        let published = await bed.eventually(10) { mac.team.state.published[bed.agentA] != nil && mac.team.state.published[bed.agentB] != nil }
        _ = await mac.drained()
        // Published again once the shared binders have arrived here (TeamBoard.sharedChanged): a moment after the first.
        for _ in 0..<50 {
            let row = try? await alex.rows(.agents, binder: UUID()).first { $0.rowID == bed.agentA }
            if row?["binder_ids"]?.array?.compactMap(\.uuid).contains(bed.shared) == true { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let rows = try await alex.rows(.agents, binder: UUID())
        let mine = rows.filter { $0["owner_id"]?.uuid == bed.samID }
        let text = TeamJSON.array(mine.map { .object($0) }).text
        check(published && mine.count >= 2, "this Mac published its agents: \(mine.count)")
        for secret in ["s3cr3t", "hooks.example.invalid", "secret-repo", "/Users/sam", "deploy", "acceptEdits", "build-box", "ssh"] {
            check(!text.contains(secret), "an agent's row never says “\(secret)”")
        }
        let rowA = mine.first { $0.rowID == bed.agentA }, rowB = mine.first { $0.rowID == bed.agentB }
        check(rowA?["name"]?.string == "Agent A (Sam)" && rowA?["kind"]?.string == "webhook" && rowA?["sends_to"]?.string == "Anthropic"
              && rowA?["purpose"]?.string == "writes release notes", "Agent A: its name with its owner, how it's woken as a word, who it sends cards to, what it's for")
        check(rowA?["takes_team_cards"]?.bool == true && rowB?["takes_team_cards"]?.bool == false,
              "whether it starts on teammates' cards: A yes (both switches on), B no (no start switch)")
        check(rowB?["sends_to"]?.string == "", "an address isn't said as who it sends cards to")
        check(rowA?["binder_ids"]?.array?.compactMap(\.uuid).contains(bed.shared) == true, "the shared binders it takes cards from")

        // MARK: A teammate's card starts your agent when its switches are on
        let first = try await bed.made("Write the release notes", by: alex, meantFor: "Agent A (Sam)")
        check(await bed.eventually(8) { mac.wakes(of: first) == ["Agent A"] }, "a card Alex meant for Agent A starts it: its switches are on")
        check(mac.card(first)?.meantFor == "Agent A" && mac.card(first)?.meantForByAgent == false, "meant for it, by a person")
        check(mac.board.timeline(first).contains { $0.kind == .woke && $0.text.contains("hooks.example.invalid") }, "this Mac keeps the wake's receipt")
        _ = await mac.drained()
        let teamLines = try await alex.rows(.cardEvents, binder: bed.shared)
        check(!teamLines.contains { ($0["text"]?.string ?? "").contains("hooks.example.invalid") } && !teamLines.contains { $0["kind"]?.string == "woke" },
              "the team's timeline never has it: where a web hook is stays on this Mac")
        // Take cards from teammates off: it waits for your Give to.
        agentA.takesTeamCards = false
        _ = AgentRegistry.shared.upsert(agentA, startsOnItsOwn: true)
        let second = try await bed.made("Write the changelog", by: alex, meantFor: "Agent A (Sam)")
        let waiting = await bed.eventually(8) {
            mac.board.timeline(second).contains { $0.text == "Waits for your Give to: Agent A takes teammates' cards only when you give them." }
        }
        try? await Task.sleep(for: .milliseconds(2600))
        check(waiting && mac.wakes(of: second).isEmpty, "with Take cards from teammates off, it waits, and the card says why")
        if let card = mac.card(second) {
            check(mac.controller.agents.waitsForYourGiveTo(card), "it waits for your Give to")
            let handed = mac.board.give(card, to: "Agent A", by: .you)
            let given = await bed.eventually(5) { mac.wakes(of: second) == ["Agent A"] }
            check(handed == .woke && given, "your Give to hands it over: \(handed)")
        }
        // The start switch off: it waits too.
        agentA.takesTeamCards = nil
        agentA.autoStart = nil
        _ = AgentRegistry.shared.upsert(agentA, startsOnItsOwn: false)
        let third = try await bed.made("Write the press note", by: alex, meantFor: "Agent A (Sam)")
        let noStart = await bed.eventually(8) {
            mac.board.timeline(third).contains { $0.text.hasPrefix("Waits for your Give to: Agent A starts on teammates' cards only once it may start on cards on its own") }
        }
        try? await Task.sleep(for: .milliseconds(2600))
        check(noStart && mac.wakes(of: third).isEmpty, "with its start switch off, it waits")
        // Both on again; a card an agent pointed at it starts nothing.
        agentA.autoStart = true
        _ = AgentRegistry.shared.upsert(agentA, startsOnItsOwn: true)
        let pointed = try await bed.made("Fix the broken link", by: alex)
        _ = try await alex.call(.assignCard(pointed, to: "Agent A (Sam)", agent: bed.agentC))
        _ = await bed.eventually(5) { mac.card(pointed)?.meantFor == "Agent A" }
        try? await Task.sleep(for: .milliseconds(2600))
        check(mac.card(pointed)?.meantForByAgent == true && mac.wakes(of: pointed).isEmpty, "a card Alex's agent pointed at Agent A starts nothing")
        // A teammate's change wakes only this Mac's agents: Alex's own agent isn't woken here.
        let theirs = try await bed.made("Sort the photos", by: alex, meantFor: "Agent C (Alex)")
        _ = await bed.eventually(5) { mac.card(theirs)?.meantFor == "Agent C (Alex)" }
        try? await Task.sleep(for: .milliseconds(2600))
        check(mac.wakes(of: theirs).isEmpty, "a card meant for a teammate's agent wakes nothing here")

        // MARK: Questions ring on the asking agent's owner's Mac, and for whoever the card is meant for
        let invite = try await mac.team.addMember(login: "helper_bot", name: "Helper login", agentName: "Helper Bot")
        let helperMember = mac.team.directory.members.values.first { $0.login == "helper_bot" }
        let helperAgent = mac.team.directory.agents.values.first { $0.login == helperMember?.id }
        check(helperAgent?.name == "Helper Bot (Sam)" && helperAgent?.owner == bed.samID, "Sam's headless agent, with its owner: \(helperAgent?.name ?? "-")")
        if let helperMember {
            _ = try await mac.team.database?.call(.shareBinder(bed.shared, with: helperMember.id))
        }
        let helper = TeamDatabase.join(invite, trust: bed.postgres.trust)
        helper.testHooks.reconnectDelay = 0.2
        try await bed.waitConnected(helper)
        let forAlex = try await bed.made("Book the room", by: alex, meantFor: "Alex")
        // Its Auto (migration 8, lane DB5): off at first, so it takes no card; Sam, its owner, turns it on from this Mac.
        let offClaim = try await helper.call(.claimCard(forAlex))
        check(offClaim.refusal?.code == "auto_off" && offClaim.refusal?.owner == "Sam", "Sam's headless agent takes no card until Sam turns on its Auto")
        if let helperAgent { try await mac.team.setAuto(helperAgent, on: true) }
        check(mac.team.directory.agents[helperAgent?.id ?? UUID()]?.auto == true, "Settings → Team's switch turns its Auto on")
        let onClaim = try await helper.call(.claimCard(forAlex))
        check(onClaim.ok, "and then it takes the card")
        _ = try await helper.call(.ask(forAlex, question: "Which floor?"))
        check(await bed.eventually(5) { mac.team.rang.contains { $0.card == forAlex && $0.kind == "question" } },
              "Sam's headless agent asks: it rings on Sam's Mac, its owner's")
        let forSam = try await bed.made("Pick the date", by: alex, meantFor: "Sam")
        _ = try await alex.call(.claimCard(forSam, agent: bed.agentC))
        _ = try await alex.call(.ask(forSam, question: "Tuesday or Thursday?", agent: bed.agentC))
        check(await bed.eventually(5) { mac.team.rang.contains { $0.card == forSam && $0.kind == "question" } },
              "Alex's agent asks on a card meant for Sam: it rings here")
        let alexsOwn = try await bed.made("Sort the invoices", by: alex, meantFor: "Alex")
        _ = try await alex.call(.claimCard(alexsOwn, agent: bed.agentC))
        _ = try await alex.call(.ask(alexsOwn, question: "Which year?", agent: bed.agentC))
        _ = await bed.eventually(5) { mac.card(alexsOwn)?.column == .blocked }
        check(!mac.team.rang.contains { $0.card == alexsOwn }, "Alex's agent on Alex's card rings on Alex's Mac, not here")
        await helper.stop()
        TeamDatabase.forget(invite.server)

        // MARK: Who decides on an approval (migration 8, lane DB5): the asking agent's owner, or whoever the card is for
        let request = AgentApproval(action: "Send an email", recipients: ["printer@example.com"], text: "Please print 200 badges.")
        let alexsAsk = try await bed.made("Order the badges", by: alex)
        _ = try await alex.call(.claimCard(alexsAsk, agent: bed.agentC))
        _ = try await alex.call(.requestApproval(alexsAsk, text: request.timelineText, agent: bed.agentC))
        _ = await bed.eventually(5) { mac.card(alexsAsk)?.column == .blocked && mac.card(alexsAsk)?.waitingApproval() != nil }
        guard let asking = mac.card(alexsAsk) else { return check(false, "Alex's agent's request for approval is here") }
        check(mac.team.decides(asking, askedBy: "Agent C (Alex)") == false && !mac.team.rang.contains { $0.card == alexsAsk },
              "what Alex's agent asks approval for, on a card that isn't Sam's, isn't Sam's to decide, and doesn't ring here")
        do {
            _ = try mac.board.decide(asking, approve: true, by: .you, on: "Test Mac")
            check(false, "Sam's Mac refuses to decide on it")
        } catch {
            check(error.localizedDescription == "Only Alex can decide on this: it's their agent asking.",
                  "Sam's Mac refuses to decide on it, before sending, saying who can: \(error.localizedDescription)")
        }
        mac.board.comment(asking, text: "Approved", by: .you)
        check(asking.column == .blocked && mac.board.timeline(alexsAsk).last?.kind == .comment, "Sam's “Approved” is a comment: it keeps waiting")
        _ = await mac.drained()
        let stillWaiting = try await alex.rows(.cards, ids: [alexsAsk]).first?["board_column"]?.string
        check(stillWaiting == "blocked", "and the team's database has it so too")
        // Meant for Sam, by a person: Sam decides, and it rings here.
        let forSamToo = try await bed.made("Post the schedule", by: alex, meantFor: "Sam")
        _ = try await alex.call(.claimCard(forSamToo, agent: bed.agentC))
        _ = try await alex.call(.requestApproval(forSamToo, text: request.timelineText, agent: bed.agentC))
        check(await bed.eventually(5) { mac.team.rang.contains { $0.card == forSamToo && $0.kind == "approval" } },
              "Alex's agent's request on a card meant for Sam rings here")
        if let card = mac.card(forSamToo) {
            let said = try mac.board.decide(card, approve: true, by: .you, on: "Test Mac")
            _ = await mac.drained()
            let decided = try await alex.rows(.cards, ids: [forSamToo]).first?["board_column"]?.string
            check(said.hasPrefix("Approved.") && decided == "in_progress", "and Sam decides it: \(said)")
        }

        // MARK: Agents may place work items
        try await placing(bed, mac: mac, alex: alex)
        await mac.stop()
    }

    /// Off, an agent's propose_work_items is a proposal and no cards; on, its cards go to Ready on the team's board, meant
    /// for whoever it picked, waiting as proposed, and agents take them in order. The database checks the switch itself.
    @MainActor
    private static func placing(_ bed: TeamDBTestBed, mac: TeamMac, alex: TeamDatabase) async throws {
        let check = bed.check
        let note = NoteItem(text: "# Launch spec\n\n## Notes\nWrite the release notes.\n\n## Site\nPublish them on the site.")
        note.binderID = bed.shared
        note.distill = true
        Store.shared.insert(note)
        let scribe = BoardActor(name: "Agent B", kind: .agent)
        let items: [[String: Any]] = [["title": "Draft the release notes", "section": "Notes", "for": "Agent A"],
                                      ["title": "Publish the notes on the site", "section": "Site", "waits_for": [1], "for": "Agent A"]]
        let before = try await alex.rows(.cards, binder: bed.shared).count
        let proposed = await mac.mcp("propose_work_items", ["id": note.id.uuidString, "items": items], as: scribe)
        _ = await mac.drained()
        let after = try await alex.rows(.cards, binder: bed.shared).count
        check(proposed.ok && after == before, "off: an agent's work items are a proposal, and no cards (\(proposed.text.prefix(80)))")
        // On, for this binder: the switch goes to the team's binder too.
        guard let shared = Store.shared.binder(bed.shared) else { return check(false, "the shared binder is here") }
        shared.agentsMayPlace = true
        Store.shared.save()
        let switched = await bed.eventually(10) {
            mac.team.state.binders[bed.shared]?.agentsMayPlace == true
        }
        check(switched, "the switch reaches the team's binder")
        let again = await mac.mcp("propose_work_items", ["id": note.id.uuidString,
                                                         "items": [["title": "Draft the launch email", "section": "Notes", "for": "Agent A"],
                                                                   ["title": "Send the launch email", "section": "Site", "waits_for": [1], "for": "Agent A"]]],
                                  as: scribe)
        _ = await mac.drained()
        let rows = try await alex.rows(.cards, binder: bed.shared)
        let draft = rows.first { $0["title"]?.string == "Draft the launch email" }, send = rows.first { $0["title"]?.string == "Send the launch email" }
        check(again.ok && draft?["board_column"]?.string == "ready" && send?["board_column"]?.string == "ready",
              "on: its cards are on the team's board, in Ready (\(again.text.prefix(90)))")
        check(draft?["meant_for"]?.string == "Agent A (Sam)" && draft?["meant_for_by_agent"]?.bool == false,
              "meant for whoever it picked, as an assignment")
        let deps = try await alex.rows(.cardDependencies, binder: bed.shared)
        check(deps.contains { $0["card_id"]?.uuid == send?.rowID && $0["waits_for_id"]?.uuid == draft?.rowID }, "waiting as proposed")
        let lines = try await alex.rows(.cardEvents, binder: bed.shared)
        check(lines.contains { $0["card_id"]?.uuid == draft?.rowID && $0["author_name"]?.string == "Binders"
                && $0["text"]?.string == "Meant for Agent A (Sam): placed by Agent B (Sam), which this binder lets place work items." },
              "the database says which agent placed it")
        if let first = draft?.rowID, let second = send?.rowID {
            check(await bed.eventually(8) { mac.wakes(of: first) == ["Agent A"] }, "Agent A, which may start on its own, takes the first")
            check(mac.wakes(of: second).isEmpty, "not the one that waits for it")
            let claimed = await mac.claim(first, as: "Agent A")
            let done = await mac.mcp("complete_task", ["id": first.uuidString, "summary": "Drafted."], as: BoardActor(name: "Agent A", kind: .agent))
            if let card = mac.card(first) { try mac.board.move(card, to: .done, by: .you) }
            check(claimed.ok && done.ok && mac.card(first)?.column == .done, "it's done, and you approve it")
            check(await bed.eventually(8) { mac.wakes(of: second) == ["Agent A"] }, "then Agent A takes the next one: in order")
        }
        // The database checks the switch itself: off, a teammate's agent can't place either.
        shared.agentsMayPlace = false
        Store.shared.save()
        _ = await bed.eventually(10) { mac.team.state.binders[bed.shared]?.agentsMayPlace == false }
        _ = await mac.drained()
        let item = TeamPlacing.item(card: UUID(), title: "Make the slides", details: "", position: 1, note: note.id, noteTitle: "Launch spec", item: UUID(),
                                    section: "Notes", distilled: nil, waitsFor: [], meantFor: "Agent C (Alex)")
        let refused = try await alex.call(.placeWorkItems(binder: bed.shared, items: [item], column: .ready, agent: bed.agentC))
        check(refused.refusal?.code == "agents_may_not_place", "off, the database refuses an agent's placing: \(refused.refusal?.message ?? "-")")
        let byAlex = try await alex.call(.placeWorkItems(binder: bed.shared, items: [item], column: .backlog))
        check(byAlex.ok && byAlex.body["cards"]?.array?.count == 1, "a person still places")
    }
}
