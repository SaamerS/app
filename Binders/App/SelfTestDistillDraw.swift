import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// Drawings of Distill on the Mac, to look at: a spec with its Work bar and Work panel, the review sheet, the report,
    /// the binder's Work list, the note's history and a distilled card. Fictional data in a throwaway folder
    /// (BINDERS_DATA_DIR), with the stand-in model and stand-in agents; PNGs in the folder given.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-distill-draw <folder> -notesShowMarkdown NO
    @MainActor
    static func distillDrawSelfTest(to directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder")
            return 1
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = DictationController()
        let store = Store.shared
        let board = controller.board
        let service = controller.distill
        service.model = { DistillModelStandIn() }
        service.settleDelay = .seconds(600)
        let registry = AgentRegistry.shared
        registry.upsert(AgentProfile(name: "Claude Code · checkout", wake: .board, purpose: "the checkout's web pages and payments"))
        registry.upsert(AgentProfile(name: "Pennant", wake: .board, purpose: "errands and email"))
        let web = BinderRecord(name: "Web", colorIndex: 2)
        store.insert(web)
        let note = NoteItem(text: DistillBench.specs[0].text)
        note.binderID = web.id
        note.distill = true
        store.insert(note)
        guard case .success(var proposal) = await service.distill(note) else { return 1 }
        let names = ["Claude Code · checkout", "Claude Code · checkout", "Claude Code · checkout", "Pennant", "Claude Code · checkout",
                     "Claude Code · checkout", "Claude Code · checkout", "You"]
        for index in proposal.items.indices { proposal.items[index].meantFor = names[index] }
        service.save(proposal)
        let cards = service.place(proposal, items: Set(proposal.items.prefix(7).map(\.id)), column: .ready)
        let agent = BoardActor(name: "Claude Code · checkout", kind: .agent)
        if cards.count == 7 {
            try? board.claim(cards[0], by: agent)
            try? board.complete(cards[0], summary: "One page.", by: agent)
            try? board.move(cards[0], to: .done, by: .you)
            try? board.claim(cards[1], by: agent)
            board.report(cards[1], progress: "Checking numbers as they're typed; the error shows under the field.", by: agent)
            try? board.claim(cards[2], by: agent)
            try? board.ask(cards[2], question: "Should the buttons show for card numbers saved in the browser too?", by: agent)
            try? board.claim(cards[4], by: agent)
            try? board.complete(cards[4], summary: "Failures are logged with their codes.", by: agent)
        }
        // A section changed after its cards were made, by an agent.
        let before = note.text
        note.text = before.replacingOccurrences(of: "offer Retry.", with: "offer Retry, and say why it failed.")
        NoteHistory.changed(note.id, previous: before, by: .agent("Pennant"))
        try? await Task.sleep(for: .milliseconds(200))
        // A second reading to review: what Distill again would offer is drawn with the first's waiting items.
        let review = DistillStore.shared.distill(proposal.id, of: note.id) ?? proposal

        func draw(_ view: some View, _ name: String, size: NSSize) async {
            let root = AnyView(view.environment(controller).environment(HubWindowController.shared.navigation).environment(controller.team)
                .environment(controller.knowledge).environment(controller.meetings).environment(controller.capture)
                .environment(controller.commitments).environment(AppSettings.shared).modelContainer(store.container)
                .defaultAppStorage(throwawayDefaults))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let hosting = NSHostingView(rootView: root)
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1500))
            capture(hosting, name: name, directory: directory)
            window.close()
            print("DRAWN: \(directory.appendingPathComponent(name).path).png")
        }
        let navigation = HubNavigation()
        navigation.binderID = web.id
        navigation.pendingBinderTab = .notes
        navigation.pendingNoteID = note.id
        navigation.selection = .binder
        await draw(HubView().environment(navigation), "distill-note", size: NSSize(width: 1500, height: 950))
        await draw(DistillReviewSheet(distill: review, note: note), "distill-review", size: NSSize(width: 860, height: 640))
        // Lane DS2: a long note read in parts, one of which gave no list; and the Work bar after a reading with no list.
        var inParts = review
        inParts.parts = 4
        inParts.readNote = "Part 3 of 4 (“Week 13 update” to “Week 18 update”) had no list of work items, even when asked again, so its work isn't here. The model wrote: “## Status summary The projects are mostly on track.” Distill Again to read the note again."
        await draw(DistillReviewSheet(distill: inParts, note: note), "distill-review-parts", size: NSSize(width: 860, height: 640))
        service.problems[note.id] = "The model answered without a list of work items for each of the 4 parts of this note, even when asked again, so the note may be too long for mlx-community/gemma-4-26b-a4b-it-4bit. Distill it with one of your agents instead, or choose another model in Settings → AI."
        service.replyStart[note.id] = "## Status summary The projects are mostly on track. Checkout is in review. …"
        await draw(WorkBar(note: note, panelShown: .constant(false)).padding(16).frame(width: 820).background(BindersTheme.ground), "distill-workbar-nolist",
                   size: NSSize(width: 820, height: 260))
        service.problems[note.id] = nil
        service.replyStart[note.id] = nil
        await draw(DistillReportSheet(note: note), "distill-report", size: NSSize(width: 640, height: 560))
        let overview = HubNavigation()
        overview.binderID = web.id
        overview.pendingBinderTab = .overview
        overview.selection = .binder
        await draw(HubView().environment(overview), "distill-worklist", size: NSSize(width: 1300, height: 800))
        await draw(NoteHistorySheet(note: note), "distill-history", size: NSSize(width: 820, height: 560))
        if cards.count == 7 { await draw(CardDetailView(card: cards[2]), "distill-card", size: NSSize(width: CardLayout.defaultWidth, height: CardLayout.defaultHeight)) }
        // At the main window's own size (1020 × 720): the note with its Work panel beside it, and the review sheet over it.
        let atDefault = HubNavigation()
        atDefault.binderID = web.id
        atDefault.pendingBinderTab = .notes
        atDefault.pendingNoteID = note.id
        atDefault.selection = .binder
        await draw(HubView().environment(atDefault), "distill-note-1020", size: HubWindowController.defaultSize)
        await draw(DistillReviewSheet(distill: review, note: note).frame(maxWidth: .infinity, maxHeight: .infinity).background(BindersTheme.ground),
                   "distill-review-1020", size: HubWindowController.defaultSize)
        // At 1020 the note page has no room for the Work panel beside the note: the panel alone, at its column's width.
        await draw(ScrollView { WorkPanel(note: note).padding(16) }.background(BindersTheme.ground), "distill-panel",
                   size: NSSize(width: 300, height: HubWindowController.defaultSize.height))
        // The note in its own window: its Work bar, then its Work panel in the note's place.
        HubWindowController.shared.controller = HubWindowController.shared.controller ?? controller
        let popoutsKept = AppDefaults.store.data(forKey: "notePopouts")
        let workShown = AppDefaults.store.object(forKey: NotePopouts.workPanelKey)
        for shown in [false, true] {
            AppDefaults.store.set(shown, forKey: NotePopouts.workPanelKey)
            NotePopouts.shared.open(note)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == note.id.uuidString && $0.isVisible }) {
                window.alphaValue = 0
                try? await Task.sleep(for: .milliseconds(1500))
                if let content = window.contentView {
                    let name = "distill-popout\(shown ? "-work" : "")"
                    capture(content, name: name, directory: directory)
                    print("DRAWN: \(directory.appendingPathComponent(name).path).png")
                }
            }
            NotePopouts.shared.close(note.id)
        }
        AppDefaults.store.set(workShown, forKey: NotePopouts.workPanelKey)
        AppDefaults.store.set(popoutsKept, forKey: "notePopouts")
        return 0
    }
}
