import Foundation
import SwiftData
import BindersKit

/// Meetings, captures, to-dos and knowledge on the team database (lane DB4), for the binders shared through it. Owned by
/// TeamBoard, which hands it the feed's updates and the outbox's answers:
/// - going (TeamContentSend.swift): this member's meetings, with their transcripts as they're written; the captures you
///   shared; your to-dos, and ticks on teammates'; nothing else, and never audio;
/// - coming (TeamContentApply.swift): teammates' meetings and captures as read-only copies, their to-dos, which you may
///   tick;
/// - knowledge (TeamKnowledge.swift): your items' index published once, teammates' taken into this Mac's index without
///   embedding them again, and their corrections.
/// What it keeps beside the outbox (`content.json`) says what was sent of each item, which captures you shared and the
/// last row seen of each to-do, so it holds after a restart.
@MainActor
final class TeamContent {
    unowned let team: TeamBoard
    var state = TeamContentState()
    /// The lines sent of each transcript in its current revision, by id, with their fingerprints. Forgotten at a restart,
    /// when a transcript that changed goes again whole.
    var transcripts: [UUID: [UUID: String]] = [:]
    /// Items saved since the last pass, by id; a pass that has to look at everything (a binder shared, something deleted).
    var dirty: Set<UUID> = []
    var sweep = true
    /// Meetings and captures whose new lines wait for room in the outbox.
    var linesWaiting: Set<UUID> = []
    lazy var knowledge = TeamKnowledge(content: self)

    private var saveObserver: NSObjectProtocol?
    private var passTask: Task<Void, Never>?
    private var started = false

    /// The one the app runs, while it runs: the knowledge index and the meeting page ask it.
    static weak var current: TeamContent?
    /// How soon a pass follows a transcript line's save (a meeting being recorded), and any other save.
    var liveDelay: Duration = .milliseconds(100)
    var editDelay: Duration = .seconds(1)

    init(team: TeamBoard) {
        self.team = team
    }

    var store: Store { Store.shared }
    var database: TeamDatabase? { team.database }
    var directory: TeamDirectory { team.directory }

    // MARK: Starting

    func start() {
        guard !started else { return }
        started = true
        Self.current = self
        loadState()
        sweep = true
        watchSaves()
        // A capture you move into a shared binder yourself is one you share.
        Store.capturesFiled = { [weak self] id, binder in self?.filed(capture: id, in: binder) }
        knowledge.start()
        passSoon(after: .milliseconds(300))
    }

    func stop() {
        started = false
        passTask?.cancel()
        passTask = nil
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        saveObserver = nil
        Store.capturesFiled = nil
        knowledge.stop()
        transcripts = [:]
        saveState()
        if Self.current === self { Self.current = nil }
    }

    /// Connected again: everything is looked at, what waited goes, and the index is published.
    func cameOnline() async {
        sweep = true
        pass()
        await knowledge.cameOnline()
    }

    // MARK: Watching saves

    private func watchSaves() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.noticed(info) }
        }
    }

    /// A save: the meetings, captures and to-dos it touched are looked at a moment later; a transcript line a moment
    /// sooner, so a meeting being recorded streams.
    private func noticed(_ info: [AnyHashable: Any]?) {
        func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] { info?[key.rawValue] as? [PersistentIdentifier] ?? [] }
        let context = store.context
        var live = false
        var touched = false
        for id in ids(.insertedIdentifiers) + ids(.updatedIdentifiers) {
            switch id.entityName {
            case "MeetingRecord":
                touched = true
                if let record = context.registeredModel(for: id) as MeetingRecord? { dirty.insert(record.id) } else { sweep = true }
            case "MeetingSegmentRecord":
                touched = true
                live = true
                if let line = context.registeredModel(for: id) as MeetingSegmentRecord? { dirty.insert(line.meetingID) } else { sweep = true }
            case "CommitmentRecord":
                touched = true
                if let todo = context.registeredModel(for: id) as CommitmentRecord? { dirty.insert(todo.id) } else { sweep = true }
            case "BinderRecord":
                // A binder shared or unshared: everything again.
                touched = true
                sweep = true
            default:
                continue
            }
        }
        // A card made from a to-do: the to-do says which card it's on.
        for id in ids(.insertedIdentifiers) where id.entityName == "TaskCard" {
            guard let card = context.registeredModel(for: id) as TaskCard?, let todo = card.sourceRef.flatMap(UUID.init(uuidString:)) else { continue }
            dirty.insert(todo)
            touched = true
        }
        for id in ids(.deletedIdentifiers) where ["MeetingRecord", "CommitmentRecord", "BinderRecord"].contains(id.entityName) {
            touched = true
            sweep = true
        }
        if info?[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] != nil {
            touched = true
            sweep = true
        }
        guard touched else { return }
        passSoon(after: live ? liveDelay : editDelay)
    }

    func passSoon(after delay: Duration) {
        // A pass already waiting keeps its turn when it comes sooner.
        if let passTask, !passTask.isCancelled, delay >= liveDelay, passScheduledSoon { return }
        passTask?.cancel()
        passScheduledSoon = delay <= liveDelay
        passTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.passScheduledSoon = false
            self.pass()
        }
    }

    private var passScheduledSoon = false

    // MARK: Captures you share

    /// A capture of yours moved into a binder (Store.move): into one shared through the team database, it's shared.
    private func filed(capture id: UUID, in binder: UUID) {
        guard team.covers(binder) else { return }
        if state.shared.insert(id).inserted {
            saveState()
            dirty.insert(id)
            passSoon(after: editDelay)
        }
    }

    /// Whether this capture of yours goes to the team: in a shared binder, and shared by you.
    func isShared(_ capture: MeetingRecord) -> Bool {
        !capture.isTeamCopy && team.covers(capture.binderID) && state.shared.contains(capture.id)
    }

    /// Whether a capture of yours sits in a shared binder without going to the team: it was there before the binder was
    /// shared, so it stays on this Mac until you choose Share It.
    func isKeptHere(_ capture: MeetingRecord) -> Bool {
        capture.isConversation && !capture.isTeamCopy && team.covers(capture.binderID) && !state.shared.contains(capture.id)
    }

    /// Share It: a capture kept on this Mac goes to the team, as it is now.
    func share(_ capture: MeetingRecord) {
        guard capture.isConversation, !capture.isTeamCopy, team.covers(capture.binderID) else { return }
        state.shared.insert(capture.id)
        saveState()
        dirty.insert(capture.id)
        pass()
    }

    /// Where a new capture lands: the binder you have open, unless it's shared through the team database (a capture
    /// joins the team only when you put it there), else General, else your first binder that isn't shared. The binder
    /// you have open when nothing else is.
    static func privateHome(preferring binder: BinderRecord?) -> BinderRecord {
        let store = Store.shared
        let shared = { (candidate: BinderRecord) in !candidate.teamDatabaseKey.isEmpty || candidate.isTeamCopy }
        if let binder, !shared(binder) { return binder }
        let general = store.defaultBinder()
        if !shared(general) { return general }
        return store.binders().first { !shared($0) } ?? binder ?? general
    }

    // MARK: On disk

    private var stateURL: URL? { team.folder?.appendingPathComponent("content.json") }

    private func loadState() {
        guard let url = stateURL, let data = try? Data(contentsOf: url), let read = try? JSONDecoder().decode(TeamContentState.self, from: data) else {
            state = TeamContentState()
            return
        }
        state = read
    }

    func saveState() {
        guard let url = stateURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
    }
}

/// What TeamContent keeps beside the outbox (`content.json`).
struct TeamContentState: Codable, Equatable {
    /// One of this member's meetings or captures, as last sent.
    struct Sent: Codable, Equatable {
        var binder: UUID
        /// The row as last sent (TeamMeetingValues.fingerprint).
        var fingerprint = ""
        /// The transcript's current revision, how many of its lines were sent, and the digest of those lines (nil: none
        /// yet in this revision).
        var revision = 0
        var count = 0
        var digest: String?
        /// Taken off the team (moved out of the shared binders, or deleted): its words erased there.
        var withdrawn = false
    }

    /// A to-do as the team database last had it (sent, or read back).
    struct Todo: Codable, Equatable {
        var binder: UUID
        var status: String
        var doneAt: Date?
        /// The whole row, for one of yours: sent again when what's here differs.
        var row = ""
        var mine: Bool
        var withdrawn = false
    }

    var meetings: [UUID: Sent] = [:]
    var captures: [UUID: Sent] = [:]
    /// The captures you shared: moved into a shared binder by you, or Share It.
    var shared: Set<UUID> = []
    var todos: [UUID: Todo] = [:]
    /// Teammates' meetings and captures here: the transcript revision this Mac shows of each.
    var received: [UUID: Int] = [:]
}

extension BinderRecord {
    /// Shared through a team database (lane DB2).
    var sharedThroughDatabase: Bool { !teamDatabaseKey.isEmpty }
}
