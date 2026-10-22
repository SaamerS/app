import AppKit
import SwiftUI
import SwiftData
import BindersKit

/// Lane DB10's self-test, on TeamDBTestBed's throwaway Postgres: a binder shared through the team database with 4 folders
/// and 400 notes, opened in the hub (its Overview, then Notes) while every statement to the database takes 80 ms, as over a
/// VPN to a server far away. A watchdog on the main thread says how long it stalled.
///
///     Binders --selftest-teamdb-open-perf   the binder opened while its 400 notes wait in the outbox and go, once they've
///                                           gone, and while a teammate types into one of them every half a second; then
///                                           what's on disk read back as after a crash and after quitting
///
/// BINDERS_SELFTEST_LATENCY_MS sets the round trip (80 by default); BINDERS_SELFTEST_NOTES the number of notes (400).
extension SelfTest {
    /// The main thread's pulse, every 5 ms: the longest it went without one, and the time spent in gaps over 50 ms.
    @MainActor
    final class MainWatchdog {
        private var timer: Timer?
        private var last = Date()
        private(set) var longest: TimeInterval = 0
        private(set) var over50: TimeInterval = 0
        private(set) var over100 = 0

        func start() {
            reset()
            let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.beat() }
            }
            timer.tolerance = 0
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func reset() {
            last = Date()
            lastCPU = Self.cpu()
            longestCPU = 0
            longest = 0
            over50 = 0
            over100 = 0
        }

        /// Counts the time since the last beat too: a stall that just ended, before the timer has had its turn.
        func sample() { beat() }

        func stop() {
            beat()
            timer?.invalidate()
            timer = nil
        }

        /// The longest the main thread itself ran without a beat (its own CPU time): what a stall costs apart from other
        /// processes taking the machine meanwhile.
        private(set) var longestCPU: TimeInterval = 0
        private var lastCPU: TimeInterval = 0

        /// The main thread's CPU time so far (the timer beats on it).
        private static func cpu() -> TimeInterval {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let thread = mach_thread_self()
            defer { mach_port_deallocate(mach_task_self_, thread) }
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
            }
            guard result == KERN_SUCCESS else { return 0 }
            return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
        }

        private func beat() {
            let now = Date()
            let gap = now.timeIntervalSince(last)
            let cpu = Self.cpu()
            last = now
            longest = max(longest, gap)
            longestCPU = max(longestCPU, cpu - lastCPU)
            lastCPU = cpu
            if gap > 0.05 { over50 += gap }
            if gap > 0.1 { over100 += 1 }
        }

        var line: String {
            "longest stall \(Int(longest * 1000)) ms, \(Int(over50 * 1000)) ms in stalls over 50 ms, \(over100) over 100 ms"
        }
    }

    /// One variant's numbers.
    struct OpenPerf {
        var name: String
        var overview: TimeInterval = 0
        var list: TimeInterval?
        var longest: TimeInterval = 0
        var longestCPU: TimeInterval = 0
        var over50: TimeInterval = 0
        var over100 = 0
        var counts = TeamPerf.Counts()
        var storeSaves = 0

        var line: String {
            let c = counts
            return "\(name): Overview drawn in \(Int(overview * 1000)) ms, list shown in \(list.map { "\(Int($0 * 1000)) ms" } ?? "never"); "
                + "longest stall \(Int(longest * 1000)) ms (longest on the main thread's own CPU \(Int(longestCPU * 1000)) ms), "
                + "\(Int(over50 * 1000)) ms in stalls over 50 ms, \(over100) over 100 ms; "
                + "sweeps \(c.sweeps) (\(c.fullSweeps) full, \(c.notesSwept) notes looked at), engine saves \(c.engineSaves) (\(c.engineBytes / 1024) KB), "
                + "documents written \(c.documentWrites) (\(c.documentBytes / 1024) KB), outbox saves \(c.outboxSaves) (\(c.outboxBytes / 1024) KB), "
                + "outbox appends \(c.outboxAppends) (\(c.outboxAppendBytes / 1024) KB), note rows read \(c.noteRowsRead) (\(c.documentsRead) with documents), "
                + "store saves \(storeSaves)"
        }
    }

    @MainActor
    static func teamOpenPerfChecks(_ bed: TeamDBTestBed) async throws {
        let environment = ProcessInfo.processInfo.environment
        let latency = environment["BINDERS_SELFTEST_LATENCY_MS"].flatMap(Int.init) ?? 80
        let total = environment["BINDERS_SELFTEST_NOTES"].flatMap(Int.init) ?? 400
        let mac = try await TeamMac.start(bed)
        let team = mac.team
        let notes = team.notes
        let store = Store.shared
        let root = try await bed.root()
        AppDefaults.store.set(false, forKey: "notesShowMarkdown")

        // MARK: The binder: 4 folders, 3 notes in 4 in them, the rest at its top.
        let binder = BinderRecord(name: "Team binder", colorIndex: 2)
        store.insert(binder)
        let folders = ["Design", "Plans", "Ops", "Ideas"].map { FolderRecord(name: $0, binderID: binder.id) }
        folders.forEach { store.context.insert($0) }
        var ids: [UUID] = []
        var inFolder: [UUID: UUID] = [:]
        let filed = total * 3 / 4
        for index in 0..<total {
            let folder = index < filed ? folders[index % folders.count].id : nil
            let note = NoteItem(text: Self.perfNote(index))
            note.binderID = binder.id
            note.folderID = folder
            note.createdAt = Date().addingTimeInterval(-Double(total - index) * 3600)
            note.updatedAt = note.createdAt
            store.context.insert(note)
            ids.append(note.id)
            if let folder { inFolder[note.id] = folder }
        }
        store.save()
        bed.check(true, "a binder with \(folders.count) folders and \(total) notes (\(filed) in folders)")

        // Saves of the library, counted.
        var storeSaves = 0
        let saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { storeSaves += 1 }
        }
        defer { NotificationCenter.default.removeObserver(saveObserver) }
        let watchdog = MainWatchdog()
        watchdog.start()
        defer { watchdog.stop() }
        func begin(_ phase: String) {
            print("PERF-PHASE \(phase)")
            fflush(stdout)
            // For a profiler to attach first (BINDERS_SELFTEST_SAMPLE_WAIT, in seconds).
            if let wait = environment["BINDERS_SELFTEST_SAMPLE_WAIT"].flatMap(Double.init) { Thread.sleep(forTimeInterval: wait) }
            TeamPerf.shared.reset()
            storeSaves = 0
            watchdog.reset()
        }
        func finish(_ perf: inout OpenPerf) {
            watchdog.sample()
            perf.longest = watchdog.longest
            perf.longestCPU = watchdog.longestCPU
            perf.over50 = watchdog.over50
            perf.over100 = watchdog.over100
            perf.counts = TeamPerf.shared.now
            perf.storeSaves = storeSaves
            print("PERF \(perf.line)")
            fflush(stdout)
        }

        // MARK: Sharing it: all its notes go into the outbox, held there (the database slow to take them).
        final class Hold { var on = true }
        let hold = Hold()
        team.database?.testHooks.holdBeforeSending = { _ in hold.on }
        TeamDatabaseLink.testLatency.value = .milliseconds(latency)
        begin("sharing")
        team.share(binder, everyone: true, with: [])
        let queued = await bed.eventually(120) { (notes.engine?.states.count ?? 0) >= total && (team.database?.waiting ?? 0) >= total }
        var sharing = OpenPerf(name: "sharing \(total) notes (held in the outbox)")
        finish(&sharing)
        bed.check(queued, "shared: every note waits in the outbox (\(notes.engine?.states.count ?? 0) notes, \(team.database?.waiting ?? 0) waiting)")

        // MARK: The hub, on this binder: Overview, then Notes.
        func hub(_ navigation: HubNavigation) -> some View {
            HubView().environment(navigation).environment(mac.controller).environment(mac.controller.meetings)
                .environment(mac.controller.knowledge).environment(mac.controller.team).environment(mac.controller.capture)
                .environment(mac.controller.commitments).environment(AppSettings.shared).modelContainer(store.container)
        }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews { if let found = table(in: sub) { return found } }
            return nil
        }
        /// The hub open on another binder first (the window is up already, as when you click a binder in its sidebar); then,
        /// measured from `phase`, the binder's Overview, its Notes after `overviewFor`, and the window kept open `notesFor`.
        func open(_ perf: inout OpenPerf, phase: String, overviewFor: Double = 2, notesFor: Double = 3, select: UUID? = nil,
                  begun: (() -> Void)? = nil, meanwhile: (() async -> Void)? = nil, opening: BinderRecord? = nil) async {
            let target = opening ?? binder
            let navigation = HubNavigation()
            navigation.binderID = store.defaultBinder().id
            navigation.selection = .binder
            navigation.pendingBinderTab = .overview
            NotesView.selectOnOpen = select.map { [$0] }
            defer { NotesView.selectOnOpen = nil }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 1020, height: 720)),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let hosting = NSHostingView(rootView: hub(navigation))
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1500))
            var shown: Date?
            BinderOverview.appeared = { id in if id == target.id, shown == nil { shown = Date() } }
            defer { BinderOverview.appeared = nil }
            begin(phase)
            begun?()
            let started = Date()
            navigation.binderID = target.id
            navigation.pendingBinderTab = .overview
            while shown == nil, Date().timeIntervalSince(started) < 5 { try? await Task.sleep(for: .milliseconds(2)) }
            perf.overview = (shown ?? Date()).timeIntervalSince(started)
            try? await Task.sleep(for: .milliseconds(Int(overviewFor * 1000)))
            let asked = Date()
            navigation.pendingBinderTab = .notes
            let wanted = min(40, total / 4)
            while Date().timeIntervalSince(asked) < 5 {
                if let rows = table(in: hosting)?.numberOfRows, rows >= wanted {
                    perf.list = Date().timeIntervalSince(asked)
                    break
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            if let meanwhile {
                await meanwhile()
            } else {
                try? await Task.sleep(for: .milliseconds(Int(notesFor * 1000)))
            }
            finish(&perf)
            window.close()
            try? await Task.sleep(for: .milliseconds(100))
        }
        /// The bar: no stall over 100 ms of the main thread's own work, and the list within 300 ms. The wall-clock stall is
        /// printed beside it; on a machine busy with other work it's longer by however long others held the processor.
        func passes(_ perf: OpenPerf) {
            bed.check(perf.longestCPU <= 0.1 && (perf.list ?? 9) <= 0.3,
                      "\(perf.name): no stall over 100 ms of work on the main thread (\(Int(perf.longestCPU * 1000)) ms; \(Int(perf.longest * 1000)) ms by the clock) "
                        + "and the list within 300 ms (\(perf.list.map { "\(Int($0 * 1000)) ms" } ?? "never"))")
        }

        // MARK: 1. Opened with every note waiting in the outbox, going at \(latency) ms a statement.
        try? await Task.sleep(for: .milliseconds(1500))
        var backlog = OpenPerf(name: "outbox backlogged (\(total) waiting, \(latency) ms)")
        await open(&backlog, phase: "backlog", begun: { hold.on = false })
        passes(backlog)
        let leftWaiting = team.database?.waiting ?? 0
        bed.check(leftWaiting > 0, "notes still waited while it was open: \(leftWaiting)")

        // What's on disk now, read as a Mac that crashed this moment would: the outbox and the notes' states.
        try? await Task.sleep(for: .milliseconds(1500))
        if let folder = team.folder {
            let read = TeamDatabaseFiles.read(folder, keepingAside: false)
            let here = team.database?.queued.map(\.id) ?? []
            let there = read.outbox.items.map(\.id)
            bed.check(Set(there).isSuperset(of: Set(here)) && there.count <= here.count + 2,
                      "after a crash, the outbox on disk has every change still waiting (\(there.count) on disk, \(here.count) waiting)")
            let states = (try? Data(contentsOf: folder.appendingPathComponent("notes/notes.json")))
                .flatMap { try? JSONDecoder().decode([UUID: TeamNoteEngine.NoteState].self, from: $0) } ?? [:]
            bed.check(states.count == total, "and the notes' states: \(states.count) of \(total)")
        }

        // Every note goes, quickly now.
        TeamDatabaseLink.testLatency.value = nil
        let drained = await mac.drained(240)
        bed.check(drained, "the outbox drained: \(team.database?.waiting ?? -1) left")
        let there = try await root.value("SELECT count(*) FROM binders.notes WHERE binder_id = $1::uuid AND deleted_at IS NULL",
                                         [binder.id.uuidString.lowercased()], as: Int64.self) ?? -1
        let filedThere = try await root.value("SELECT count(*) FROM binders.notes WHERE binder_id = $1::uuid AND folder_id IS NOT NULL AND deleted_at IS NULL",
                                              [binder.id.uuidString.lowercased()], as: Int64.self) ?? -1
        bed.check(there == Int64(total) && filedThere == Int64(filed), "the database has every note once, \(filedThere) in folders (\(there) notes)")

        // MARK: 2. Opened once everything has gone.
        TeamDatabaseLink.testLatency.value = .milliseconds(latency)
        try? await Task.sleep(for: .milliseconds(2500))
        var quiet = OpenPerf(name: "outbox drained (\(latency) ms)")
        await open(&quiet, phase: "drained")
        passes(quiet)

        // MARK: For comparison: the same notes in a binder of this Mac's own, which the team database has nothing to do with.
        let own = BinderRecord(name: "Own binder", colorIndex: 4)
        store.insert(own)
        let ownFolders = ["Design", "Plans", "Ops", "Ideas"].map { FolderRecord(name: $0, binderID: own.id) }
        ownFolders.forEach { store.context.insert($0) }
        for index in 0..<total {
            let note = NoteItem(text: Self.perfNote(index))
            note.binderID = own.id
            note.folderID = index < filed ? ownFolders[index % ownFolders.count].id : nil
            note.createdAt = Date().addingTimeInterval(-Double(total - index) * 3600)
            note.updatedAt = note.createdAt
            store.context.insert(note)
        }
        store.save()
        try? await Task.sleep(for: .milliseconds(2500))
        var reference = OpenPerf(name: "for comparison, the same \(total) notes in a binder that isn't shared")
        await open(&reference, phase: "reference", opening: own)
        // What the team database adds to opening it: nothing beyond drawing as many notes (50 ms of leeway for a busy machine).
        for perf in [backlog, quiet] {
            bed.check(perf.longestCPU <= reference.longestCPU + 0.05,
                      "\(perf.name): the main thread's longest stall is no longer than for the binder that isn't shared "
                        + "(\(Int(perf.longestCPU * 1000)) ms against \(Int(reference.longestCPU * 1000)) ms)")
        }

        // MARK: 3. Opened while a teammate types into one of its notes every half a second for 20 seconds.
        TeamDatabaseLink.testLatency.value = nil
        let alex = try await NotesMac.start(bed)
        let typedIn = ids[filed + 1]
        let caughtUp = await bed.eventually(120) { alex.engine.knows(typedIn) && !alex.text(typedIn).isEmpty }
        bed.check(caughtUp, "the teammate's Mac has the binder's notes")
        try? await alex.be(in: typedIn)
        TeamDatabaseLink.testLatency.value = .milliseconds(latency)
        try? await Task.sleep(for: .milliseconds(2500))
        var typing = OpenPerf(name: "a teammate typing every 500 ms (\(latency) ms)")
        var words = 0
        await open(&typing, phase: "typing", select: typedIn, meanwhile: {
            let until = Date().addingTimeInterval(20)
            while Date() < until {
                words += 1
                alex.type(typedIn, alex.text(typedIn) + " word\(words)")
                try? await Task.sleep(for: .milliseconds(500))
            }
        })
        passes(typing)
        let heard = await bed.eventually(30) { store.note(typedIn)?.text.contains("word\(words)") == true }
        bed.check(heard, "every word the teammate typed is in the note here (\(words) words)")
        TeamDatabaseLink.testLatency.value = nil
        _ = await alex.drained()
        await alex.stop()

        // MARK: Quitting with changes waiting: what's on disk is what this Mac had, in the file an earlier Binders reads.
        hold.on = true
        for id in ids.prefix(30) { store.note(id)?.text += "\nEdited before quitting." }
        store.save()
        let edited = await bed.eventually(20) { (team.database?.waiting ?? 0) >= 30 }
        bed.check(edited, "30 notes edited, their changes waiting: \(team.database?.waiting ?? 0)")
        let statesBefore = notes.engine?.states ?? [:]
        let waitingBefore = team.database?.queued.map(\.id) ?? []
        let folderURL = team.folder
        // As quitting does (AppDelegate).
        TeamBoard.current?.flushToDisk()
        if let folderURL {
            let file = (try? Data(contentsOf: folderURL.appendingPathComponent("outbox.json"))).flatMap { try? TeamOutbox(data: $0) }
            bed.check(file?.items.map(\.id) == waitingBefore, "on quitting, outbox.json alone has every change waiting (\(file?.count ?? -1) of \(waitingBefore.count))")
            let states = (try? Data(contentsOf: folderURL.appendingPathComponent("notes/notes.json")))
                .flatMap { try? JSONDecoder().decode([UUID: TeamNoteEngine.NoteState].self, from: $0) } ?? [:]
            bed.check(states == statesBefore, "and notes.json every note's state as it was (\(states.count))")
        }
        await mac.stop()
        // Kept until the process ends: the knowledge it publishes may still be finishing a call.
        Self.keptForTheEnd.append(mac)
        if let folderURL {
            let read = TeamDatabaseFiles.read(folderURL, keepingAside: false)
            bed.check(read.outbox.items.map(\.id) == waitingBefore, "opened again, the outbox reads back as it was (\(read.outbox.count))")
        }
        print("PERF SUMMARY")
        for perf in [sharing, backlog, quiet, reference, typing] { print("PERF \(perf.line)") }
    }

    @MainActor static var keptForTheEnd: [AnyObject] = []

    /// A note of about 1,500 characters: a title, paragraphs, and to-dos.
    static func perfNote(_ index: Int) -> String {
        let topics = ["the booth", "the launch post", "the crates", "the second morning", "the pipeline", "the stand"]
        let topic = topics[index % topics.count]
        var text = "# Note \(index): \(topic)\n\n"
        for paragraph in 0..<4 {
            text += "Paragraph \(paragraph) about \(topic): what we saw, what we decided and what's still open. "
            text += String(repeating: "The quick brown fox jumps over the lazy dog near \(topic). ", count: 4) + "\n\n"
        }
        text += "- [ ] Ask Sam about \(topic) (\(index))\n- [x] Sent the draft for \(topic)\n- [ ] Book the room for \(index % 7 + 1) May\n"
        return text
    }
}
