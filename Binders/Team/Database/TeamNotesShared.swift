import Foundation
import SwiftData
import BindersKit

/// What TeamNotes keeps beside the outbox of the binders' folders and distills: what the database last said of each, so a
/// change made here is told apart from one that came from the team (as DB2's card shadows).
struct TeamNotesFolderState: Codable, Equatable {
    struct Shadow: Codable, Equatable {
        var binder: UUID
        var parent: UUID?
        var name: String
        var position: Double
    }

    struct DistillShadow: Codable, Equatable {
        var print: String
        var items: Set<UUID>
    }

    var shadows: [UUID: Shadow] = [:]
    var distills: [UUID: DistillShadow] = [:]
    /// This Mac's own notes the team has were checked against the database once (lane DB6: what an earlier Binders left
    /// there put right). Nil in what an earlier Binders kept.
    var checkedDatabase: Bool?
    /// This Mac's member id in the team folder it moved from (TeamAuthor.id), for the notes it brought in.
    var movedAs: String?
}

// MARK: - Folders

extension TeamNotes {
    private var stateURL: URL? { board.folder?.appendingPathComponent("notes", isDirectory: true).appendingPathComponent("shared.json") }

    func loadFolders() {
        guard let url = stateURL, let data = try? Data(contentsOf: url), let read = try? JSONDecoder().decode(TeamNotesFolderState.self, from: data) else { return }
        folders = read
    }

    func saveFolders() {
        guard let url = stateURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(folders) { try? data.write(to: url, options: .atomic) }
    }

    /// The shared binders' folders against what the database last said: a new one, or one renamed or moved here, goes
    /// (parents first, so each finds its parent there); one deleted here is deleted for the team, and what it held moves
    /// up there too. A folder that went because its binder left this Mac isn't a deletion.
    func sweepFolders() {
        guard let database = board.database else { return }
        var changed = false
        for binder in board.sharedBinders {
            let all = store.folders(in: binder)
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            func depth(_ folder: FolderRecord) -> Int {
                var depth = 0, current = folder.parentID, seen: Set<UUID> = []
                while let id = current, let parent = byID[id], seen.insert(id).inserted {
                    depth += 1
                    current = parent.parentID
                }
                return depth
            }
            for folder in all.sorted(by: { depth($0) < depth($1) }) {
                let now = TeamNotesFolderState.Shadow(binder: binder, parent: store.shownFolder(folder.parentID, in: binder), name: folder.name,
                                                      position: folder.position)
                guard folders.shadows[folder.id] != now else { continue }
                let fields: [String: TeamJSON] = ["name": .string(folder.name), "parent_id": TeamJSON(now.parent), "position": .number(folder.position)]
                database.send(.putFolder(folder.id, binder: binder, fields: fields))
                folders.shadows[folder.id] = now
                changed = true
            }
        }
        for (id, shadow) in folders.shadows where store.folder(id) == nil {
            folders.shadows[id] = nil
            changed = true
            guard board.covers(shadow.binder), removedFolders.remove(id) == nil else { continue }
            database.send(.deleteFolder(id))
        }
        if changed { saveFolders() }
    }

    /// Folders as the database has them: made here, renamed or moved as the team did (unless changed here since the
    /// database last said, which then goes), or deleted, with what they held moving up to where they were. `whole`: the
    /// binder read whole. A folder this Mac has that the rows don't name stays: only a row saying it was deleted removes
    /// one here.
    func applyFolders(_ rows: [TeamRow], whole binder: UUID? = nil) {
        let list = rows.compactMap(TeamFolderRow.init(row:)).filter { board.covers($0.binderID) }
        guard !list.isEmpty else { return }
        // Every new folder first, then where each goes, as one may be inside another.
        var arrived: [(FolderRecord, TeamFolderRow)] = []
        for row in list where row.deletedAt == nil && store.folder(row.id) == nil {
            let record = FolderRecord(name: FolderTree.cleanName(row.name) ?? "Folder", binderID: row.binderID)
            record.id = row.id
            record.position = row.position
            store.context.insert(record)
            arrived.append((record, row))
        }
        for (record, row) in arrived {
            record.parentID = row.parentID
            folders.shadows[row.id] = .init(binder: row.binderID, parent: row.parentID, name: record.name, position: row.position)
        }
        let arrivedIDs = Set(arrived.map(\.1.id))
        for row in list where !arrivedIDs.contains(row.id) {
            guard let record = store.folder(row.id), record.binderID == row.binderID else { continue }
            // Deleted, and put back here (Undo) since this Mac's deletion went: it goes back to the team, not away again.
            if row.deletedAt != nil, folders.shadows[row.id] == nil { continue }
            if row.deletedAt != nil {
                store.moveUp(from: record.id, to: store.shownFolder(record.parentID, in: record.binderID))
                removedFolders.insert(record.id)
                store.context.delete(record)
                folders.shadows[row.id] = nil
                continue
            }
            let shadow = folders.shadows[row.id]
            let here = TeamNotesFolderState.Shadow(binder: record.binderID, parent: store.shownFolder(record.parentID, in: record.binderID),
                                                   name: record.name, position: record.position)
            let theirs = TeamNotesFolderState.Shadow(binder: row.binderID, parent: row.parentID, name: FolderTree.cleanName(row.name) ?? record.name,
                                                     position: row.position)
            // Changed here since the database last said: this Mac's change goes; else the team's comes.
            if shadow == nil || shadow == here {
                if record.name != theirs.name { record.name = theirs.name }
                if record.position != theirs.position { record.position = theirs.position }
                if record.parentID != theirs.parent,
                   theirs.parent.map({ FolderTree.canMove(record.id, into: $0, in: store.folderNodes(in: record.binderID)) }) ?? true {
                    record.parentID = theirs.parent
                }
            }
            folders.shadows[row.id] = theirs
        }
        saveFolders()
    }
}

// MARK: - Who's in a note

extension TeamNotes {
    /// The note is open here (its page, or a pop-out): the team hears so, and every 45 seconds while it stays open.
    func opened(_ note: UUID) {
        open[note, default: 0] += 1
        guard open[note] == 1 else { return }
        Task { @MainActor [weak self] in await self?.say(in: note) }
    }

    /// The note was closed here: once nothing shows it, the team hears it's been left.
    func closed(_ note: UUID) {
        guard let count = open[note] else { return }
        if count > 1 {
            open[note] = count - 1
            return
        }
        open[note] = nil
        reviewing[note] = nil
        guard shares(note), let database = board.database, board.isConnected else { return }
        Task { _ = try? await database.call(.beInNote(note, here: false)) }
    }

    /// Reviewing one of the note's proposals here (the review sheet is open), or not any more (nil).
    func reviewing(_ note: UUID, distill: UUID?) {
        reviewing[note] = distill
        Task { @MainActor [weak self] in
            guard let self else { return }
            if distill == nil, self.open[note] == nil {
                guard self.shares(note), let database = self.board.database, self.board.isConnected else { return }
                _ = try? await database.call(.beInNote(note, here: false))
            } else {
                await self.say(in: note)
            }
        }
    }

    /// This person is in the note, viewing it or reviewing a proposal: sent at once, never kept waiting.
    func say(in note: UUID) async {
        guard shares(note), let database = board.database, board.isConnected else { return }
        let distill = reviewing[note]
        _ = try? await database.call(.beInNote(note, here: true, kind: distill == nil ? .viewing : .reviewing, distill: distill))
    }

    /// Who's in which note, as rows arrive: this member left out.
    func applyPresence(_ rows: [TeamPresenceRow]) {
        guard !rows.isEmpty else { return }
        let me = directory.me
        for row in rows where row.memberID != me {
            var list = presence[row.noteID] ?? []
            list.removeAll { $0.memberID == row.memberID }
            if row.isHere(lasts: presenceLasts) { list.append(row) }
            presence[row.noteID] = list
        }
    }

    /// The people in the note now, by name.
    func here(_ note: UUID, reviewing distill: UUID? = nil) -> [String] {
        let now = Date()
        return inNote(note).rows.filter { $0.isHere(at: now, lasts: presenceLasts) && (distill == nil || ($0.kind == .reviewing && $0.distillID == distill)) }
            .compactMap { directory.memberName($0.memberID) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// "Dana is in this note", under its title.
    func presenceLine(_ note: UUID) -> String? { TeamPresenceRow.line(here(note)) }

    /// "Dana is reviewing these items", on the Work bar beside the proposal.
    func reviewingLine(_ note: UUID, distill: UUID) -> String? { TeamPresenceRow.reviewingLine(here(note, reviewing: distill)) }
}

// MARK: - Distill's records

extension TeamNotes {
    /// A note's distills written here (DistillStore): those that differ from what the database last said go to it.
    func distillsChanged(_ file: DistillFile) {
        guard !applyingDistills, let engine, let state = engine.state(file.note), !state.deleted, let database = board.database else { return }
        let directory = self.directory
        var changed = false
        for record in file.distills {
            let rows = TeamDistillRows.rows(record, binder: state.binder, teamName: { directory.teamName($0) ?? $0 })
            let print = TeamJSON.object(["distill": .object(rows.distill), "items": .array(rows.items.map { .object($0) })]).text
            let shadow = folders.distills[record.id]
            guard shadow?.print != print else { continue }
            database.send(.put(rows.distill, in: .distills))
            if !rows.items.isEmpty { database.send(.put(rows: rows.items, in: .distillItems)) }
            let now = Set(record.items.map(\.id))
            for gone in (shadow?.items ?? []).subtracting(now) { database.send(.delete(gone, from: .distillItems)) }
            folders.distills[record.id] = .init(print: print, items: now)
            changed = true
        }
        if changed { saveFolders() }
    }

    /// A note just shared: its distills go with it.
    func sendDistills(of note: UUID) {
        distillsChanged(DistillStore.shared.file(for: note))
    }

    /// Distills and their items as the database has them, into each note's file here, with names as this Mac has them.
    func applyDistills(distills: [TeamRow], items: [TeamRow]) {
        guard !distills.isEmpty || !items.isEmpty else { return }
        let directory = self.directory
        func local(_ name: String) -> String { directory.localName(name) ?? name }
        func team(_ name: String) -> String { directory.teamName(name) ?? name }
        var byDistill = Dictionary(grouping: items, by: { $0["distill_id"]?.uuid ?? UUID() })
        var rowsByID = Dictionary(distills.compactMap { row in row.rowID.map { ($0, row) } }, uniquingKeysWith: { _, last in last })
        // Items whose distill didn't change: the distill as this Mac has it, for the rest of its fields.
        for distill in byDistill.keys where rowsByID[distill] == nil {
            guard let note = noteOf(distill: distill), let record = DistillStore.shared.distill(distill, of: note),
                  let state = engine?.state(note) else { continue }
            let rows = TeamDistillRows.rows(record, binder: state.binder, teamName: team)
            rowsByID[distill] = rows.distill
            let incoming = Set((byDistill[distill] ?? []).compactMap(\.rowID))
            byDistill[distill] = rows.items.filter { !incoming.contains($0.rowID ?? UUID()) } + (byDistill[distill] ?? [])
        }
        applyingDistills = true
        defer { applyingDistills = false }
        for (id, row) in rowsByID {
            guard let note = row["note_id"]?.uuid, engine?.knows(note) == true else { continue }
            if row.deletedAt != nil {
                DistillStore.shared.update(note) { $0.distills.removeAll { $0.id == id } }
                folders.distills[id] = nil
                continue
            }
            // Items the database has that this batch didn't bring stay as this Mac has them.
            let known = DistillStore.shared.distill(id, of: note)
            var itemRows = byDistill[id] ?? []
            if let known, let state = engine?.state(note) {
                let incoming = Set(itemRows.compactMap(\.rowID))
                itemRows += TeamDistillRows.rows(known, binder: state.binder, teamName: team).items.filter { !incoming.contains($0.rowID ?? UUID()) }
            }
            guard let record = TeamDistillRows.record(row, items: itemRows, localName: local), let state = engine?.state(note) else { continue }
            let rows = TeamDistillRows.rows(record, binder: state.binder, teamName: team)
            folders.distills[id] = .init(print: TeamJSON.object(["distill": .object(rows.distill), "items": .array(rows.items.map { .object($0) })]).text,
                                         items: Set(record.items.map(\.id)))
            DistillStore.shared.update(note) { file in
                if let index = file.distills.firstIndex(where: { $0.id == id }) { file.distills[index] = record } else { file.distills.append(record) }
            }
        }
        saveFolders()
    }

    /// The note a distill this Mac has belongs to.
    private func noteOf(distill: UUID) -> UUID? {
        guard let engine else { return nil }
        return engine.states.keys.first { DistillStore.shared.distill(distill, of: $0) != nil }
    }
}

// MARK: - History

extension TeamNotes {
    /// One of a shared note's versions as the History sheet and MCP show it: the version, its text, the text before it,
    /// who made it, and the distills that read it.
    struct Version: Identifiable, Equatable {
        let row: TeamNoteVersionRow
        let text: String
        let before: String
        let by: NoteAuthor
        let distills: [UUID]
        var id: UUID { row.id }
        var at: Date { row.endedAt ?? row.startedAt ?? Date(timeIntervalSince1970: 0) }
    }

    /// What a distill keeps as the version it read of a shared note: the document's heads then ("heads:" and their
    /// hashes), so the words it read can always be read again exactly.
    static let headsPrefix = "heads:"

    /// Whether this note's history is the team's.
    func keepsHistory(of note: NoteItem) -> Bool { covers(note) && shares(note.id) }

    /// The team's versions of a shared note, newest first, each with its text: read from the database first when this Mac
    /// hasn't kept them (after a restart).
    func versions(of note: NoteItem) async -> [Version] {
        guard let engine, shares(note.id) else { return [] }
        if engine.history(note.id).isEmpty { await engine.readVersions(note.id) }
        _ = await engine.document(note.id)
        return versionsHere(of: note)
    }

    /// The same, from what this Mac has.
    func versionsHere(of note: NoteItem) -> [Version] {
        guard let engine else { return [] }
        let distills = DistillStore.shared.file(for: note.id).distills
        return engine.history(note.id).compactMap { row in
            guard let text = engine.text(of: row) else { return nil }
            let read = distills.filter { record in
                row.distillID == record.id || record.version == row.id.uuidString
                    || (row.lastHash.map { record.version == Self.headsPrefix + $0 } ?? false)
            }.map(\.id)
            return Version(row: row, text: text, before: engine.text(before: row) ?? "", by: author(member: row.memberID, agent: row.agentID),
                           distills: read)
        }
    }

    /// History's list for a shared note, as NoteHistory.entries gives it: the note as it is now on top, then every version,
    /// newest first, with its numbers worked out from the document.
    func entries(of note: NoteItem) -> [NoteVersions.Entry] {
        let versions = versionsHere(of: note)
        var list: [NoteVersions.Entry] = []
        if let latest = versions.first {
            let change = TeamNoteStats.between(latest.text, note.text)
            list.append(NoteVersions.Entry(id: NoteVersions.nowID, at: Date(), by: latest.by, added: change.added, removed: change.removed,
                                           sections: change.sections))
        }
        for version in versions {
            let change = TeamNoteStats.between(version.before, version.text)
            list.append(NoteVersions.Entry(id: version.id.uuidString, at: version.at, by: version.by, name: version.row.name, added: change.added,
                                           removed: change.removed, sections: change.sections, distills: version.distills,
                                           restoredFrom: version.row.restoredFrom?.uuidString))
        }
        return list
    }

    /// A version's text by its id (a team version's, or the heads a distill read); nil for one that isn't the team's.
    func text(of version: String, note: NoteItem) -> String? {
        guard let engine, shares(note.id), let document = engine.documentHere(note.id) else { return nil }
        if version.hasPrefix(Self.headsPrefix) {
            let heads = version.dropFirst(Self.headsPrefix.count).split(separator: ",").map(String.init)
            return try? document.text(at: heads)
        }
        guard let id = UUID(uuidString: version), let row = engine.history(note.id).first(where: { $0.id == id }) else { return nil }
        return engine.text(of: row)
    }

    /// Puts a version back: the note's text becomes that version's, as a change by you that starts a version of its own
    /// saying so. Nothing in the history is taken away. False for a version that isn't the team's.
    @discardableResult
    func restore(_ version: String, to note: NoteItem) -> Bool {
        guard let engine, covers(note), let id = UUID(uuidString: version), let row = engine.history(note.id).first(where: { $0.id == id }),
              let text = engine.text(of: row) else { return false }
        MarkdownEditor.flushAll()
        capture(note, by: .person)
        NoteHistory.willChange(note, to: text, always: true, by: .you)
        note.text = text
        note.updatedAt = Date()
        engine.edited(note.id, text: note.text, props: teamProps(of: note), by: .person, restores: id)
        store.save()
        revision += 1
        if note.distill { DistillService.shared?.noteChanged(note.id, by: .you) }
        return true
    }

    /// Gives a version a name ("Approved"), or takes it away. False for a version that isn't the team's.
    @discardableResult
    func name(_ version: String, of note: NoteItem, _ name: String) -> Bool {
        guard let id = UUID(uuidString: version), engine?.history(note.id).contains(where: { $0.id == id }) == true else { return false }
        board.database?.send(.nameNoteVersion(id, name: name))
        engine?.renamed(id, of: note.id, to: name)
        revision += 1
        return true
    }

    /// The version a distill reads now: what's typed here goes first, then the document's heads are kept as the version it
    /// read, and the database marks the version they're in. Nil for a note that isn't the team's.
    func markRead(_ note: NoteItem, by distill: UUID) -> String? {
        guard let engine, keepsHistory(of: note), let document = engine.documentHere(note.id) else { return nil }
        MarkdownEditor.flushAll()
        capture(note, by: .person)
        let heads = document.heads
        guard let head = heads.first else { return nil }
        board.database?.send(.markNoteVersion(note.id, version: nil, hash: head, distill: distill))
        return Self.headsPrefix + heads.joined(separator: ",")
    }

    /// A version kept earlier (the one an agent was given to read) marked with the distill that read it. False for one
    /// that isn't the team's.
    @discardableResult
    func markVersion(_ version: String, of note: NoteItem, by distill: UUID) -> Bool {
        guard keepsHistory(of: note), version.hasPrefix(Self.headsPrefix),
              let head = version.dropFirst(Self.headsPrefix.count).split(separator: ",").first else { return false }
        board.database?.send(.markNoteVersion(note.id, version: nil, hash: String(head), distill: distill))
        return true
    }
}
