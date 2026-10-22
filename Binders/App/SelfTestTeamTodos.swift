import Foundation
import SwiftData
import PostgresNIO
import BindersKit

extension SelfTest {
    // MARK: To-dos

    /// To-dos on the team database: yours in a shared binder go (whose, due, where from, never the message), not yours in
    /// your own binders nor what you said to yourself; a tick anywhere is a tick everywhere; a teammate's is theirs here,
    /// which you may tick; a card's to-do follows it to Done; moved out it's taken off the team; a restart sends nothing
    /// again; and MCP reads and ticks a teammate's only for a tool that may read teammates' items.
    @MainActor
    static func teamTodoChecks(_ bed: TeamDBTestBed) async throws {
        let mac = try await TeamMac.start(bed)
        var content: TeamContent { mac.team.content }
        content.editDelay = .milliseconds(150)
        let alex = try await bed.teammate()
        let root = try await bed.root()
        let store = Store.shared
        let commitments = mac.controller.commitments
        func todos() async throws -> [TeamRow] {
            try await root.json("SELECT coalesce(json_agg(to_jsonb(t)), '[]')::text FROM binders.todos t").array?.compactMap(\.object) ?? []
        }
        func alexRow(_ id: UUID) async -> TeamRow? {
            guard let rows = try? await alex.rows(.todos, ids: [id]) else { return nil }
            return rows.first
        }
        func settle() async {
            try? await Task.sleep(for: .milliseconds(500))
            _ = await mac.drained()
        }
        let friday = Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(17 * 3600)

        // MARK: Yours in a shared binder goes; whose it is, when it's due, where it came from; never its message.
        let promise = CommitmentRecord(task: "Send the deck to the venue", kind: "promise", owner: "You")
        promise.to = "Robin"
        promise.dueAt = friday
        promise.dueText = "by Friday"
        promise.quote = "Robin, I'll send you the deck by Friday."
        promise.sourceApp = "Mail"
        promise.sourceWritingID = UUID()
        promise.binderID = bed.shared
        store.insert(promise)
        let sent = await bed.until(5) { await alexRow(promise.id) != nil }
        var row = await alexRow(promise.id)
        bed.check(sent && row?["owner"]?.string == "Sam" && row?["to_name"]?.string == "Robin" && row?["kind"]?.string == "promise"
                  && row?["due_text"]?.string == "by Friday" && row?["due_at"]?.date.map { abs($0.timeIntervalSince(friday)) < 1 } == true
                  && row?["status"]?.string == "open" && row?["created_by"]?.uuid == bed.samID,
                  "your promise in the shared binder reaches Alex: yours (Sam), to Robin, due Friday, open")
        bed.check(row?["source_title"]?.string == "Promised to Robin in Mail", "where it came from, in your words: \(row?["source_title"]?.string ?? "-")")
        let wire = TeamJSON.object(row ?? [:]).text
        bed.check(!wire.contains("deck by Friday.") && !wire.contains(promise.sourceWritingID!.uuidString.lowercased()),
                  "never the message it was found in")
        let own = BinderRecord(name: "Errands", colorIndex: 2)
        store.insert(own)
        let passport = CommitmentRecord(task: "Renew the passport", kind: "todo", owner: "You")
        passport.binderID = own.id
        store.insert(passport)
        let said = commitments.addMoment("Call the printer about the banners", due: nil, dueText: nil, binderID: bed.shared, id: UUID(), heard: Date(),
                                         said: "Remind me to call the printer about the banners", app: "iPhone", fireAutomation: false)
        await settle()
        let ids = Set(try await todos().compactMap(\.rowID))
        bed.check(ids == [promise.id], "a to-do in your own binder never goes, nor one you said to yourself in the shared binder")

        // MARK: Ticking anywhere ticks everywhere.
        let ticked = Date()
        _ = try await alex.call(.put(["id": TeamJSON(promise.id), "status": "done", "done_at": TeamJSON(ticked)], in: .todos))
        let tickedHere = await bed.eventually(5) { promise.status == "done" }
        bed.check(tickedHere, "Alex ticks it: ticked here")
        commitments.setStatus(promise, "open")
        let reopened = await bed.until(5) { await alexRow(promise.id)?["status"]?.string == "open" }
        bed.check(reopened, "you open it again here: open there")

        // MARK: Alex's to-do: here as Alex's, which you may tick.
        let van = UUID()
        _ = try await alex.call(.putItem(TeamTodoValues(id: van, binder: bed.shared, text: "Book the van for the booth", kind: "todo", owner: "Alex",
                                                        due: friday, dueText: "Friday", source: "Added by voice").row(), in: .todos))
        let forYou = UUID()
        _ = try await alex.call(.putItem(TeamTodoValues(id: forYou, binder: bed.shared, text: "Print the badges", kind: "ask", owner: "Sam",
                                                        to: "Sam", source: "Asked of Sam in Slack").row(), in: .todos))
        var vanHere: CommitmentRecord? { content.todo(van) }
        let arrived = await bed.eventually(5) { vanHere != nil && content.todo(forYou) != nil }
        bed.check(arrived && vanHere?.teamAuthorName == "Alex" && vanHere?.owner == "Alex" && vanHere?.sourceTitle == "From Alex: Added by voice",
                  "Alex's to-do shows here as Alex's: \(vanHere?.sourceTitle ?? "-")")
        bed.check(content.todo(forYou)?.owner == "You", "one Alex asked of you is yours here")
        if let vanHere {
            commitments.setStatus(vanHere, "done")
            let there = await bed.until(5) { await alexRow(van)?["status"]?.string == "done" }
            row = await alexRow(van)
            bed.check(there && row?["text"]?.string == "Book the van for the booth" && row?["owner"]?.string == "Alex",
                      "you tick Alex's: ticked there, still Alex's")
        }

        // MARK: A card on the shared board made from your to-do: Done there ticks it everywhere.
        guard let item = Todos.find(promise.id.uuidString) else { return bed.check(false, "the promise reads as a to-do") }
        let card = mac.board.create(from: item, column: .ready, binderID: bed.shared, by: .you).card
        await settle()
        let onCard = await bed.until(5) { await alexRow(promise.id)?["card_id"]?.uuid == card.id }
        bed.check(onCard, "the to-do says which card it's on")
        let cardRow = try await alex.rows(.cards, ids: [card.id]).first
        bed.check(cardRow?["todo_id"]?.uuid == promise.id, "and the card on the team's board says which to-do it's for")
        _ = try await alex.call(.moveCard(card.id, to: .done))
        let followed = await bed.eventually(5) { promise.status == "done" }
        let databaseTodo = await alexRow(promise.id)?["status"]?.string
        bed.check(followed && databaseTodo == "done", "Alex moves the card to Done: the to-do is done in the database and here")

        // MARK: Moved out of the shared binders, or deleted: off the team, its words erased.
        let flyer = CommitmentRecord(task: "Proof the flyer", kind: "todo", owner: "You")
        flyer.binderID = bed.shared
        store.insert(flyer)
        _ = await bed.until(5) { await alexRow(flyer.id) != nil }
        flyer.binderID = own.id
        store.save()
        let erased = await bed.until(5) { await alexRow(flyer.id)?.deletedAt != nil }
        row = await alexRow(flyer.id)
        bed.check(erased && row?["text"]?.string == "" && row?["source_title"]?.string == "", "moved to your own binder: off the team, its words erased")
        flyer.binderID = bed.shared
        store.save()
        let back = await bed.until(5) { await alexRow(flyer.id).map { $0.deletedAt == nil && $0["text"]?.string == "Proof the flyer" } == true }
        bed.check(back, "moved back: shared again")
        commitments.remove(flyer)
        let deleted = await bed.until(5) { await alexRow(flyer.id)?.deletedAt != nil }
        bed.check(deleted, "deleted here: off the team")
        _ = try await alex.call(.withdrawItem(van, from: .todos))
        let vanGone = await bed.eventually(5) { content.todo(van) == nil }
        bed.check(vanGone, "Alex takes theirs off the team: it goes from here")

        // MARK: A restart sends nothing again.
        await settle()
        let before = try await root.json("SELECT json_agg(json_build_object('id', id, 'at', updated_at) ORDER BY id)::text FROM binders.todos").text
        await mac.team.stop()
        mac.team.run(bed.sam)
        let reconnected = await bed.eventually(30) { mac.team.isConnected && mac.team.directory.myName == "Sam" }
        try await Task.sleep(for: .seconds(1))
        _ = await mac.drained()
        let after = try await root.json("SELECT json_agg(json_build_object('id', id, 'at', updated_at) ORDER BY id)::text FROM binders.todos").text
        bed.check(reconnected && before == after, "after a restart, every to-do as it was: nothing sent again")
        let saidThere = try await todos().contains { $0.rowID == said.id }
        bed.check(content.todo(said.id) != nil && !saidThere, "and what you said to yourself still stays here")

        // MARK: MCP: a teammate's to-do for what may read teammates' items, and only that ticks it.
        let printBadges = forYou
        func call(_ tool: String, _ arguments: [String: Any], team: Bool) async -> (ok: Bool, text: String) {
            do {
                return (true, try await MCPServer.call(tool, arguments, knowledge: mac.controller.knowledge, write: MCPServer.writeInApp(controller: mac.controller),
                                                       actor: BoardActor(name: "Claude Code", kind: .agent),
                                                       reads: MCPServer.Reads(captures: false, transcripts: false, team: team), host: "Claude Code"))
            } catch {
                return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription)
            }
        }
        let hidden = TeamMac.list((await call("list_todos", ["status": "all"], team: false)).text)
        bed.check(!hidden.contains { $0["id"] as? String == printBadges.uuidString } && hidden.contains { $0["id"] as? String == promise.id.uuidString },
                  "list_todos, for a tool that may not read teammates' items: yours, not Alex's")
        let shown = TeamMac.list((await call("list_todos", ["status": "all"], team: true)).text)
        bed.check(shown.first { $0["id"] as? String == printBadges.uuidString }?["author"] as? String == "Alex", "for one that may: Alex's too, saying whose")
        let phone = TeamMac.list((try? await MCPServer.call("list_todos", ["status": "all"], knowledge: mac.controller.knowledge,
                                                             write: MCPServer.writeInApp(controller: mac.controller), actor: .you)) ?? "[]")
        bed.check(phone.first { $0["id"] as? String == printBadges.uuidString }?["author"] as? String == "Alex", "the iPhone lists it as this Mac shows it")
        let refused = await call("set_todo_status", ["id": printBadges.uuidString, "status": "done"], team: false)
        bed.check(!refused.ok && refused.text.contains("Teammates' items"), "set_todo_status won't tick Alex's for the first: \(refused.text.prefix(60))")
        let allowed = await call("set_todo_status", ["id": printBadges.uuidString, "status": "done"], team: true)
        let mcpTicked = await bed.until(5) { await alexRow(printBadges)?["status"]?.string == "done" }
        bed.check(allowed.ok && mcpTicked, "and ticks it for the second, everywhere")
        await mac.stop()
    }
}
