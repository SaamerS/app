import Foundation
import BindersKit

/// Settings → Team → Remove Copies Made When Teammates Joined… (lane DB9): a one-time repair an admin runs from their Mac.
/// Build 39 shared a note again under a new id whenever the database said it was deleted while something for it waited,
/// so connecting over deletions an earlier Binders left, and each teammate joining from their team-folder copies, made
/// copies of the team's notes. This finds them in the database (TeamNoteCopies: same title and words, made by another
/// member than the note that stays) and removes them with the database's own delete, so every Mac follows. It never runs
/// on its own, never touches a note whose words differ by a character, and run again it finds nothing.
extension TeamNotes {
    /// What a look for copies found, and whether they may go now.
    struct CopiesFound {
        var found = TeamNoteCopies.Found()
        /// Why they can't go now, and what to do first; nil when they can.
        var refusal: String?
        /// What to make sure of first, when the database can't tell.
        var caution: String?
        /// Copies left because this Mac's own copy of them is changing (something for it waits to go, or its words here
        /// differ from the database's).
        var changing = 0
        var memberNames: [UUID: String] = [:]
        var binderNames: [UUID: String] = [:]
        var folderNames: [UUID: String] = [:]

        /// "Robin, 22 Oct 2026 at 03:02, in Plans · Harbor"
        func line(_ note: TeamNoteCopies.Note) -> String {
            var parts = [note.maker.flatMap { memberNames[$0] } ?? "A teammate"]
            if let made = note.createdAt { parts.append(made.formatted(date: .abbreviated, time: .shortened)) }
            let place = [note.folder.flatMap { folderNames[$0] }, binderNames[note.binder]].compactMap { $0 }.joined(separator: " · ")
            return parts.joined(separator: ", ") + (place.isEmpty ? "" : ", in \(place)")
        }
    }

    enum CopiesProblem: LocalizedError {
        case notConnected, notAdmin, refused(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: "This Mac isn't connected to the team database now. Try again once Settings → Team says Connected."
            case .notAdmin: "Only an admin of the team can remove copies for everyone."
            case .refused(let why): why
            }
        }
    }

    /// Looks for copies in every binder shared through the database, as it has them now. Reads only.
    func findCopies() async throws -> CopiesFound {
        guard let engine, let database = board.database, board.isConnected else { throw CopiesProblem.notConnected }
        guard board.isAdmin else { throw CopiesProblem.notAdmin }
        var result = CopiesFound()
        for member in directory.members.values { result.memberNames[member.id] = member.name }
        var candidates: [TeamNoteCopies.Note] = []
        var owners: [UUID: UUID] = [:]
        let binders = board.sharedBinders.sorted { $0.uuidString < $1.uuidString }
        for row in try await database.rows(.binders, ids: binders) {
            guard let id = row.rowID else { continue }
            result.binderNames[id] = row["name"]?.string
            owners[id] = row["created_by"]?.uuid
        }
        for binder in binders {
            for folder in store.folders(in: binder) { result.folderNames[folder.id] = folder.name }
            let rows = try await database.rows(.notes, binder: binder).compactMap(TeamNoteRow.init(row:)).filter { $0.deletedAt == nil }
            // Only notes that share a title with another can be copies: their words are read whole (the saved copy and every
            // change since), the rest aren't.
            let byTitle = Dictionary(grouping: rows, by: \.title).filter { $0.value.count > 1 }
            let wanted = byTitle.values.flatMap { $0 }
            guard !wanted.isEmpty else { continue }
            let changes = try await database.json(TeamQueries.notesChanges, [TeamJSON(wanted.map(\.id)).text]).array?
                .compactMap { $0.object.flatMap(TeamNoteChangeRow.init(row:)) } ?? []
            let changesByNote = Dictionary(grouping: changes, by: \.noteID)
            let seen = try await database.json(TeamQueries.notesFirstSeen, [binder.uuidString.lowercased()]).object ?? [:]
            for row in wanted {
                guard let document = try? TeamNoteDocument(note: row.id, saved: row.document, changes: (changesByNote[row.id] ?? []).map(\.change),
                                                           actor: TeamNoteDocument.newActor()) else { continue }
                candidates.append(TeamNoteCopies.Note(id: row.id, binder: row.binderID, folder: row.folderID, title: row.title, text: document.text,
                                                      maker: row.createdBy, createdAt: row.createdAt,
                                                      firstSeen: seen[row.id.uuidString.lowercased()]?.int64))
            }
        }
        var found = TeamNoteCopies.Found()
        for binder in binders {
            let here = TeamNoteCopies.find(candidates.filter { $0.binder == binder }, owner: owners[binder])
            found.copies += here.copies
            found.near += here.near
        }
        // A copy whose copy on this Mac is changing is left for now: what's here may differ from what was compared.
        found.copies.removeAll { copy in
            let waits = engine.database.queued.contains { $0.call.note == copy.note.id }
            let differs = store.note(copy.note.id).map { $0.text != copy.note.text } ?? false
            if waits || differs { result.changing += 1 }
            return waits || differs
        }
        result.found = found
        result.refusal = try await copiesRefusal(binders)
        if result.refusal == nil {
            result.caution = "Before you remove them, make sure no teammate's Mac still syncs the old team folder for these binders (their Settings → Team shows a team folder): a Mac that does could share its copies again."
        }
        return result
    }

    /// Why copies can't go now, when the database (or this Mac) can tell: this Mac still syncs a team folder that has
    /// these binders, or a member hasn't connected to the database yet, so their Mac may still be on the team folder.
    private func copiesRefusal(_ binders: [UUID]) async throws -> String? {
        if let sync = board.controller?.team, sync.isConfigured,
           binders.contains(where: { store.binder($0).map { $0.sharedWithTeam || $0.isTeamCopy } ?? false }) {
            return "This Mac still syncs the team folder these binders came from, which could bring the copies back. Move This Team to a Database… first (Settings → Team), then remove them."
        }
        guard let database = board.database else { throw CopiesProblem.notConnected }
        let waiting = (try await database.json(TeamQueries.membersNotConnected)).array?.compactMap(\.string) ?? []
        guard !waiting.isEmpty else { return nil }
        let names = waiting.formatted(.list(type: .and))
        return "\(names) \(waiting.count == 1 ? "hasn't" : "haven't") connected to the team database yet, so \(waiting.count == 1 ? "their Mac" : "their Macs") may still sync the old team folder and share the copies again. Once \(waiting.count == 1 ? "they've" : "each has") joined (Move This Team to a Database… on a Mac in a team folder), try again."
    }

    /// Removes what `findCopies` found, for everyone: each through the database's own delete, so every Mac follows, and from
    /// this Mac at once. Looks again first, and removes only what it finds then; refused while `refusal` says so. Returns how
    /// many went.
    func removeCopies() async throws -> Int {
        let now = try await findCopies()
        if let refusal = now.refusal { throw CopiesProblem.refused(refusal) }
        guard let engine, let database = board.database else { throw CopiesProblem.notConnected }
        for copy in now.found.copies {
            let id = copy.note.id
            if engine.knows(id) {
                engine.deleted(id)
            } else {
                database.send(.delete(id, from: .notes))
            }
            if let note = store.note(id) {
                NotificationCenter.default.post(name: TeamSyncService.itemsWillBeRemoved, object: self, userInfo: ["ids": Set([id])])
                ScratchpadController.shared.noteWillBeDeleted(note)
                NotePopouts.shared.close(id)
                store.delete(note)
            }
        }
        engine.save()
        store.save()
        return now.found.copies.count
    }
}

extension TeamQueries {
    /// Every change of the notes in $1 (a JSON list of ids), oldest first: their words read whole at once.
    static let notesChanges = """
        SELECT coalesce(json_agg(to_jsonb(c) ORDER BY c.created_at, c.id), '[]')::text FROM binders.note_changes c
        WHERE c.note_id = ANY (ARRAY(SELECT jsonb_array_elements_text($1::jsonb))::uuid[])
        """

    /// Where the feed first had each note of a binder ($1): the number of its first `insert`, by note id (lower case).
    static let notesFirstSeen = """
        SELECT coalesce(json_object_agg(t.row_id, t.seq), '{}')::text FROM (
            SELECT row_id, min(seq) AS seq FROM binders.changes WHERE table_name = 'notes' AND binder_id = $1::uuid AND kind = 'insert' GROUP BY row_id) t
        """

    /// The people in the team who haven't connected yet (their one-time password unchanged), by name.
    static let membersNotConnected = """
        SELECT coalesce(json_agg(name ORDER BY name), '[]')::text FROM binders.members WHERE kind = 'person' AND deleted_at IS NULL AND temporary_password
        """
}
