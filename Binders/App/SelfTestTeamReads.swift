import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// Lane DB5: teammates' items that come through the team database, kept from a tool that may not read teammates'
    /// items (Settings → MCP), as a team folder's copies are, and shown to one that may. This Mac is Sam, with Agent A
    /// asking over MCP; Alex is a teammate whose Mac runs the note engine. Alex's binder (shared with Sam), its folder and a
    /// note in it; on the shared board, a card of Alex's with Alex's and Alex's agent's words on it, a card of Agent A's
    /// that Alex answers, and a question Alex's agent asks. Meetings, captures, to-dos and knowledge passages from the
    /// database have their own checks (`--selftest-teamdb-meetings`, `-todos`, `-knowledge`).
    @MainActor
    static func teamReadChecks(_ bed: TeamDBTestBed) async throws {
        let check = bed.check
        let agentA = AgentProfile(id: bed.agentA, name: "Agent A", wake: .webhook(url: "https://example.invalid/agent-a"), report: .mcp)
        let mac = try await TeamMac.start(bed, agents: [agentA])
        let alex = try await NotesMac.start(bed)
        let none = MCPServer.Reads(captures: false, transcripts: false, team: false)
        let team = MCPServer.Reads(captures: false, transcripts: false, team: true)
        let agent = BoardActor(name: "Agent A", kind: .agent)
        func call(_ tool: String, _ arguments: [String: Any], reads: MCPServer.Reads) async -> (ok: Bool, text: String) {
            do {
                return (true, try await MCPServer.call(tool, arguments, knowledge: mac.controller.knowledge,
                                                       write: MCPServer.writeInApp(controller: mac.controller), actor: agent, reads: reads,
                                                       host: "Claude Code"))
            } catch {
                return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription)
            }
        }

        // MARK: Alex's binder, its folder and a note in it

        let research = UUID(), interviews = UUID(), findings = UUID()
        let alexLink = try await bed.link(bed.alex)
        try await bed.expectOK(alexLink, .createBinder(research, name: "Alex's research"))
        try await bed.expectOK(alexLink, .shareBinder(research, with: bed.samID))
        alex.database.send(.putFolder(interviews, binder: research, fields: ["name": "Interviews"]))
        alex.engine.share(findings, binder: research, folder: interviews, text: "# Interview findings\n\nThe badges were hard to read.",
                          props: TeamNoteProps().values, fields: ["title": "Interview findings"])
        let arrived = await bed.eventually(20) {
            Store.shared.binder(research)?.teamMadeBy == "Alex" && Store.shared.note(findings) != nil && Store.shared.folder(interviews) != nil
        }
        check(arrived && Store.shared.note(findings)?.isTeamCopy == true, "Alex's binder, folder and note are here, the note as a teammate's")

        let mineOnly = TeamMac.list((await call("list_binders", [:], reads: none)).text)
        let withTeam = TeamMac.list((await call("list_binders", [:], reads: team)).text)
        check(!mineOnly.contains { $0["id"] as? String == research.uuidString }, "list_binders leaves Alex's binder out for a tool that may not read teammates' items")
        check(withTeam.contains { $0["id"] as? String == research.uuidString && $0["shared"] as? Bool == true },
              "and lists it, as shared, for one that may")
        check([mineOnly, withTeam].allSatisfy { list in list.contains { $0["id"] as? String == bed.shared.uuidString && $0["shared"] as? Bool == true } },
              "a binder of Sam's shared through the team database lists as shared, for either")
        let foldersMine = TeamMac.list((await call("list_folders", [:], reads: none)).text)
        let foldersTeam = TeamMac.list((await call("list_folders", [:], reads: team)).text)
        check(!foldersMine.contains { $0["id"] as? String == interviews.uuidString } && foldersTeam.contains { $0["id"] as? String == interviews.uuidString },
              "list_folders: Alex's binder's folders only for a tool that may read teammates' items")
        let rename = await call("rename_folder", ["folder": interviews.uuidString, "name": "Calls"], reads: none)
        check(!rename.ok && rename.text.contains("Teammates' items"), "nor can such a tool rename one: \(rename.text)")
        let notesMine = TeamMac.list((await call("list_notes", [:], reads: none)).text)
        let notesTeam = TeamMac.list((await call("list_notes", [:], reads: team)).text)
        check(!notesMine.contains { $0["id"] as? String == findings.uuidString } && notesTeam.contains { $0["id"] as? String == findings.uuidString },
              "list_notes: Alex's note only for a tool that may read teammates' items")
        let read = await call("get_note", ["id": findings.uuidString], reads: none)
        check(!read.ok && read.text.contains("Teammates' items"), "and get_note refuses it to one that may not: \(read.text)")

        // MARK: Teammates' words on shared cards

        // A card of Alex's: Alex's agent works on it and says so, and Alex comments.
        let theirs = try await bed.made("Sort the interview notes", by: alex.database)
        try await bed.expectOK(alexLink, .claimCard(theirs, agent: bed.agentC))
        try await bed.expectOK(alexLink, .report(theirs, progress: "Read the notes from the dentist's office", agent: bed.agentC))
        try await bed.expectOK(alexLink, .answer(theirs, text: "Leave out the names, please."))
        // A card of Agent A's: it asks, and Alex answers, then adds a word.
        let ours = try await bed.made("Draft the welcome note", by: alex.database)
        _ = await bed.eventually(10) { mac.card(ours) != nil }
        let claimed = await mac.claim(ours, as: "Agent A")
        let asked = await mac.mcp("ask_on_task", ["id": ours.uuidString, "question": "Formal or friendly?"], as: agent)
        let sent = await mac.drained()
        check(claimed.ok && asked.ok && sent, "Agent A takes a card Alex made, and asks about it: \(claimed.text) \(asked.text)")
        try await bed.expectOK(alexLink, .answer(ours, text: "Friendly."))
        try await bed.expectOK(alexLink, .answer(ours, text: "And add the date."))
        // A question Alex's agent asks on another card.
        let asking = try await bed.made("Choose the badge font", by: alex.database)
        try await bed.expectOK(alexLink, .claimCard(asking, agent: bed.agentC))
        try await bed.expectOK(alexLink, .ask(asking, question: "Serif or sans for the badges?", agent: bed.agentC))
        let here = await bed.eventually(15) {
            mac.board.timeline(theirs).contains { $0.text == "Leave out the names, please." }
                && mac.board.timeline(ours).contains { $0.text == "And add the date." } && mac.card(asking)?.column == .blocked
        }
        check(here, "Alex's and Alex's agent's words are on this Mac's copy of the shared board")

        func timeline(_ card: UUID, _ reads: MCPServer.Reads) async -> [[String: Any]] {
            TeamMac.object((await call("get_task", ["id": card.uuidString], reads: reads)).text)["timeline"] as? [[String: Any]] ?? []
        }
        let theirsMine = await timeline(theirs, none), theirsTeam = await timeline(theirs, team)
        check(!theirsMine.contains { ($0["who"] as? String).map { $0 == "Alex" || $0 == "Agent C (Alex)" } == true }
                && !theirsMine.contains { $0["text"] as? String == "Read the notes from the dentist's office" },
              "get_task on a teammate's card leaves out Alex's and Alex's agent's words for a tool that may not read teammates' items")
        check(theirsTeam.contains { $0["who"] as? String == "Alex" && $0["text"] as? String == "Leave out the names, please." }
                && theirsTeam.contains { $0["who"] as? String == "Agent C (Alex)" && $0["kind"] as? String == "progress" },
              "and shows them to one that may")
        let oursMine = await timeline(ours, none)
        check(oursMine.contains { $0["who"] as? String == "Alex" && $0["text"] as? String == "Friendly." }
                && oursMine.contains { $0["who"] as? String == "Alex" && $0["text"] as? String == "And add the date." },
              "on Agent A's own card, what Alex wrote to it reaches it either way: the answer to its question, and the word after"
                + (oursMine.count < 4 ? " — \(oursMine.map { "\($0["who"] ?? "") \($0["kind"] ?? ""): \($0["text"] ?? "")" }), held by \(mac.card(ours)?.assignee ?? "no one")" : ""))
        let askingMine = TeamMac.object((await call("get_task", ["id": asking.uuidString], reads: none)).text)
        let askingTeam = TeamMac.object((await call("get_task", ["id": asking.uuidString], reads: team)).text)
        check(!((askingMine["timeline"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "Serif or sans for the badges?" })
                && (askingTeam["timeline"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "Serif or sans for the badges?" },
              "a question Alex's agent asked: only for a tool that may read teammates' items")
        check(askingMine["state"] as? String == "input_required", "its state still says it waits for an answer")
        let streamsMine = (await call("work_streams", [:], reads: none)).text, streamsTeam = (await call("work_streams", [:], reads: team)).text
        check(!streamsMine.contains("Serif or sans") && streamsTeam.contains("Serif or sans"),
              "work_streams says what Alex's agent asks only to a tool that may read teammates' items")
        check(streamsMine.contains("Choose the badge font"), "and still says the card waits")

        await alex.stop()
        await mac.stop()
    }
}
