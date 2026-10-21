import Foundation
import Observation
import SwiftData
import BindersKit

extension WorkStreams {
    /// The boards as the digest reads them: every card, or one binder's, with the question each blocked card waits on.
    @MainActor
    static func cards(in binderID: UUID? = nil, where readable: (TaskCard) -> Bool = { _ in true }, doing: Bool = true) -> [Card] {
        cards(on: Store.shared.context, in: binderID, where: readable, doing: doing)
    }

    /// The same, read on any context: the window's, or one a background task made for itself. Only the cards the digest
    /// can use are read (open ones, and the ones finished today), and the timelines of the blocked and done ones in one go.
    /// With `doing`, a card in progress in a run Binders started carries what the run says it's doing (`AgentDoing`).
    static func cards(on context: ModelContext, in binderID: UUID? = nil, where readable: (TaskCard) -> Bool = { _ in true },
                      now: Date = Date(), doing withDoing: Bool = true) -> [Card] {
        // Archived binders are done with: their cards stay out.
        let binders = (try? context.fetch(FetchDescriptor<BinderRecord>(predicate: #Predicate { !$0.archived }))) ?? []
        let live = Dictionary(binders.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let today = Calendar.current.startOfDay(for: now)
        let done = BoardColumn.done.rawValue
        // A card done before today and touched since (a comment) wasn't finished today; one long done isn't read.
        let read = FetchDescriptor<TaskCard>(predicate: #Predicate { $0.columnRaw != done || $0.updatedAt >= today })
        let all = ((try? context.fetch(read)) ?? [])
            .filter { binderID == nil || $0.binderID == binderID }
            .filter(readable)
            .filter { $0.binderID.map { live[$0] != nil } ?? true }
        let watched = all.filter { $0.column == .blocked || $0.column == .done }.map(\.id)
        let events = watched.isEmpty ? [] : (try? context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { watched.contains($0.taskID) },
                                                                                           sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let timelines = Dictionary(grouping: events, by: \.taskID)
        let doing = withDoing ? AgentDoing.lines(for: all, on: context, now: now) : [:]
        return all.map { card in
            var question: TaskEvent?
            var finished: Date?
            if card.column == .blocked || card.column == .done {
                let events = timelines[card.id] ?? []
                if card.column == .blocked {
                    question = BoardRules.waitingQuestion(in: events.map { (kind: $0.kindRaw, to: $0.toColumn ?? "") }).map { events[$0] }
                } else {
                    finished = events.last { $0.toColumn == BoardColumn.done.rawValue }?.createdAt ?? card.updatedAt
                }
            }
            let held = BoardRules.isClaimed(card.state, at: now) || card.column == .review || card.column == .done
            return Card(title: card.title, binder: card.binderID.flatMap { live[$0] } ?? "", column: card.column,
                        assignee: held ? card.assignee : nil, assigneeIsAgent: card.assigneeIsAgent, meantFor: card.meantFor,
                        question: question?.text, asker: question?.author, updated: card.updatedAt, finished: finished, doing: doing[card.id])
        }
    }

    /// The digest as tools give it: a few sentences, and each part as a list. A stream whose run says what it's doing has
    /// `doing`, its words beside each card's title; others leave the key out.
    static func json(_ digest: Digest) -> [String: Any] {
        ["summary": digest.summary, "headline": digest.headline,
         "by_binder": digest.byBinder.map { ["binder": $0.binder, "working": $0.working, "questions": $0.questions, "reviews": $0.reviews,
                                             "waiting_to_start": $0.waitingToStart, "done_today": $0.doneToday] as [String: Any] },
         "working": digest.streams.map { stream in
             var entry: [String: Any] = ["who": stream.who, "agent": stream.isAgent, "cards": stream.working]
             if !stream.doing.isEmpty { entry["doing"] = stream.doing.map { ["card": $0.card, "line": $0.line] } }
             return entry
         },
         "questions": digest.questions.map { ["card": $0.card, "who": $0.who, "question": $0.question] },
         "reviews": digest.reviews.map { ["card": $0.card, "who": $0.who] },
         "waiting_to_start": digest.queued.map { ["card": $0.card, "for": $0.who] },
         "done_today": digest.doneToday]
    }
}

/// The digest of every board, as Home, Today and Work show it: built off the main thread once per board change (a card
/// or its timeline saved, a binder renamed or archived), and kept until the next one, or until the day turns, as "done
/// today" means today. It's built only while a page shows it; a change meanwhile is caught up on when one does. What runs
/// say they're doing goes from it once no page shows it, and is read again when one does.
@MainActor
@Observable
final class WorkStreamsFeed {
    static let shared = WorkStreamsFeed()

    /// Nil until the first build is in.
    private(set) var digest: WorkStreams.Digest?

    /// For self-tests: builds finished, and whether the last one ran off the main thread.
    @ObservationIgnored private(set) var builds = 0
    @ObservationIgnored private(set) var builtOffMain = false
    @ObservationIgnored private var showing = 0
    @ObservationIgnored private var stale = true
    @ObservationIgnored private var building = false
    @ObservationIgnored private var builtOn: Date?
    @ObservationIgnored private var changes: SaveWatcher?
    @ObservationIgnored private var dayObserver: NSObjectProtocol?

    /// A page showing the digest appeared: it's brought up to date if it isn't.
    func show() {
        showing += 1
        if changes == nil {
            changes = SaveWatcher(kinds: ["TaskCard", "TaskEvent", "BinderRecord"]) { [weak self] in self?.changed() }
            dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            }
        }
        if let builtOn, !Calendar.current.isDateInToday(builtOn) { stale = true }
        build()
    }

    func hide() {
        showing = max(0, showing - 1)
        if showing == 0 { letGoOfDoing() }
    }

    /// No page shows the digest: what runs said they were doing goes from it, as their words are shown only fresh, and
    /// it's built again when a page shows it, with what they say then.
    private func letGoOfDoing() {
        guard let digest, digest.saysWhatRunsAreDoing else { return }
        self.digest = digest.withoutDoing
        stale = true
    }

    /// The boards changed: built again now if a page shows the digest, and otherwise when one does.
    func changed() {
        stale = true
        build()
    }

    private func build() {
        guard stale, showing > 0, !building else { return }
        stale = false
        building = true
        let container = Store.shared.container
        Task {
            let (digest, offMain) = await Task.detached(priority: .userInitiated) {
                (WorkStreams.digest(WorkStreams.cards(on: ModelContext(container))), pthread_main_np() == 0)
            }.value
            if self.digest != digest { self.digest = digest }
            // Built for a page that has gone since.
            if showing == 0 { letGoOfDoing() }
            builtOffMain = offMain
            builtOn = Date()
            builds += 1
            building = false
            // Something changed while it was being built.
            build()
        }
    }
}
