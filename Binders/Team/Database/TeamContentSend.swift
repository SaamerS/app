import Foundation
import SwiftData
import BindersKit

/// This Mac's meetings, captures and to-dos to the team database (lane DB4): a pass a moment after each save sends what
/// differs from what was last sent, for the binders shared through it, and takes off the team what left them.
extension TeamContent {
    /// One pass: the items saved since the last (everything, after a restart or a binder shared), each sent as it is now.
    func pass() {
        guard let database, team.server != nil else { return }
        let ids: Set<UUID>
        if sweep {
            sweep = false
            dirty = []
            ids = everything()
        } else {
            ids = dirty
            dirty = []
        }
        guard !ids.isEmpty else { return }
        let context = store.context
        let wanted = Array(ids)
        let meetings = Dictionary(((try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { wanted.contains($0.id) }))) ?? [])
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let todos = Dictionary(((try? context.fetch(FetchDescriptor<CommitmentRecord>(predicate: #Predicate { wanted.contains($0.id) }))) ?? [])
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let meeting = meetings[id] {
                changed = send(meeting: meeting, database: database) || changed
            } else if let todo = todos[id] {
                changed = send(todo: todo, database: database) || changed
            } else if state.meetings[id] != nil || state.captures[id] != nil {
                changed = gone(item: id, database: database) || changed
            } else if state.todos[id] != nil {
                changed = gone(todo: id, database: database) || changed
            }
        }
        if changed { saveState() }
    }

    /// Every item that might go or might have to leave: this member's meetings, captures and to-dos in the shared binders,
    /// and everything sent before.
    private func everything() -> Set<UUID> {
        let shared = Array(team.sharedBinders)
        let context = store.context
        var ids = Set(state.meetings.keys).union(state.captures.keys).union(state.todos.keys)
        guard !shared.isEmpty else { return ids }
        let meetings = (try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID != nil && !$0.isTeamCopy }))) ?? []
        ids.formUnion(meetings.filter { $0.binderID.map(shared.contains) == true }.map(\.id))
        let todos = (try? context.fetch(FetchDescriptor<CommitmentRecord>(predicate: #Predicate { $0.binderID != nil }))) ?? []
        ids.formUnion(todos.filter { $0.binderID.map(shared.contains) == true }.map(\.id))
        return ids
    }

    // MARK: Meetings and captures

    /// One of this member's meetings or captures: its row when it changed, then its transcript (while connected); taken
    /// off the team when it left the shared binders; moved with its transcript when it went to another shared binder.
    @discardableResult
    func send(meeting record: MeetingRecord, database: TeamDatabase) -> Bool {
        guard !record.isTeamCopy else { return false }
        let id = record.id
        let capture = record.isConversation
        let table: TeamTable = capture ? .captures : .meetings
        var sent = capture ? state.captures[id] : state.meetings[id]
        let inShared = team.covers(record.binderID)
        // A capture you moved out of the shared binders isn't shared any more: moved back in by you, it is again.
        if capture, !inShared { state.shared.remove(id) }
        let goes = inShared && (!capture || state.shared.contains(id))
        guard goes, let binder = record.binderID else {
            guard let current = sent, !current.withdrawn else { return false }
            send(.withdrawItem(id, from: table), database: database)
            sent = withdrawn(current)
            store(sent, for: id, capture: capture)
            transcripts[id] = nil
            return true
        }
        // A capture goes once it's written up (kept, or hidden as small talk); one being written again keeps what went.
        if capture, !["ready", "trivial", "failed"].contains(record.status) {
            return false
        }
        var item = sent ?? TeamContentState.Sent(binder: binder)
        var changed = sent == nil
        // To another shared binder: the database moves it with its transcript and index.
        if let current = sent, !current.withdrawn, current.binder != binder {
            send(.moveItem(id, in: table, to: binder), database: database)
            changed = true
        }
        item.binder = binder
        // Nothing sent yet in this revision: no line of it is known as sent.
        if item.withdrawn || item.digest == nil { transcripts[id] = [:] }
        // Its transcript decides the revision the row says is current.
        let lines = store.segments(for: id)
        var plan = TeamTranscript.plan(local: lines, sent: transcripts[id], sentDigest: item.withdrawn ? nil : item.digest)
        if case .revise(let all) = plan {
            item.revision += 1
            item.count = 0
            item.digest = nil
            transcripts[id] = [:]
            plan = all.isEmpty ? .nothing : .append(all)
        }
        let values = Self.values(of: record, binder: binder, revision: item.revision, capture: capture)
        let print = values.fingerprint(capture: capture)
        if print != item.fingerprint || item.withdrawn {
            send(.putItem(values.row(capture: capture), in: table), database: database)
            item.fingerprint = print
            item.withdrawn = false
            changed = true
        }
        // Lines go only while connected: what's written offline goes in one batch once it's back, rather than filling
        // the outbox a few lines at a time. And only while the outbox has room: a binder shared with many transcripts in
        // it sends them a few at a time, as the outbox empties.
        if case .append = plan, team.isConnected, database.waiting >= Self.outboxRoom {
            linesWaiting.insert(id)
        } else if case .append(let new) = plan, team.isConnected {
            let rows = TeamTranscript.rows(new, item: id, binder: binder, revision: item.revision, after: item.count, capture: capture)
            for start in stride(from: 0, to: rows.count, by: 400) {
                send(.put(rows: Array(rows[start..<min(start + 400, rows.count)]), in: capture ? .captureSegments : .meetingSegments),
                     database: database)
            }
            var known = transcripts[id] ?? [:]
            for line in new { known[line.id] = TeamTranscript.fingerprint(line) }
            transcripts[id] = known
            item.count += new.count
            item.digest = TeamTranscript.digest(lines)
            changed = true
        }
        if changed || sent != item { store(item, for: id, capture: capture) }
        return changed
    }

    /// A meeting or capture of this member's that's gone from this Mac: taken off the team.
    private func gone(item id: UUID, database: TeamDatabase) -> Bool {
        let capture = state.captures[id] != nil
        guard let current = capture ? state.captures[id] : state.meetings[id], !current.withdrawn else {
            state.shared.remove(id)
            return false
        }
        send(.withdrawItem(id, from: capture ? .captures : .meetings), database: database)
        store(withdrawn(current), for: id, capture: capture)
        state.shared.remove(id)
        transcripts[id] = nil
        return true
    }

    /// Taken off the team (or no longer the team's to update): what goes back later goes as a new revision, as its lines
    /// there were erased, or may have been.
    func withdrawn(_ sent: TeamContentState.Sent) -> TeamContentState.Sent {
        var item = sent
        item.withdrawn = true
        item.revision += 1
        item.count = 0
        item.digest = nil
        item.fingerprint = ""
        return item
    }

    private func store(_ sent: TeamContentState.Sent?, for id: UUID, capture: Bool) {
        if capture { state.captures[id] = sent } else { state.meetings[id] = sent }
    }

    /// What the team sees of a meeting or capture: a fixed list of its fields (TeamMeetingValues), never its audio.
    static func values(of record: MeetingRecord, binder: UUID, revision: Int, capture: Bool) -> TeamMeetingValues {
        TeamMeetingValues(id: record.id, binder: binder, title: record.title, started: record.createdAt, ended: record.endedAt,
                          duration: record.duration, app: record.appName, attendees: capture ? [] : record.attendees,
                          templateID: capture ? nil : record.templateID, summary: record.summary, notes: record.userNotes,
                          speakerNames: record.speakerNames, status: record.status, revision: revision,
                          folder: Store.shared.shownFolder(record.folderID, in: binder))
    }

    // MARK: To-dos

    /// A to-do: one of yours in a shared binder goes as it is when it changed (not one said to yourself, which stays here);
    /// a teammate's sends only a tick, a reopening or a dismissal made here.
    @discardableResult
    func send(todo record: CommitmentRecord, database: TeamDatabase) -> Bool {
        let id = record.id
        let last = state.todos[id]
        if record.teamAuthorID != nil {
            guard let last, !last.withdrawn, last.status != record.status || !TeamBoard.same(last.doneAt, record.doneAt) else { return false }
            let values = TeamTodoValues(id: id, binder: last.binder, text: record.task, status: record.status, doneAt: record.doneAt)
            send(.put(values.statusRow(), in: .todos), database: database)
            state.todos[id]?.status = record.status
            state.todos[id]?.doneAt = record.doneAt
            return true
        }
        guard let binder = record.binderID, team.covers(binder), !Self.saidToYourself(record), let me = directory.myName else {
            guard let last, last.mine, !last.withdrawn else { return false }
            send(.withdrawItem(id, from: .todos), database: database)
            state.todos[id]?.withdrawn = true
            return true
        }
        let values = todoValues(record, binder: binder, me: me)
        let row = TeamJSON.object(values.row()).text
        guard last?.row != row || last?.withdrawn == true || last?.mine != true else { return false }
        send(.putItem(values.row(), in: .todos), database: database)
        state.todos[id] = TeamContentState.Todo(binder: binder, status: record.status, doneAt: record.doneAt, row: row, mine: true)
        return true
    }

    /// What the team sees of one of your to-dos: its words, kind, whose promise ("You" as your name), to whom, when due,
    /// where it stands, where it came from in your words, its origin, who added it, and its card. Never its message.
    func todoValues(_ record: CommitmentRecord, binder: UUID, me: String) -> TeamTodoValues {
        TeamTodoValues(id: record.id, binder: binder, text: record.task, kind: record.kind,
                       owner: TeamTodoValues.owner(sending: record.owner, maker: me), to: record.to, due: record.dueAt,
                       dueText: record.dueText, status: record.status, doneAt: record.doneAt, origin: record.origin,
                       madeBy: record.madeBy, source: record.sourceTitle, card: card(of: record.id))
    }

    /// A to-do gone from this Mac: one of yours is taken off the team; a teammate's isn't this Mac's to take away.
    private func gone(todo id: UUID, database: TeamDatabase) -> Bool {
        guard let last = state.todos[id] else { return false }
        if last.mine, !last.withdrawn {
            send(.withdrawItem(id, from: .todos), database: database)
            state.todos[id]?.withdrawn = true
            return true
        }
        state.todos[id] = nil
        return true
    }

    /// Said to yourself, near your iPhone or Mac: it stays on this Mac, as a note made from what you said does.
    static func saidToYourself(_ todo: CommitmentRecord) -> Bool {
        TodoOrigin.isSaidToYourself(origin: todo.origin, source: nil) || Store.shared.isMoment(todo.id)
    }

    /// The card a to-do is on, on any board here.
    private func card(of todo: UUID) -> UUID? {
        let key: String? = todo.uuidString
        var descriptor = FetchDescriptor<TaskCard>(predicate: #Predicate { $0.sourceRef == key })
        descriptor.fetchLimit = 1
        return (try? store.context.fetch(descriptor))?.first?.id
    }

    // MARK: Sending

    /// How many changes may wait in the outbox before a transcript's lines wait for them to go.
    static let outboxRoom = 10

    /// A change to the outbox, noted as the team board notes its own.
    func send(_ call: TeamCall, database: TeamDatabase) {
        database.send(call)
        team.noteSent(call.operation)
    }

    /// An outbox answer for one of this lane's changes: a transcript's lines that didn't go make the next pass send it
    /// whole as a new revision; a row that didn't go is sent again at the next look.
    func settled(_ outcome: TeamOutboxOutcome) {
        // Transcripts that waited for room in the outbox go once there's some.
        if !linesWaiting.isEmpty, (database?.waiting ?? 0) < Self.outboxRoom / 2 {
            dirty.formUnion(linesWaiting)
            linesWaiting = []
            passSoon(after: liveDelay)
        }
        if let (table, id) = outcome.call.item, outcome.call.function != "withdraw_item" {
            switch outcome.outcome {
            case .applied:
                break
            case .refused(let refusal):
                Log.app.error("Team content: \(outcome.call.function, privacy: .public) refused: \(refusal.message, privacy: .public)")
                redo(table, id)
            case .failed(let message):
                Log.app.error("Team content: \(outcome.call.function, privacy: .public) failed: \(message, privacy: .public)")
                redo(table, id)
            }
        }
        knowledge.outboxSettled()
    }

    private func redo(_ table: TeamTable, _ id: UUID) {
        switch table {
        case .meetings, .captures, .meetingSegments, .captureSegments:
            let capture = table == .captures || table == .captureSegments
            guard var item = capture ? state.captures[id] : state.meetings[id] else { return }
            if table == .meetingSegments || table == .captureSegments {
                item.revision += 1
                item.count = 0
                item.digest = nil
                transcripts[id] = [:]
            }
            item.fingerprint = ""
            store(item, for: id, capture: capture)
        case .todos:
            state.todos[id]?.row = ""
        default:
            return
        }
        saveState()
        dirty.insert(id)
        passSoon(after: .seconds(5))
    }
}
