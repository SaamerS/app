import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// Home, Today, the work-streams digest, the board's columns and the knowledge graph, on the demo data plus a heavy
    /// user's library (about 2,000 notes and 200 more cards):
    /// - Home's and Today's bounded reads give what reading everything gave, a ticked to-do shows at once, and a save
    ///   (a new note, an old one deleted) reaches them;
    /// - the digest is built off the main thread, once per board change, only while a page shows it;
    /// - at the default window, Backlog and Done fold and Blocked and Review show without scrolling sideways;
    /// - a settled graph draws nothing more, a selection's pulse ends, and with Reduce Motion nothing animates.
    /// The pages are drawn to `directory`. A throwaway store (BINDERS_DATA_DIR).
    @MainActor
    static func pagesSelfTest(directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this seeds fictional data there")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = DictationController()
        guard await DemoData.seed(knowledge: controller.knowledge),
              let harbor = Store.shared.binders().first(where: { $0.name == DemoData.binderName }) else { return 1 }
        let store = Store.shared
        let context = store.context
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let binders = store.binders()

        // A heavy user's library: 2,000 notes over the binders, a tenth with to-dos, 130 worked on today and 10
        // yesterday, some due today, overdue, done or due tomorrow; 40 more meetings; 200 more cards with timelines.
        let todaySoFar = max(Date().timeIntervalSince(today) - 60, 1)
        var random = SeededGenerator(seed: 6_006)
        for index in 0..<2_000 {
            var text = IndexFixtures.noteText(index: index, paragraphs: 1 + random.next(upTo: 4), using: &random)
            if index % 10 == 0 { text += "\n\n- [ ] Follow up on item \(index)" }
            let note = NoteItem(text: text)
            note.binderID = binders[index % binders.count].id
            switch index {
            // Earlier today, whatever the time: notes dated later today would sort above one saved now.
            case 0..<130: note.updatedAt = today.addingTimeInterval(min(Double(index) * 37 + 60, todaySoFar * Double(index + 1) / 131))
            case 130..<140: note.updatedAt = yesterday.addingTimeInterval(Double(index) * 53)
            default: note.updatedAt = yesterday.addingTimeInterval(-Double(index) * 3_100)
            }
            note.createdAt = note.updatedAt.addingTimeInterval(-3_600)
            switch index {
            case 200..<212: note.properties = NoteProperties(status: index % 2 == 0 ? "Draft" : nil, owner: "Sam", due: today.addingTimeInterval(Double(index) * 60))
            case 212..<220: note.properties = NoteProperties(status: "Draft", owner: nil, due: yesterday.addingTimeInterval(-Double(index) * 3_600))
            case 220..<225: note.properties = NoteProperties(status: "Done", owner: nil, due: yesterday.addingTimeInterval(-Double(index) * 60))
            case 225..<228: note.properties = NoteProperties(status: nil, owner: nil, due: tomorrow.addingTimeInterval(Double(index) * 60))
            case 228..<231: note.properties = NoteProperties(status: nil, owner: nil, due: yesterday.addingTimeInterval(Double(index) * 60))
            default: break
            }
            context.insert(note)
        }
        for index in 0..<40 {
            let meeting = MeetingRecord(title: "Weekly sync \(index + 1)", appName: "Zoom", templateID: "general")
            meeting.status = "ready"
            meeting.binderID = binders[index % binders.count].id
            meeting.kind = index % 8 == 7 ? MeetingRecord.conversationKind : "meeting"
            meeting.createdAt = index < 3 ? today.addingTimeInterval(Double(index + 1) * 1_800) : yesterday.addingTimeInterval(-Double(index) * 86_400)
            if index == 2 { meeting.kind = MeetingRecord.conversationKind }
            if index == 1 { meeting.status = "trivial"; meeting.kind = MeetingRecord.conversationKind }
            meeting.summary = "## Action items\n- [ ] Sam: send the agenda for sync \(index + 1)\n- [x] Book the room"
            context.insert(meeting)
        }
        let load = BinderRecord(name: "Ops", colorIndex: 4)
        context.insert(load)
        for index in 0..<200 {
            let column: BoardColumn = index < 150 ? .done : (index % 5 == 0 ? .ready : .backlog)
            let card = TaskCard(title: "Ops task \(index + 1)", binderID: load.id, column: column)
            card.updatedAt = index < 150 ? yesterday.addingTimeInterval(-Double(index) * 3_600) : today.addingTimeInterval(Double(index))
            context.insert(card)
            for step in 0..<3 {
                let event = TaskEvent(taskID: card.id, kind: step == 2 && column == .done ? .completed : .comment, author: .you, text: "Step \(step)",
                                      to: step == 2 && column == .done ? .done : nil)
                event.createdAt = card.updatedAt.addingTimeInterval(Double(step - 2) * 60)
                context.insert(event)
            }
        }
        store.save()

        let noActions = TaskActions(openMeeting: { _ in }, openNote: { _ in }, commitments: CommitmentActions(
            toggle: { controller.commitments.toggle($0) }, dismiss: { controller.commitments.setStatus($0, "dismissed") }, open: { _ in }))
        func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) async {
            for _ in 0..<Int(seconds * 20) where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
        }
        func all<T: PersistentModel>(_ type: T.Type, _ sort: [SortDescriptor<T>] = []) -> [T] {
            (try? context.fetch(FetchDescriptor<T>(sortBy: sort))) ?? []
        }

        // MARK: Home
        // What 0.8.0's page read and worked out each time it drew: every meeting and note.
        var started = Date()
        let everyMeeting = all(MeetingRecord.self, [SortDescriptor(\.createdAt, order: .reverse)])
        let everyNote = all(NoteItem.self, [SortDescriptor(\.updatedAt, order: .reverse)])
        let everyPromise = all(CommitmentRecord.self, [SortDescriptor(\.createdAt, order: .reverse)])
        let reference = TaskCollector.collect(meetings: Array(everyMeeting.prefix(30)), notes: Array(everyNote.prefix(80)), commitments: Array(everyPromise.prefix(60)),
                                              openMeeting: { _ in }, openNote: { _ in })
        let everyMeetingByBinder = Dictionary(grouping: everyMeeting.filter { !$0.isConversation }, by: \.binderID)
        let everyNoteByBinder = Dictionary(grouping: everyNote, by: \.binderID)
        let oldDraw = ms(since: started)

        let home = HomeData()
        started = Date()
        home.start(noActions)
        let newRead = ms(since: started)
        await waitUntil { home.activity != nil && home.statsRead }
        started = Date()
        home.readSources()
        let again = ms(since: started)
        print("HOME: \(everyNote.count) notes; reading what the page shows took \(newRead) ms on the main thread (\(again) ms after a save), "
              + "where 0.8.0 read and worked out \(oldDraw) ms each time it drew")
        check(Set(home.tasks.map(\.id)) == Set(reference.map(\.id)) && home.tasks.count == reference.count,
              "Home's to-dos are the ones reading everything gave: \(home.tasks.count)")
        check(home.openCount == reference.filter { !$0.done }.count, "and the open count: \(home.openCount)")
        let countsAgree = store.binders(includeArchived: true).allSatisfy { binder in
            let meetings = everyMeetingByBinder[binder.id] ?? [], notes = everyNoteByBinder[binder.id] ?? []
            let counted = home.activity?[binder.id]
            return counted?.meetings == meetings.count && counted?.notes == notes.count
                && counted?.last == (meetings.map(\.createdAt) + notes.map(\.updatedAt)).max()
        }
        check(countsAgree, "each binder's meetings, notes and last change are counted, not read, and come out the same")
        let usage = all(TranscriptRecord.self).filter { $0.mode == "dictation" && $0.status == "inserted" }
            .map { UsageRecord(date: $0.createdAt, words: $0.wordCount, duration: $0.duration) }
        check(home.stats == StatsCalculator.compute(usage) && home.daily.map(\.words) == StatsCalculator.dailyWords(usage).map(\.words),
              "the stats and the chart are worked out off the main thread, the same: \(home.stats.wordsThisWeek) words this week")

        if let task = home.tasks.first(where: { !$0.done && $0.kind == .meeting }) {
            task.toggle()
            await waitUntil(1) { home.tasks.first { $0.id == task.id }?.done == true }
            check(home.tasks.first { $0.id == task.id }?.done == true, "a to-do ticked on Home shows ticked at once, before anything is saved")
        } else {
            check(false, "Home has a meeting's to-do to tick")
        }
        // Typing elsewhere: in a note older than the latest 80 it costs Home nothing; in one of them, a collect per change.
        // (Autosave waits meanwhile, so no save lands in the middle.)
        context.autosaveEnabled = false
        let (reads, collects) = (home.reads, home.collects)
        let old = everyNote[1_000]
        for index in 0..<20 {
            old.text += " \(index)"
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(100))
        check(home.reads == reads && home.collects == collects, "typing in an old note, unsaved, costs Home nothing")
        if let recent = everyNote.first {
            for index in 0..<5 {
                recent.text += " \(index)"
                try? await Task.sleep(for: .milliseconds(30))
            }
            check(home.reads == reads && (1...5).contains(home.collects - collects),
                  "typing in one of its latest notes collects its to-dos again, without reading: \(home.collects - collects) for 5 changes")
        }
        context.autosaveEnabled = true
        let harborNotes = home.activity?[harbor.id]?.notes ?? 0
        let fresh = NoteItem(text: "# Call the venue\n\n- [ ] Ask about the projector")
        fresh.binderID = harbor.id
        store.insert(fresh)
        await waitUntil { home.tasks.contains { $0.text == "Ask about the projector" } && home.activity?[harbor.id]?.notes == harborNotes + 1 }
        check(home.tasks.contains { $0.text == "Ask about the projector" }, "a new note's to-do reaches Home after its save")
        check(home.activity?[harbor.id]?.notes == harborNotes + 1, "and its binder counts one more note")
        if let oldest = everyNote.last(where: { $0.binderID == harbor.id }) {
            store.delete(oldest)
            await waitUntil { home.activity?[harbor.id]?.notes == harborNotes }
            check(home.activity?[harbor.id]?.notes == harborNotes, "a note deleted, long after the latest 80, is counted out")
        }

        // The cards made from Home's to-dos, read by their to-dos rather than every card made from one.
        let refs = home.tasks.filter { !$0.done }.map(\.ref)
        if let first = home.tasks.first(where: { !$0.done }) { controller.board.create(from: first.todo, column: .ready, by: .you) }
        let linked = (try? context.fetch(FetchDescriptor<TaskCard>(predicate: TaskBoard.cards(for: refs)))) ?? []
        let expectedLinked = all(TaskCard.self).filter { $0.sourceRef.map(refs.contains) ?? false }
        check(!linked.isEmpty && Set(linked.map(\.id)) == Set(expectedLinked.map(\.id)), "the to-do list reads only its own to-dos' cards: \(linked.count)")

        // MARK: Today
        func everything(on day: Date) -> (daily: NoteItem?, notes: [NoteItem], due: [NoteItem], meetings: [MeetingRecord], conversations: [MeetingRecord],
                                          moved: [UUID], tasks: [String]) {
            let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let isToday = calendar.isDateInToday(day)
            func onDay(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: day) }
            let title = TodayView.dailyTitle(for: day)
            let notes = all(NoteItem.self, [SortDescriptor(\.updatedAt, order: .reverse)])
            let meetings = all(MeetingRecord.self, [SortDescriptor(\.createdAt)]).filter { $0.createdAt >= day && $0.createdAt < end }
            let events = all(TaskEvent.self, [SortDescriptor(\.createdAt, order: .reverse)]).filter { $0.createdAt >= day && $0.createdAt < end }
            let cards = all(TaskCard.self)
            var seen = Set<UUID>()
            let moved = events.filter { seen.insert($0.taskID).inserted }.map(\.taskID).filter { id in cards.contains { $0.id == id } }
            let promises = all(CommitmentRecord.self, [SortDescriptor(\.createdAt, order: .reverse)]).filter { record in
                guard record.status != "dismissed" else { return false }
                if onDay(record.createdAt) { return true }
                return isToday && record.status == "open" && (record.dueAt.map { $0 < end } ?? false)
            }
            let held = meetings.filter { !$0.isConversation }, captures = meetings.filter { $0.isConversation && $0.status != "trivial" }
            return (notes.first { $0.title == title }, notes.filter { onDay($0.updatedAt) && $0.title != title },
                    notes.filter { note in
                        guard let due = note.dueAt, note.status != "Done" else { return false }
                        return onDay(due) || (isToday && due < day)
                    },
                    held, captures, moved,
                    TaskCollector.collect(meetings: held + captures, notes: [], commitments: promises, openMeeting: { _ in }, openNote: { _ in }).map(\.id))
        }
        for (name, day) in [("today", today), ("yesterday", yesterday)] {
            let page = TodayData()
            started = Date()
            page.show(day, actions: noActions)
            let read = ms(since: started)
            started = Date()
            page.read()
            let again = ms(since: started)
            let expected = everything(on: day)
            print("TODAY (\(name)): read in \(read) ms (\(again) ms after a save); \(page.notes.count) + \(page.moreNotes) notes worked on, "
                  + "\(page.dueNotes.count) due, \(page.moved.count) cards moved")
            check(page.dailyNote?.id == expected.daily?.id, "\(name): the day's own note is found by its date")
            check(page.notes.map(\.id) == Array(expected.notes.prefix(TodayData.noteLimit)).map(\.id)
                  && page.moreNotes == max(0, expected.notes.count - TodayData.noteLimit),
                  "\(name): notes worked on that day, the latest first, at most \(TodayData.noteLimit) and the rest counted: \(expected.notes.count)")
            check(Set(page.dueNotes.map(\.id)) == Set(expected.due.map(\.id))
                  && page.dueNotes.map { $0.dueAt ?? .distantPast } == page.dueNotes.map { $0.dueAt ?? .distantPast }.sorted(),
                  "\(name): notes due\(day == today ? ", and overdue," : "") and not done, the earliest first: \(expected.due.count)")
            check(page.meetings.map(\.id) == expected.meetings.map(\.id) && page.conversations.map(\.id) == expected.conversations.map(\.id),
                  "\(name): the day's meetings and captures, without the small talk")
            check(page.moved.map(\.card.id) == expected.moved, "\(name): cards moved that day, read by their ids: \(expected.moved.count)")
            check(page.tasks.map(\.id) == expected.tasks, "\(name): the day's to-dos and promises: \(expected.tasks.count)")
            guard day == today else { continue }
            // The day's note, written in: typing reads nothing again until it's saved.
            let note = NoteItem(text: "# \(TodayView.dailyTitle(for: day))\n\nOpened the doors.")
            note.binderID = store.defaultBinder().id
            store.insert(note)
            await waitUntil { page.dailyNote?.id == note.id }
            check(page.dailyNote?.id == note.id, "today: a day's note made elsewhere reaches the page after its save")
            context.autosaveEnabled = false
            let readsBefore = page.reads
            for index in 0..<20 {
                note.text += " \(index)"
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(100))
            check(page.reads == readsBefore, "today: typing in the day's note reads nothing again")
            store.save()
            await waitUntil { page.reads > readsBefore }
            check(page.reads == readsBefore + 1, "today: its save is read once: \(page.reads - readsBefore)")
            context.autosaveEnabled = true
        }

        // MARK: Work streams
        let feed = WorkStreamsFeed.shared
        var builds = feed.builds
        feed.show()
        await waitUntil { feed.builds > builds }
        check(feed.digest == WorkStreams.digest(WorkStreams.cards()), "the digest built off the main thread is the one read on it: \(feed.digest?.headline ?? "none")")
        check(feed.builtOffMain, "and it was built off the main thread")
        if let card = controller.board.cards(in: harbor.id).first(where: { $0.column == .ready }) {
            builds = feed.builds
            try? controller.board.claim(card, by: .you)
            await waitUntil { feed.builds > builds }
            try? await Task.sleep(for: .milliseconds(400))
            check(feed.builds == builds + 1, "one board change, one build: \(feed.builds - builds)")
            check(feed.digest == WorkStreams.digest(WorkStreams.cards()) && feed.digest?.streams.contains { $0.who == BoardActor.you.name } == true,
                  "and the digest shows it: \(feed.digest?.headline ?? "")")
            builds = feed.builds
            for index in 0..<10 { controller.board.comment(card, text: "Progress \(index)", by: .you) }
            await waitUntil { feed.builds > builds }
            try? await Task.sleep(for: .milliseconds(400))
            check(feed.builds - builds <= 2, "ten saves in a row are built once or twice: \(feed.builds - builds)")
            builds = feed.builds
            store.insert(NoteItem(text: "# Not a card"))
            try? await Task.sleep(for: .milliseconds(600))
            check(feed.builds == builds, "a note's save doesn't build it again")
            feed.hide()
            controller.board.comment(card, text: "Nearly there", by: .you)
            try? await Task.sleep(for: .milliseconds(600))
            check(feed.builds == builds, "with no page showing it, a board change waits")
            feed.show()
            await waitUntil { feed.builds > builds }
            check(feed.builds == builds + 1 && feed.digest == WorkStreams.digest(WorkStreams.cards()), "and is caught up on when a page shows it again")
            feed.hide()
        } else {
            check(false, "the demo board has a card in Ready")
        }

        // MARK: The pages at the default window, and the board's columns
        func page(_ configure: (HubNavigation) -> Void) -> some View {
            let navigation = HubNavigation()
            navigation.binderID = harbor.id
            configure(navigation)
            return HubView().environment(navigation).environment(controller).environment(controller.meetings)
                .environment(controller.knowledge).environment(controller.team).environment(controller.capture)
                .environment(controller.commitments).environment(AppSettings.shared).modelContainer(Store.shared.container)
        }
        func show<V: View>(_ view: V, size: NSSize, name: String, wait: Double = 1.5) async -> (NSWindow, NSView) {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let hosting = NSHostingView(rootView: view)
            hosting.wantsLayer = true
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            capture(hosting, name: name, directory: directory)
            return (window, hosting)
        }
        let defaultSize = NSSize(width: 1020, height: 720)
        var (window, _) = await show(page { $0.selection = .home }, size: defaultSize, name: "pages-home")
        window.close()
        (window, _) = await show(page { $0.selection = .today }, size: defaultSize, name: "pages-today")
        window.close()
        (window, _) = await show(page { $0.selection = .work }, size: defaultSize, name: "pages-work")
        window.close()
        for (size, name) in [(defaultSize, "pages-board"), (NSSize(width: 1500, height: 800), "pages-board-wide")] {
            BoardView.lastLayout = nil
            (window, _) = await show(page { $0.selection = .binder; $0.pendingBinderTab = .board }, size: size, name: name)
            if let last = BoardView.lastLayout {
                let (layout, width) = last
                let columns = BoardColumn.allCases.map { "\($0.title) \(layout.folded.contains($0) ? "folded" : "\(Int(layout.columnWidth)) pt")" }
                print("BOARD at \(Int(size.width)) pt (\(Int(width)) pt for the board): \(columns.joined(separator: ", "))")
                let inView = [BoardColumn.blocked, .review].allSatisfy { layout.span(of: $0).upperBound <= width + 0.5 }
                if size == defaultSize {
                    check(layout.folded == [.backlog, .done] && !layout.scrolls(in: width) && inView,
                          "at the default window Backlog and Done fold, and Blocked and Review show in full, without scrolling sideways")
                } else {
                    check(layout.folded.isEmpty && !layout.scrolls(in: width), "a wide window shows all six columns open")
                }
            } else {
                check(false, "the board was drawn at \(Int(size.width)) pt")
            }
            window.close()
        }

        // MARK: The graph
        let selection = GraphSelection()
        let entity = await controller.knowledge.store.entities(limit: 1).first
        let graphSize = NSSize(width: 900, height: 600)
        let graphView = KnowledgeGraphView(selectedEntityID: Binding(get: { selection.id }, set: { selection.id = $0 })).environment(controller.knowledge)
        var drawn = KnowledgeGraphView.framesDrawn
        (window, _) = await show(graphView.padding(16), size: graphSize, name: "pages-graph", wait: 5)
        let bloom = KnowledgeGraphView.framesDrawn - drawn
        drawn = KnowledgeGraphView.framesDrawn
        try? await Task.sleep(for: .milliseconds(1500))
        check(bloom > 30, "the graph blooms: \(bloom) frames")
        check(KnowledgeGraphView.framesDrawn == drawn, "once settled it draws nothing more: \(KnowledgeGraphView.framesDrawn - drawn) frames in 1.5 s")
        if let entity {
            selection.id = entity.id
            try? await Task.sleep(for: .milliseconds(500))
            let pulsing = KnowledgeGraphView.framesDrawn - drawn
            try? await Task.sleep(for: .milliseconds(1700))
            drawn = KnowledgeGraphView.framesDrawn
            try? await Task.sleep(for: .milliseconds(1000))
            check(pulsing > 5 && KnowledgeGraphView.framesDrawn == drawn,
                  "selecting a node pulses it, and then the graph holds still again: \(pulsing) frames, then \(KnowledgeGraphView.framesDrawn - drawn)")
        }
        window.close()
        drawn = KnowledgeGraphView.framesDrawn
        let still = KnowledgeGraphView(selectedEntityID: .constant(entity?.id), reduceMotionOverride: true).environment(controller.knowledge)
        (window, _) = await show(still.padding(16), size: graphSize, name: "pages-graph-reduce-motion", wait: 2)
        check(KnowledgeGraphView.framesDrawn - drawn <= 6, "with Reduce Motion it shows settled without animating: \(KnowledgeGraphView.framesDrawn - drawn) frames")
        window.close()

        print(failures == 0 ? "PAGES_OK" : "PAGES_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

/// A selection the graph's self-test changes from outside.
@MainActor
@Observable
private final class GraphSelection {
    var id: Int64?
}
