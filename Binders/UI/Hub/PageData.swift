import Foundation
import Observation
import SwiftData
import BindersKit

/// Calls back on the main actor a moment after the library saved a change to one of `kinds` (entity names such as
/// "NoteItem"), from any of its contexts: this window's, the iPhone link's, an agent's over MCP. A burst of saves, such as
/// an agent's progress reports, is one call.
@MainActor
final class SaveWatcher {
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var pending = false

    init(kinds: Set<String>, delay: Duration = .milliseconds(250), _ changed: @escaping @MainActor () -> Void) {
        let container = Store.shared.container
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] notification in
            // On the thread that saved, while its context is still its own.
            guard let context = notification.object as? ModelContext, context.container === container,
                  SaveWatcher.touches(notification.userInfo, kinds) else { return }
            Task { @MainActor in self?.schedule(after: delay, changed) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func schedule(after delay: Duration, _ changed: @escaping @MainActor () -> Void) {
        guard !pending else { return }
        pending = true
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.pending = false
            changed()
        }
    }

    /// Whether a save changed anything of `kinds`. One that made every id out of date did.
    nonisolated static func touches(_ userInfo: [AnyHashable: Any]?, _ kinds: Set<String>) -> Bool {
        if userInfo?[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] != nil { return true }
        return [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
            .flatMap { userInfo?[$0.rawValue] as? [PersistentIdentifier] ?? [] }
            .contains { kinds.contains($0.entityName) }
    }
}

/// Where a to-do on Home or Today leads, and what its promise's buttons do.
struct TaskActions {
    var openMeeting: (MeetingRecord) -> Void
    var openNote: (NoteItem) -> Void
    var commitments: CommitmentActions
}

extension HubNavigation {
    /// A note, on its binder's Notes.
    func open(note: NoteItem) {
        binderID = note.binderID ?? Store.shared.defaultBinder().id
        pendingNoteID = note.id
        pendingBinderTab = .notes
        selection = .binder
    }
}

/// What Home shows that takes work to put together: the to-dos in the latest meetings, notes and promises, each binder's
/// counts, and the dictation stats. It reads with bounded fetches when the page opens and again after a save that could
/// change them, and rebuilds the to-dos as soon as one of them changes (ticked here, say), so the page never works them
/// out as it draws. Counts and stats are read off the main thread.
@MainActor
@Observable
final class HomeData {
    /// A binder at a glance: its meetings (captures aside) and notes, and when one of them was last touched.
    struct Activity: Equatable, Sendable {
        var meetings = 0
        var notes = 0
        var last: Date?
    }

    /// How many of the latest meetings, notes and promises the to-dos come from, as in 0.8.0.
    static let meetingLimit = 30, noteLimit = 80, commitmentLimit = 60

    private(set) var tasks: [TaskEntry] = []
    private(set) var openCount = 0
    private(set) var openByBinder: [UUID: Int] = [:]
    /// Nil until the first count is in.
    private(set) var activity: [UUID: Activity]?
    private(set) var stats = StatsCalculator.compute([])
    private(set) var daily = StatsCalculator.dailyWords([])
    private(set) var statsRead = false
    /// For self-tests: how many times the latest items were read, and their to-dos collected.
    @ObservationIgnored private(set) var reads = 0
    @ObservationIgnored private(set) var collects = 0

    @ObservationIgnored private var actions: TaskActions?
    @ObservationIgnored private var sources: (meetings: [MeetingRecord], notes: [NoteItem], commitments: [CommitmentRecord]) = ([], [], [])
    @ObservationIgnored private var watchers: [SaveWatcher] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var counting: Task<Void, Never>?
    @ObservationIgnored private var measuring: Task<Void, Never>?

    /// Reads everything, and from then on what a save changes.
    func start(_ actions: TaskActions) {
        self.actions = actions
        if watchers.isEmpty {
            watchers = [
                SaveWatcher(kinds: ["MeetingRecord", "NoteItem", "CommitmentRecord", "BinderRecord"]) { [weak self] in
                    self?.readSources()
                    self?.readActivity()
                },
                SaveWatcher(kinds: ["TranscriptRecord"]) { [weak self] in self?.readStats() },
            ]
        }
        readSources()
        readActivity()
        readStats()
    }

    /// The latest meetings, notes and promises, and their to-dos.
    func readSources() {
        let context = Store.shared.context
        var meetings = FetchDescriptor<MeetingRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        meetings.fetchLimit = Self.meetingLimit
        var notes = FetchDescriptor<NoteItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        notes.fetchLimit = Self.noteLimit
        var commitments = FetchDescriptor<CommitmentRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        commitments.fetchLimit = Self.commitmentLimit
        sources = ((try? context.fetch(meetings)) ?? [], (try? context.fetch(notes)) ?? [], (try? context.fetch(commitments)) ?? [])
        reads += 1
        collect()
    }

    /// The to-dos in what was read, collected again as soon as anything they came from changes.
    private func collect() {
        guard let actions else { return }
        generation += 1
        collects += 1
        let current = generation
        let sources = sources
        let collected = withObservationTracking {
            TaskCollector.collect(meetings: sources.meetings, notes: sources.notes, commitments: sources.commitments,
                                  openMeeting: actions.openMeeting, openNote: actions.openNote, commitmentActions: actions.commitments)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.collect()
            }
        }
        tasks = collected
        let open = collected.filter { !$0.done }
        openCount = open.count
        openByBinder = open.reduce(into: [:]) { counts, task in
            if let id = task.binderID { counts[id, default: 0] += 1 }
        }
    }

    /// Each binder's counts, read on a context of their own.
    func readActivity() {
        let binders = ((try? Store.shared.context.fetch(FetchDescriptor<BinderRecord>())) ?? []).map(\.id)
        let container = Store.shared.container
        counting?.cancel()
        counting = Task { [weak self] in
            let counted = await Task.detached(priority: .utility) { HomeData.activity(of: binders, in: container) }.value
            guard !Task.isCancelled, let self, self.activity != counted else { return }
            self.activity = counted
        }
    }

    /// The stats and the two weeks' chart, from every dictation's words and time, without reading its text.
    func readStats() {
        let container = Store.shared.container
        measuring?.cancel()
        measuring = Task { [weak self] in
            let (stats, daily) = await Task.detached(priority: .utility) {
                let records = HomeData.dictations(in: container)
                return (StatsCalculator.compute(records), StatsCalculator.dailyWords(records))
            }.value
            guard !Task.isCancelled, let self else { return }
            if self.stats != stats { self.stats = stats }
            if !self.daily.elementsEqual(daily, by: { $0.date == $1.date && $0.words == $1.words }) { self.daily = daily }
            if !self.statsRead { self.statsRead = true }
        }
    }

    /// Counted, not read: a binder with thousands of notes costs no more to show than one with a few.
    nonisolated static func activity(of binders: [UUID], in container: ModelContainer) -> [UUID: Activity] {
        let context = ModelContext(container)
        let capture = MeetingRecord.conversationKind
        var counted: [UUID: Activity] = [:]
        for id in binders {
            var meetings = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == id && $0.kind != capture },
                                                          sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            var notes = FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == id }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            var activity = Activity(meetings: (try? context.fetchCount(meetings)) ?? 0, notes: (try? context.fetchCount(notes)) ?? 0)
            meetings.fetchLimit = 1
            notes.fetchLimit = 1
            activity.last = [(try? context.fetch(meetings))?.first?.createdAt, (try? context.fetch(notes))?.first?.updatedAt].compactMap { $0 }.max()
            counted[id] = activity
        }
        return counted
    }

    /// Every dictation kept: its day, words and time.
    nonisolated static func dictations(in container: ModelContainer) -> [UsageRecord] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.mode == "dictation" && $0.status == "inserted" })
        descriptor.propertiesToFetch = [\.createdAt, \.wordCount, \.duration]
        return ((try? context.fetch(descriptor)) ?? []).map { UsageRecord(date: $0.createdAt, words: $0.wordCount, duration: $0.duration) }
    }
}

/// One day's page: that day's meetings, captures, notes worked on, dictations and card moves, what's due by its end, and
/// the day's own note. Each is a fetch bounded to the day, or to what's due by its end, read when the page opens and
/// again after a save that could change it; the to-dos are collected again as soon as one of them changes.
@MainActor
@Observable
final class TodayData {
    /// A card with something on its timeline that day, and the latest of it.
    struct Move: Identifiable {
        let card: TaskCard
        let event: TaskEvent
        var id: UUID { card.id }
    }

    /// Notes worked on that are listed; the rest are counted.
    static let noteLimit = 100
    /// Notes due that are listed at most, the longest overdue first.
    static let dueLimit = 200

    private(set) var day: Date?
    private(set) var loaded = false
    private(set) var dailyNote: NoteItem?
    /// Meetings and the iPhone's captures (less the small talk), the earliest first.
    private(set) var meetings: [MeetingRecord] = []
    private(set) var conversations: [MeetingRecord] = []
    /// Notes worked on that day, the latest first, less the day's own note, and how many more there were.
    private(set) var notes: [NoteItem] = []
    private(set) var moreNotes = 0
    /// Due that day; on today's page, also the ones overdue. None of them done.
    private(set) var dueNotes: [NoteItem] = []
    private(set) var dictations: [TranscriptRecord] = []
    private(set) var moved: [Move] = []
    private(set) var tasks: [TaskEntry] = []
    /// For self-tests: how many times the day was read.
    @ObservationIgnored private(set) var reads = 0

    @ObservationIgnored private var actions: TaskActions?
    @ObservationIgnored private var commitments: [CommitmentRecord] = []
    @ObservationIgnored private var watchers: [SaveWatcher] = []
    @ObservationIgnored private var generation = 0

    /// Reads the day, and from then on what a save changes.
    func show(_ day: Date, actions: TaskActions) {
        self.actions = actions
        self.day = day
        if watchers.isEmpty {
            watchers = [
                SaveWatcher(kinds: ["MeetingRecord", "NoteItem", "CommitmentRecord", "TranscriptRecord"]) { [weak self] in self?.read() },
                // An agent's progress reports land here: only the moves are read again for them.
                SaveWatcher(kinds: ["TaskCard", "TaskEvent"]) { [weak self] in self?.readMoves() },
            ]
        }
        read()
    }

    /// The day's note was just made, by typing in it: it's the one from now on, before its save is read back.
    func made(_ note: NoteItem) {
        dailyNote = note
    }

    /// Where the day starts and ends, and whether it's today.
    private var bounds: (start: Date, end: Date, isToday: Bool)? {
        guard let day else { return nil }
        let calendar = Calendar.current
        return (day, calendar.date(byAdding: .day, value: 1, to: day) ?? day, calendar.isDateInToday(day))
    }

    func read() {
        guard let day, let bounds else { return }
        let (start, end, isToday) = bounds
        let context = Store.shared.context
        let title = TodayView.dailyTitle(for: day)
        let never = Date.distantFuture

        // The day's own note is titled by its date, so only notes with the date in them are read to find it.
        let dated = FetchDescriptor<NoteItem>(predicate: #Predicate { $0.text.localizedStandardContains(title) },
                                              sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let found = ((try? context.fetch(dated)) ?? []).first { $0.title == title }
        if found !== dailyNote { dailyNote = found }

        let held = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.createdAt >= start && $0.createdAt < end },
                                                  sortBy: [SortDescriptor(\.createdAt)])
        let all = (try? context.fetch(held)) ?? []
        set(\.meetings, to: all.filter { !$0.isConversation })
        set(\.conversations, to: all.filter { $0.isConversation && $0.status != "trivial" })

        var worked = FetchDescriptor<NoteItem>(predicate: #Predicate { $0.updatedAt >= start && $0.updatedAt < end },
                                               sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let workedCount = (try? context.fetchCount(worked)) ?? 0
        worked.fetchLimit = Self.noteLimit + 1
        set(\.notes, to: Array(((try? context.fetch(worked)) ?? []).filter { $0.title != title }.prefix(Self.noteLimit)))
        let dailyWorkedOn = found.map { $0.updatedAt >= start && $0.updatedAt < end } ?? false
        let more = max(0, workedCount - (dailyWorkedOn ? 1 : 0) - notes.count)
        if more != moreNotes { moreNotes = more }

        let dueBy: Predicate<NoteItem> = isToday
            ? #Predicate { ($0.dueAt ?? never) < end && ($0.status ?? "") != "Done" }
            : #Predicate { ($0.dueAt ?? never) >= start && ($0.dueAt ?? never) < end && ($0.status ?? "") != "Done" }
        var due = FetchDescriptor<NoteItem>(predicate: dueBy, sortBy: [SortDescriptor(\.dueAt)])
        due.fetchLimit = Self.dueLimit
        set(\.dueNotes, to: (try? context.fetch(due)) ?? [])

        let said = FetchDescriptor<TranscriptRecord>(
            predicate: #Predicate { $0.createdAt >= start && $0.createdAt < end && $0.mode == "dictation" && $0.status == "inserted" },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        set(\.dictations, to: (try? context.fetch(said)) ?? [])

        // That day's promises; on today's page, also the ones still open and due by tonight, whenever they were made.
        let promised: Predicate<CommitmentRecord> = isToday
            ? #Predicate { ($0.createdAt >= start && $0.createdAt < end) || ($0.status == "open" && ($0.dueAt ?? never) < end) }
            : #Predicate { $0.createdAt >= start && $0.createdAt < end }
        commitments = (try? context.fetch(FetchDescriptor<CommitmentRecord>(predicate: promised, sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []

        readMoves()
        collect()
        reads += 1
        loaded = true
    }

    /// Cards with something on their timeline that day, the latest first, each with its last event.
    func readMoves() {
        guard let bounds else { return }
        let (start, end) = (bounds.start, bounds.end)
        let context = Store.shared.context
        let events = FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.createdAt >= start && $0.createdAt < end },
                                                sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        var seen = Set<UUID>()
        let latest = ((try? context.fetch(events)) ?? []).filter { seen.insert($0.taskID).inserted }
        let ids = latest.map(\.taskID)
        let cards = ids.isEmpty ? [] : (try? context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fresh = latest.compactMap { event in byID[event.taskID].map { Move(card: $0, event: event) } }
        if !moved.elementsEqual(fresh, by: { $0.card === $1.card && $0.event === $1.event }) { moved = fresh }
    }

    /// Sets a list only when it holds other items, so a save that changed nothing here doesn't draw the page again.
    private func set<Item: AnyObject>(_ list: ReferenceWritableKeyPath<TodayData, [Item]>, to items: [Item]) {
        if !self[keyPath: list].elementsEqual(items, by: ===) { self[keyPath: list] = items }
    }

    /// The to-dos in the day's meetings and captures and its promises, collected again as soon as one of them changes.
    private func collect() {
        guard let actions, let bounds else { return }
        let (start, end, isToday) = bounds
        generation += 1
        let current = generation
        let held = meetings + conversations
        let commitments = commitments
        tasks = withObservationTracking {
            let promised = commitments.filter { record in
                guard record.status != "dismissed" else { return false }
                if record.createdAt >= start && record.createdAt < end { return true }
                return isToday && record.status == "open" && (record.dueAt.map { $0 < end } ?? false)
            }
            return TaskCollector.collect(meetings: held, notes: [], commitments: promised, openMeeting: actions.openMeeting,
                                         openNote: actions.openNote, commitmentActions: actions.commitments)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.collect()
            }
        }
    }
}

/// What a binder's Overview shows that takes work to put together (lane DB10), kept the way HomeData keeps Home's: its
/// counts, its latest meetings and notes, and the to-dos in them, read with bounded fetches when the page opens and again
/// after a save that could change them, the to-dos collected again as soon as one of them changes. Before, the page fetched
/// every note in the binder and scanned the latest 120 for to-dos each time it drew, which a shared binder's sync made
/// often.
@MainActor
@Observable
final class BinderOverviewData {
    /// How many of the latest meetings, notes and promises the to-dos come from, as the page had it.
    static let meetingLimit = 60, noteLimit = 120, commitmentLimit = 100

    private(set) var meetingCount = 0
    private(set) var noteCount = 0
    private(set) var recentMeetings: [MeetingRecord] = []
    private(set) var recentNotes: [NoteItem] = []
    private(set) var tasks: [TaskEntry] = []
    private(set) var openCount = 0
    /// For self-tests: how many times the binder was read, and its to-dos collected.
    @ObservationIgnored private(set) var reads = 0
    @ObservationIgnored private(set) var collects = 0

    @ObservationIgnored private var binder: UUID?
    @ObservationIgnored private var actions: TaskActions?
    @ObservationIgnored private var sources: (meetings: [MeetingRecord], notes: [NoteItem], commitments: [CommitmentRecord]) = ([], [], [])
    @ObservationIgnored private var watcher: SaveWatcher?
    @ObservationIgnored private var generation = 0

    /// Reads the binder, and from then on what a save changes.
    func start(binder: UUID, _ actions: TaskActions) {
        self.actions = actions
        if watcher == nil {
            watcher = SaveWatcher(kinds: ["MeetingRecord", "NoteItem", "CommitmentRecord"]) { [weak self] in self?.read() }
        }
        guard self.binder != binder || reads == 0 else { return }
        reads = 0
        self.binder = binder
        read()
    }

    /// Stops reading (the page closed): a page that isn't showing does no work.
    func stop() {
        watcher = nil
        generation += 1
        reads = 0
    }

    /// The binder's counts, its latest meetings, notes and promises, and their to-dos.
    func read() {
        guard let binder, watcher != nil else { return }
        let context = Store.shared.context
        let id: UUID? = binder
        let capture = MeetingRecord.conversationKind
        var meetings = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == id && $0.kind != capture },
                                                      sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let allNotes = FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == id })
        var notes = FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == id }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        var commitments = FetchDescriptor<CommitmentRecord>(predicate: #Predicate { $0.binderID == id },
                                                            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let meetingCount = (try? context.fetchCount(meetings)) ?? 0
        let noteCount = (try? context.fetchCount(allNotes)) ?? 0
        notes.fetchLimit = Self.noteLimit
        commitments.fetchLimit = Self.commitmentLimit
        // Conversations (captures) carry to-dos too, as the page always read them: the latest of every kind.
        var everyMeeting = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == id }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        everyMeeting.fetchLimit = Self.meetingLimit
        let latestMeetings = (try? context.fetch(everyMeeting)) ?? []
        let latestNotes = (try? context.fetch(notes)) ?? []
        sources = (latestMeetings, latestNotes, (try? context.fetch(commitments)) ?? [])
        meetings.fetchLimit = 6
        let recentMeetings = (try? context.fetch(meetings)) ?? []
        let recentNotes = Array(latestNotes.prefix(6))
        if self.meetingCount != meetingCount { self.meetingCount = meetingCount }
        if self.noteCount != noteCount { self.noteCount = noteCount }
        if self.recentMeetings.map(\.id) != recentMeetings.map(\.id) { self.recentMeetings = recentMeetings }
        if self.recentNotes.map(\.id) != recentNotes.map(\.id) { self.recentNotes = recentNotes }
        reads += 1
        collect()
    }

    /// The to-dos in what was read, collected again as soon as anything they came from changes.
    private func collect() {
        guard let actions, watcher != nil else { return }
        generation += 1
        collects += 1
        let current = generation
        let sources = sources
        let collected = withObservationTracking {
            TaskCollector.collect(meetings: sources.meetings, notes: sources.notes, commitments: sources.commitments,
                                  openMeeting: actions.openMeeting, openNote: actions.openNote, commitmentActions: actions.commitments)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.collect()
            }
        }
        tasks = collected
        openCount = collected.filter { !$0.done }.count
    }
}
