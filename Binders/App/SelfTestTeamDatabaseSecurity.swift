import Foundation
import PostgresNIO
import BindersKit

extension SelfTest {
    /// Row-level security: a member not in a binder sees none of its rows, its changes or its cards, and can't change
    /// them; a NOTIFY says nothing about where. Agents: one can't act under another owner's login, and a headless agent's
    /// login acts only as its agent, and takes cards only once its owner turned its Auto on (migration 8). Logins: a
    /// one-time password opens nothing until it's changed, a reset password stops the old one, and a member taken out sees
    /// nothing at once.
    @MainActor
    static func teamDatabaseSecurityChecks(_ bed: TeamDBTestBed) async throws {
        let check = bed.check
        let root = try await bed.root()
        let samLink = try await bed.link(bed.sam)
        let alexLink = try await bed.link(bed.alex)

        // Something in every binder table of Sam's Private binder, through the functions.
        let personal = bed.personal
        let card = UUID(), other = UUID(), note = UUID(), meeting = UUID(), capture = UUID(), distill = UUID(), folder = UUID()
        try await bed.expectOK(samLink, .createCard(card, binder: personal, title: "Private card", fields: ["column": "ready"]))
        try await bed.expectOK(samLink, .createCard(other, binder: personal, title: "Another private card"))
        try await bed.expectOK(samLink, .addDependency(card, waitsFor: other))
        let rows: [(TeamTable, TeamRow)] = [
            (.folders, ["id": TeamJSON(folder), "binder_id": TeamJSON(personal), "name": "Plans"]),
            (.notes, ["id": TeamJSON(note), "binder_id": TeamJSON(personal), "folder_id": TeamJSON(folder), "title": "Private note",
                      "body": "Only Sam's.", "distill": true]),
            (.noteChanges, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(personal), "note_id": TeamJSON(note),
                            "change": TeamJSON(bytes: Data([1, 2, 3])), "hash": "h1"]),
            (.noteVersions, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(personal), "note_id": TeamJSON(note), "lines_added": 3]),
            (.meetings, ["id": TeamJSON(meeting), "binder_id": TeamJSON(personal), "title": "Private meeting", "live": true]),
            (.meetingSegments, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(personal), "meeting_id": TeamJSON(meeting), "position": 0,
                                "speaker": "Sam", "text": "Just us."]),
            (.captures, ["id": TeamJSON(capture), "binder_id": TeamJSON(personal), "title": "Private capture"]),
            (.captureSegments, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(personal), "capture_id": TeamJSON(capture), "position": 0,
                                "text": "Heard at the Ignite booth."]),
            (.knowledgeChunks, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(personal), "source_kind": "note", "source_id": TeamJSON(note),
                                "text": "the private plan"]),
            (.entities, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(personal), "source_kind": "note", "source_id": TeamJSON(note),
                         "name": "Ignite booth", "kind": "place"]),
            (.relations, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(personal), "source_kind": "note", "source_id": TeamJSON(note),
                          "subject": "Sam", "predicate": "plans", "object": "Ignite booth"]),
            (.corrections, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(personal), "source_kind": "note", "source_id": TeamJSON(note),
                            "text": "It's the north hall."]),
            (.distills, ["id": TeamJSON(distill), "binder_id": TeamJSON(personal), "note_id": TeamJSON(note), "reader": "the model"]),
            (.distillItems, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(personal), "distill_id": TeamJSON(distill), "title": "Book the booth"]),
            (.todos, ["id": TeamJSON(UUID()), "binder_id": TeamJSON(personal), "source_kind": "note", "source_id": TeamJSON(note),
                      "text": "Call the dentist"]),
        ]
        for (table, row) in rows { try await bed.expectOK(samLink, .put(row, in: table)) }
        // Who's in a note (migration 6): Sam, in the private one.
        try await bed.expectOK(samLink, .beInNote(note, here: true))

        // Alex, not in it, sees none of it: no rows in any binder table, no changes, no cards.
        var hidden: [String] = []
        for table in TeamTable.binderTables {
            let column = table.binderColumn ?? "binder_id"
            let sql = "SELECT count(*)::bigint FROM binders.\(table.rawValue) WHERE \(column) = $1::uuid"
            let there = try await root.value(sql, [personal.uuidString], as: Int64.self) ?? 0
            let seen = try await alexLink.value(sql, [personal.uuidString], as: Int64.self) ?? 0
            if there == 0 || seen != 0 { hidden.append("\(table.rawValue): \(seen) of \(there)") }
        }
        check(hidden.isEmpty, "a member not in a binder sees none of its rows, in every binder table \(hidden)")
        let changes = "SELECT count(*)::bigint FROM binders.changes WHERE binder_id = $1::uuid"
        let feedThere = try await root.value(changes, [personal.uuidString], as: Int64.self) ?? 0
        let feedSeen = try await alexLink.value(changes, [personal.uuidString], as: Int64.self) ?? 0
        check(feedThere > 10 && feedSeen == 0, "none of its changes in the feed (\(feedSeen) of \(feedThere))")
        let allChanges = try await alexLink.changes(after: 0, limit: 10_000)
        check(allChanges.allSatisfy { $0.binderID == nil || $0.binderID == bed.shared }, "the feed shows Alex only the shared binder and the team")
        check(try await alexLink.visibleBinders() == [bed.shared], "Alex's binders: the shared one")
        let search = try await alexLink.json("SELECT binders.search_knowledge('private plan')::text").array ?? []
        check(search.isEmpty, "nor does searching the team's knowledge find it")

        // Nor change it.
        let claim = try await alexLink.call(.claimCard(card))
        check(claim.refusal?.code == "not_found", "claiming its card: no such card on Alex's boards")
        let comment = try await alexLink.call(.answer(card, text: "Hello?"))
        check(comment.refusal?.code == "not_found", "commenting on it: the same")
        let write = await bed.failure { _ = try await alexLink.call(.put(["id": TeamJSON(note), "title": "Mine"], in: .notes)) }
        check(write == "42501", "writing its note: refused (\(write ?? "written"))")
        let create = await bed.failure { _ = try await alexLink.call(.createCard(UUID(), binder: personal, title: "Sneaky")) }
        check(create == "42501", "putting a card on its board: refused")
        let delete = try await alexLink.call(.delete(note, from: .notes))
        check(delete.refusal?.code == "not_found", "deleting its note: nothing of that id for Alex")
        let share = await bed.failure { _ = try await alexLink.call(.shareBinder(personal, with: bed.alexID)) }
        check(share == "42501", "sharing it with themselves: refused")
        var direct: [String] = []
        for statement in ["UPDATE binders.cards SET title = 'x'", "INSERT INTO binders.binder_members (id, binder_id, member_id) VALUES (gen_random_uuid(), '\(personal)', '\(bed.alexID!)')",
                          "DELETE FROM binders.notes", "TRUNCATE binders.changes", "UPDATE binders.members SET is_admin = true",
                          "SELECT binders._put(NULL, 'notes', '{}')"] {
            if await bed.failure({ try await alexLink.execute(statement) }) != "42501" { direct.append(statement) }
        }
        check(direct.isEmpty, "no member writes a table directly or runs an internal function \(direct)")
        let untouched = try await root.json("SELECT to_jsonb(n)::text FROM binders.notes n WHERE id = $1::uuid", [note.uuidString])
        check(untouched["title"]?.string == "Private note" && untouched["deleted_at"] == .null, "and the note is as Sam left it")

        // A NOTIFY carries only a number: nothing of where, or what.
        let (payloads, received) = AsyncStream<String>.makeStream()
        let (listening, ready) = AsyncStream<Void>.makeStream()
        let listener = Task {
            try await alexLink.listen(TeamSchema.channel, ready: { ready.yield() }, notified: { received.yield($0) })
        }
        for await _ in listening { break }
        try await bed.expectOK(samLink, .report(card, progress: "A private step"))
        var payload: String?
        for await text in payloads {
            payload = text
            break
        }
        listener.cancel()
        check(payload.map { !$0.isEmpty && $0.allSatisfy(\.isNumber) } == true, "a change notifies with only its number (“\(payload ?? "")”)")

        // Meetings change only by their author, notes by anyone in the binder, agents only by their owner.
        let sharedMeeting = UUID(), sharedNote = UUID()
        try await bed.expectOK(samLink, .put(["id": TeamJSON(sharedMeeting), "binder_id": TeamJSON(bed.shared), "title": "Standup"], in: .meetings))
        try await bed.expectOK(samLink, .put(["id": TeamJSON(sharedNote), "binder_id": TeamJSON(bed.shared), "title": "Spec"], in: .notes))
        let meetingEdit = await bed.failure { _ = try await alexLink.call(.put(["id": TeamJSON(sharedMeeting), "title": "Mine"], in: .meetings)) }
        check(meetingEdit == "42501", "only a meeting's author changes it")
        let segment = await bed.failure {
            _ = try await alexLink.call(.put(["id": TeamJSON(UUID()), "binder_id": TeamJSON(bed.shared), "meeting_id": TeamJSON(sharedMeeting),
                                              "position": 0, "text": "Not mine to add"], in: .meetingSegments))
        }
        check(segment == "42501", "and only its author adds to its transcript")
        let noteEdit = try await alexLink.call(.put(["id": TeamJSON(sharedNote), "title": "Spec, edited"], in: .notes))
        check(noteEdit.row?["last_edited_by"]?.uuid == bed.alexID && noteEdit.row?["created_by"]?.uuid == bed.samID,
              "anyone in the binder edits a note, and it says who")
        let forged = try await alexLink.call(.put(["id": TeamJSON(UUID()), "binder_id": TeamJSON(bed.shared), "title": "Forged",
                                                    "created_by": TeamJSON(bed.samID)], in: .notes))
        check(forged.row?["created_by"]?.uuid == bed.alexID, "who wrote a row is the database's to say, not the caller's")
        let agentEdit = await bed.failure { _ = try await alexLink.call(.putAgent(bed.agentA, fields: ["purpose": "Alex's now"])) }
        check(agentEdit == "42501", "only an agent's owner changes it")

        // An agent can't act under another owner's login.
        let shared = UUID()
        try await bed.expectOK(samLink, .createCard(shared, binder: bed.shared, title: "Shared card", fields: ["column": "ready"]))
        let borrowed = await bed.failure { _ = try await alexLink.call(.claimCard(shared, agent: bed.agentA)) }
        check(borrowed == "42501", "Alex's login can't act as Sam's agent")
        let named = try await alexLink.call(.claimCard(shared, agent: bed.agentC))
        check(named.ok && named.card?.holderAgentID == bed.agentC && named.events.first?.author == BoardActor(name: "Agent C", kind: .agent),
              "but acts as its own agent, named on the change")

        // A headless agent with a login of its own: one-time password first, then only ever itself.
        let helper = UUID(), helperLogin = UUID()
        let headless = try await samLink.call(.addMember(helperLogin, login: "helper_two", name: "Helper", verifier: TeamPassword.verifier(for: "unused-1"),
                                                         agent: (helper, "Helper")))
        check(headless.ok && headless.body["member"]?["kind"]?.string == "agent" && headless.body["member"]?["is_admin"]?.bool == false,
              "an admin adds a headless agent's login, which isn't an admin")
        let botServer = bed.postgres.server(database: bed.database, login: "helper_two")
        TeamDatabase.keep(password: "unused-1", for: botServer)
        defer { TeamDatabase.forget(botServer) }
        let botLink = try await bed.link(botServer)
        let early = await bed.failure { _ = try await botLink.call(.claimCard(shared)) }
        check(early == "BD001", "on its one-time password it can do nothing yet (\(early ?? "did"))")
        let unseen = try await botLink.value("SELECT count(*)::bigint FROM binders.cards", as: Int64.self)
        check(unseen == 0, "and sees nothing")
        let changed = try await botLink.call(.changePassword(verifier: TeamPassword.verifier(for: "its-own-1")))
        check(changed.ok, "it changes its password")
        _ = try await samLink.call(.release(shared))
        let notShared = try await botLink.call(.claimCard(shared))
        check(notShared.refusal?.code == "not_found", "a headless agent sees only binders shared with its login")
        try await bed.expectOK(samLink, .shareBinder(bed.shared, with: helperLogin))
        // Its Auto (migration 8): off until its owner turns it on, and while it's off it takes no card.
        let offClaim = try await botLink.call(.claimCard(shared))
        check(offClaim.refusal?.code == "auto_off" && offClaim.refusal?.owner == "Sam"
                && offClaim.refusal?.message.contains("until its owner, Sam, turns on its Auto") == true,
              "with its Auto off it can't claim a card, and hears who can turn it on: \(offClaim.refusal?.message ?? "claimed")")
        let offMove = try await botLink.call(.moveCard(shared, to: .inProgress))
        check(offMove.refusal?.code == "auto_off", "nor take one by moving it into In progress")
        let offFinish = try await botLink.call(.finish(shared, summary: "Done"))
        check(offFinish.refusal?.code == "auto_off", "nor finish one it doesn't hold, which would make it its own")
        let offComment = try await botLink.call(.answer(shared, text: "I can look at this once Auto is on."))
        check(offComment.ok, "it can still comment")
        let ownAuto = await bed.failure { _ = try await botLink.call(.setAgentAuto(helper, on: true)) }
        check(ownAuto == "42501", "it can't turn on its own Auto (\(ownAuto ?? "it did"))")
        let teammatesAuto = try await alexLink.call(.setAgentAuto(helper, on: true))
        check(teammatesAuto.refusal?.code == "not_owner" && teammatesAuto.refusal?.owner == "Sam", "nor can a teammate: only its owner, Sam")
        let macAuto = try await samLink.call(.setAgentAuto(bed.agentA, on: true))
        check(macAuto.refusal?.code == "on_a_mac", "an agent on a Mac keeps its Auto on its owner's Mac, not in the database")
        let turnedOn = try await samLink.call(.setAgentAuto(helper, on: true))
        check(turnedOn.ok && turnedOn.body["agent"]?["auto"]?.bool == true, "its owner turns its Auto on")
        let botClaim = try await botLink.call(.claimCard(shared))
        check(botClaim.ok && botClaim.card?.holderAgentID == helper && botClaim.card?.holderKind == .agent,
              "and then it acts as its agent: the card is Helper's, an agent's")
        // Given to another person, its Auto goes off for them to turn on.
        try await bed.expectOK(samLink, .handAgent(helper, to: bed.alexID))
        _ = try await samLink.call(.release(shared))
        let handed = try await botLink.call(.claimCard(shared))
        check(handed.refusal?.code == "auto_off" && handed.refusal?.owner == "Alex", "handed to Alex, its Auto is off until Alex turns it on")
        try await bed.expectOK(alexLink, .setAgentAuto(helper, on: true))
        let alexsNow = try await botLink.call(.claimCard(shared))
        check(alexsNow.ok, "which Alex, its owner now, can")
        let botAsA = await bed.failure { _ = try await botLink.call(.claimCard(shared, agent: bed.agentA)) }
        check(botAsA == "42501", "never as another agent")
        let botDecides = try await botLink.call(.decide(shared, approve: true, device: "a server"))
        check(botDecides.refusal?.code == "not_you", "never as a person: it can't decide on an approval")
        let botBinder = await bed.failure { _ = try await botLink.call(.createBinder(UUID(), name: "Bot's binder")) }
        check(botBinder == "42501", "nor make binders, or add members")

        // A reset password: the old one stops working, the new one is one-time.
        let reset = try await samLink.call(.resetPassword(bed.alexID, verifier: TeamPassword.verifier(for: "fresh-one-1")))
        check(reset.ok, "an admin resets Alex's password")
        let oldPassword = Keychain.read(TeamDatabase.passwordKey(bed.alex)) ?? ""
        let old = await bed.failure {
            let link = try await TeamDatabaseLink.connect(to: bed.alex, password: oldPassword, trust: bed.postgres.trust)
            await link.close()
        }
        check(old == "28P01", "Alex's old password no longer works (\(old ?? "it does"))")
        let fresh = try await TeamDatabaseLink.connect(to: bed.alex, password: "fresh-one-1", trust: bed.postgres.trust)
        let whoami = try await fresh.json(TeamQueries.whoami)
        check(whoami["member"]?["temporary_password"]?.bool == true && whoami["binders"]?.array?.isEmpty == true,
              "the new one is one-time: Alex sees nothing until it's changed")
        await fresh.close()

        // Taken out of the team: their open connection sees nothing at once, and they can't log in again.
        let removed = try await samLink.call(.removeMember(bed.alexID))
        check(removed.ok, "an admin takes Alex out of the team")
        let after = try await alexLink.value("SELECT count(*)::bigint FROM binders.cards", as: Int64.self)
        check(after == 0, "Alex's open connection sees no cards now")
        let afterCall = await bed.failure { _ = try await alexLink.call(.claimCard(shared)) }
        check(afterCall == "42501", "and changes nothing")
        let again = await bed.failure {
            let link = try await TeamDatabaseLink.connect(to: bed.alex, password: "fresh-one-1", trust: bed.postgres.trust)
            await link.close()
        }
        check(again != nil, "nor logs in again (\(again ?? "logged in"))")
        let yourself = try await samLink.call(.removeMember(bed.samID))
        check(yourself.refusal?.code == "not_yourself", "an admin can't take themselves out")
    }
}
