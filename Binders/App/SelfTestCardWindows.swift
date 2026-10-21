import AppKit
import SwiftUI
import BindersKit

extension SelfTest {
    /// A card in a window of its own: one window per card, cards as tabs of one card window, over a full-screen Binders
    /// window, in the Window menu; the size you leave it at; Details beside the conversation only from 1000 pt wide; a card
    /// deleted while it's open; a card whose binder is gone; a binders://card link that doesn't take the cursor; and the
    /// conversation keeping to the newest entry, or to what you're reading when you've scrolled up. The windows never show
    /// in a throwaway folder (BINDERS_DATA_DIR), the only place this runs.
    @MainActor
    static func cardWindowsSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        HubWindowController.shared.controller = controller
        CardWindows.shared.controller = controller
        MainMenu.install()
        let board = controller.board
        let windows = CardWindows.shared
        let launch = BinderRecord(name: "Launch", colorIndex: 1)
        Store.shared.insert(launch)
        func card(_ title: String, _ column: BoardColumn = .backlog) -> TaskCard {
            board.create(title: title, binderID: launch.id, column: column, by: .you)
        }
        func settle(_ milliseconds: Int = 700) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
            guard let view else { return nil }
            return (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        AppDefaults.store.removeObject(forKey: CardWindows.sizeKey)
        AppDefaults.store.removeObject(forKey: CardWindows.detailsKey)

        // One window per card; a second card is a tab of it.
        let first = card("Update the pricing table")
        windows.open(first, controller: controller)
        windows.open(first, controller: controller)
        await settle()
        let window = windows.window(for: first.id)
        check(window != nil && NSApp.windows.filter { $0.identifier?.rawValue == "card-\(first.id.uuidString)" }.count == 1,
              "opening a card twice is one window")
        check(window.map { NSSize(width: $0.contentLayoutRect.width, height: $0.contentLayoutRect.height) } == NSSize(width: 1100, height: 760)
              || window.map { $0.contentRect(forFrameRect: $0.frame).size } == NSSize(width: 1100, height: 760),
              "the first card opens at 1100 × 760: \(window.map { "\($0.contentRect(forFrameRect: $0.frame).size)" } ?? "no window")")
        check(window?.tabbingIdentifier == CardWindows.tabbing && window?.tabbingMode == .preferred, "card windows gather as tabs of one another")
        check(window?.collectionBehavior.contains(.fullScreenAuxiliary) == true, "and open over a full-screen Binders window, on its Space")
        check(window?.contentMinSize == NSSize(width: 880, height: 600) || window?.minSize == window?.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 880, height: 600)).size,
              "down to 880 × 600: \(window.map { "\($0.contentMinSize), frame \($0.minSize)" } ?? "")")
        check(window?.title == first.title && window?.subtitle == "Launch", "its title is the card's and its subtitle the binder's: \(window?.subtitle ?? "")")
        /// How far down the window its title and tab bars reach, and where the card's title row starts.
        func titleRow(_ card: TaskCard, in window: NSWindow?) -> (bars: CGFloat, title: CGFloat) {
            guard let window else { return (0, -1) }
            return (window.frame.height - window.contentLayoutRect.maxY, CardHeader.titleTops[card.id] ?? -1)
        }
        let alone = titleRow(first, in: window)
        check(alone.bars > 20 && alone.title >= alone.bars, "one card: its title row (\(Int(alone.title)) pt down) is below the title bar (\(Int(alone.bars)) pt)")
        // Opened with nothing waiting on you, nothing in it has the cursor: not the title, whose words a key would replace.
        let responder = window?.firstResponder
        check(!(responder is NSText) && !(responder is NSTextField), "opened with nothing waiting, no field has the cursor: \(responder.map { String(describing: type(of: $0)) } ?? "none")")
        let second = card("Check the screenshots")
        windows.open(second, controller: controller)
        await settle()
        let tab = windows.window(for: second.id)
        check(tab != nil && tab !== window && (window?.tabbedWindows ?? []).contains { $0 === tab }, "a second card opens as a tab of the first: \(window?.tabbedWindows?.count ?? 0) tabs")
        // With two cards the tab bar comes under the title bar: the card keeps below both, so its title, Show Details, ⋯ and
        // Done stay in view and can be clicked.
        let tabbed = titleRow(second, in: tab)
        check(tabbed.bars > alone.bars + 20 && tabbed.title >= tabbed.bars,
              "two cards as tabs: the title row (\(Int(tabbed.title)) pt down) is below the title and tab bars (\(Int(tabbed.bars)) pt)")
        let tabResponder = tab?.firstResponder
        check(!(tabResponder is NSText) && !(tabResponder is NSTextField),
              "opened as a tab, no field has the cursor either: \(tabResponder.map { String(describing: type(of: $0)) } ?? "none")")
        window?.tabGroup?.selectedWindow = window
        await settle(500)
        let back = titleRow(first, in: window)
        check(back.bars > alone.bars + 20 && back.title >= back.bars, "and the first card's, chosen again: \(Int(back.title)) pt, the bars \(Int(back.bars)) pt")

        // The Window menu lists them, with Bring All to Front, after the menu is rebuilt too.
        func windowMenu() -> NSMenu? { NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu }
        check(NSApp.windowsMenu != nil && NSApp.windowsMenu === windowMenu(), "the Window menu is the app's windows menu")
        check(windowMenu()?.items.contains { $0.title == "Bring All to Front" && $0.action == #selector(NSApplication.arrangeInFront(_:)) } == true,
              "with Bring All to Front")
        MenuShortcuts.rebuildMenu()
        check(NSApp.windowsMenu === windowMenu() && NSApp.windowsMenu != nil, "and still after the menu is rebuilt")
        windows.retitle(first.id, title: first.title, binder: "Launch")
        await settle(300)
        let listed = windowMenu()?.items.map(\.title) ?? []
        print("WINDOW MENU: \(listed)")
        check(listed.contains { $0.hasPrefix(first.title) } && listed.contains { $0.hasPrefix(second.title) }, "it lists each card by its title")
        check(!listed.contains { $0.isEmpty == false && ["Flow", "Scratchpad"].contains(where: $0.hasPrefix) }, "and no panel")

        // Moved to another binder with Move to, or its binder renamed: the window, and so the Window menu, names the binder
        // it's in now.
        let studio = BinderRecord(name: "Studio", colorIndex: 3)
        Store.shared.insert(studio)
        try? controller.router.move(first, to: studio)
        await settle(500)
        check(first.binderID == studio.id && window?.subtitle == "Studio", "after Move to, its window names the new binder: \(window?.subtitle ?? "")")
        studio.name = "Studio B"
        Store.shared.save()
        await settle(500)
        check(window?.subtitle == "Studio B", "and its new name once it's renamed: \(window?.subtitle ?? "")")
        try? controller.router.move(first, to: launch)
        await settle(300)

        // The size you leave a card at is the next card's.
        if let window {
            window.setContentSize(NSSize(width: 1240, height: 812))
            windows.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
            check(AppDefaults.store.string(forKey: CardWindows.sizeKey) == "1240x812", "a resize's end is remembered: \(AppDefaults.store.string(forKey: CardWindows.sizeKey) ?? "nothing")")
        }
        windows.close(first.id)
        windows.close(second.id)
        await settle(300)
        check(!windows.isOpen(first.id) && !windows.isOpen(second.id) && !windows.hasOpenWindows, "Done closes a card's window")
        let third = card("Draft the FAQ")
        windows.open(third, controller: controller)
        await settle()
        let sized = windows.window(for: third.id).map { $0.contentRect(forFrameRect: $0.frame).size }
        check(sized == NSSize(width: 1240, height: 812), "the next card opens at that size: \(sized.map { "\($0)" } ?? "no window")")
        check(find(MarkdownTextView.self, in: windows.window(for: third.id)?.contentView) != nil, "wide enough, Details sit beside the conversation")
        windows.close(third.id)
        await settle(300)

        // Narrower than 1000 pt, Details start hidden whatever you chose.
        AppDefaults.store.set("900x640", forKey: CardWindows.sizeKey)
        AppDefaults.store.set(true, forKey: CardWindows.detailsKey)
        let narrow = card("Book the venue")
        windows.open(narrow, controller: controller)
        await settle()
        check(find(MarkdownTextView.self, in: windows.window(for: narrow.id)?.contentView) == nil, "under 1000 pt wide, Details aren't docked")
        windows.close(narrow.id)
        await settle(300)
        AppDefaults.store.removeObject(forKey: CardWindows.sizeKey)

        // Show or Hide Details. Hidden at full width, then shown over a narrow card, then the card widened: Hide Details
        // hides them, and your choice for every card stays hidden.
        let shownOver = CardDetailView.toggledDetails(width: 900, open: false, over: false)
        check(shownOver == (false, true), "narrow, Show Details lays them over the conversation and leaves your choice: \(shownOver)")
        let widened = CardDetailView.toggledDetails(width: 1200, open: false, over: true)
        check(widened == (false, false), "widened, Hide Details hides them and your choice stays hidden: \(widened)")
        let docked = CardDetailView.toggledDetails(width: 1200, open: true, over: true)
        check(docked == (false, false), "docked, Hide Details hides them: \(docked)")
        check(CardDetailView.toggledDetails(width: 1200, open: false, over: false) == (true, false), "wide, Show Details docks them, for every card")

        // A card deleted while its window is open: the window goes, and its draft.
        let doomed = card("Plan the offsite")
        windows.open(doomed, controller: controller)
        windows.setDraft("Half-written words", for: doomed.id)
        await settle()
        board.delete(doomed)
        await settle(300)
        check(!windows.isOpen(doomed.id) && windows.draft(for: doomed.id).isEmpty, "deleting a card closes its window and drops its draft")

        // A card whose binder was deleted opens without a binder.
        let orphan = board.create(title: "Renew the domain", binderID: UUID(), column: .backlog, by: .you)
        windows.open(orphan, controller: controller)
        await settle()
        check(windows.window(for: orphan.id)?.subtitle == "", "a card whose binder is gone opens with no subtitle")
        windows.close(orphan.id)
        await settle(300)

        // A question waiting: the composer takes the cursor, unless the card opened from a binders://card link.
        let asked = card("Choose the plan names")
        try? board.claim(asked, by: BoardActor(name: "Echo", kind: .agent))
        try? board.ask(asked, question: "Starter or Basic?", by: BoardActor(name: "Echo", kind: .agent))
        windows.open(asked, controller: controller)
        await settle(1000)
        check(windows.window(for: asked.id)?.firstResponder is ComposerTextView, "opened on a question, the composer has the cursor")
        windows.close(asked.id)
        await settle(300)
        URLCommands.handle(URL(string: "binders://card/\(asked.id.uuidString)")!, controller: controller)
        await settle(1000)
        check(windows.isOpen(asked.id) && windows.openedFromLink(asked.id) && !(windows.window(for: asked.id)?.firstResponder is ComposerTextView),
              "opened from a binders://card link, it comes forward without the composer taking the cursor")
        windows.close(asked.id)
        await settle(300)

        // The conversation: at the newest, a new entry keeps the newest at the bottom; scrolled up, nothing moves, and the pill
        // says how many are new.
        let long = card("Update the pricing comparison table", .inProgress)
        for index in 1...40 { board.comment(long, text: "Line \(index) of a long conversation, to scroll through.", by: .you) }
        windows.open(long, controller: controller)
        await settle(1500)
        if let scroll = findScroll(in: windows.window(for: long.id)?.contentView ?? NSView()), let document = scroll.documentView {
            func bottomGap() -> CGFloat { document.bounds.height - scroll.contentView.bounds.maxY }
            check(document.bounds.height > scroll.contentView.bounds.height && bottomGap() < 9, "it opens at the newest entry: \(Int(bottomGap())) pt from the end")
            board.comment(long, text: "One more.", by: .you)
            await settle(900)
            check(bottomGap() < 9, "at the newest, a new entry keeps the newest at the bottom: \(Int(bottomGap())) pt from the end")
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            await settle(400)
            board.comment(long, text: "And another.", by: .you)
            await settle(900)
            check(scroll.contentView.bounds.minY < 1, "scrolled up, a new entry leaves what you're reading where it was: \(scroll.contentView.bounds.minY)")
            check(ConversationView.newCounts[long.id] == 1, "and the pill says 1 new: \(ConversationView.newCounts[long.id] ?? 0)")
        } else {
            check(false, "the conversation has its scroll view")
        }
        windows.close(long.id)
        await settle(300)

        // The conversation's own height changing at the newest: a question comes while the card is open (the tray comes up
        // under the conversation), then you type three lines (the composer grows): the newest entry stays in view.
        let asking = card("Choose the photographer", .inProgress)
        try? board.claim(asking, by: BoardActor(name: "Echo", kind: .agent))
        for index in 1...30 { board.comment(asking, text: "Line \(index) of what we said about the photographer, to scroll through.", by: .you) }
        windows.open(asking, controller: controller)
        await settle(1500)
        if let scroll = findScroll(in: windows.window(for: asking.id)?.contentView ?? NSView()), let document = scroll.documentView {
            func bottomGap() -> CGFloat { document.bounds.height - scroll.contentView.bounds.maxY }
            let tall = scroll.contentView.frame.height
            try? board.ask(asking, question: "Sam or the studio? Sam is free on the 28th; the studio has the better lights.", by: BoardActor(name: "Echo", kind: .agent))
            await settle(1500)
            check(scroll.contentView.frame.height < tall - 20 && bottomGap() < 9,
                  "a question comes while it's open: the tray takes room, and the newest stays in view: \(Int(tall)) to \(Int(scroll.contentView.frame.height)) pt, \(Int(bottomGap())) pt from the end")
            let shorter = scroll.contentView.frame.height
            if let field = find(ComposerTextView.self, in: windows.window(for: asking.id)?.contentView) {
                field.window?.makeFirstResponder(field)
                field.insertText("Sam, if the 28th works.\nAsk about the lights.\nAnd send me the quote.", replacementRange: NSRange(location: 0, length: 0))
                await settle(1000)
                check(scroll.contentView.frame.height < shorter - 10 && bottomGap() < 9,
                      "three lines typed: the composer grows, and the newest stays in view: \(Int(shorter)) to \(Int(scroll.contentView.frame.height)) pt, \(Int(bottomGap())) pt from the end")
                field.string = ""
                field.didChangeText()
            } else {
                check(false, "the composer is there")
            }
        } else {
            check(false, "the conversation has its scroll view")
        }
        windows.close(asking.id)
        await settle(300)

        print(failures == 0 ? "CARD_WINDOWS_OK" : "CARD_WINDOWS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
