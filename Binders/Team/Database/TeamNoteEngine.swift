import Foundation
import BindersKit

/// Who made a change this Mac captures: a person at this Mac, or one of this member's agents (its id in the team).
struct TeamNoteAuthor: Equatable, Hashable {
    var agent: UUID?

    static let person = TeamNoteAuthor(agent: nil)
}

/// The shared notes of one team database on one Mac, as Automerge documents (lane DB3). It knows nothing of SwiftData:
/// the app's TeamNotes hands it the notes' text and props and writes back what the team changed, and a teammate's Mac in
/// the self-tests runs the same code with notes kept in memory.
///
/// - A note this Mac shares goes as `create_note`: the document's skeleton and its words, in one version.
/// - An edit here is the difference from the text the note and the document last agreed on (`NoteState.text`), turned
///   into splices, as one change, sent through the outbox (`add_note_changes`), with what it did to its version.
/// - A teammate's changes are applied to the document as they come; the caller captures anything typed here first, then
///   takes the document's text: both keep their words.
/// - Every so often (5 seconds after this Mac's last change, at most every 30 seconds) the note goes whole (`save_note`).
@MainActor
final class TeamNoteEngine {
    struct NoteState: Codable, Equatable {
        var binder: UUID
        var folder: UUID?
        /// The note's text and props as this Mac and the document last agreed.
        var text: String
        var props: [String: TeamJSON]
        /// This Mac's actor for the note's changes.
        var actor: UUID
        /// The heads it was first shared or brought in as.
        var origin: [String]
        /// Changes made here since the note last went whole, and when the last one was.
        var unsaved: Int = 0
        var lastChange: Date?
        var lastSaved: Date?
        /// The database turned it down as deleted: this Mac's copy waits for what to do.
        var deleted: Bool = false
    }

    /// The version a change of this Mac's is expected to go in, until the database says.
    private struct Expected {
        var firstHash: String
        var agent: UUID?
        var endedAt: Date
        var closed: Bool
    }

    let database: TeamDatabase
    let folder: URL
    private(set) var states: [UUID: NoteState] = [:] {
        didSet { statesChanged = true }
    }
    /// Whether `states` changed since it was last written.
    private var statesChanged = false
    private var documents: [UUID: TeamNoteDocument] = [:]
    /// Each note's versions as the database last said.
    private(set) var versions: [UUID: [TeamNoteVersionRow]] = [:]
    private var expected: [UUID: Expected] = [:]
    /// Each note's row as last read (without its document).
    private(set) var rows: [UUID: TeamNoteRow] = [:]
    /// Notes whose documents changed since they were written to disk.
    private var unwritten: Set<UUID> = []
    /// Notes this Mac is making in the database (`create_note` not answered yet), and the team's changes to them held
    /// meanwhile: if another Mac made the note first, this Mac's document is read again from the database, and those
    /// changes, applied to the document made here, would put the note's first words in twice.
    private var creating: Set<UUID> = []
    private var held: [UUID: [TeamNoteChangeRow]] = [:]
    /// Notes the team deleted that this Mac puts back (Undo), with their text and props here: once the database has put
    /// the note back, its document is read again and what differs here goes as an edit.
    private var restoring: [UUID: (text: String, props: [String: TeamJSON])] = [:]
    /// Notes with an edit made here whose answer this engine hasn't taken yet (lane DB9): one that has left the outbox is
    /// still unanswered here until `settle` takes its answer, so a deletion arriving meanwhile waits for it.
    private var editsUnanswered: Set<UUID> = []
    /// For the self-tests: how soon a note goes whole after its last change, and how often at most.
    var saveAfter: TimeInterval = 5
    var saveEvery: TimeInterval = 30
    /// Writes the states and documents to disk, one after another, off the main thread (lane DB10).
    private let writer = DispatchQueue(label: "io.binders.mac.team-notes", qos: .utility)
    private var saving: Task<Void, Never>?
    private var lastSave = Date.distantPast

    init(database: TeamDatabase, folder: URL) {
        self.database = database
        self.folder = folder
        load()
    }

    /// This Mac's member in the team.
    var me: UUID? { database.member?["id"]?.uuid }

    func state(_ note: UUID) -> NoteState? { states[note] }

    /// Whether this Mac shares the note through the database.
    func knows(_ note: UUID) -> Bool { states[note] != nil }

    // MARK: Documents

    /// The note's document: in memory, else on disk, else read from the database (its saved copy and every change).
    func document(_ note: UUID) async -> TeamNoteDocument? {
        if let document = documents[note] { return document }
        if let document = loadDocument(note) { return document }
        guard let actor = states[note]?.actor ?? Optional(TeamNoteDocument.newActor()),
              let row = try? await database.rows(.notes, ids: [note]).first.flatMap(TeamNoteRow.init(row:)),
              let changes = try? await database.json(TeamQueries.noteChanges, [note.uuidString.lowercased()]).array?
                .compactMap({ $0.object.flatMap(TeamNoteChangeRow.init(row:)) }),
              let document = try? TeamNoteDocument(note: note, saved: row.document, changes: changes.map(\.change) + queued(note), actor: actor)
        else { return nil }
        documents[note] = document
        unwritten.insert(note)
        return document
    }

    /// The document as it is in memory or on disk, without asking the database.
    func documentHere(_ note: UUID) -> TeamNoteDocument? {
        documents[note] ?? loadDocument(note)
    }

    private func loadDocument(_ note: UUID) -> TeamNoteDocument? {
        // Being put back: the file on disk is the copy `forget` is removing off the main thread (lane DB10), not the
        // team's document, which is read again once the database has put the note back (`settle`).
        guard restoring[note] == nil else { return nil }
        guard let state = states[note], let data = try? Data(contentsOf: documentURL(note)),
              let document = try? TeamNoteDocument(note: note, saved: data, changes: queued(note), actor: state.actor) else { return nil }
        documents[note] = document
        return document
    }

    /// Changes of this note still waiting in the outbox: a document read again has them too.
    private func queued(_ note: UUID) -> [Data] {
        database.queued.filter { $0.call.note == note }.flatMap { item -> [Data] in
            guard let list = item.call.argument("p_changes").flatMap({ TeamJSON(text: $0) })?.array else { return [] }
            return list.compactMap { $0["change"]?.bytes }
        }
    }

    // MARK: Sharing a note

    /// A note of this Mac's goes to the team: its document made (the skeleton, then its words and props, as one version),
    /// and `create_note` queued. `fields` adds what the row should say besides (title, folder, an import's author).
    func share(_ note: UUID, binder: UUID, folder: UUID?, text: String, props: [String: TeamJSON], fields: [String: TeamJSON] = [:],
               by author: TeamNoteAuthor = .person, operation: UUID = UUID(), undelete: Bool = false) {
        // Shared already (a move run again): what changed goes as an edit, never a second note.
        if states[note] != nil, !undelete { return }
        // Put back after the team deleted it (Undo): the note's document is the team's, never a second one beside it. The
        // database puts it back with nothing new; then what differs here goes as an edit (`settle`).
        if undelete, let skeleton = TeamNoteDocument.skeletonHash(note),
           let bytes = (try? TeamNoteDocument(new: note, actor: UUID()))?.changeBytes(skeleton) {
            restoring[note] = (text, props)
            states[note] = NoteState(binder: binder, folder: folder, text: text, props: props, actor: TeamNoteDocument.newActor(), origin: [])
            documents[note] = nil
            creating.insert(note)
            database.send(.createNote(note, binder: binder, fields: ["folder_id": TeamJSON(folder)], changes: [TeamNoteChange(hash: skeleton, deps: [], bytes: bytes)],
                                      agent: author.agent, undelete: true, operation: operation))
            save()
            return
        }
        guard let document = try? TeamNoteDocument(new: note, actor: TeamNoteDocument.newActor()),
              let skeleton = TeamNoteDocument.skeletonHash(note), let skeletonBytes = document.changeBytes(skeleton) else { return }
        var changes = [TeamNoteChange(hash: skeleton, deps: [], bytes: skeletonBytes)]
        if let made = try? document.change(splices: TextEdits.splices(from: "", to: text), props: props) {
            let stats = TeamNoteStats.between("", text)
            changes.append(TeamNoteChange(hash: made.hash, deps: made.deps, bytes: made.bytes, stats: stats, versionFirst: skeleton, versionStats: stats))
        }
        var all = fields
        all["folder_id"] = TeamJSON(folder)
        all["body"] = .string(text)
        all["properties"] = .object(TeamNoteProps(values: props).rowProperties)
        all["distill"] = .bool(props["distill"]?.bool ?? false)
        all["document"] = TeamJSON(bytes: document.save())
        all["document_heads"] = TeamJSON(document.heads)
        all["document_changes"] = .number(Double(document.changeCount))
        all["origin_heads"] = TeamJSON(document.heads)
        documents[note] = document
        states[note] = NoteState(binder: binder, folder: folder, text: text, props: props, actor: document.actorID, origin: document.heads,
                                 lastSaved: Date())
        creating.insert(note)
        database.send(.createNote(note, binder: binder, fields: all, changes: changes, agent: author.agent, undelete: undelete, operation: operation))
        unwritten.insert(note)
        save()
    }

    /// One of this Mac's own notes brought in from a team folder that the database has as someone else's: claimed, as
    /// create_note lets the person who wrote it in the folder (`folder`, their own id there) do. Sent once; nothing else
    /// about the note changes (its answer, `exists`, is let be).
    func claim(_ note: UUID, binder: UUID, importedAuthor: TeamImportedAuthor, as folder: String, member: UUID) {
        guard states[note] != nil, let skeleton = TeamNoteDocument.skeletonHash(note),
              let bytes = (try? TeamNoteDocument(new: note, actor: UUID()))?.changeBytes(skeleton) else { return }
        database.send(.createNote(note, binder: binder, fields: ["imported_author": importedAuthor.json, "claim": .string(folder), Self.claimOnly: true],
                                  changes: [TeamNoteChange(hash: skeleton, deps: [], bytes: bytes)],
                                  operation: TeamOperationID.derived("claim note \(note.uuidString.lowercased()) by \(member.uuidString.lowercased())")))
    }

    /// The field that marks a create_note as a claim only.
    static let claimOnly = "claim_only"

    /// A note the database has that this Mac doesn't know yet (a teammate's): its state starts from the document as it
    /// came. Returns its text and props.
    func adopt(_ row: TeamNoteRow, changes: [TeamNoteChangeRow]) -> (text: String, props: [String: TeamJSON])? {
        let actor = states[row.id]?.actor ?? TeamNoteDocument.newActor()
        let document: TeamNoteDocument
        if let existing = documents[row.id] ?? loadDocument(row.id) {
            try? existing.apply(changes.map(\.change))
            document = existing
        } else {
            guard let made = try? TeamNoteDocument(note: row.id, saved: row.document, changes: changes.map(\.change), actor: actor) else { return nil }
            document = made
        }
        documents[row.id] = document
        states[row.id] = NoteState(binder: row.binderID, folder: row.folderID, text: document.text, props: document.props, actor: actor,
                                   origin: row.originHeads)
        rows[row.id] = row
        unwritten.insert(row.id)
        save()
        return (document.text, document.props)
    }

    // MARK: Edits made here

    /// The note as it is here now, against what the document has: the difference, as one change of this Mac's, queued.
    /// `restores`: the version this edit puts back. Returns whether anything changed.
    @discardableResult
    func edited(_ note: UUID, text: String, props: [String: TeamJSON], by author: TeamNoteAuthor = .person, restores: UUID? = nil,
                at date: Date = Date()) -> Bool {
        guard var state = states[note], !state.deleted else { return false }
        // Nothing changed here since the note and the document last agreed: nothing to look at (the sweep asks of every note).
        let changedHere = text != state.text || props.contains { (state.props[$0.key] ?? .null) != $0.value } || restores != nil
        guard changedHere, let document = documentHere(note) else { return false }
        let before = document.text
        // What changed here since the note and the document last agreed, on top of what the document has now: a teammate's
        // change the note doesn't show yet is kept, never taken back.
        let target = before == state.text ? text : TextMerge.merge(base: state.text, mine: text, theirs: before)
        let changedProps = props.filter { (state.props[$0.key] ?? .null) != $0.value }
        guard let made = try? document.change(splices: TextEdits.splices(from: before, to: target), props: changedProps, at: date) else {
            return false
        }
        let stats = TeamNoteStats.between(before, target)
        var change = TeamNoteChange(hash: made.hash, deps: made.deps, bytes: made.bytes, stats: stats)
        // The version it goes in, as the database will decide it: this author's session, or a new one.
        if restores == nil, let current = latestVersion(note), current.agent == author.agent, !current.closed,
           date.timeIntervalSince(current.endedAt) < TeamNoteVersionRow.session,
           let base = try? document.text(at: document.deps(of: current.firstHash) ?? []) {
            change.versionFirst = current.firstHash
            change.versionStats = TeamNoteStats.between(base, target)
            expected[note] = Expected(firstHash: current.firstHash, agent: author.agent, endedAt: date, closed: false)
        } else {
            expected[note] = Expected(firstHash: made.hash, agent: author.agent, endedAt: date, closed: restores != nil)
        }
        database.send(.addNoteChanges(note, changes: [change], agent: author.agent, restores: restores))
        editsUnanswered.insert(note)
        state.text = document.text
        state.props = document.props
        state.unsaved += 1
        state.lastChange = date
        states[note] = state
        unwritten.insert(note)
        return true
    }

    /// The latest version of the note this Mac's next change would meet: what it expects its own last change made, else
    /// the database's latest, when it's this member's.
    private func latestVersion(_ note: UUID) -> Expected? {
        let known = (versions[note] ?? []).filter { $0.deletedAt == nil }.max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
        let theirs = known.flatMap { version -> Expected? in
            guard let first = version.firstHash, let ended = version.endedAt, version.memberID == me else { return nil }
            return Expected(firstHash: first, agent: version.agentID, endedAt: ended,
                            closed: version.name != nil || version.distillID != nil || version.restoredFrom != nil || version.imported)
        }
        if let mine = expected[note] {
            // Someone else's version since: the database starts a new one for this Mac's next change.
            if let known, known.memberID != me, (known.endedAt ?? .distantPast) > mine.endedAt { return nil }
            if let theirs, theirs.endedAt > mine.endedAt { return theirs }
            return mine
        }
        guard let known, known.memberID == me else { return nil }
        return theirs
    }

    // MARK: The team's changes

    /// A teammate's changes (any order within a note: Automerge waits for what a change depends on), applied to the notes'
    /// documents. A note this Mac has no document for is read whole. Returns the notes that changed.
    func receive(_ changes: [TeamNoteChangeRow]) async -> Set<UUID> {
        var touched: Set<UUID> = []
        for (index, (note, list)) in Dictionary(grouping: changes, by: \.noteID).enumerated() {
            // A turn for the window between every few notes (lane DB10): a binder read whole brings every note's changes.
            if index > 0, index.isMultiple(of: 20) { await Task.yield() }
            guard states[note] != nil else { continue }
            if creating.contains(note) {
                held[note, default: []] += list
                continue
            }
            if documents[note] == nil, loadDocument(note) == nil {
                // Read whole from the database, these changes among them.
                guard await document(note) != nil else { continue }
                touched.insert(note)
                continue
            }
            guard let document = documents[note] else { continue }
            // Ones it has change nothing; whether any was new, its heads say (asking it of each change means building
            // that change from the whole document, lane DB10).
            let before = document.heads
            try? document.apply(list.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }.map(\.change))
            guard document.heads != before else { continue }
            unwritten.insert(note)
            touched.insert(note)
        }
        return touched
    }

    /// The note's text and props in its document now.
    func current(_ note: UUID) -> (text: String, props: [String: TeamJSON])? {
        guard let document = documentHere(note) else { return nil }
        return (document.text, document.props)
    }

    /// The note here now says what its document says.
    func agree(_ note: UUID, text: String, props: [String: TeamJSON]) {
        states[note]?.text = text
        states[note]?.props = props
    }

    /// The note's row as the database has it now: its binder and folder here follow it (the caller moves the note).
    func take(row: TeamNoteRow) {
        rows[row.id] = row
        guard var state = states[row.id] else { return }
        state.binder = row.binderID
        state.folder = row.folderID
        if row.deletedAt != nil { state.deleted = true }
        if state.origin.isEmpty { state.origin = row.originHeads }
        states[row.id] = state
    }

    /// The note moved here (another folder, or another shared binder): the database is told.
    func moved(_ note: UUID, binder: UUID, folder: UUID?, by author: TeamNoteAuthor = .person) {
        guard var state = states[note], state.binder != binder || state.folder != folder else { return }
        state.binder = binder
        state.folder = folder
        states[note] = state
        database.send(.moveNote(note, binder: binder, folder: folder, agent: author.agent))
        save()
    }

    /// The note deleted here: deleted for the team, and forgotten here.
    func deleted(_ note: UUID) {
        guard states[note] != nil else { return }
        database.send(.delete(note, from: .notes))
        forget(note)
    }

    /// The note is no longer shared through the database on this Mac (its binder went, or the team deleted it).
    func forget(_ note: UUID) {
        states[note] = nil
        editsUnanswered.remove(note)
        documents[note] = nil
        expected[note] = nil
        versions[note] = nil
        rows[note] = nil
        unwritten.remove(note)
        // After any write of it still under way.
        let url = documentURL(note)
        writer.async { try? FileManager.default.removeItem(at: url) }
        save()
    }

    // MARK: Versions

    /// Versions as the database has them now.
    func take(versions list: [TeamNoteVersionRow]) {
        for version in list {
            var known = versions[version.noteID] ?? []
            known.removeAll { $0.id == version.id }
            if version.deletedAt == nil { known.append(version) }
            versions[version.noteID] = known
            // What this Mac expected is now the database's word.
            if let mine = expected[version.noteID], version.firstHash == mine.firstHash || version.lastHash == mine.firstHash,
               (version.endedAt ?? .distantPast) >= mine.endedAt.addingTimeInterval(-1) {
                expected[version.noteID] = nil
            }
        }
    }

    /// A version named here: shown with its name at once, before the database says so.
    func renamed(_ version: UUID, of note: UUID, to name: String) {
        guard var list = versions[note], let index = list.firstIndex(where: { $0.id == version }) else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        list[index].name = trimmed.isEmpty ? nil : trimmed
        versions[note] = list
    }

    /// The note's versions, newest first.
    func history(_ note: UUID) -> [TeamNoteVersionRow] {
        (versions[note] ?? []).sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
    }

    /// A version's text: the document at its last change.
    func text(of version: TeamNoteVersionRow) -> String? {
        guard let last = version.lastHash, let document = documentHere(version.noteID) else { return nil }
        return try? document.text(at: [last])
    }

    /// The text just before a version's first change.
    func text(before version: TeamNoteVersionRow) -> String? {
        guard let first = version.firstHash, let document = documentHere(version.noteID), let deps = document.deps(of: first) else { return nil }
        return try? document.text(at: deps)
    }

    /// The note's versions read whole from the database (the History sheet opening on a note whose versions this Mac hasn't
    /// kept, as after a restart).
    func readVersions(_ note: UUID) async {
        guard let list = try? await database.json(TeamQueries.noteVersions, [note.uuidString.lowercased()]).array else { return }
        take(versions: list.compactMap { $0.object.flatMap(TeamNoteVersionRow.init(row:)) })
    }

    // MARK: Going whole

    /// Notes changed here that are due to go whole: saved now, past the outbox (a copy that can't go waits for the next).
    func saveDue(now: Date = Date()) async {
        guard database.status.isConnected else { return }
        for (note, state) in states where state.unsaved > 0 && !state.deleted {
            let quiet = state.lastChange.map { now.timeIntervalSince($0) >= saveAfter } ?? true
            let long = state.lastSaved.map { now.timeIntervalSince($0) >= saveEvery } ?? true
            guard quiet || long, let document = documentHere(note) else { continue }
            guard let fields = await Self.whole(document, note: note, actor: state.actor),
                  let result = try? await database.call(.saveNote(note, fields: fields)), result.ok else { continue }
            states[note]?.unsaved = 0
            states[note]?.lastSaved = now
        }
        save()
        writeDocuments()
    }

    /// What `save_note` sends for a note, made off the main thread (lane DB10): the document saved at one moment, and its
    /// heads, words and number of changes read from that copy, so they all say the same however it changes meanwhile.
    nonisolated private static func whole(_ document: TeamNoteDocument, note: UUID, actor: UUID) async -> [String: TeamJSON]? {
        await Task.detached(priority: .utility) { () -> [String: TeamJSON]? in
            let saved = document.save()
            guard let copy = try? TeamNoteDocument(note: note, saved: saved, changes: [], actor: actor) else { return nil }
            let props = TeamNoteProps(values: copy.props)
            let text = copy.text
            return ["document": TeamJSON(bytes: saved), "document_heads": TeamJSON(copy.heads), "document_changes": .number(Double(copy.changeCount)),
                    "body": .string(text), "title": .string(MarkdownSyntax.noteTitle(text)), "properties": .object(props.rowProperties),
                    "distill": .bool(props.properties.distill)]
        }.value
    }

    // MARK: Answers

    /// What became of one of this engine's calls. Versions an answer brings are kept. Returns notes a refusal changed here.
    func settle(_ outcome: TeamOutboxOutcome) async -> Set<UUID> {
        guard let note = outcome.call.note else { return [] }
        if outcome.call.function == "add_note_changes",
           !database.queued.contains(where: { $0.call.note == note && $0.call.function == "add_note_changes" && isEditMadeHere($0.call) }) {
            editsUnanswered.remove(note)
        }
        // A claim (checkAgainstDatabase): the note was there, as it always is for one; nothing to merge.
        if outcome.call.function == "create_note", outcome.call.argument("p_fields").flatMap({ TeamJSON(text: $0) })?[Self.claimOnly]?.bool == true {
            return []
        }
        var waited: [TeamNoteChangeRow] = []
        if outcome.call.function == "create_note" {
            creating.remove(note)
            waited = held.removeValue(forKey: note) ?? []
            // The putting back's own answer (another create_note for the note, answered first, isn't).
            if TeamNoteOperations.isUndelete(outcome.call), let wanted = restoring.removeValue(forKey: note) {
                guard case .applied = outcome.outcome, await rebuild(note) else { forget(note); return [note] }
                edited(note, text: wanted.text, props: wanted.props)
                return [note]
            }
        }
        switch outcome.outcome {
        case .applied(let result):
            take(versions: (result.body["versions"]?.array ?? []).compactMap { $0.object.flatMap(TeamNoteVersionRow.init(row:)) })
            if let row = result.body["note"]?.object.flatMap(TeamNoteRow.init(row:)) { take(row: row) }
            // The team's changes that came while it was being made: on top of it now.
            return waited.isEmpty ? [] : await receive(waited)
        case .refused(let refusal) where refusal.code == "exists" && outcome.call.function == "create_note":
            // Shared, or brought in, by another Mac first: this Mac's words go in as changes from the version it was brought
            // in as, so nothing is doubled and what's changed since is kept. One being put back meanwhile is the putting
            // back's (lane DB9).
            guard restoring[note] == nil else { return [] }
            return await merge(note, intended: outcome.call) ? [note] : []
        case .refused(let refusal) where refusal.code == "deleted":
            // Being put back (lane DB9): the putting back answers for it, then sends what differs here as one edit.
            guard restoring[note] == nil else { return [] }
            states[note]?.deleted = true
            save()
            return [note]
        case .refused(let refusal) where refusal.code == "not_found":
            forget(note)
            return [note]
        default:
            return []
        }
    }

    /// The note's document read again from the database (its saved copy and every change), and taken as what this Mac
    /// and the document agree on.
    private func rebuild(_ note: UUID) async -> Bool {
        guard let actor = states[note]?.actor,
              let row = try? await database.rows(.notes, ids: [note]).first.flatMap(TeamNoteRow.init(row:)),
              let changes = try? await database.json(TeamQueries.noteChanges, [note.uuidString.lowercased()]).array?
                .compactMap({ $0.object.flatMap(TeamNoteChangeRow.init(row:)) }),
              let document = try? TeamNoteDocument(note: note, saved: row.document, changes: changes.map(\.change), actor: actor)
        else { return false }
        documents[note] = document
        rows[note] = row
        states[note]?.text = document.text
        states[note]?.props = document.props
        states[note]?.origin = row.originHeads
        states[note]?.binder = row.binderID
        states[note]?.folder = row.folderID
        unwritten.insert(note)
        save()
        return true
    }

    /// A note this Mac tried to make that the database already had: read as the database has it, then what this Mac would
    /// have made goes in as a change from the version it was first brought in as.
    private func merge(_ note: UUID, intended call: TeamCall) async -> Bool {
        guard let mine = states[note], let fields = call.argument("p_fields").flatMap({ TeamJSON(text: $0) }),
              let row = try? await database.rows(.notes, ids: [note]).first.flatMap(TeamNoteRow.init(row:)),
              let changes = try? await database.json(TeamQueries.noteChanges, [note.uuidString.lowercased()]).array?
                .compactMap({ $0.object.flatMap(TeamNoteChangeRow.init(row:)) }),
              let document = try? TeamNoteDocument(note: note, saved: row.document, changes: changes.map(\.change), actor: mine.actor)
        else { return false }
        // Deleted for the team (lane DB9): nothing goes into it. What becomes of this Mac's copy is TeamNotes' to say: one the
        // team deleted is left out, never shared again under a new id.
        if row.deletedAt != nil {
            rows[note] = row
            states[note]?.deleted = true
            save()
            return true
        }
        documents[note] = document
        let text = fields["body"]?.string ?? mine.text
        let origin = row.originHeads.isEmpty ? document.heads : row.originHeads
        states[note] = NoteState(binder: row.binderID, folder: row.folderID, text: document.text, props: document.props, actor: mine.actor,
                                 origin: origin)
        rows[note] = row
        if let made = try? document.change(from: origin, to: text, props: mine.props, actor: mine.actor) {
            let stats = TeamNoteStats.between((try? document.text(at: origin)) ?? "", text)
            database.send(.addNoteChanges(note, changes: [TeamNoteChange(hash: made.hash, deps: made.deps, bytes: made.bytes, stats: stats)],
                                          operation: TeamNoteOperations.merge(note: note, hash: made.hash)))
            states[note]?.unsaved += 1
            states[note]?.lastChange = Date()
        }
        states[note]?.text = document.text
        states[note]?.props = document.props
        unwritten.insert(note)
        save()
        return true
    }

    /// The folder team's words for a note the database already has (moving a folder team over, or a Mac that had the note
    /// from the team folder): what changed in the folder since the note was brought in, merged from that version, so
    /// what's changed in the database since is kept too. Nothing when nothing changed there. The note's document is here
    /// (`document(_:)` reads it first when it isn't).
    @discardableResult
    func bringIn(_ note: UUID, text: String, props: [String: TeamJSON], member: UUID) -> Bool {
        guard let document = documentHere(note), var state = states[note] else { return false }
        let origin = state.origin.isEmpty ? (rows[note]?.originHeads ?? []) : state.origin
        guard !origin.isEmpty, let base = try? document.text(at: origin), let baseProps = try? document.props(at: origin) else { return false }
        let changedProps = props.filter { (baseProps[$0.key] ?? .null) != $0.value }
        guard base != text || !changedProps.isEmpty,
              let made = try? document.change(from: origin, to: text, props: changedProps, actor: state.actor) else { return false }
        let stats = TeamNoteStats.between(base, text)
        database.send(.addNoteChanges(note, changes: [TeamNoteChange(hash: made.hash, deps: made.deps, bytes: made.bytes, stats: stats)],
                                      operation: TeamNoteOperations.bringIn(note: note, member: member, hash: made.hash)))
        state.text = document.text
        state.props = document.props
        state.unsaved += 1
        state.lastChange = Date()
        states[note] = state
        unwritten.insert(note)
        save()
        return true
    }

    // MARK: Notes the team deleted (lane DB9)

    /// Whether a call is an edit made on this Mac, rather than a merge or a move's bringing in.
    func isEditMadeHere(_ call: TeamCall) -> Bool { TeamNoteOperations.isEditMadeHere(call, member: me) }

    /// Whether something of this Mac's for the note awaits the answer this engine takes in `settle`: an edit made here, or
    /// the note being made (its `create_note`).
    func awaitsAnswer(_ note: UUID) -> Bool { editsUnanswered.contains(note) || creating.contains(note) }

    /// Whether the note is being put back for the team (Undo, or a deletion this Mac doesn't follow): its `create_note`
    /// with `p_undelete` waits, or its answer is awaited.
    func puttingBack(_ note: UUID) -> Bool {
        restoring[note] != nil || database.queued.contains { $0.call.note == note && TeamNoteOperations.isUndelete($0.call) }
    }

    /// What waits to go for a note this Mac is about to put back: taken back before it's sent, so the putting back goes
    /// first. Nothing is lost: what those changes said is in the note here, and goes as one edit once it's back (`settle`).
    func withdrawWaiting(_ note: UUID) {
        for item in database.queued where item.call.note == note && ["add_note_changes", "move_note", "save_note"].contains(item.call.function) {
            _ = database.withdraw(item.id)
        }
    }

    /// The note as the database has it now (its saved copy and every change, read again), with every text it had on the
    /// way, one at each of its changes: what tells whether a copy here holds anything the team never had.
    func teamTexts(_ note: UUID) async -> (text: String, all: Set<String>)? {
        guard let row = try? await database.rows(.notes, ids: [note]).first.flatMap(TeamNoteRow.init(row:)),
              let changes = try? await database.json(TeamQueries.noteChanges, [note.uuidString.lowercased()]).array?
                .compactMap({ $0.object.flatMap(TeamNoteChangeRow.init(row:)) }),
              let document = try? TeamNoteDocument(note: note, saved: row.document, changes: changes.map(\.change), actor: TeamNoteDocument.newActor())
        else { return nil }
        var all: Set<String> = [document.text, row.body]
        for change in changes {
            if let text = try? document.text(at: [change.hash]) { all.insert(text) }
        }
        return (document.text, all)
    }

    // MARK: On disk

    private var stateURL: URL { folder.appendingPathComponent("notes.json") }
    private func documentURL(_ note: UUID) -> URL { folder.appendingPathComponent("\(note.uuidString).automerge") }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL), let read = try? JSONDecoder().decode([UUID: NoteState].self, from: data) else { return }
        states = read
        statesChanged = false
    }

    /// The notes' states written, when they changed since: at most about once a second, encoded and written off the main
    /// thread, in order (lane DB10). Before, every note shared, brought in or moved wrote every note's state, its words
    /// included, so a loop over 400 notes wrote 400 files of growing size. `flush` writes at once (stopping, quitting).
    func save() {
        guard statesChanged, saving == nil else { return }
        let wait = max(0, Self.statesEvery - Date().timeIntervalSince(lastSave))
        saving = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.saving = nil
            self.writeStates()
        }
    }

    /// How often at most the states are written.
    static let statesEvery: TimeInterval = 1

    private func writeStates(now: Bool = false) {
        guard statesChanged else { return }
        statesChanged = false
        lastSave = Date()
        let snapshot = states, folder = folder, url = stateURL
        let write = {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
            TeamPerf.shared.count { $0.engineSaves += 1; $0.engineBytes += data.count }
        }
        if now { writer.sync(execute: write) } else { writer.async(execute: write) }
    }

    /// The documents changed since they were last written, written off the main thread (Automerge's documents take a lock
    /// of their own, so one can be saved there while the main thread changes it; what it misses goes next time).
    func writeDocuments(now: Bool = false) {
        guard !unwritten.isEmpty else {
            if now { writer.sync {} }
            return
        }
        let list = unwritten.compactMap { note in documents[note].map { (documentURL(note), $0) } }
        unwritten = []
        let folder = folder
        let write = {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (url, document) in list {
                let data = document.save()
                try? data.write(to: url, options: .atomic)
                TeamPerf.shared.count { $0.documentWrites += 1; $0.documentBytes += data.count }
            }
        }
        if now { writer.sync(execute: write) } else { writer.async(execute: write) }
    }

    /// Everything on disk now: the documents and the states (stopping, quitting).
    func flush() {
        saving?.cancel()
        saving = nil
        writeDocuments(now: true)
        writeStates(now: true)
    }
}

extension TeamQueries {
    /// Every change of one note ($1), oldest first: what a Mac reads to make the note's document again.
    static let noteChanges = """
        SELECT coalesce(json_agg(to_jsonb(c) ORDER BY c.created_at, c.id), '[]')::text FROM binders.note_changes c WHERE c.note_id = $1::uuid
        """

    /// Every version of one note ($1) still kept.
    static let noteVersions = """
        SELECT coalesce(json_agg(to_jsonb(v)), '[]')::text FROM binders.note_versions v WHERE v.note_id = $1::uuid AND v.deleted_at IS NULL
        """
}
