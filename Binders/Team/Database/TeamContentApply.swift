import Foundation
import SwiftData
import BindersKit

/// Teammates' meetings, captures and to-dos into this Mac's copy (lane DB4). A teammate's meeting or capture is a
/// read-only copy (`isTeamCopy`, named by its maker), its transcript the current revision's lines; a teammate's to-do is
/// theirs (`teamAuthorID`), which you may tick. This member's own items coming back are as this Mac sent them, and only a
/// tick, a reopening or a dismissal by someone else lands on a to-do of yours. Rows are current versions, so an update
/// that comes again changes nothing.
extension TeamContent {
    // MARK: Updates from the feed

    /// One update, after TeamBoard's own: meetings and captures, then their lines, then to-dos, then what's gone; then the
    /// knowledge. Binders newly shared are read whole instead (readWhole).
    func apply(_ update: TeamUpdate, from database: TeamDatabase) async {
        let added = update.bindersAdded
        func inAdded(_ row: TeamRow) -> Bool { row["binder_id"]?.uuid.map(added.contains) ?? false }
        var changed = false
        for row in update.rows[.meetings] ?? [] where !inAdded(row) { changed = take(item: row, capture: false) || changed }
        for row in update.rows[.captures] ?? [] where !inAdded(row) { changed = take(item: row, capture: true) || changed }
        changed = await take(lines: (update.rows[.meetingSegments] ?? []).filter { !inAdded($0) }, capture: false, database: database) || changed
        changed = await take(lines: (update.rows[.captureSegments] ?? []).filter { !inAdded($0) }, capture: true, database: database) || changed
        for row in update.rows[.todos] ?? [] where !inAdded(row) { changed = take(todo: row) || changed }
        for gone in update.gone {
            switch gone.table {
            case .meetings, .captures: changed = dropCopy(gone.id) || changed
            case .todos: changed = dropTodo(gone.id) || changed
            default: continue
            }
        }
        if changed {
            store.save()
            saveState()
        }
        await knowledge.apply(update)
    }

    /// A binder read whole, newly shared with this Mac (or read again after the feed was pruned past it): teammates'
    /// meetings, captures and to-dos in it as the database has them now, and copies of ones it no longer has dropped.
    func readWhole(_ binder: UUID, rows: [TeamTable: [TeamRow]]) async {
        var alive = Set<UUID>()
        for (table, capture) in [(TeamTable.meetings, false), (.captures, true)] {
            for row in rows[table] ?? [] {
                take(item: row, capture: capture)
                if row.deletedAt == nil, let id = row.rowID { alive.insert(id) }
            }
        }
        // Each copy's lines: exactly its current revision's.
        for (table, capture) in [(TeamTable.meetingSegments, false), (.captureSegments, true)] {
            let lines = (rows[table] ?? []).compactMap { TeamTranscript.line($0, capture: capture) }
            for (item, all) in Dictionary(grouping: lines, by: \.item) {
                guard let record = meeting(item), record.isTeamCopy, let revision = state.received[item] else { continue }
                let current = all.filter { $0.revision == revision }.sorted { $0.position < $1.position }.map(\.segment)
                if Set(current.map(\.id)) != Set(store.segments(for: item).map(\.id)) { store.replaceSegments(for: item, with: current) }
            }
        }
        let binderID: UUID? = binder
        let copies = (try? store.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID && $0.isTeamCopy }))) ?? []
        for copy in copies where !alive.contains(copy.id) { _ = dropCopy(copy.id) }
        var todosAlive = Set<UUID>()
        for row in rows[.todos] ?? [] {
            take(todo: row)
            if row.deletedAt == nil, let id = row.rowID { todosAlive.insert(id) }
        }
        for todo in store.commitments() where todo.binderID == binder && todo.teamAuthorID != nil && !todosAlive.contains(todo.id) {
            _ = dropTodo(todo.id)
        }
        store.save()
        saveState()
        await knowledge.readWhole(binder, rows: rows)
    }

    /// The team lost a binder for this Mac: teammates' meetings, captures and to-dos in it go from here (before the board
    /// moves what's left to General); this Mac's own stay, and are no longer the team's to update.
    func binderGone(_ binder: UUID) {
        let binderID: UUID? = binder
        let copies = (try? store.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID && $0.isTeamCopy }))) ?? []
        for copy in copies { _ = dropCopy(copy.id) }
        for todo in store.commitments() where todo.binderID == binder && todo.teamAuthorID != nil { _ = dropTodo(todo.id) }
        for (id, sent) in state.meetings where sent.binder == binder { state.meetings[id] = withdrawn(sent) }
        for (id, sent) in state.captures where sent.binder == binder { state.captures[id] = withdrawn(sent) }
        for (id, todo) in state.todos where todo.binder == binder { state.todos[id] = todo.mine ? Self.forgotten(todo) : nil }
        store.save()
        saveState()
        knowledge.binderGone(binder)
    }

    /// One of yours in a binder the team lost: what this Mac does next with it isn't the team's.
    private static func forgotten(_ todo: TeamContentState.Todo) -> TeamContentState.Todo {
        var forgotten = todo
        forgotten.withdrawn = true
        forgotten.row = ""
        return forgotten
    }

    // MARK: Meetings and captures

    func meeting(_ id: UUID) -> MeetingRecord? {
        var descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? store.context.fetch(descriptor))?.first
    }

    /// A teammate's meeting or capture: a read-only copy here, named by its maker, its "You" theirs. A new transcript
    /// revision clears the lines here, for the new revision's. True when something changed here.
    @discardableResult
    func take(item row: TeamRow, capture: Bool) -> Bool {
        guard let values = TeamMeetingValues(row: row, capture: capture) else { return false }
        let id = values.id
        if let me = directory.me, values.maker == me { return false }
        let existing = meeting(id)
        // One of this Mac's own, whatever the row says, is never written over.
        if let existing, !existing.isTeamCopy { return false }
        if values.deleted {
            state.received[id] = nil
            guard let existing else { return false }
            store.deleteMeeting(existing)
            return true
        }
        guard team.covers(values.binder) else { return false }
        let maker = directory.memberName(values.maker) ?? "A teammate"
        let record: MeetingRecord
        if let existing {
            record = existing
        } else {
            record = MeetingRecord(title: values.title, appName: values.app, templateID: values.templateID ?? (capture ? MeetingTemplate.conversation.id : ""))
            record.id = id
            record.isTeamCopy = true
            store.context.insert(record)
        }
        var changed = existing == nil
        func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<MeetingRecord, Value>, _ value: Value) {
            if record[keyPath: keyPath] != value {
                record[keyPath: keyPath] = value
                changed = true
            }
        }
        set(\.kind, capture ? MeetingRecord.conversationKind : "meeting")
        set(\.isTeamCopy, true)
        set(\.title, values.title)
        set(\.binderID, values.binder)
        set(\.folderID, store.shownFolder(values.folder, in: values.binder))
        set(\.createdAt, values.started)
        set(\.endedAt, values.ended)
        // While it's recorded its length grows with its lines here (its maker's Mac knows it only at the end).
        if !values.isLive || values.duration > 0 { set(\.duration, values.duration) }
        set(\.appName, values.app)
        set(\.attendees, values.attendees)
        if let template = values.templateID { set(\.templateID, template) }
        set(\.summary, values.summary)
        set(\.userNotes, values.notes)
        let names = TeamSpeakers.shown(values.speakerNames, maker: maker)
        if record.speakerNames != names {
            record.speakerNames = names
            changed = true
        }
        set(\.status, values.status)
        set(\.teamAuthorID, values.maker?.uuidString)
        set(\.teamAuthorName, maker)
        set(\.sharedWithTeam, false)
        if record.errorMessage != nil { set(\.errorMessage, nil) }
        // A new revision clears the lines here for its own. A copy whose revision this Mac never knew keeps its lines.
        if state.received[id] != values.revision {
            if let known = state.received[id], known != values.revision, !store.segments(for: id).isEmpty {
                store.replaceSegments(for: id, with: [])
            }
            state.received[id] = values.revision
            changed = true
        }
        return changed
    }

    /// Lines of teammates' transcripts: those of each copy's current revision that aren't here yet, added in one save
    /// per copy. Lines of an item whose row hasn't come yet bring its row first.
    func take(lines rows: [TeamRow], capture: Bool, database: TeamDatabase) async -> Bool {
        let read = rows.compactMap { TeamTranscript.line($0, capture: capture) }
        guard !read.isEmpty else { return false }
        var changed = false
        for (item, lines) in Dictionary(grouping: read, by: \.item) {
            if meeting(item) == nil, let found = try? await database.rows(capture ? .captures : .meetings, ids: [item]) {
                for row in found { changed = take(item: row, capture: capture) || changed }
            }
            guard let record = meeting(item), record.isTeamCopy, let revision = state.received[item] else { continue }
            let have = Set(store.segments(for: item).map(\.id))
            let new = lines.filter { $0.revision == revision && !have.contains($0.segment.id) }.sorted { $0.position < $1.position }.map(\.segment)
            guard !new.isEmpty else { continue }
            store.appendSegments(new, to: item)
            if record.status == "recording", let end = new.map(\.end).max(), end > record.duration { record.duration = end }
            changed = true
        }
        return changed
    }

    /// A teammate's meeting or capture gone from the team (or from what this member sees): its copy goes.
    func dropCopy(_ id: UUID) -> Bool {
        state.received[id] = nil
        guard let record = meeting(id), record.isTeamCopy else { return false }
        store.deleteMeeting(record)
        return true
    }

    // MARK: To-dos

    func todo(_ id: UUID) -> CommitmentRecord? {
        var descriptor = FetchDescriptor<CommitmentRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? store.context.fetch(descriptor))?.first
    }

    /// A to-do's row: a teammate's is theirs here (its words, whose, due, where it stands); one of yours takes a tick,
    /// reopening or dismissal made elsewhere, unless it was changed here since the team last said.
    @discardableResult
    func take(todo row: TeamRow) -> Bool {
        guard let values = TeamTodoValues(row: row) else { return false }
        let id = values.id
        let local = todo(id)
        if let me = directory.me, values.maker == me {
            guard let local, let last = state.todos[id], last.mine else { return false }
            if values.deleted {
                // Taken off the team by someone else while it's still in a shared binder here: the next pass shares it again.
                if !last.withdrawn {
                    state.todos[id]?.row = ""
                    dirty.insert(id)
                    passSoon(after: editDelay)
                }
                return false
            }
            // Its words, whose it is and when it's due are yours: changed in the database by someone else, sent again.
            if let sent = TeamJSON(text: last.row)?.object.flatMap(TeamTodoValues.init(row:)) {
                var theirs = values
                theirs.status = sent.status
                theirs.doneAt = sent.doneAt
                if !theirs.same(as: sent) {
                    state.todos[id]?.row = ""
                    dirty.insert(id)
                    passSoon(after: editDelay)
                }
            }
            guard values.status != last.status || !TeamBoard.same(values.doneAt, last.doneAt) else { return false }
            if local.status == last.status { setStatus(local, values.status, doneAt: values.doneAt) }
            state.todos[id]?.status = values.status
            state.todos[id]?.doneAt = values.doneAt
            if let binder = local.binderID, let me = directory.myName {
                state.todos[id]?.row = TeamJSON.object(todoValues(local, binder: binder, me: me).row()).text
            }
            return true
        }
        if values.deleted {
            state.todos[id] = nil
            guard let local, local.teamAuthorID != nil else { return false }
            store.delete(local)
            return true
        }
        guard team.covers(values.binder) else { return false }
        if let local, local.teamAuthorID == nil { return false }
        let maker = directory.memberName(values.maker) ?? "A teammate"
        let record: CommitmentRecord
        if let local {
            record = local
        } else {
            record = CommitmentRecord(task: values.text, kind: values.kind, owner: maker)
            record.id = id
            store.context.insert(record)
        }
        let changedHere = local != nil && state.todos[id].map { $0.status != record.status } == true
        record.task = values.text
        record.kind = values.kind
        record.owner = TeamTodoValues.owner(received: values.owner, me: directory.myName, maker: maker)
        record.to = values.to
        record.dueAt = values.due
        record.dueText = values.dueText
        record.binderID = values.binder
        record.origin = values.origin
        record.madeBy = values.madeBy
        record.teamAuthorID = values.maker?.uuidString ?? ""
        record.teamAuthorName = maker
        record.teamSource = values.source
        if !changedHere {
            record.status = values.status
            record.doneAt = values.doneAt
        }
        // A reminder only for a promise that's yours: a teammate's own promises don't ring here.
        if record.owner != BoardActor.you.name { record.reminderScheduled = true }
        state.todos[id] = TeamContentState.Todo(binder: values.binder, status: values.status, doneAt: values.doneAt, mine: false)
        return true
    }

    /// A teammate's to-do gone from the team (or from what this member sees): it goes from here. One of yours stays.
    func dropTodo(_ id: UUID) -> Bool {
        guard let local = todo(id), local.teamAuthorID != nil else {
            if state.todos[id]?.mine == false { state.todos[id] = nil }
            return false
        }
        state.todos[id] = nil
        store.delete(local)
        return true
    }

    /// A to-do's status as someone else set it, with its reminder kept as CommitmentService keeps it.
    private func setStatus(_ todo: CommitmentRecord, _ status: String, doneAt: Date?) {
        if let commitments = team.controller?.commitments {
            commitments.setStatus(todo, status)
        } else {
            todo.status = status
        }
        todo.doneAt = status == "done" ? (doneAt ?? todo.doneAt ?? Date()) : nil
    }
}
