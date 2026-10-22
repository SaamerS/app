import AppKit
import Foundation
import Observation
import SwiftData
import BindersKit

/// What `TeamNotes.checkAgainstDatabase` found: this Mac's own notes the database had, and how many it had filed elsewhere,
/// without the agent's mark the note has here, or as someone else's.
struct TeamNotesCheck: Equatable {
    var notes = 0
    /// The shared binders' folders the database didn't have as this Mac has them.
    var folders = 0
    var misfiled = 0
    var unmarked = 0
    var claimed = 0
    /// This Mac's own notes the database had deleted by nobody but this member, put back under their own ids (lane DB9).
    var putBack = 0
}

/// Who else is in one shared note now (lane DB10): what a note's page watches.
@MainActor
@Observable
final class TeamNotePresence {
    var rows: [TeamPresenceRow]

    init(rows: [TeamPresenceRow]) {
        self.rows = rows
    }
}

/// Notes on the team database (lane DB3): the notes, folders and Distill records of the binders shared through it, and who
/// is in a note, on this Mac. TeamBoard runs it beside the boards, on the same connection and feed:
/// - going: a note made or moved into a shared binder is shared once (`create_note`); typing, an agent's write over MCP, a
///   restore, a property, a move or a delete becomes a change of its Automerge document (TeamNoteEngine) or of its row;
/// - coming: a teammate's notes, changes, versions, folders, distills and presence, into this Mac's copy, attributed;
/// - the note page says who else is in it, and the Work bar who's reviewing a proposal.
@MainActor
@Observable
final class TeamNotes {
    @ObservationIgnored unowned let board: TeamBoard
    @ObservationIgnored private(set) var engine: TeamNoteEngine?
    /// Who else is in each shared note now, by note. Watched one note at a time (`inNote`, lane DB10), so someone coming
    /// into one note doesn't draw every open note again.
    @ObservationIgnored var presence: [UUID: [TeamPresenceRow]] = [:] {
        didSet {
            for note in Set(oldValue.keys).union(presence.keys) where oldValue[note] != presence[note] {
                inNote(note).rows = presence[note] ?? []
            }
        }
    }
    @ObservationIgnored private var presenceByNote: [UUID: TeamNotePresence] = [:]

    /// Who's in one note, to watch.
    func inNote(_ note: UUID) -> TeamNotePresence {
        if let known = presenceByNote[note] { return known }
        let made = TeamNotePresence(rows: presence[note] ?? [])
        presenceByNote[note] = made
        return made
    }
    /// Bumped when a note's versions change, for the History sheet.
    var revision = 0

    /// For the self-tests: how long typing gathers before it's a change, and how long someone counts as in a note.
    @ObservationIgnored var gather: Duration = .milliseconds(750)
    @ObservationIgnored var presenceLasts: TimeInterval = TeamPresenceRow.lasts

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var sweeping: Task<Void, Never>?
    /// What the next sweep looks at (lane DB10): every note at first, then the notes saves named since, and whether a
    /// note of the shared binders was deleted.
    @ObservationIgnored private var dirtyAll = true
    @ObservationIgnored private var dirty: Set<UUID> = []
    @ObservationIgnored private var dirtyGone = false
    /// Notes whose rows the feed brought without their documents and couldn't be read whole then (lane DB10).
    @ObservationIgnored private var unreadRows: Set<UUID> = []
    /// Notes the team deleted or took away, which this Mac then removed: not deletions of its own.
    @ObservationIgnored private var removedByTeam: Set<UUID> = []
    /// Notes deleted here lately, by when: one that comes back (Undo) goes back to the team.
    @ObservationIgnored private var deletedHere: [UUID: Date] = [:]
    /// Notes open on this Mac, how many times (the note page, a pop-out), and the proposal being reviewed in each.
    @ObservationIgnored var open: [UUID: Int] = [:]
    @ObservationIgnored var reviewing: [UUID: UUID] = [:]
    /// Folders the team deleted, which this Mac then removed: not deletions of its own.
    @ObservationIgnored var removedFolders: Set<UUID> = []
    @ObservationIgnored private var lastBeat = Date.distantPast
    /// The last note, folder and distill changes the database turned down, and why: for the self-tests and for looking into a
    /// problem.
    @ObservationIgnored private(set) var turnedDown: [String] = []
    /// While a folder team moves over: this Mac's notes aren't shared one by one meanwhile (the move brings them).
    @ObservationIgnored var moving = false
    @ObservationIgnored var folders = TeamNotesFolderState()
    @ObservationIgnored var applyingDistills = false
    /// The check against the database (`checkAgainstDatabase`) is running, and when it last began (one that couldn't read
    /// the database tries again a minute later).
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var lastCheck = Date.distantPast
    /// What the last check against the database found and sent, for the self-tests and for looking into a problem.
    @ObservationIgnored private(set) var checked = TeamNotesCheck()
    /// Notes the team had deleted that this Mac shared again (lane DB9): left out, the ones unchanged here gone, the ones
    /// with changes the team never had kept in General. Counted for the self-tests; said once they've all come in.
    @ObservationIgnored private(set) var leftOut = (dropped: 0, kept: 0)
    @ObservationIgnored private var leftOutToSay = (dropped: 0, kept: 0)
    @ObservationIgnored private var leftOutSaying: Task<Void, Never>?
    /// Notes whose answer came while a folder team moved over: left out once the move is done, so the team folder never
    /// hears of it.
    @ObservationIgnored private var leavingOut: Set<UUID> = []
    /// Notes the team deleted whose fate this Mac is deciding (`deletedForTeam`, `leaveOut`, which read the database): the
    /// feed's word on them waits for that.
    @ObservationIgnored private var deciding: Set<UUID> = []

    /// The app's own, while one runs: the editor, MCP, History and Distill reach it here.
    static weak var current: TeamNotes?

    init(board: TeamBoard) {
        self.board = board
    }

    var store: Store { Store.shared }
    var directory: TeamDirectory { board.directory }

    /// Where its files go: beside the outbox.
    private var folderURL: URL? { board.folder?.appendingPathComponent("notes", isDirectory: true) }

    // MARK: Starting

    func start(_ database: TeamDatabase) {
        guard engine == nil, let folderURL else { return }
        Self.current = self
        engine = TeamNoteEngine(database: database, folder: folderURL)
        // Note rows from the feed come without their documents; `apply` reads whole the few it makes documents from.
        database.lightNoteRows = true
        loadFolders()
        lastCheck = .distantPast
        DistillStore.shared.onWrite = { [weak self] file in self?.distillsChanged(file) }
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            // Cards and their timelines are the board's: a save of only those changes nothing here.
            guard !TaskCard.onlyBoards(note.userInfo) else { return }
            MainActor.assumeIsolated { self?.saved(note.userInfo) }
        })
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.tick()
            }
        }
    }

    func stop() async {
        for (note, _) in open { _ = try? await board.database?.call(.beInNote(note, here: false)) }
        timer?.cancel()
        sweeping?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        await engine?.saveDue(now: .distantFuture)
        engine?.flush()
        engine = nil
        presence = [:]
        if DistillStore.shared.onWrite != nil { DistillStore.shared.onWrite = nil }
        if Self.current === self { Self.current = nil }
    }

    /// Every 2 seconds: notes that are due go whole, documents are written, and who's here says so every 45 seconds. Once
    /// connected the first time, this Mac's own notes are checked against the database, once.
    private func tick() async {
        guard let engine else { return }
        await engine.saveDue()
        engine.writeDocuments()
        if !unreadRows.isEmpty, board.isConnected { await readUnreadRows() }
        if folders.checkedDatabase != true, board.isConnected, !moving, !checking, Date().timeIntervalSince(lastCheck) >= 60 {
            checking = true
            lastCheck = Date()
            await checkAgainstDatabase()
            checking = false
        }
        if Date().timeIntervalSince(lastBeat) >= TeamPresenceRow.heartbeat, board.isConnected {
            lastBeat = Date()
            for note in open.keys { await say(in: note) }
        }
        // Someone who went quiet goes from the line on their own.
        let now = Date()
        for (note, rows) in presence where rows.contains(where: { !$0.isHere(at: now, lasts: presenceLasts) }) {
            presence[note] = rows.filter { $0.isHere(at: now, lasts: presenceLasts) }
        }
    }

    // MARK: Which notes

    /// Whether a note goes through the team database: in a shared binder, and not one made from what you said.
    func covers(_ note: NoteItem) -> Bool {
        engine != nil && board.covers(note.binderID) && !note.staysUnshared
    }

    /// Whether the team has this note: it's shared through the database on this Mac.
    func shares(_ note: UUID) -> Bool { engine?.knows(note) ?? false }

    private func notes(in binder: UUID) -> [NoteItem] {
        (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binder }))) ?? []
    }

    // MARK: Names

    /// What travels with a note, with names as the team has them.
    func teamProps(of note: NoteItem) -> [String: TeamJSON] {
        let directory = self.directory
        func team(_ name: String?) -> String? { name.flatMap { directory.teamName($0) ?? $0 } }
        return TeamNoteProps(properties: note.properties,
                             mark: TeamNoteMark(madeBy: team(note.madeBy), editedBy: team(note.editedBy), editedAt: note.editedAt)).values
    }

    /// The team's props onto a note here, with names as this Mac has them. `keepingMark`: all but the agent's mark.
    private func take(_ props: [String: TeamJSON], into note: NoteItem, keepingMark: Bool = false) {
        let read = TeamNoteProps(values: props)
        let directory = self.directory
        func local(_ name: String?) -> String? { name.flatMap { directory.localName($0) ?? $0 } }
        if note.properties != read.properties { note.properties = read.properties }
        guard !keepingMark else { return }
        let madeBy = local(read.mark.madeBy), editedBy = local(read.mark.editedBy)
        if note.madeBy != madeBy { note.madeBy = madeBy }
        if note.editedBy != editedBy { note.editedBy = editedBy }
        if note.editedAt != read.mark.editedAt { note.editedAt = read.mark.editedAt }
    }

    /// Who made a change, as a note's history and Distill say it: a teammate, or an agent and whose.
    func author(member: UUID?, agent: UUID?) -> NoteAuthor {
        if let agent {
            let directory = self.directory
            if let known = directory.agents[agent] {
                // Yours by the name it goes by here; a teammate's by its own name, with whose it is beside it.
                if directory.isMine(known) { return .agent(directory.name(of: known), owner: BoardActor.you.name) }
                let owner = directory.ownerName(of: known)
                return .agent(TeamNames.local(known.name, owner: owner), owner: owner)
            }
            if let name = directory.local[agent] { return .agent(name) }
            return .agent("An agent", owner: directory.memberName(member))
        }
        if let member, member == directory.me { return .you }
        return .teammate(directory.memberName(member) ?? "A teammate")
    }

    // MARK: Going: this Mac's notes

    /// The notes typed in a moment ago, looked at once the typing pauses (the editor says so: its text changed).
    func typed(_ note: UUID) { sweepSoon([note]) }

    /// What a save of the library changed, for the next sweep (lane DB10): the notes it inserted or updated, by id; a
    /// deleted note, whose id the save doesn't say, has the sweep look for notes gone; a folder or binder, every note. A
    /// save that changed nothing, or only what the team's notes don't hold, sweeps nothing.
    private func saved(_ info: [AnyHashable: Any]?) {
        if info?[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] != nil { return sweepSoon() }
        func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] { info?[key.rawValue] as? [PersistentIdentifier] ?? [] }
        let inserted = ids(.insertedIdentifiers), updated = ids(.updatedIdentifiers), deleted = ids(.deletedIdentifiers)
        let all = inserted + updated + deleted
        guard !all.isEmpty else { return }
        if all.contains(where: { ["FolderRecord", "BinderRecord"].contains($0.entityName) }) { return sweepSoon() }
        var notes: Set<UUID> = []
        for id in inserted + updated where id.entityName == "NoteItem" {
            // Saved by a context of its own: which note isn't known here, so every note is looked at.
            guard let note: NoteItem = store.context.registeredModel(for: id) else { return sweepSoon() }
            notes.insert(note.id)
        }
        let gone = deleted.contains { $0.entityName == "NoteItem" }
        guard !notes.isEmpty || gone else { return }
        sweepSoon(notes, gone: gone)
    }

    /// Every note of the shared binders is looked at, soon.
    func sweepSoon() {
        dirtyAll = true
        scheduleSweep()
    }

    /// These notes are looked at soon, and with `gone`, whether any note of the shared binders went.
    func sweepSoon(_ notes: Set<UUID>, gone: Bool = false) {
        dirty.formUnion(notes)
        if gone { dirtyGone = true }
        scheduleSweep()
    }

    private func scheduleSweep(after wait: Duration? = nil) {
        sweeping?.cancel()
        let delay = wait ?? gather
        sweeping = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.sweepDirty()
        }
    }

    /// What saves named since the last sweep, against what the team has; every note when one named a folder or a binder,
    /// or nothing said which (at the start, a binder shared).
    private func sweepDirty() {
        guard engine != nil, !moving, store.canSave else { return }
        let full = dirtyAll, notes = dirty, gone = dirtyGone
        dirtyAll = false
        dirty = []
        dirtyGone = false
        // A binder of hundreds of notes shared at once goes a few notes at a time, so the window keeps answering: the rest
        // are looked at again a moment later.
        let left = full ? sweep(sharingAtMost: Self.sharedPerSweep) : sweep(only: notes, gone: gone, sharingAtMost: Self.sharedPerSweep)
        guard !left.isEmpty else { return }
        dirty.formUnion(left)
        scheduleSweep(after: .milliseconds(20))
    }

    /// How many new notes one sweep shares at most when it isn't asked for directly: each makes its document.
    static let sharedPerSweep = 8

    /// Every note of the shared binders, against what the team has: a new one is shared, a change is captured (as yours),
    /// a move is told, a deletion goes; folders the same; then what's done is written. One fetch of notes and one of
    /// folders per binder (lane DB10).
    func sweep() {
        sweep(sharingAtMost: .max)
    }

    /// The whole sweep, sharing at most `limit` new notes; returns the ones left to share.
    @discardableResult
    private func sweep(sharingAtMost limit: Int) -> Set<UUID> {
        guard let engine, !moving, store.canSave else { return [] }
        TeamPerf.shared.count { $0.sweeps += 1; $0.fullSweeps += 1 }
        dirtyAll = false
        dirty = []
        dirtyGone = false
        deletedHere = deletedHere.filter { Date().timeIntervalSince($0.value) < 3600 }
        sweepFolders()
        let shared = board.sharedBinders
        var seen: Set<UUID> = []
        var sharing = 0
        var left: Set<UUID> = []
        for binder in shared {
            let folders = folderIDs(in: binder)
            let list = notes(in: binder)
            TeamPerf.shared.count { $0.notesSwept += list.count }
            for note in list where !note.staysUnshared {
                seen.insert(note.id)
                if engine.state(note.id) == nil {
                    guard sharing < limit else {
                        left.insert(note.id)
                        continue
                    }
                    sharing += 1
                }
                sweep(note, in: binder, folders: folders, engine: engine)
            }
        }
        // Gone from the shared binders here: deleted, or moved to a binder of this Mac's own.
        for (id, state) in engine.states where !seen.contains(id) && !state.deleted { leftShared(id, shared: shared, engine: engine) }
        engine.save()
        return left
    }

    /// The notes a save named (lane DB10), each as the whole sweep would look at it, and with `gone` the notes this Mac
    /// shares that aren't in a shared binder any more.
    private func sweep(only ids: Set<UUID>, gone: Bool, sharingAtMost limit: Int = .max) -> Set<UUID> {
        guard let engine else { return [] }
        TeamPerf.shared.count { $0.sweeps += 1; $0.notesSwept += ids.count }
        deletedHere = deletedHere.filter { Date().timeIntervalSince($0.value) < 3600 }
        let shared = board.sharedBinders
        var folders: [UUID: Set<UUID>] = [:]
        func inFolders(_ binder: UUID) -> Set<UUID> {
            if let known = folders[binder] { return known }
            let known = folderIDs(in: binder)
            folders[binder] = known
            return known
        }
        let wanted = Array(ids)
        let list = ids.isEmpty ? [] : ((try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { wanted.contains($0.id) }))) ?? [])
        var found: Set<UUID> = []
        var sharing = 0
        var left: Set<UUID> = []
        for note in list {
            found.insert(note.id)
            if let binder = note.binderID, shared.contains(binder), !note.staysUnshared {
                if engine.state(note.id) == nil {
                    guard sharing < limit else {
                        left.insert(note.id)
                        continue
                    }
                    sharing += 1
                }
                sweep(note, in: binder, folders: inFolders(binder), engine: engine)
            } else if let state = engine.state(note.id), !state.deleted {
                leftShared(note.id, shared: shared, engine: engine)
            }
        }
        // Named and not found: deleted since.
        for id in ids where !found.contains(id) {
            if let state = engine.state(id), !state.deleted { leftShared(id, shared: shared, engine: engine) }
        }
        if gone {
            var seen: Set<UUID> = []
            for binder in shared {
                for note in notes(in: binder) where !note.staysUnshared { seen.insert(note.id) }
            }
            for (id, state) in engine.states where !seen.contains(id) && !state.deleted { leftShared(id, shared: shared, engine: engine) }
        }
        engine.save()
        return left
    }

    /// One note of a shared binder: shared when the team doesn't have it, else where it's filed and what changed in it go.
    private func sweep(_ note: NoteItem, in binder: UUID, folders: Set<UUID>, engine: TeamNoteEngine) {
        guard let state = engine.state(note.id) else {
            share(note, folders: folders)
            return
        }
        if state.deleted { return }
        let folder = teamFolder(of: note, agreed: state.binder == binder ? state.folder : nil, folders: folders)
        if state.binder != binder || state.folder != folder { engine.moved(note.id, binder: binder, folder: folder) }
        capture(note, by: .person)
    }

    /// A note this Mac shares that isn't in a shared binder here any more: deleted, or moved to a binder of this Mac's own.
    private func leftShared(_ id: UUID, shared: Set<UUID>, engine: TeamNoteEngine) {
        if removedByTeam.remove(id) != nil { return engine.forget(id) }
        let note = store.note(id)
        if let note, !note.staysUnshared, shared.contains(note.binderID ?? UUID()) { return }
        // In a binder the team folder this Mac still syncs keeps for now (an earlier Binders shared it both ways): the
        // folder's until the move, which brings it over. Nothing of it is deleted for the team.
        if let note, board.keptByFolder(note.binderID) { return }
        if note == nil { deletedHere[id] = Date() }
        // The team's copy goes; a note moved to a binder of this Mac's own stays here, its own.
        engine.deleted(id)
    }

    /// The folders of one binder, by id: what a note's folder is checked against, read once for every note in it.
    private func folderIDs(in binder: UUID) -> Set<UUID> {
        Set(store.folders(in: binder).map(\.id))
    }

    /// A note of this Mac's in a shared binder goes to the team, once. One deleted here a moment ago and put back (Undo)
    /// comes back for the team.
    /// `folders`: the binder's folders, when the caller has read them (the sweep).
    func share(_ note: NoteItem, by author: TeamNoteAuthor = .person, fields: [String: TeamJSON]? = nil, operation: UUID = UUID(),
               folders: Set<UUID>? = nil) {
        guard let engine, let binder = note.binderID, !note.staysUnshared else { return }
        let undelete = deletedHere.removeValue(forKey: note.id).map { Date().timeIntervalSince($0) < 3600 } ?? false
        // A note an agent of yours wrote is its, from its first version; one from a team folder is whoever wrote it there.
        let madeBy = fields == nil ? note.madeBy.flatMap { board.agentID(for: BoardActor(name: $0, kind: .agent)) } : nil
        let folder = folders.map { known in note.folderID.flatMap { known.contains($0) ? $0 : nil } } ?? store.shownFolder(note.folderID, in: binder)
        engine.share(note.id, binder: binder, folder: folder, text: note.text, props: teamProps(of: note),
                     fields: fields ?? ["title": .string(note.title), "created_at": TeamJSON(note.createdAt)],
                     by: madeBy.map { TeamNoteAuthor(agent: $0) } ?? author, operation: operation, undelete: undelete)
        sendDistills(of: note.id)
    }

    // MARK: Moving a folder team over

    enum MoveProblem: LocalizedError {
        case notConnected, noFolderTeam

        var errorDescription: String? {
            switch self {
            case .notConnected: "This Mac isn't connected to the team database yet. Try again once it says Connected."
            case .noFolderTeam: "This Mac isn't in a team folder, so there's nothing to move."
            }
        }
    }

    /// Move This Team to a Database: after one last sync, everything the team folder shares comes in once (TeamMove), then
    /// folder sync stops on this Mac, leaving the folder as it is. Binders made here go as Share does, their boards with
    /// them. Returns what came in.
    func moveFolderTeam(from sync: TeamSyncService) async throws -> TeamMove.Summary {
        guard sync.isConfigured else { throw MoveProblem.noFolderTeam }
        guard let engine, let database = board.database, board.isConnected, let member = directory.me, let server = board.server else {
            throw MoveProblem.notConnected
        }
        moving = true
        defer { moving = false }
        MarkdownEditor.flushAll()
        await sync.syncNow()
        let directory = self.directory
        let move = TeamMove(store: store, database: database, engine: engine, directory: directory, me: sync.me, member: member, key: server.key,
                            teamName: { directory.teamName($0) ?? $0 },
                            shareBoard: { [weak board] binder in board?.share(binder, everyone: true, with: []) },
                            shareNote: { [weak self] note, fields, operation in self?.share(note, fields: fields, operation: operation) },
                            props: { [weak self] note in self?.teamProps(of: note) ?? [:] })
        folders.movedAs = sync.me.id
        saveFolders()
        // The binders the database already had, which it left alone on this Mac while the team folder had them
        // (TeamBoard.sharedBinders, lane DB9): read whole once the move is done.
        let leftAlone = move.binders().filter { $0.teamDatabaseKey == server.key }.map(\.id)
        let summary = await move.run()
        await sync.stopForMove(TeamMoveMarker(database: server.database, host: server.host, by: sync.me, at: Date()))
        move.finish()
        board.sharedChanged()
        moving = false
        for id in leavingOut.sorted(by: { $0.uuidString < $1.uuidString }) {
            leavingOut.remove(id)
            if let note = store.note(id), engine.state(id)?.deleted == true { await leaveOut(note) }
        }
        readWholeOnceSent(leftAlone)
        sweepSoon()
        return summary
    }

    /// Binders this Mac reads whole once what it sent has gone (the move's notes in first, so what's read is everything):
    /// kept in the board's list of binders still to read, so a Mac that quits first reads them when it next connects.
    private func readWholeOnceSent(_ binders: [UUID]) {
        guard !binders.isEmpty else { return }
        for id in binders where !board.state.readWhole.contains(id) { board.state.readWhole.append(id) }
        board.saveState()
        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(600)
            while let database = self?.board.database, database.waiting > 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(500)) }
            guard let self, let database = self.board.database, database.status.isConnected else { return }
            await self.board.readWholeWhatsLeft(database)
        }
    }

    // MARK: Checking against the database (lane DB6)

    /// Once per database, the first time this build is connected to it: each of this Mac's own notes the team has (not a
    /// teammate's copy), as the database has it now, against the note here, which is what counts. Where it's filed, and an
    /// agent's mark on it, go back to the team when the database says otherwise: the engine takes the database's word, so
    /// the sweep sends the difference, as for any change made here. A note brought in from the team folder as this
    /// member's that the database has as someone else's is claimed (create_note's claim). Nothing on this Mac changes.
    /// What an earlier Binders may have left wrong in the database is put right this way, without a migration.
    func checkAgainstDatabase() async {
        guard let engine, let database = board.database, board.isConnected, let me = directory.me else { return }
        let ids = engine.states.compactMap { id, state -> UUID? in
            guard !state.deleted, let note = store.note(id), !note.isTeamCopy, covers(note) else { return nil }
            return id
        }.sorted { $0.uuidString < $1.uuidString }
        var rows: [TeamNoteRow] = []
        var start = 0
        while start < ids.count {
            guard let page = try? await database.rows(.notes, ids: Array(ids[start..<min(start + 200, ids.count)])) else { return }
            rows += page.compactMap(TeamNoteRow.init(row:))
            start += 200
        }
        var found = TeamNotesCheck(notes: rows.count)
        // The shared binders' folders: one the database doesn't have as this Mac has it (missing, deleted, renamed or
        // elsewhere) goes again from the sweep, before the notes filed in it.
        for binder in board.sharedBinders {
            guard let list = try? await database.rows(.folders, binder: binder) else { return }
            let there = Dictionary(list.compactMap(TeamFolderRow.init(row:)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for folder in store.folders(in: binder) {
                let row = there[folder.id]
                let parent = store.shownFolder(folder.parentID, in: binder)
                if row == nil || row?.deletedAt != nil || row?.name != folder.name || row?.parentID != parent {
                    found.folders += 1
                    folders.shadows[folder.id] = nil
                }
            }
        }
        let folderMember = folders.movedAs ?? AppSettings.shared.teamMemberID
        // One of this Mac's own notes the database has deleted, by nobody but this member and never on this Mac (what an
        // earlier Binders could have left): back for the team under its own id (lane DB9), as when the feed brings it.
        for row in rows where row.deletedAt != nil {
            guard let note = store.note(row.id), !note.isTeamCopy, engine.knows(row.id), deletedHere[row.id] == nil, !engine.puttingBack(row.id) else { continue }
            if await deletedOnlyByMe(row.id) {
                found.putBack += 1
                putBack(note)
            }
        }
        for row in rows where row.deletedAt == nil {
            guard let note = store.note(row.id), !note.isTeamCopy, engine.knows(row.id) else { continue }
            if row.binderID != note.binderID || row.folderID != teamFolder(of: note, agreed: row.folderID) {
                found.misfiled += 1
                engine.take(row: row)
            }
            if let document = await engine.document(row.id), let state = engine.state(row.id) {
                let there = TeamNoteProps(values: document.props).mark, here = TeamNoteProps(values: teamProps(of: note)).mark
                if there.madeBy != here.madeBy || there.editedBy != here.editedBy {
                    found.unmarked += 1
                    engine.agree(row.id, text: state.text, props: document.props)
                }
            }
            if row.createdBy != me, let imported = row.importedAuthor, !imported.id.isEmpty, imported.id == folderMember {
                found.claimed += 1
                engine.claim(row.id, binder: row.binderID, importedAuthor: imported, as: folderMember, member: me)
            }
        }
        checked = found
        folders.checkedDatabase = true
        saveFolders()
        engine.save()
        sweepSoon()
    }

    /// A note changed here, as its author made it: what differs from the team's copy goes as one change. Agents' writes over
    /// MCP come here at once (`InboxCommands`), so they're the agent's; anything else is found by the sweep, as yours.
    func capture(_ note: NoteItem, by author: TeamNoteAuthor) {
        guard let engine, covers(note) else { return }
        guard engine.knows(note.id) else { return share(note, by: author) }
        let props = board.knowsItself ? teamProps(of: note) : (engine.state(note.id)?.props ?? [:])
        guard engine.edited(note.id, text: note.text, props: props, by: author) else { return }
        // Typed on top of a teammate's change the note didn't show yet: the note takes both now, so nothing reads the
        // teammate's words as taken out.
        if let current = engine.current(note.id), current.text != note.text {
            let last = engine.history(note.id).first
            takeCurrent(note.id, by: last.map { self.author(member: $0.memberID, agent: $0.agentID) } ?? .teammate("A teammate"))
        }
    }

    /// An agent's write to a note over MCP, captured as the agent's at once (`InboxCommands`).
    func captured(_ note: NoteItem, byAgent name: String) {
        guard covers(note) else { return }
        let agent = board.agentID(for: BoardActor(name: name, kind: .agent))
        capture(note, by: TeamNoteAuthor(agent: agent))
    }

    // MARK: Coming: the team's notes

    /// The notes part of one update from the feed: folders first (so notes find theirs), notes made, moved or deleted,
    /// changes applied (anything typed here captured first, so both keep their words), versions, who's in which note, and
    /// Distill's records. Rows of binders newly shared are left to the whole read.
    func apply(_ update: TeamUpdate) async {
        guard let engine else { return }
        let added = update.bindersAdded
        func inAdded(_ row: TeamRow) -> Bool { row["binder_id"]?.uuid.map(added.contains) ?? false }
        applyFolders((update.rows[.folders] ?? []).filter { !inAdded($0) })
        let changes = (update.rows[.noteChanges] ?? []).filter { !inAdded($0) }.compactMap(TeamNoteChangeRow.init(row:))
        // The note rows someone other than this Mac's member changed in this update (the feed says who); unknown until this
        // Mac knows who it is.
        let me = directory.me
        let byTeammates = Set(update.changes.filter { $0.table == .notes && $0.memberID != me }.map(\.rowID))
        let noteRows = await wholeRows((update.rows[.notes] ?? []).filter { !inAdded($0) })
        let changesByNote = Dictionary(grouping: changes, by: \.noteID)
        for (index, row) in noteRows.compactMap(TeamNoteRow.init(row:)).enumerated() {
            if index > 0, index.isMultiple(of: Self.notesPerTurn) { await Task.yield() }
            applyNote(row, changes: changesByNote[row.id] ?? [], byTeammate: me == nil ? nil : byTeammates.contains(row.id))
        }
        await applyChanges(changes.filter { engine.knows($0.noteID) })
        engine.take(versions: (update.rows[.noteVersions] ?? []).filter { !inAdded($0) }.compactMap(TeamNoteVersionRow.init(row:)))
        if !(update.rows[.noteVersions] ?? []).isEmpty { revision += 1 }
        applyPresence((update.rows[.notePresence] ?? []).compactMap(TeamPresenceRow.init(row:)))
        applyDistills(distills: (update.rows[.distills] ?? []).filter { !inAdded($0) }, items: (update.rows[.distillItems] ?? []).filter { !inAdded($0) })
        // A note that's no longer in a binder this member sees goes from here.
        for gone in update.gone where gone.table == .notes {
            if let note = store.note(gone.id), engine.knows(gone.id) { remove(note) }
            engine.forget(gone.id)
        }
        saveIfChanged()
    }

    /// How many notes are taken from the feed, or a binder read whole, between turns for the window (lane DB10).
    static let notesPerTurn = 20

    /// A binder's notes and changes as read from the database, decoded off the main thread.
    nonisolated private static func decoded(notes: [TeamRow], changes: [TeamRow]) async -> ([TeamNoteRow], [TeamNoteChangeRow]) {
        await Task.detached(priority: .userInitiated) {
            (notes.compactMap(TeamNoteRow.init(row:)), changes.compactMap(TeamNoteChangeRow.init(row:)))
        }.value
    }

    /// The library saved only when the team's changes changed something in it (lane DB10): a save that changes nothing
    /// still tells everyone who listens, this sweep among them.
    func saveIfChanged() {
        if store.context.hasChanges { store.save() }
    }

    /// Note rows the feed read without their documents (lane DB10), read whole for the notes this Mac doesn't share yet,
    /// whose documents it makes from them; checked again after each read, as a note can stop being shared meanwhile. One
    /// that can't be read now is left out and read whole later (`readUnreadRows`), so it's never made from nothing.
    private func wholeRows(_ rows: [TeamRow]) async -> [TeamRow] {
        guard let engine else { return rows }
        func wanted(_ rows: [TeamRow]) -> [UUID] {
            rows.compactMap { row in
                guard !TeamNoteRow.isWhole(row), row.deletedAt == nil, let id = row.rowID, !engine.knows(id) else { return nil }
                return id
            }
        }
        var rows = rows
        for _ in 0..<3 {
            let ids = wanted(rows)
            guard !ids.isEmpty else { return rows }
            guard let database = board.database, let whole = try? await database.rows(.notes, ids: ids) else { break }
            let byID = Dictionary(whole.compactMap { row in row.rowID.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
            rows = rows.map { row in row.rowID.flatMap { byID[$0] } ?? row }
            // Not there any more for this member: nothing to make.
            let missing = Set(ids).subtracting(byID.keys)
            rows.removeAll { row in row.rowID.map(missing.contains) ?? false }
        }
        let left = Set(wanted(rows))
        guard !left.isEmpty else { return rows }
        unreadRows.formUnion(left)
        return rows.filter { row in !(row.rowID.map(left.contains) ?? false) }
    }

    /// Notes whose rows couldn't be read whole when they came (lane DB10): read now, with every change of each, and taken
    /// as the feed would have given them.
    private func readUnreadRows() async {
        guard let engine, let database = board.database else { return }
        let ids = Array(unreadRows)
        guard let rows = try? await database.rows(.notes, ids: ids) else { return }
        unreadRows.subtract(ids)
        for row in rows.compactMap(TeamNoteRow.init(row:)) where !engine.knows(row.id) {
            guard let list = try? await database.json(TeamQueries.noteChanges, [row.id.uuidString.lowercased()]).array else {
                unreadRows.insert(row.id)
                continue
            }
            applyNote(row, changes: list.compactMap { $0.object.flatMap(TeamNoteChangeRow.init(row:)) }, byTeammate: nil)
        }
        saveIfChanged()
    }

    /// A binder read whole (newly shared with this Mac, or read again): its folders, notes with their changes, versions,
    /// who's in its notes, and its distills, as the database has them now.
    func readWhole(_ binder: UUID, rows: [TeamTable: [TeamRow]]) async {
        guard engine != nil else { return }
        applyFolders(rows[.folders] ?? [], whole: binder)
        // Read off the main thread, and taken a few at a time with the window answering between (lane DB10).
        let (noteRows, changes) = await Self.decoded(notes: rows[.notes] ?? [], changes: rows[.noteChanges] ?? [])
        let byNote = Dictionary(grouping: changes, by: \.noteID)
        for (index, row) in noteRows.enumerated() {
            if index > 0, index.isMultiple(of: Self.notesPerTurn) { await Task.yield() }
            applyNote(row, changes: byNote[row.id] ?? [], byTeammate: nil)
        }
        guard let engine else { return }
        await applyChanges(changes.filter { engine.knows($0.noteID) })
        engine.take(versions: (rows[.noteVersions] ?? []).compactMap(TeamNoteVersionRow.init(row:)))
        revision += 1
        applyPresence((rows[.notePresence] ?? []).compactMap(TeamPresenceRow.init(row:)))
        applyDistills(distills: rows[.distills] ?? [], items: rows[.distillItems] ?? [])
        saveIfChanged()
    }

    /// A note's row: made here when it's new to this Mac (a teammate's, or one brought in), moved to its binder and folder,
    /// or removed when the team deleted it. A note this Mac already had (the same note from a team folder) keeps what was
    /// written here since it was brought in: merged, never replaced. `byTeammate`: whether someone other than this Mac's
    /// member changed the row in this update; nil when that isn't known (a binder read whole).
    ///
    /// One of this Mac's own notes (not a teammate's copy) is never moved to another folder or binder, made a teammate's,
    /// or removed here because of a row only this member wrote (lane DB6): that's this Mac's own change coming back, or
    /// what an earlier Binders wrote wrong, and this Mac already has the note as it is. The row is still the database's
    /// word, so the sweep tells the team where the note is here. A teammate's change still moves or removes it.
    private func applyNote(_ row: TeamNoteRow, changes: [TeamNoteChangeRow], byTeammate: Bool?) {
        guard let engine else { return }
        let existing = store.note(row.id)
        let own = existing.map { !$0.isTeamCopy } ?? false
        // Whether the note here follows the row: a teammate's change does; read whole, a teammate's copy does.
        let follows = byTeammate ?? !own
        if row.deletedAt != nil {
            // Deleted here and put back with Undo since: it goes back to the team (the sweep), not away again.
            if deletedHere[row.id] != nil, existing != nil { return }
            // In a binder the team folder this Mac still syncs keeps for now: the folder's to say (TeamBoard.keptByFolder).
            if let note = existing, board.keptByFolder(note.binderID) { return }
            // Being put back already (Undo, or below), or being decided on (`deletedForTeam`): this deletion is what that
            // answers. One older than what the database last said of the note is old news.
            if engine.puttingBack(row.id) || deciding.contains(row.id) { return }
            if let known = engine.rows[row.id]?.updatedAt, let at = row.updatedAt, at < known { return }
            if let note = existing, engine.knows(row.id), own, !follows {
                // Deleted in the database by nobody but this member, while it's here: the echo of a deletion this Mac has
                // undone since (the database answered with a newer row), or one an earlier Binders made. That one goes back
                // to the team under its own id, as Undo puts a note back, ahead of anything that waits to go for it (lane
                // DB9: before, it waited for those to be turned down, then kept the note aside as a new note).
                let newer = engine.rows[row.id]?.updatedAt.map { known in row.updatedAt.map { $0 < known } ?? true } ?? false
                guard !newer else { return }
                putBack(note)
                return
            }
            if let note = existing, engine.knows(row.id) || (!own && note.binderID == row.binderID && follows && board.covers(row.binderID)) {
                if engine.knows(row.id), engine.awaitsAnswer(row.id) || engine.database.queued.contains(where: { $0.call.note == row.id && decidesLater($0.call) }) {
                    // An edit made here waits to go or for its answer, or this Mac is sharing the note: the database's answer
                    // to it says what becomes of the note here (`settle`), knowing what the team last had.
                    engine.take(row: row)
                    return
                }
                remove(note)
            }
            engine.forget(row.id)
            return
        }
        guard board.covers(row.binderID) else { return }
        // Deleted here a moment ago, and this row is from before that (the echo of its own making): it stays deleted; the
        // deletion is on its way. A teammate putting it back later is newer, and comes.
        if existing == nil, let deleted = deletedHere[row.id], (row.updatedAt ?? .distantPast) <= deleted.addingTimeInterval(2) { return }
        if !engine.knows(row.id) {
            guard let came = engine.adopt(row, changes: changes) else { return }
            let note: NoteItem
            if let existing {
                note = existing
                // The same note from a team folder, or one of this Mac's the team had before this Mac shared it: what was
                // written here since it was brought in (its words, its properties, an agent's mark) goes in too, merged
                // from the version it was brought in as, before anything else looks at it. Then the note is the merged
                // document, so the team's newer words aren't taken back either.
                let brought = engine.me.map { engine.bringIn(row.id, text: existing.text, props: teamProps(of: existing), member: $0) } ?? false
                let last = engine.history(row.id).first
                takeCurrent(row.id, by: brought ? .you : last.map { author(member: $0.memberID, agent: $0.agentID) } ?? .teammate("A teammate"))
                if own {
                    // One of this Mac's own: where it's filed, and that it's this member's, stay as they are here. The sweep
                    // tells the team where it is when the row says otherwise.
                    if let updated = row.updatedAt, updated > note.updatedAt { note.updatedAt = updated }
                    return
                }
            } else {
                note = NoteItem(text: came.text)
                note.id = row.id
                note.createdAt = row.createdAt ?? Date()
                store.context.insert(note)
                take(came.props, into: note)
            }
            note.binderID = row.binderID
            // In its folder, which may not have arrived here yet: it shows at the top of its binder until it does.
            note.folderID = row.folderID
            let mine = row.createdBy != nil && row.createdBy == directory.me
            note.isTeamCopy = !mine
            note.teamAuthorID = mine ? nil : row.createdBy?.uuidString.lowercased()
            note.teamAuthorName = mine ? nil : (directory.memberName(row.createdBy) ?? row.importedAuthor?.name ?? "A teammate")
            note.updatedAt = row.updatedAt ?? Date()
            return
        }
        guard let note = existing else { return }
        // Moved by a teammate: to its binder and folder here too, unless it was moved here since the database last said
        // (that move goes, from the sweep) or a move made here still waits to go.
        let agreed = engine.state(row.id)
        let movedHere = note.binderID != agreed?.binder || teamFolder(of: note, agreed: agreed?.folder) != agreed?.folder
        let waiting = engine.database.queued.contains { $0.call.function == "move_note" && $0.call.note == row.id }
        engine.take(row: row)
        guard !movedHere, !waiting, follows else { return }
        if note.binderID != row.binderID { note.binderID = row.binderID }
        // In its folder, which may not have arrived here yet: it shows at the top of its binder until it does.
        if note.folderID != row.folderID { note.folderID = row.folderID }
    }

    /// The folder a note is filed in, as the team has it: its folder here, or the one the team last said it's in when that
    /// folder hasn't arrived on this Mac yet (the note shows at the top of its binder until it does); else the top.
    func teamFolder(of note: NoteItem, agreed: UUID?) -> UUID? {
        if let folder = note.folderID, folder == agreed { return folder }
        return store.shownFolder(note.folderID, in: note.binderID)
    }

    /// The same, with its binder's folders read already (lane DB10: the sweep reads them once per binder).
    func teamFolder(of note: NoteItem, agreed: UUID?, folders: Set<UUID>) -> UUID? {
        if let folder = note.folderID, folder == agreed { return folder }
        return note.folderID.flatMap { folders.contains($0) ? $0 : nil }
    }

    /// A teammate's changes: editors hand over their typing, what was typed here goes first (so it's merged, never
    /// overwritten), then each note takes its document's text, attributed to whoever made the change.
    private func applyChanges(_ changes: [TeamNoteChangeRow]) async {
        guard let engine, !changes.isEmpty else { return }
        let ids = Array(Set(changes.map(\.noteID)))
        MarkdownEditor.flushAll()
        // One fetch for them all (lane DB10).
        let here = (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        for (index, note) in here.enumerated() where covers(note) {
            if index > 0, index.isMultiple(of: Self.notesPerTurn * 5) { await Task.yield() }
            capture(note, by: .person)
        }
        let teamCopies = Set(here.filter(\.isTeamCopy).map(\.id)), found = Set(here.map(\.id))
        let touched = await engine.receive(changes)
        let me = directory.me
        let byNote = Dictionary(grouping: changes, by: \.noteID)
        // A note in a binder the team folder this Mac still syncs keeps for now: its document follows the team, the note
        // here doesn't until the move (TeamBoard.keptByFolder).
        let kept = Set(here.filter { board.keptByFolder($0.binderID) }.map(\.id))
        for id in touched where !kept.contains(id) {
            let its = byNote[id] ?? []
            let last = its.max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            // Changes only this member made, and not on this Mac (an earlier Binders): one of this Mac's own notes keeps its
            // agent's mark as it is here, which goes back to the team from the sweep (lane DB6). Its words are merged.
            let keepsMark = me != nil && its.allSatisfy { $0.memberID == me } && found.contains(id) && !teamCopies.contains(id)
            takeCurrent(id, by: author(member: last?.memberID, agent: last?.agentID), keepingMark: keepsMark)
        }
    }

    /// The note here takes its document's text and props, kept first in its history as it was, by whoever changed it.
    /// `keepingMark`: the agent's mark stays as it is here (the sweep sends it), the rest as the document has it.
    func takeCurrent(_ id: UUID, by author: NoteAuthor, keepingMark: Bool = false) {
        guard let engine, let note = store.note(id), let current = engine.current(id) else { return }
        if note.text != current.text {
            NoteHistory.willChange(note, to: current.text, always: true, by: author)
            note.text = current.text
            note.updatedAt = Date()
        }
        take(current.props, into: note, keepingMark: keepingMark)
        engine.agree(id, text: current.text, props: current.props)
    }

    /// The team deleted the note: it goes from here, its windows first.
    private func remove(_ note: NoteItem) {
        removedByTeam.insert(note.id)
        NotificationCenter.default.post(name: TeamSyncService.itemsWillBeRemoved, object: self, userInfo: ["ids": Set([note.id])])
        ScratchpadController.shared.noteWillBeDeleted(note)
        NotePopouts.shared.close(note.id)
        store.delete(note)
    }

    /// The team deleted a note this Mac had changed and not yet sent, and its words here differ from the team's last: what
    /// was written here stays, and the note comes back for the team under its own id, as Undo puts one back, with those
    /// words. Never a new note (lane DB9: one under a new id was shared again by every Mac that kept it aside).
    private func keepAside(_ note: NoteItem) {
        board.controller?.flowBar.toast("“\(note.title)” was deleted for the team after you changed it. It's back for the team, with your changes.",
                                        symbol: "arrow.uturn.backward", duration: 6)
        putBack(note)
    }

    /// One of this Mac's notes back for the team under its own id: what waits to go for it is taken back, the note goes as
    /// Undo sends one (`create_note` with `p_undelete`), then what differs here goes as one edit (TeamNoteEngine.settle).
    private func putBack(_ note: NoteItem) {
        guard let engine else { return }
        engine.withdrawWaiting(note.id)
        engine.forget(note.id)
        deletedHere[note.id] = Date()
        share(note)
    }

    /// Whether the answer to a call waiting for a note decides what becomes of it here when the team deleted it: an edit
    /// made here, or the note being shared (not a claim, not a putting back).
    private func decidesLater(_ call: TeamCall) -> Bool {
        guard let engine else { return false }
        if engine.isEditMadeHere(call) { return true }
        guard call.function == "create_note", !TeamNoteOperations.isUndelete(call) else { return false }
        return call.argument("p_fields").flatMap { TeamJSON(text: $0) }?[TeamNoteEngine.claimOnly]?.bool != true
    }

    /// Whether the last deletion of a note in the database was this member's (by any of their Macs, or by an earlier
    /// Binders as them), as the feed's record says. False when it can't tell (that part of the feed was pruned).
    private func deletedOnlyByMe(_ id: UUID) async -> Bool {
        guard let me = directory.me, let database = board.database,
              let answer = try? await database.json(TeamQueries.noteDeletedBy, [id.uuidString.lowercased()]) else { return false }
        return answer.uuid == me
    }

    /// One of this Mac's notes the database had deleted, as the answer to a call for it says (lane DB9). It never comes back
    /// as a new note:
    /// - shared from here (a move, a join, the sweep): left out (`leaveOut`), unless it's one of this Mac's own whose deletion
    ///   was this member's and never this Mac's, which is put back;
    /// - an edit made here that hadn't gone, with words that differ from the team's last: kept, and put back for the team
    ///   under its own id, with those words (`keepAside`);
    /// - one of this Mac's own whose deletion was this member's and never this Mac's (what an earlier Binders could have
    ///   left): put back;
    /// - anything else (a move, a property, a merge): the team's deletion stands, and it goes from here.
    private func deletedForTeam(_ note: NoteItem, answering call: TeamCall) async {
        guard let engine, !deciding.contains(note.id) else { return }
        let id = note.id
        deciding.insert(id)
        defer { deciding.remove(id) }
        let mineOnly = !note.isTeamCopy && deletedHere[id] == nil ? await deletedOnlyByMe(id) : false
        guard engine.state(id)?.deleted == true, store.note(id) != nil else { return }
        if call.function == "create_note" {
            if mineOnly { return putBack(note) }
            return await leaveOut(note)
        }
        if engine.isEditMadeHere(call) {
            let team = await engine.teamTexts(id)
            guard engine.state(id)?.deleted == true, store.note(id) != nil else { return }
            if team.map({ $0.text != note.text }) ?? true { return keepAside(note) }
        }
        if mineOnly { return putBack(note) }
        remove(note)
        engine.forget(note.id)
    }

    /// A note this Mac shared that the team had deleted (lane DB9): a joiner's copy from the team folder, say. It isn't
    /// shared again. Unchanged since the team had it (its words are words the team's note had), it goes from here, as the
    /// team's deletion would have taken it; with changes the team never had, it stays on this Mac, in General, as a
    /// private note. While a folder team moves over, it waits for the move to finish.
    private func leaveOut(_ note: NoteItem) async {
        guard let engine else { return }
        if moving {
            leavingOut.insert(note.id)
            return
        }
        let id = note.id
        let decided = deciding.insert(id).inserted
        defer { if decided { deciding.remove(id) } }
        let team = await engine.teamTexts(id)
        guard engine.state(id)?.deleted == true, store.note(id) != nil else { return }
        engine.forget(note.id)
        if let team, team.all.contains(note.text) {
            remove(note)
            leftOut.dropped += 1
            leftOutToSay.dropped += 1
        } else {
            let general = store.defaultBinder()
            note.binderID = general.id
            note.folderID = nil
            note.sharedWithTeam = false
            // A General shared with the team: the note still stays on this Mac.
            if covers(note) { note.staysUnshared = true }
            note.updatedAt = Date()
            leftOut.kept += 1
            leftOutToSay.kept += 1
        }
        leftOutSaying?.cancel()
        leftOutSaying = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            let said = self.leftOutToSay
            self.leftOutToSay = (0, 0)
            self.board.controller?.flowBar.toast(Self.leftOutLine(dropped: said.dropped, kept: said.kept), symbol: "tray", duration: 6)
        }
    }

    /// "3 notes the team had deleted weren't shared again. One had changes the team never had: it's in General, on this Mac
    /// only."
    static func leftOutLine(dropped: Int, kept: Int) -> String {
        let all = dropped + kept
        var line = all == 1 ? "A note the team had deleted wasn't shared again." : "\(all) notes the team had deleted weren't shared again."
        if kept == 1 {
            line += all == 1 ? " It had changes the team never had, so it's in General, on this Mac only." : " One had changes the team never had: it's in General, on this Mac only."
        } else if kept > 1 {
            line += " \(kept) had changes the team never had: they're in General, on this Mac only."
        }
        return line
    }

    /// A binder the team lost on this Mac (DB2's binderGone): its notes and folders aren't the team's here any more, and
    /// nothing of what happens to them now is a change for the team.
    func binderGone(_ binder: UUID) {
        guard let engine else { return }
        for (id, state) in engine.states where state.binder == binder { engine.forget(id) }
        for (id, shadow) in folders.shadows where shadow.binder == binder { folders.shadows[id] = nil }
        saveFolders()
    }

    // MARK: Answers

    /// What became of one of this Mac's note calls: versions kept, a note another Mac shared first merged, a note the team
    /// deleted decided on (`deletedForTeam`), once the last call that decides it has its answer.
    func settle(_ outcome: TeamOutboxOutcome) async {
        guard let engine, outcome.call.note != nil || ["put_folder", "delete_folder", "put_row", "put_rows", "delete_row"].contains(outcome.call.function) else { return }
        switch outcome.outcome {
        case .refused(let refusal): turnedDown.append("\(outcome.call.function): \(refusal.code): \(refusal.message)")
        case .failed(let message): turnedDown.append("\(outcome.call.function): \(message)")
        case .applied: break
        }
        if turnedDown.count > 50 { turnedDown.removeFirst(turnedDown.count - 50) }
        guard let answered = outcome.call.note else { return }
        var touched = await engine.settle(outcome)
        if case .applied = outcome.outcome { revision += 1 }
        // The team deleted it while this call waited, and nothing else that decides it waits now (an edit that went before
        // the deletion, say): decided now.
        if engine.state(answered)?.deleted == true, !engine.awaitsAnswer(answered),
           !(engine.database.queued.contains { $0.call.note == answered && decidesLater($0.call) }) {
            touched.insert(answered)
        }
        for id in touched {
            if engine.state(id)?.deleted == true {
                if let note = store.note(id) { await deletedForTeam(note, answering: outcome.call) } else { engine.forget(id) }
            } else if engine.knows(id) {
                takeCurrent(id, by: .you)
            }
        }
        saveIfChanged()
    }
}

extension TeamQueries {
    /// Who deleted a note ($1) last, as the feed recorded it in the binder it's in (a move to another binder is recorded as
    /// a deletion from the one it left): their member id as JSON, or null when the feed no longer has it.
    static let noteDeletedBy = """
        SELECT coalesce((SELECT to_jsonb(c.member_id) FROM binders.changes c JOIN binders.notes n ON n.id = c.row_id AND n.binder_id = c.binder_id
                         WHERE c.table_name = 'notes' AND c.row_id = $1::uuid AND c.kind = 'delete' ORDER BY c.seq DESC LIMIT 1), 'null')::text
        """
}
