import Foundation
import SwiftData
import BindersKit

/// Moving a folder team over to a team database (lane DB3; Settings → Team → Move This Team to a Database…). From this
/// Mac's copy of the team folder, just synced: every binder the folder shares (this Mac's and teammates'), their folders,
/// notes (with who wrote them, agents' marks, and Distill's records) and meetings (with their transcripts, never audio),
/// each brought in once, with operation ids made from its Binders id and this member. Something another Mac brought in
/// first isn't made twice: a note gets what changed in the folder since it was brought in, merged from that version; a
/// meeting changes only for its author. Then the caller stops folder sync, leaving the folder as it is.
///
/// Written against a store, a database client and a note engine, so the app (TeamNotes) and a teammate's Mac in the
/// self-tests run the same code.
@MainActor
struct TeamMove {
    struct Summary: Equatable {
        var binders = 0
        var folders = 0
        var notes = 0
        var merged = 0
        var meetings = 0

        /// "Brought in 3 binders, 2 folders, 14 notes and 5 meetings."
        var line: String {
            func count(_ number: Int, _ one: String, _ many: String) -> String { "\(number) \(number == 1 ? one : many)" }
            var parts = [count(binders, "binder", "binders"), count(folders, "folder", "folders"), count(notes, "note", "notes"),
                         count(meetings, "meeting", "meetings")]
            let last = parts.removeLast()
            let merges = merged > 0 ? " \(count(merged, "note", "notes")) the database already had took what changed in the folder since." : ""
            return "Brought in \(parts.joined(separator: ", ")) and \(last).\(merges)"
        }
    }

    let store: Store
    let database: TeamDatabase
    let engine: TeamNoteEngine
    /// Who's who in the team database, for the folder's authors.
    let directory: TeamDirectory
    /// This Mac in the team folder.
    let me: TeamAuthor
    /// This Mac's member in the database.
    let member: UUID
    /// The database's key on this Mac (BinderRecord.teamDatabaseKey).
    let key: String
    /// An agent's name as the team names it (the agents' marks on notes).
    var teamName: (String) -> String = { $0 }
    /// A binder made here goes as DB2's Share does, its board with it; nil: as an import, without its board.
    var shareBoard: ((BinderRecord) -> Void)?
    /// A note goes to the team (TeamNotes.share, which sends its distills too); nil: straight through the engine.
    var shareNote: ((NoteItem, [String: TeamJSON], UUID) -> Void)?
    /// What travels with a note, names as the team has them.
    var props: (NoteItem) -> [String: TeamJSON]

    /// The folder team's binders on this Mac: the ones it shares, and teammates' copies.
    func binders() -> [BinderRecord] {
        store.binders(includeArchived: true).filter { $0.sharedWithTeam || $0.isTeamCopy }
    }

    /// Brings everything in. Run again, it changes nothing: the database keeps each item once, and a note it has gets only
    /// what changed in the folder since.
    func run() async -> Summary {
        var summary = Summary()
        let all = binders()
        for binder in all {
            importBinder(binder)
            summary.binders += 1
        }
        for binder in all { summary.folders += importFolders(of: binder) }
        for binder in all {
            for note in notes(in: binder.id) where !note.staysUnshared {
                if await importNote(note, in: binder) { summary.merged += 1 }
                summary.notes += 1
            }
        }
        for binder in all {
            for meeting in meetings(in: binder.id) {
                importMeeting(meeting, in: binder)
                summary.meetings += 1
            }
        }
        store.save()
        engine.save()
        return summary
    }

    /// Once it's all in: the folder team's marks come off, as these are the database's now (who wrote each stays, by name).
    func finish() {
        for binder in binders() {
            binder.sharedWithTeam = false
            binder.isTeamCopy = false
            binder.teamDatabaseKey = key
            if binder.teamMadeBy.isEmpty, let author = binder.teamAuthorName, binder.teamAuthorID != me.id { binder.teamMadeBy = author }
            for note in notes(in: binder.id) { note.sharedWithTeam = false }
            for meeting in meetings(in: binder.id) { meeting.sharedWithTeam = false }
        }
        store.save()
    }

    // MARK: Each kind

    private func author(id: String?, name: String?) -> TeamImportedAuthor {
        TeamImportedAuthor(id: id ?? me.id, name: name ?? me.name)
    }

    /// Whose a teammate's item is in the database: the member with their name, when there's one.
    private func member(named name: String?, mine: Bool) -> UUID? {
        mine ? member : TeamMoveMarker.member(named: name, in: directory.members)
    }

    private func importBinder(_ binder: BinderRecord) {
        let mine = !binder.isTeamCopy
        if mine, let shareBoard {
            shareBoard(binder)
            return
        }
        let fields: [String: TeamJSON] = ["color": .string(String(binder.colorIndex)), "everyone": true, "agents_may_finish": .bool(binder.agentsMayFinish),
                                          "agents_may_place": .bool(binder.agentsMayPlace)]
        database.send(.importBinder(binder.id, name: binder.name, fields: fields,
                                    importedAuthor: author(id: mine ? me.id : binder.teamAuthorID, name: mine ? me.name : binder.teamAuthorName),
                                    author: member(named: binder.teamAuthorName, mine: mine), claim: me.id,
                                    operation: TeamMoveIDs.binder(binder.id, member: member)))
    }

    /// The binder's folders, parents first. Returns how many.
    private func importFolders(of binder: BinderRecord) -> Int {
        let folders = store.folders(in: binder.id)
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func depth(_ folder: FolderRecord) -> Int {
            var depth = 0, current = folder.parentID, seen: Set<UUID> = []
            while let id = current, let parent = byID[id], seen.insert(id).inserted {
                depth += 1
                current = parent.parentID
            }
            return depth
        }
        for folder in folders.sorted(by: { depth($0) < depth($1) }) {
            let parent = store.shownFolder(folder.parentID, in: binder.id)
            database.send(.putFolder(folder.id, binder: binder.id,
                                     fields: ["name": .string(folder.name), "parent_id": TeamJSON(parent), "position": .number(folder.position),
                                              "imported_author": author(id: binder.isTeamCopy ? binder.teamAuthorID : me.id,
                                                                        name: binder.isTeamCopy ? binder.teamAuthorName : me.name).json],
                                     operation: TeamMoveIDs.folder(folder.id, member: member)))
        }
        return folders.count
    }

    /// A note: made in the database once; one it has already gets what changed in the folder since it was brought in.
    /// Returns whether it was one the database had.
    private func importNote(_ note: NoteItem, in binder: BinderRecord) async -> Bool {
        let props = self.props(note)
        if engine.knows(note.id) {
            _ = await engine.document(note.id)
            engine.bringIn(note.id, text: note.text, props: props, member: member)
            return true
        }
        let mine = !note.isTeamCopy
        var fields: [String: TeamJSON] = ["title": .string(note.title), "created_at": TeamJSON(note.createdAt),
                                          "imported_author": author(id: mine ? me.id : note.teamAuthorID, name: mine ? me.name : note.teamAuthorName).json,
                                          "started_at": TeamJSON(note.createdAt), "ended_at": TeamJSON(note.updatedAt), "claim": .string(me.id)]
        if let author = member(named: note.teamAuthorName, mine: mine) { fields["author"] = TeamJSON(author) }
        if let shareNote {
            shareNote(note, fields, TeamMoveIDs.note(note.id, member: member))
        } else {
            engine.share(note.id, binder: binder.id, folder: store.shownFolder(note.folderID, in: binder.id), text: note.text, props: props,
                         fields: fields, operation: TeamMoveIDs.note(note.id, member: member))
        }
        return false
    }

    private func importMeeting(_ meeting: MeetingRecord, in binder: BinderRecord) {
        let mine = !meeting.isTeamCopy
        let segments = store.segments(for: meeting.id).enumerated().map { index, segment -> TeamJSON in
            ["position": .number(Double(index)), "speaker": .string(segment.speaker), "text": .string(segment.text),
             "start_time": .number(segment.start), "end_time": .number(segment.end)]
        }
        var names: [String: TeamJSON] = [:]
        for (label, name) in meeting.speakerNames { names[label] = .string(name) }
        let fields: [String: TeamJSON] = ["folder_id": TeamJSON(store.shownFolder(meeting.folderID, in: binder.id)), "title": .string(meeting.title),
                                          "started_at": TeamJSON(meeting.createdAt),
                                          "ended_at": TeamJSON(meeting.endedAt ?? meeting.createdAt.addingTimeInterval(meeting.duration)),
                                          "duration": .number(meeting.duration), "app_name": TeamJSON(meeting.appName),
                                          "attendees": TeamJSON(meeting.attendees), "template_id": .string(meeting.templateID),
                                          "summary": .string(meeting.summary), "notes": .string(meeting.userNotes), "speaker_names": .object(names)]
        database.send(.importMeeting(meeting.id, binder: binder.id, fields: fields, segments: segments,
                                     importedAuthor: author(id: mine ? me.id : meeting.teamAuthorID, name: mine ? me.name : meeting.teamAuthorName),
                                     author: member(named: meeting.teamAuthorName, mine: mine), claim: me.id,
                                     operation: TeamMoveIDs.meeting(meeting.id, member: member)))
    }

    // MARK: Reading the store

    private func notes(in binder: UUID) -> [NoteItem] {
        (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binder }))) ?? []
    }

    /// Meetings the team folder shares: not conversations, which never went to it, and finished.
    private func meetings(in binder: UUID) -> [MeetingRecord] {
        let kind = MeetingRecord.conversationKind
        return ((try? store.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binder && $0.kind != kind }))) ?? [])
            .filter { $0.status == "ready" || $0.status == "failed" }
    }
}
