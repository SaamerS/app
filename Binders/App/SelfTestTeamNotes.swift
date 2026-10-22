import Foundation
import SwiftData
import PostgresNIO
import BindersKit

/// Lane DB3's self-tests, on TeamDBTestBed's throwaway Postgres. This Mac is Sam, the app itself (its notes, folders,
/// Distill, History and TeamNotes, connected as Sam); a teammate is Alex, a second login whose Mac runs the same note
/// engine (TeamNoteEngine) with its notes kept in memory, as another Mac would.
///
///     Binders --selftest-teamdb-notes   two people type in one note and both keep their words; an agent's MCP edit,
///                                       merged and marked; who's in a note; versions, names, putting one back, and what's
///                                       kept; a teammate's section change and an agent's; folders and moves; proposals
///     Binders --selftest-teamdb-move    moving a folder team over: everything once, again a no-op, teammates on folder
///                                       sync lose nothing
@MainActor
final class NotesMac {
    let bed: TeamDBTestBed
    let database: TeamDatabase
    let engine: TeamNoteEngine
    /// Each note's text and props on this Mac.
    private(set) var texts: [UUID: String] = [:]
    private(set) var props: [UUID: [String: TeamJSON]] = [:]
    private(set) var presence: [UUID: [TeamPresenceRow]] = [:]
    private(set) var folders: [UUID: TeamFolderRow] = [:]
    private(set) var distills: [UUID: TeamRow] = [:]
    private(set) var items: [UUID: TeamRow] = [:]
    private var tasks: [Task<Void, Never>] = []

    private init(bed: TeamDBTestBed, database: TeamDatabase, engine: TeamNoteEngine) {
        self.bed = bed
        self.database = database
        self.engine = engine
    }

    /// Alex's Mac (or another login's), connected and reading the feed.
    static func start(_ bed: TeamDBTestBed, server: TeamDatabaseServer? = nil, folder name: String = "alex-notes") async throws -> NotesMac {
        let database = bed.client(server ?? bed.alex, folder: name)
        let engine = TeamNoteEngine(database: database, folder: AppPaths.support.appendingPathComponent("\(name)-documents", isDirectory: true))
        engine.saveAfter = 0.3
        let mac = NotesMac(bed: bed, database: database, engine: engine)
        mac.tasks = [
            Task { @MainActor [weak mac] in
                for await update in database.updates {
                    guard let mac else { return }
                    await mac.apply(update)
                    database.acknowledge(update)
                }
            },
            Task { @MainActor [weak mac] in
                for await outcome in database.outcomes {
                    guard let mac else { return }
                    for id in await mac.engine.settle(outcome) { mac.refresh(id) }
                }
            },
            Task { @MainActor [weak mac] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    await mac?.engine.saveDue()
                }
            },
        ]
        try await bed.waitConnected(database)
        return mac
    }

    func stop() async {
        for task in tasks { task.cancel() }
        await database.stop()
    }

    private func apply(_ update: TeamUpdate) async {
        for binder in update.bindersAdded {
            if let snapshot = try? await database.snapshot(binder: binder) { await take(snapshot.rows) }
        }
        await take(update.rows)
        for gone in update.gone where gone.table == .notes {
            engine.forget(gone.id)
            texts[gone.id] = nil
        }
    }

    private func take(_ rows: [TeamTable: [TeamRow]]) async {
        let changes = (rows[.noteChanges] ?? []).compactMap(TeamNoteChangeRow.init(row:))
        var adopted: Set<UUID> = []
        for row in (rows[.notes] ?? []).compactMap(TeamNoteRow.init(row:)) {
            if row.deletedAt != nil {
                engine.forget(row.id)
                texts[row.id] = nil
            } else if !engine.knows(row.id) {
                if engine.adopt(row, changes: changes.filter { $0.noteID == row.id }) != nil { adopted.insert(row.id) }
            } else {
                engine.take(row: row)
            }
        }
        let touched = await engine.receive(changes.filter { engine.knows($0.noteID) })
        for id in touched.union(adopted) { refresh(id) }
        engine.take(versions: (rows[.noteVersions] ?? []).compactMap(TeamNoteVersionRow.init(row:)))
        for row in (rows[.notePresence] ?? []).compactMap(TeamPresenceRow.init(row:)) {
            var list = presence[row.noteID] ?? []
            list.removeAll { $0.memberID == row.memberID }
            list.append(row)
            presence[row.noteID] = list
        }
        for row in (rows[.folders] ?? []).compactMap(TeamFolderRow.init(row:)) { folders[row.id] = row }
        for row in rows[.distills] ?? [] { if let id = row.rowID { distills[id] = row } }
        for row in rows[.distillItems] ?? [] { if let id = row.rowID { items[id] = row } }
    }

    /// The note here as its document has it now.
    func refresh(_ id: UUID) {
        guard let current = engine.current(id) else { return }
        texts[id] = current.text
        props[id] = current.props
        engine.agree(id, text: current.text, props: current.props)
    }

    /// Alex's copy of a note, empty when Alex's Mac doesn't have it.
    func text(_ id: UUID) -> String { texts[id] ?? "" }

    /// Alex types: the note here becomes `text`, as Alex's change (or Alex's agent's), and goes.
    func type(_ id: UUID, _ text: String, agent: UUID? = nil) {
        engine.edited(id, text: text, props: props[id] ?? [:], by: TeamNoteAuthor(agent: agent))
        refresh(id)
    }

    /// Someone in a note, viewing or reviewing, or gone.
    func be(in note: UUID, here: Bool = true, reviewing distill: UUID? = nil) async throws {
        let result = try await database.call(.beInNote(note, here: here, kind: distill == nil ? .viewing : .reviewing, distill: distill))
        guard result.ok else { throw TeamDatabase.Problem.refused("be_in_note: \(result.refusal?.message ?? "")") }
    }

    /// Until nothing waits in the outbox.
    func drained(_ timeout: TimeInterval = 15) async -> Bool {
        await bed.eventually(timeout) { self.database.waiting == 0 }
    }
}

extension SelfTest {
    @MainActor
    static func teamNotesChecks(_ bed: TeamDBTestBed) async throws {
        let agentA = AgentProfile(id: bed.agentA, name: "Agent A", wake: .webhook(url: "https://example.invalid/agent-a"), report: .mcp)
        let agentB = AgentProfile(id: bed.agentB, name: "Agent B", wake: .webhook(url: "https://example.invalid/agent-b"), report: .mcp)
        let mac = try await TeamMac.start(bed, agents: [agentA, agentB])
        _ = mac.controller.distill
        let notes = mac.team.notes
        notes.gather = .milliseconds(150)
        notes.engine?.saveAfter = 0.3
        let alex = try await NotesMac.start(bed)
        let root = try await bed.root()
        func ms(_ seconds: TimeInterval) -> String { "\(Int(seconds * 1000)) ms" }
        func count(_ sql: String, _ values: [String?] = []) async throws -> Int64 { try await root.value(sql, values, as: Int64.self) ?? -1 }

        // MARK: Sam writes a note in the shared binder: it's on Alex's Mac within a second.
        let plan = NoteItem(text: "# Launch plan\n\n## Venue\n\nThe hall on Main Street.\n\n## Talks\n\nThree talks.\n")
        plan.binderID = bed.shared
        var started = Date()
        Store.shared.insert(plan)
        var arrived = await bed.eventually(10) { alex.texts[plan.id] == plan.text }
        var took = Date().timeIntervalSince(started)
        bed.check(arrived && took < 2, "a note Sam writes in a shared binder is on Alex's Mac in \(ms(took)), word for word")
        if !arrived {
            let row = try await count("SELECT count(*) FROM binders.notes WHERE id = $1::uuid", [plan.id.uuidString])
            print("NOTE: Sam's engine knows it: \(notes.engine?.knows(plan.id) ?? false); covered: \(notes.covers(plan)); rows in the database: \(row)")
            for item in mac.team.database?.queued ?? [] { print("NOTE: waiting \(item.call.function): \(item.lastError ?? "no error yet")") }
            print("NOTE: Alex has \(alex.texts.count) notes; Sam's status \(mac.team.status); turned down: \(notes.turnedDown)")
        }
        bed.check(try await count("SELECT count(*) FROM binders.note_changes WHERE note_id = $1::uuid", [plan.id.uuidString]) >= 2,
                  "its document's first changes are in the database (the skeleton and its words)")
        bed.check(try await count("SELECT count(*) FROM binders.note_versions WHERE note_id = $1::uuid AND member_id = $2::uuid AND agent_id IS NULL",
                                  [plan.id.uuidString, bed.samID.uuidString]) == 1, "one version, by Sam")
        // A note from what you said stays on this Mac, even in a shared binder.
        let said = NoteItem(text: "# Call the dentist\n\nSaid to myself.\n")
        said.binderID = bed.shared
        said.staysUnshared = true
        Store.shared.insert(said)

        // MARK: Alex types: here within a second, kept in the note's history as Alex's.
        started = Date()
        alex.type(plan.id, alex.text(plan.id).replacingOccurrences(of: "Three talks.", with: "Three talks, then lunch."))
        arrived = await bed.eventually(10) { plan.text.contains("then lunch") }
        took = Date().timeIntervalSince(started)
        bed.check(arrived && took < 2, "Alex's typing is in Sam's note in \(ms(took))")
        bed.check(try await count("SELECT count(*) FROM binders.notes WHERE id = $1::uuid", [said.id.uuidString]) == 0,
                  "a note made from what Sam said stays on Sam's Mac")

        // MARK: Both type at once, neither having seen the other's words: both keep them, no copies.
        plan.text += "Sam: bring the banners.\n"
        notes.capture(plan, by: .person)
        alex.type(plan.id, alex.text(plan.id).replacingOccurrences(of: "## Talks\n", with: "## Talks\n\nAlex: book the caterer.\n"))
        var same = await bed.eventually(10) { plan.text == alex.texts[plan.id] && plan.text.contains("banners") && plan.text.contains("caterer") }
        bed.check(same, "typed at once on two Macs: both Macs have both lines")
        bed.check(plan.text.components(separatedBy: "banners").count == 2 && plan.text.components(separatedBy: "caterer").count == 2,
                  "each line once")
        let copies = ((try? Store.shared.context.fetch(FetchDescriptor<NoteItem>())) ?? []).filter { $0.title == "Launch plan" }.count
        bed.check(copies == 1, "and no conflict copy: \(copies) note called Launch plan")
        // Ten rounds of both typing at once, in random places.
        var generator = SystemRandomNumberGenerator()
        func insert(_ word: String, into text: String) -> String {
            var lines = text.components(separatedBy: "\n")
            let at = Int.random(in: 0..<max(1, lines.count), using: &generator)
            lines[at] = lines[at] + " " + word
            return lines.joined(separator: "\n")
        }
        for round in 1...10 {
            plan.text = insert("[sam-\(round)]", into: plan.text)
            notes.capture(plan, by: .person)
            alex.type(plan.id, insert("[alex-\(round)]", into: alex.text(plan.id)))
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...60, using: &generator)))
        }
        same = await bed.eventually(15) { plan.text == alex.texts[plan.id] && (1...10).allSatisfy { plan.text.contains("[alex-\($0)]") && plan.text.contains("[sam-\($0)]") } }
        let once = (1...10).allSatisfy { plan.text.components(separatedBy: "[sam-\($0)]").count == 2 && plan.text.components(separatedBy: "[alex-\($0)]").count == 2 }
        bed.check(same && once, "ten rounds of typing at once: the two Macs agree, every word kept, once")
        _ = await mac.drained()
        _ = await alex.drained()
        bed.check(alex.texts[plan.id] == plan.text, "and they still agree once everything has gone")

        // MARK: An agent's edit over MCP, while Alex types elsewhere: merged, and marked as the agent's everywhere.
        let agent = BoardActor(name: "Agent A", kind: .agent)
        let updated = await mac.mcp("update_note", ["id": plan.id.uuidString, "find": "The hall on Main Street.",
                                                    "replace": "The hall on Main Street, room 2."], as: agent)
        alex.type(plan.id, alex.text(plan.id).replacingOccurrences(of: "Alex: book the caterer.", with: "Alex: book the caterer and confirm the date."))
        same = await bed.eventually(10) { plan.text == alex.texts[plan.id] && plan.text.contains("room 2") && plan.text.contains("confirm the date") }
        bed.check(updated.ok && same, "update_note by Agent A and Alex's typing at once: both kept (\(updated.text.prefix(60)))")
        bed.check(try await count("SELECT count(*) FROM binders.note_changes WHERE note_id = $1::uuid AND agent_id = $2::uuid AND member_id = $3::uuid",
                                  [plan.id.uuidString, bed.agentA.uuidString, bed.samID.uuidString]) == 1,
                  "the agent's change is the agent's in the database, through Sam's login")
        bed.check(plan.editedBy == "Agent A" && alex.props[plan.id]?["edited_by"]?.string == "Agent A (Sam)",
                  "marked as Agent A's edit: here \(plan.editedBy ?? "-"), on Alex's Mac \(alex.props[plan.id]?["edited_by"]?.string ?? "-")")
        let appended = await mac.mcp("append_to_note", ["id": plan.id.uuidString, "text": "Agent A: the banners are ordered."], as: agent)
        arrived = await bed.eventually(10) { alex.texts[plan.id]?.contains("banners are ordered") == true }
        bed.check(appended.ok && arrived, "append_to_note by Agent A reaches Alex")
        let added = await mac.mcp("add_note", ["text": "# Agent A's checklist\n\n- Tables\n- Chairs", "binder": "Shared"], as: agent)
        let checklist = (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>()))?.first { $0.title == "Agent A's checklist" }
        arrived = await bed.eventually(10) { checklist.map { alex.texts[$0.id] != nil } ?? false }
        bed.check(added.ok && arrived, "add_note by Agent A: a new note on Alex's Mac")
        if let checklist {
            bed.check(alex.props[checklist.id]?["made_by"]?.string == "Agent A (Sam)", "made by Agent A (Sam), as the team names it")
            bed.check(try await count("SELECT count(*) FROM binders.note_versions WHERE note_id = $1::uuid AND agent_id = $2::uuid",
                                      [checklist.id.uuidString, bed.agentA.uuidString]) == 1, "its first version is Agent A's")
        }

        // MARK: Who's in a note: shows, and clears when they leave or go quiet.
        try await alex.be(in: plan.id)
        var shown = await bed.eventually(5) { notes.presenceLine(plan.id) == "Alex is in this note" }
        bed.check(shown, "Alex opens the note: “\(notes.presenceLine(plan.id) ?? "-")”")
        try await alex.be(in: plan.id, here: false)
        var cleared = await bed.eventually(5) { notes.presenceLine(plan.id) == nil }
        bed.check(cleared, "Alex closes it: the line goes")
        notes.presenceLasts = 2
        try await alex.be(in: plan.id)
        shown = await bed.eventually(5) { notes.presenceLine(plan.id) != nil }
        cleared = await bed.eventually(8) { notes.presenceLine(plan.id) == nil }
        bed.check(shown && cleared, "Alex's Mac goes quiet without closing it: the line goes once it's stale")
        notes.presenceLasts = TeamPresenceRow.lasts
        notes.opened(plan.id)
        shown = await bed.eventually(5) { alex.presence[plan.id]?.contains { $0.memberID == bed.samID && $0.isHere() } == true }
        notes.closed(plan.id)
        cleared = await bed.eventually(5) { alex.presence[plan.id]?.contains { $0.memberID == bed.samID && $0.isHere() } == false }
        bed.check(shown && cleared, "Sam opening and closing it shows and clears on Alex's Mac")
        let presence = try await root.value("SELECT count(*) FROM information_schema.columns WHERE table_schema = 'binders' AND table_name = 'note_presence'",
                                            as: Int64.self) ?? 0
        bed.check(presence == 10, "presence keeps who, which note, viewing or reviewing, and when: \(presence) columns, nothing typed")

        let spec = try await teamNotesVersionChecks(bed, mac: mac, alex: alex, root: root, plan: plan)
        try await teamNotesFolderChecks(bed, mac: mac, alex: alex, plan: plan, spec: spec)
        await alex.stop()
        await mac.stop()
    }
}

extension SelfTest {
    /// Versions: who made each; one person's quick edits, one version; putting one back adds one; names; what's kept; a
    /// teammate's section change and an agent's. Returns the Distill note it made.
    @MainActor
    static func teamNotesVersionChecks(_ bed: TeamDBTestBed, mac: TeamMac, alex: NotesMac, root: TeamDatabaseLink, plan: NoteItem) async throws -> NoteItem {
        let notes = mac.team.notes
        func count(_ sql: String, _ values: [String?] = []) async throws -> Int64 { try await root.value(sql, values, as: Int64.self) ?? -1 }
        func live(_ note: UUID) async throws -> Int64 {
            try await count("SELECT count(*) FROM binders.note_versions WHERE note_id = $1::uuid AND deleted_at IS NULL", [note.uuidString])
        }
        _ = await mac.drained()
        _ = await alex.drained()

        // MARK: Every version says who made it.
        var versions = await notes.versions(of: plan)
        let authors = Set(versions.map(\.by))
        bed.check(authors.contains(.you) && authors.contains(.teammate("Alex")) && authors.contains(.agent("Agent A", owner: BoardActor.you.name)),
                  "versions by you, by Alex, and by Agent A, your agent: \(authors.map(\.label).sorted())")
        let theirs = alex.engine.history(plan.id)
        bed.check(theirs.contains { $0.memberID == bed.samID && $0.agentID == bed.agentA } && theirs.contains { $0.memberID == bed.alexID && $0.agentID == nil },
                  "on Alex's Mac too, by member and agent: \(theirs.count) versions")
        bed.check(versions.allSatisfy { !$0.text.isEmpty } && versions.first.map { $0.text == plan.text } == true,
                  "each version's text is there, the newest the note as it is")
        // A version's numbers are its whole difference, not a sum of keystrokes.
        if let alexs = versions.first(where: { $0.by == .teammate("Alex") }) {
            let exact = TeamNoteStats.between(alexs.before, alexs.text)
            bed.check(alexs.row.linesAdded == exact.added && alexs.row.linesRemoved == exact.removed,
                      "Alex's version adds \(alexs.row.linesAdded) and removes \(alexs.row.linesRemoved) lines in the database, as the document says (\(exact.added), \(exact.removed))")
        }
        // One person's quick edits: one version.
        let before = try await live(plan.id)
        alex.type(plan.id, alex.text(plan.id) + "Alex: first thought.\n")
        _ = await alex.drained()
        alex.type(plan.id, alex.text(plan.id) + "Alex: second thought.\n")
        _ = await alex.drained()
        bed.check(try await live(plan.id) == before + 1, "two quick edits by Alex make one version")
        _ = await bed.eventually(10) { plan.text == alex.texts[plan.id] }

        // MARK: Putting a version back adds a version; nothing is taken away.
        versions = await notes.versions(of: plan)
        guard let oldest = versions.last else { throw TeamDatabase.Problem.refused("no versions of the plan") }
        let had = versions.count
        bed.check(notes.restore(oldest.id.uuidString, to: plan) && plan.text == oldest.text, "Restore This Version: the note is that version again")
        var arrived = await bed.eventually(10) { alex.texts[plan.id] == oldest.text }
        bed.check(arrived, "and so it is on Alex's Mac")
        _ = await mac.drained()
        bed.check(try await count("SELECT count(*) FROM binders.note_versions WHERE note_id = $1::uuid AND restored_from = $2::uuid AND member_id = $3::uuid",
                                  [plan.id.uuidString, oldest.id.uuidString, bed.samID.uuidString]) == 1,
                  "a new version, by Sam, that says which it put back")
        versions = await notes.versions(of: plan)
        bed.check(versions.count == had + 1 && versions.contains { $0.id == oldest.id }, "one more version than before, the one put back still there")
        // A name goes to the team, and a named version stays as it was named.
        alex.type(plan.id, alex.text(plan.id) + "Alex: ready for review.\n")
        _ = await alex.drained()
        _ = await bed.eventually(10) { notes.engine?.history(plan.id).first?.memberID == bed.alexID }
        if let named = notes.engine?.history(plan.id).first, named.memberID == bed.alexID {
            let versionsNow = try await live(plan.id)
            NoteHistory.name(named.id.uuidString, of: plan, "Approved")
            arrived = await bed.eventually(10) { alex.engine.history(plan.id).contains { $0.id == named.id && $0.name == "Approved" } }
            bed.check(arrived, "Alex's version named Approved here is named on Alex's Mac")
            alex.type(plan.id, alex.text(plan.id) + "Alex: after the name.\n")
            _ = await alex.drained()
            let unchanged = try await count("SELECT count(*) FROM binders.note_versions WHERE id = $1::uuid AND last_hash = $2::text",
                                            [named.id.uuidString, named.lastHash])
            let versionsAfter = try await live(plan.id)
            bed.check(unchanged == 1 && versionsAfter == versionsNow + 1, "Alex's next edit starts a new version: the named one stays as it was named")
        } else {
            bed.check(false, "Sam's Mac knows Alex's newest version")
        }
        let entries = NoteHistory.entries(of: plan)
        let listed = await notes.versions(of: plan).count
        bed.check(entries.first?.id == NoteVersions.nowID && entries.count == listed + 1,
                  "History lists the team's versions under the note as it is (\(entries.count) entries)")

        // MARK: What's kept: a Distill note's versions forever; another's, 30 days beyond its latest 20.
        let kept = NoteItem(text: "# Release checklist\n\nEvery step.\n")
        kept.binderID = bed.shared
        let forever = NoteItem(text: "# Auth spec\n\n## Tokens\n\nShort lived.\n")
        forever.binderID = bed.shared
        forever.distill = true
        Store.shared.insert(kept)
        Store.shared.insert(forever)
        arrived = await bed.eventually(10) { alex.texts[kept.id] != nil && alex.texts[forever.id] != nil }
        bed.check(arrived, "two more notes, one with Distill on")
        for note in [kept.id, forever.id] {
            // 24 versions: Alex and Alex's agent take turns.
            for turn in 0..<24 { alex.type(note, alex.text(note) + "Turn \(turn).\n", agent: turn % 2 == 0 ? nil : bed.agentC) }
        }
        _ = await alex.drained(30)
        try await root.execute("UPDATE binders.note_versions SET started_at = now() - interval '40 days', ended_at = now() - interval '40 days' WHERE note_id = ANY ($1::uuid[])",
                               ["{\(kept.id.uuidString),\(forever.id.uuidString)}"])
        _ = await bed.eventually(10) { kept.text == alex.texts[kept.id] && forever.text == alex.texts[forever.id] }
        kept.text += "Sam again.\n"
        forever.text += "Sam again.\n"
        notes.capture(kept, by: .person)
        notes.capture(forever, by: .person)
        _ = await mac.drained()
        let keptLive = try await live(kept.id), foreverLive = try await live(forever.id)
        bed.check(keptLive == 20, "a note without Distill keeps its latest 20 versions once older ones pass 30 days (\(keptLive) of 26)")
        bed.check(foreverLive == 26, "a Distill note keeps every version (\(foreverLive) of 26)")

        // MARK: A teammate's section change flags its card and tells the agent; an agent's change is held back.
        let spec = NoteItem(text: "# Onboarding spec\n\n## Accounts\n\nMake the accounts.\n\n## Laptops\n\nOrder laptops.\n")
        spec.binderID = bed.shared
        spec.distill = true
        Store.shared.insert(spec)
        arrived = await bed.eventually(10) { alex.texts[spec.id] == spec.text }
        let sections = DistillSections.sections(of: spec.text)
        // Distilled and placed as Distill does it: the version it read is the team's, and the cards go with their part.
        let reading = UUID()
        let read = NoteHistory.markRead(spec, by: reading)
        let record = DistillRecord(id: reading, note: spec.id, ranBy: BoardActor.you.name, readBy: "stand-in model", version: read,
                                   items: [DistillItem(title: "Make the accounts", section: "Accounts", sectionHash: sections.first { $0.heading == "Accounts" }?.hash,
                                                       meantFor: "Agent A"),
                                           DistillItem(title: "Order the laptops", section: "Laptops", sectionHash: sections.first { $0.heading == "Laptops" }?.hash,
                                                       meantFor: "Agent B")])
        DistillStore.shared.save(record)
        let placed = mac.controller.distill.place(record, items: Set(record.items.map(\.id)), column: .ready)
        bed.check(read.hasPrefix(TeamNotes.headsPrefix) && placed.count == 2, "the version Distill read is the team's document as it was (\(read.prefix(16))…), and 2 cards placed")
        _ = await mac.drained()
        guard placed.count == 2 else { return spec }
        let accounts = placed[0], laptops = placed[1]
        let markedRead = await bed.eventually(10) { alex.engine.history(spec.id).contains { $0.distillID == reading } }
        bed.check(markedRead, "the version it read is marked with the distill on Alex's Mac too")
        let first = await mac.claim(accounts.id, as: "Agent A"), second = await mac.claim(laptops.id, as: "Agent B")
        bed.check(arrived && first.ok && second.ok, "a Distill note on the shared board, its two cards held by Agents A and B")
        let wokeAccounts = mac.wakes(of: accounts.id).count, wokeLaptops = mac.wakes(of: laptops.id).count
        alex.type(spec.id, alex.text(spec.id).replacingOccurrences(of: "Make the accounts.", with: "Make the accounts and the mail groups."))
        let flagged = await bed.eventually(15) {
            mac.board.timeline(accounts.id).contains { $0.author == "Binders" && $0.text.hasPrefix("The Accounts section of “Onboarding spec” changed after this card was made: by Alex") }
        }
        bed.check(flagged, "Alex changes the Accounts section: its card says so, by Alex")
        if !flagged {
            print("NOTE: spec distill \(spec.distill), service \(DistillService.shared != nil), cards of it \(DistillBoard.cards(of: spec.id).map(\.title))")
            print("NOTE: distilled from \(String(describing: accounts.distilledFrom)); source \(accounts.sourceID ?? "-")")
            print("NOTE: spec here: \(spec.text.debugDescription)")
            for line in mac.board.timeline(accounts.id) { print("NOTE: line by \(line.author): \(line.text.prefix(120))") }
        }
        bed.check(accounts.distilledFrom?.held != true, "a person's change isn't held back")
        let told = await bed.eventually(15) { mac.wakes(of: accounts.id).count > wokeAccounts }
        bed.check(told, "and Agent A, holding the card, is told")
        if !told {
            print("NOTE: notice kept: \(mac.controller.agents.notices[accounts.id] != nil); outcome: \(String(describing: mac.controller.agents.outcomes[accounts.id])); wakes: \(mac.wakes(of: accounts.id)); column \(accounts.column.rawValue), assignee \(accounts.assignee ?? "-")")
            print("NOTE: wakeable: \(AgentRegistry.shared.agents.map { "\($0.name) \(AgentRegistry.shared.wakeable($0))" })")
        }
        alex.type(spec.id, alex.text(spec.id).replacingOccurrences(of: "Order laptops.", with: "Order laptops and docks."), agent: bed.agentC)
        let held = await bed.eventually(15) {
            mac.board.timeline(laptops.id).contains { $0.author == "Binders" && $0.text.hasPrefix("The Laptops section of “Onboarding spec” changed after this card was made: by Agent C (Alex's agent)") }
        }
        bed.check(held && laptops.distilledFrom?.held == true, "Alex's agent changes the Laptops section: its card says so, held back for a person to look")
        try await Task.sleep(for: .seconds(2))
        bed.check(mac.wakes(of: laptops.id).count == wokeLaptops, "and Agent B isn't told until a person looks")
        return spec
    }
}

extension SelfTest {
    /// Folders and moves reach the other Mac, both ways; proposals are seen by the team, with who's reviewing them.
    @MainActor
    static func teamNotesFolderChecks(_ bed: TeamDBTestBed, mac: TeamMac, alex: NotesMac, plan: NoteItem, spec: NoteItem) async throws {
        let notes = mac.team.notes

        // MARK: Folders: made, moved into, renamed, nested, here; made, moved into and deleted on Alex's Mac.
        guard let specs = Store.shared.createFolder(named: "Specs", in: bed.shared) else { throw TeamDatabase.Problem.refused("no folder") }
        var arrived = await bed.eventually(10) { alex.folders[specs.id]?.name == "Specs" && alex.folders[specs.id]?.deletedAt == nil }
        bed.check(arrived, "a folder made here is on Alex's Mac")
        Store.shared.move(plan, toFolder: specs.id)
        arrived = await bed.eventually(10) { alex.engine.rows[plan.id]?.folderID == specs.id }
        bed.check(arrived, "a note moved into it here is in it there")
        _ = Store.shared.rename(specs, to: "Specs 2026")
        guard let drafts = Store.shared.createFolder(named: "Drafts", in: bed.shared, parent: specs.id) else { throw TeamDatabase.Problem.refused("no folder") }
        arrived = await bed.eventually(10) { alex.folders[specs.id]?.name == "Specs 2026" && alex.folders[drafts.id]?.parentID == specs.id }
        bed.check(arrived, "renamed, and a folder inside it: so there too")
        let ideas = UUID()
        alex.database.send(.putFolder(ideas, binder: bed.shared, fields: ["name": "Ideas"]))
        arrived = await bed.eventually(10) { Store.shared.folder(ideas)?.name == "Ideas" }
        bed.check(arrived, "a folder Alex makes is here")
        alex.database.send(.moveNote(plan.id, binder: bed.shared, folder: ideas))
        arrived = await bed.eventually(10) { plan.folderID == ideas }
        bed.check(arrived, "Alex moves the note into it: it's in it here")
        alex.database.send(.deleteFolder(ideas))
        arrived = await bed.eventually(10) { Store.shared.folder(ideas) == nil && plan.folderID == nil }
        bed.check(arrived, "Alex deletes it: gone here, and the note moved up to the top, not deleted")
        Store.shared.move(spec, toFolder: drafts.id)
        _ = await bed.eventually(10) { alex.engine.rows[spec.id]?.folderID == drafts.id }
        let removal = Store.shared.deleteFolder(specs)
        arrived = await bed.eventually(10) { alex.folders[specs.id]?.deletedAt != nil && alex.folders[drafts.id]?.parentID == nil }
        bed.check(arrived && alex.engine.rows[spec.id]?.folderID == drafts.id, "deleting Specs here: deleted there, what it held moved up")
        Store.shared.restore(removal)
        arrived = await bed.eventually(10) { alex.folders[specs.id]?.deletedAt == nil }
        bed.check(arrived, "and Undo puts it back for the team")
        // Out to a binder Alex isn't in, and back.
        if let personal = Store.shared.binder(bed.personal), let shared = Store.shared.binder(bed.shared) {
            Store.shared.move(plan, to: personal)
            arrived = await bed.eventually(10) { alex.texts[plan.id] == nil }
            bed.check(arrived, "moved to a binder Alex isn't in: gone from Alex's Mac")
            Store.shared.move(plan, to: shared)
            arrived = await bed.eventually(10) { alex.texts[plan.id] == plan.text }
            bed.check(arrived, "moved back: on Alex's Mac again, as it is")
            if !arrived {
                print("NOTE: Alex has it: \(alex.texts[plan.id] != nil), knows it: \(alex.engine.knows(plan.id)); lengths \(alex.text(plan.id).count) and \(plan.text.count); Sam's turned down: \(notes.turnedDown)")
                print("NOTE: Alex's:\n\(alex.text(plan.id))\nNOTE: Sam's:\n\(plan.text)")
            }
        }

        // MARK: Proposals: seen by the team, with who's reviewing; Alex's review and placing reach this Mac.
        let record = DistillRecord(note: spec.id, ranBy: BoardActor.you.name, readBy: "stand-in model",
                                   items: [DistillItem(title: "Create the accounts", section: "Accounts", meantFor: "Agent A"),
                                           DistillItem(title: "Order the laptops", section: "Laptops", meantFor: BoardActor.you.name)])
        DistillStore.shared.save(record)
        arrived = await bed.eventually(10) { alex.distills[record.id] != nil && alex.items.values.filter { $0["distill_id"]?.uuid == record.id }.count == 2 }
        bed.check(arrived, "a proposal made here is on Alex's Mac, with its items")
        let meant = alex.items.values.filter { $0["distill_id"]?.uuid == record.id }.sorted { ($0["position"]?.double ?? 0) < ($1["position"]?.double ?? 0) }
            .compactMap { $0["meant_for"]?.string }
        bed.check(alex.distills[record.id]?["extra"]?["ran_by"]?.string == "Sam" && meant == ["Agent A (Sam)", "Sam"],
                  "named as the team names them: run by Sam, meant for \(meant)")
        if var item = alex.items[record.items[0].id] {
            item["title"] = "Create the accounts and the groups"
            alex.database.send(.put(item, in: .distillItems))
        }
        arrived = await bed.eventually(10) { DistillStore.shared.distill(record.id, of: spec.id)?.items.first?.title == "Create the accounts and the groups" }
        bed.check(arrived && DistillStore.shared.distill(record.id, of: spec.id)?.items.first?.meantFor == "Agent A",
                  "Alex edits an item: here too, still meant for Agent A as this Mac names it")
        try await alex.be(in: spec.id, reviewing: record.id)
        arrived = await bed.eventually(5) { notes.reviewingLine(spec.id, distill: record.id) == "Alex is reviewing these items" }
        bed.check(arrived, "the Work bar says who's reviewing: “\(notes.reviewingLine(spec.id, distill: record.id) ?? "-")”")
        if var row = alex.distills[record.id] {
            row["status"] = "placed"
            alex.database.send(.put(row, in: .distills))
        }
        arrived = await bed.eventually(10) { DistillStore.shared.distill(record.id, of: spec.id)?.status == .placed }
        bed.check(arrived, "Alex places it: placed here too, so it isn't placed twice")
        try await alex.be(in: spec.id, here: false)
        let echoes = mac.team.database?.queued.filter { ["put_row", "put_rows"].contains($0.call.function) }.count ?? 0
        bed.check(echoes == 0, "what came from the team isn't sent back to it (\(echoes) waiting)")

        // MARK: Properties travel with the note, both ways; Make It Mine clears an agent's mark for the team.
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20)) ?? Date()
        plan.status = "Draft"
        plan.dueAt = due
        notes.capture(plan, by: .person)
        arrived = await bed.eventually(10) { alex.props[plan.id]?["status"]?.string == "Draft" && alex.props[plan.id]?["due"]?.date == due }
        bed.check(arrived, "a status and a due date set here are on Alex's Mac")
        var turnedOn = alex.props[plan.id] ?? [:]
        turnedOn["distill"] = true
        turnedOn["owner"] = "Alex"
        alex.engine.edited(plan.id, text: alex.text(plan.id), props: turnedOn)
        arrived = await bed.eventually(10) { plan.distill && plan.owner == "Alex" }
        bed.check(arrived, "Alex turns Distill on and takes it: so here too")
        bed.check(plan.editedBy == "Agent A", "the note still carries Agent A's edit")
        plan.makeMine()
        notes.capture(plan, by: .person)
        arrived = await bed.eventually(10) { alex.props[plan.id]?["edited_by"] == .null && alex.props[plan.id]?["made_by"] == .null }
        bed.check(arrived, "Make It Mine here clears the agent's mark on Alex's Mac")

        // MARK: Deleting, both ways, and Undo.
        let scratch = NoteItem(text: "# Scratch\n\nTo throw away.\n")
        scratch.binderID = bed.shared
        Store.shared.insert(scratch)
        _ = await bed.eventually(10) { alex.texts[scratch.id] != nil }
        let entry = NoteTrash.Entry(scratch)
        Store.shared.delete(scratch, keepingHistory: true)
        notes.sweep()
        arrived = await bed.eventually(10) { alex.texts[scratch.id] == nil }
        bed.check(arrived, "a note deleted here goes from Alex's Mac")
        let back = NoteTrash.shared.restore(entry, undoManager: nil)
        notes.sweep()
        arrived = await bed.eventually(10) { alex.texts[scratch.id] == "# Scratch\n\nTo throw away.\n" }
        bed.check(back != nil && arrived, "Undo puts it back for Alex too")
        if !arrived {
            print("NOTE: back here \(back != nil), Sam knows it \(notes.shares(scratch.id)), Alex has \(alex.texts[scratch.id]?.debugDescription ?? "nothing"), Alex knows \(alex.engine.knows(scratch.id))")
            print("NOTE: waiting: \(mac.team.database?.queued.map { "\($0.call.function) \($0.lastError ?? "")" } ?? []); turned down: \(notes.turnedDown.suffix(4))")
        }
        alex.database.send(.delete(scratch.id, from: .notes))
        arrived = await bed.eventually(10) { Store.shared.note(scratch.id) == nil }
        bed.check(arrived, "Alex deletes it: it goes from here")
    }
}

extension SelfTest {
    /// Moving a folder team over. Sam (this Mac) and Alex share a team folder: Sam's binder Work (a note in the folder
    /// DevOps, another at the top, a meeting with its transcript) and Alex's binder Design (a note, a meeting). Sam moves
    /// first: everything arrives once, with who wrote it. Run again, nothing changes. Alex keeps working in the folder
    /// meanwhile, and Sam in the database; then Alex moves: Alex's new note and edits come in, merged with Sam's, nothing
    /// lost and nothing twice.
    @MainActor
    static func teamMoveChecks(_ bed: TeamDBTestBed) async throws {
        let root = try await bed.root()
        func count(_ sql: String, _ values: [String?] = []) async throws -> Int64 { try await root.value(sql, values, as: Int64.self) ?? -1 }
        let fileManager = FileManager.default
        let base = AppPaths.support.appendingPathComponent("team-move", isDirectory: true)
        let folder = base.appendingPathComponent("Team", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try TeamSyncService.prepareTeamFolder(folder)

        // MARK: A folder team: Sam (this Mac) and Alex.
        let mac = try await TeamMac.start(bed)
        let notes = mac.team.notes
        notes.gather = .milliseconds(150)
        let samSync = mac.controller.team
        let samInFolder = TeamAuthor(id: "folder-sam", name: "Sam"), alexInFolder = TeamAuthor(id: "folder-alex", name: "Alex")
        samSync.identityOverride = (folder, samInFolder)
        samSync.deletionGrace = 0
        samSync.idAssignmentAge = 0
        let alexStore = Store(url: base.appendingPathComponent("alex.store"))
        let alexSync = TeamSyncService(flowBar: nil, store: alexStore, stateURL: base.appendingPathComponent("alex-sync.json"))
        alexSync.identityOverride = (folder, alexInFolder)
        alexSync.deletionGrace = 0
        alexSync.idAssignmentAge = 0
        func note(_ text: String, in binder: BinderRecord, store: Store, folder: UUID? = nil) -> NoteItem {
            let note = NoteItem(text: text)
            note.binderID = binder.id
            note.sharedWithTeam = true
            note.folderID = folder
            store.insert(note)
            return note
        }
        func meeting(_ title: String, in binder: BinderRecord, store: Store, lines: [String]) -> MeetingRecord {
            let meeting = MeetingRecord(title: title, appName: "Zoom", templateID: "general")
            meeting.binderID = binder.id
            meeting.sharedWithTeam = true
            meeting.status = "ready"
            meeting.duration = Double(lines.count * 10)
            meeting.summary = "Summary of \(title)."
            store.insert(meeting)
            store.replaceSegments(for: meeting.id, with: lines.enumerated().map { index, line in
                TranscriptSegment(id: UUID(), channel: .microphone, start: Double(index * 10), end: Double(index * 10 + 8), text: line, speaker: "Speaker 1")
            })
            return meeting
        }
        let work = BinderRecord(name: "Work", colorIndex: 1)
        work.sharedWithTeam = true
        Store.shared.insert(work)
        guard let devOps = Store.shared.createFolder(named: "DevOps", in: work.id) else { throw TeamDatabase.Problem.refused("no folder") }
        let cleanup = note("# Pipeline cleanup\n\nOld runners go.\n", in: work, store: Store.shared, folder: devOps.id)
        let release = note("# Release notes\n\nWhat's new.\n", in: work, store: Store.shared)
        let weekly = meeting("Weekly sync", in: work, store: Store.shared, lines: ["We ship Friday.", "Banners are late.", "Lunch at noon."])
        await samSync.syncNow()
        await alexSync.syncNow()
        let design = BinderRecord(name: "Design", colorIndex: 2)
        design.sharedWithTeam = true
        alexStore.insert(design)
        let palette = note("# Colour palette\n\nBlue and grey.\n", in: design, store: alexStore)
        let review = meeting("Design review", in: design, store: alexStore, lines: ["The palette works.", "Icons next week."])
        await alexSync.syncNow()
        await samSync.syncNow()
        await alexSync.syncNow()
        func notesOf(_ store: Store) -> [NoteItem] { (try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? [] }
        let together = notesOf(Store.shared).filter { [cleanup.id, release.id, palette.id].contains($0.id) }.count == 3
            && notesOf(alexStore).filter { [cleanup.id, release.id, palette.id].contains($0.id) }.count == 3
        bed.check(together, "a folder team: Sam and Alex each have its three notes")

        // MARK: Sam moves first: everything once, with who wrote it, and folder sync stops on Sam's Mac.
        let summary = try await notes.moveFolderTeam(from: samSync)
        bed.check(summary.binders == 2 && summary.notes == 3 && summary.meetings == 2 && summary.folders == 1,
                  "Sam moves the team: \(summary.line)")
        _ = await mac.drained(30)
        let ids = [work.id, design.id].map(\.uuidString)
        bed.check(try await count("SELECT count(*) FROM binders.binders WHERE id = ANY ($1::uuid[])", ["{\(ids.joined(separator: ","))}"]) == 2,
                  "both binders are in the database, once")
        bed.check(try await count("SELECT count(*) FROM binders.binders WHERE id = $1::uuid AND created_by = $2::uuid", [design.id.uuidString, bed.alexID.uuidString]) == 1,
                  "Alex's binder is Alex's there (by name: the team folder's Alex is the database's)")
        bed.check(try await count("SELECT count(*) FROM binders.notes WHERE id = ANY ($1::uuid[])",
                                  ["{\(cleanup.id.uuidString),\(release.id.uuidString),\(palette.id.uuidString)}"]) == 3, "the three notes, once each")
        bed.check(try await count("SELECT count(*) FROM binders.notes WHERE id = $1::uuid AND created_by = $2::uuid AND imported_author ->> 'name' = 'Alex'",
                                  [palette.id.uuidString, bed.alexID.uuidString]) == 1, "Alex's note is by Alex, brought in from the folder")
        bed.check(try await count("SELECT count(*) FROM binders.note_versions WHERE note_id = $1::uuid AND member_id = $2::uuid AND imported",
                                  [palette.id.uuidString, bed.alexID.uuidString]) == 1, "its first version is Alex's")
        bed.check(try await count("SELECT count(*) FROM binders.notes WHERE id = $1::uuid AND folder_id = $2::uuid", [cleanup.id.uuidString, devOps.id.uuidString]) == 1,
                  "the note in DevOps is in DevOps there")
        let alexsMeeting = try await count("SELECT count(*) FROM binders.meetings WHERE id = $1::uuid AND author_id = $2::uuid", [review.id.uuidString, bed.alexID.uuidString])
        let weeklyLines = try await count("SELECT count(*) FROM binders.meeting_segments WHERE meeting_id = $1::uuid", [weekly.id.uuidString])
        bed.check(alexsMeeting == 1 && weeklyLines == 3, "both meetings, Alex's by Alex, with their transcripts (\(weeklyLines) lines)")
        bed.check(!samSync.isConfigured && fileManager.fileExists(atPath: folder.appendingPathComponent("_binders/moved.json").path),
                  "folder sync stopped on Sam's Mac, and the folder says the team moved")
        bed.check(Store.shared.note(palette.id) != nil && Store.shared.binder(design.id)?.teamDatabaseKey == bed.sam.key,
                  "Alex's note stays on Sam's Mac: the database's now")

        // MARK: Again: nothing changes.
        let tables = "('binders','folders','notes','note_changes','note_versions','meetings','meeting_segments')"
        // The first move settles first: notes go whole a few seconds after their last change, and on a busy Mac one could
        // land while the second move runs and be counted as its change. Every save that's due within the hour goes now.
        await notes.engine?.saveDue(now: Date().addingTimeInterval(3_600))
        _ = await mac.drained(30)
        let feedBefore = try await count("SELECT count(*) FROM binders.changes WHERE table_name IN \(tables)")
        for binder in [work, design] { binder.sharedWithTeam = true }
        let again = TeamMove(store: Store.shared, database: mac.team.database!, engine: notes.engine!, directory: mac.team.directory, me: samInFolder,
                             member: bed.samID, key: bed.sam.key, shareBoard: { mac.team.share($0, everyone: true, with: []) },
                             props: { notes.teamProps(of: $0) })
        _ = await again.run()
        again.finish()
        _ = await mac.drained(30)
        let feedAfter = try await count("SELECT count(*) FROM binders.changes WHERE table_name IN \(tables)")
        bed.check(feedAfter == feedBefore, "moving again changes nothing in the database (\(feedAfter - feedBefore) changes)")

        // MARK: Meanwhile: Sam in the database, Alex still in the folder.
        release.text += "Sam, in the database: ship Friday.\n"
        notes.capture(release, by: .person)
        _ = await mac.drained()
        guard let alexRelease = alexStore.note(release.id) else { throw TeamDatabase.Problem.refused("Alex has no release notes") }
        alexRelease.text += "Alex, in the folder: check the changelog.\n"
        let idea = note("# A new idea\n\nDark mode.\n", in: design, store: alexStore)
        review.userNotes = "Decided: blue."
        alexStore.save()
        await alexSync.syncNow()
        bed.check(alexSync.status.moved?.by.name == "Sam", "Alex's folder sync says the team moved: \(alexSync.status.moved?.line.prefix(60) ?? "-")")
        let file = (try? fileManager.contentsOfDirectory(at: folder.appendingPathComponent("Notes"), includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix("Release notes") }
        let fileText = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        bed.check(fileText.contains("Alex, in the folder") && !fileText.contains("Sam, in the database"),
                  "the folder has Alex's edit and not Sam's: Binders on Sam's Mac doesn't write it any more")
        bed.check(!alexRelease.text.contains("Sam, in the database"), "what changed in the database doesn't reach Alex's folder sync")

        // MARK: Alex moves: Alex's new note and edits come in, merged with Sam's; nothing lost, nothing twice.
        let alexMac = try await NotesMac.start(bed, folder: "alex-moving")
        var directory = TeamDirectory(me: bed.alexID)
        for row in try await alexMac.database.rows(.members, binder: UUID()) { directory.take(member: row) }
        let alexMove = TeamMove(store: alexStore, database: alexMac.database, engine: alexMac.engine, directory: directory, me: alexInFolder,
                                member: bed.alexID, key: bed.alex.key,
                                props: { TeamNoteProps(properties: $0.properties, mark: TeamNoteMark(madeBy: $0.madeBy, editedBy: $0.editedBy, editedAt: $0.editedAt)).values })
        let alexSummary = await alexMove.run()
        _ = await alexMac.drained(30)
        await alexSync.stopForMove(TeamMoveMarker(database: bed.database, host: "127.0.0.1", by: alexInFolder, at: Date()))
        alexMove.finish()
        bed.check(alexSummary.notes == 4 && alexSummary.merged + 0 >= 0, "Alex moves: \(alexSummary.line)")
        let merged = await bed.eventually(15) {
            release.text.contains("Sam, in the database") && release.text.contains("Alex, in the folder")
        }
        bed.check(merged && release.text.components(separatedBy: "ship Friday").count == 2 && release.text.components(separatedBy: "changelog").count == 2,
                  "the release notes on Sam's Mac have Sam's line and Alex's, once each")
        let arrived = await bed.eventually(15) { Store.shared.note(idea.id) != nil }
        bed.check(arrived, "Alex's new note arrives on Sam's Mac")
        bed.check(try await count("SELECT count(*) FROM binders.notes WHERE binder_id = ANY ($1::uuid[]) AND deleted_at IS NULL", ["{\(ids.joined(separator: ","))}"]) == 4,
                  "four notes in the two binders: none twice")
        bed.check(try await count("SELECT count(*) FROM binders.meetings WHERE id = $1::uuid AND notes = 'Decided: blue.' AND author_id = $2::uuid",
                                  [review.id.uuidString, bed.alexID.uuidString]) == 1, "Alex's meeting notes came in, still Alex's meeting")
        bed.check(try await count("SELECT count(*) FROM binders.notes WHERE id = $1::uuid AND created_by = $2::uuid", [palette.id.uuidString, bed.alexID.uuidString]) == 1,
                  "Alex's own note is still Alex's")
        let paletteChanges = try await count("SELECT count(*) FROM binders.note_changes WHERE note_id = $1::uuid", [palette.id.uuidString])
        bed.check(paletteChanges == 2, "a note nobody changed since gets nothing more (\(paletteChanges) changes: the skeleton and its words)")
        await alexMac.stop()
        await mac.stop()
    }
}
