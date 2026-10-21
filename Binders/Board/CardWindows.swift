import AppKit
import SwiftUI
import BindersKit

/// Cards in windows of their own, over the Binders window: one window per card, so you can keep talking to the agent doing
/// the work while you look at the board, a note or another card. Cards gather as tabs of one card window, open over a
/// full-screen Binders window, and are listed in the Window menu. A card that's deleted closes its window. Every way in
/// (the board, Needs you, a notification, the Work page, a to-do, the quick switcher, a binders://card link) opens it here.
@MainActor
final class CardWindows: NSObject, NSWindowDelegate {
    static let shared = CardWindows()

    /// The app's controller, set beside the Binders window's; a self-test sets its own.
    var controller: DictationController?
    /// What you typed and didn't send, by card, while Binders runs: closing a card with Esc and opening it again finds your
    /// words. Nothing is written to disk.
    private(set) var drafts: [UUID: String] = [:]
    private var windows: [UUID: NSWindow] = [:]
    /// Cards opened from a binders://card link, whose composer doesn't take the cursor as they appear.
    private var fromLink: Set<UUID> = []
    /// Card windows that haven't been key yet (`windowDidBecomeKey`).
    private var unkeyed: Set<ObjectIdentifier> = []

    /// The size you last left a card window at ("1100x760"), and whether Details are open, in the app's own defaults.
    static let sizeKey = "cardWindowSize"
    static let detailsKey = "cardDetailsOpen"
    /// Card windows gather as tabs of one another, and never join the Binders window.
    static let tabbing = "BindersCard"

    var hasOpenWindows: Bool { !windows.isEmpty }
    func isOpen(_ id: UUID) -> Bool { windows[id] != nil }
    func window(for id: UUID) -> NSWindow? { windows[id] }
    /// Whether the card was opened from a binders://card link, so its composer takes no cursor.
    func openedFromLink(_ id: UUID) -> Bool { fromLink.contains(id) }

    // MARK: Opening and closing

    /// Opens the card in its own window, or brings its window (or its tab) forward. `fromLink`: opened by binders://card,
    /// which any app can open, so Binders doesn't bring itself forward and the composer takes no cursor.
    func open(_ card: TaskCard, controller: DictationController? = nil, fromLink: Bool = false) {
        guard let controller = controller ?? self.controller ?? HubWindowController.shared.controller else { return }
        if fromLink { self.fromLink.insert(card.id) } else { self.fromLink.remove(card.id) }
        if let window = windows[card.id] {
            bringForward(window, fromLink: fromLink)
            return
        }
        let window = makeWindow(for: card, controller: controller)
        windows[card.id] = window
        // A card opened while another is open becomes its tab, where that window is.
        if let other = windows.first(where: { $0.key != card.id && $0.value.isVisible })?.value {
            other.addTabbedWindow(window, ordered: .above)
        } else {
            place(window)
        }
        bringForward(window, fromLink: fromLink)
        // Showing a tab, AppKit puts the cursor in its first text field, the title, its words selected for the next key to
        // replace: nothing in a card has the cursor as it opens but what the card gives it (the composer, for a question).
        Self.outOfTextFields(window)
        DispatchQueue.main.async { Self.outOfTextFields(window) }
    }

    func close(_ id: UUID) {
        windows[id]?.close()
    }

    /// The card is being deleted (BoardService.delete, from anywhere: the iPhone's Undo on an idea deletes its card): its
    /// window goes at once, with its content view, so no view reads the card again, and so does its draft.
    func cardDeleted(_ id: UUID) {
        drafts[id] = nil
        guard let window = windows.removeValue(forKey: id) else { return }
        fromLink.remove(id)
        unkeyed.remove(ObjectIdentifier(window))
        window.delegate = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        windowsChanged()
    }

    func setDraft(_ text: String, for id: UUID) {
        drafts[id] = text.isEmpty ? nil : text
    }

    func draft(for id: UUID) -> String { drafts[id] ?? "" }

    /// The window's title and subtitle follow the card's title and binder, for the Window menu, Mission Control and VoiceOver.
    func retitle(_ id: UUID, title: String, binder: String?) {
        guard let window = windows[id] else { return }
        if window.title != title { window.title = title }
        if window.subtitle != (binder ?? "") { window.subtitle = binder ?? "" }
    }

    // MARK: Windows

    private func makeWindow(for card: TaskCard, controller: DictationController) -> NSWindow {
        let size = openingSize()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = card.title
        window.subtitle = Store.shared.binder(card.binderID)?.name ?? ""
        // The header shows both; the title bar floats over the page.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: CardLayout.smallestWidth, height: CardLayout.smallestHeight)
        window.backgroundColor = BindersTheme.NS.ground
        window.tabbingIdentifier = Self.tabbing
        window.tabbingMode = .preferred
        // Opened over a full-screen Binders window, it opens over it, on its Space; it doesn't go full screen itself.
        window.collectionBehavior = [.managed, .fullScreenAuxiliary]
        window.identifier = NSUserInterfaceItemIdentifier("card-" + card.id.uuidString)
        window.delegate = self
        let id = card.id
        // The smallest a card window goes, which the hosting view gives the window as its minimum, adding the title bar.
        let titleBar = window.frame.height - window.contentLayoutRect.height
        let root = CardDetailView(card: card)
            .frame(minWidth: CardLayout.smallestWidth, minHeight: CardLayout.smallestHeight - titleBar)
            .environment(controller)
            .environment(HubWindowController.shared.navigation)
            .environment(\.closeCard, { [weak self] in self?.close(id) })
            .modelContainer(Store.shared.container)
            .defaultAppStorage(AppDefaults.store)
        let hosting = NSHostingView(rootView: root)
        // Its minimum from the view (880 × 600); no maximum, and its size is the window's.
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        unkeyed.insert(ObjectIdentifier(window))
        // A self-test's window never shows.
        if AppPaths.isDemo { window.alphaValue = 0 }
        return window
    }

    /// The size you last left a card at, or the default, no larger than the Binders window it opens over or the screen.
    private func openingSize() -> (width: Double, height: Double) {
        let saved = CardLayout.size(from: AppDefaults.store.string(forKey: Self.sizeKey))
        let hub = HubWindowController.shared.visibleWindow
        let screen = (hub?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CardLayout.openingSize(saved: saved, over: hub.map { Self.frame($0.frame) }, screen: Self.frame(screen))
    }

    /// Centred on the Binders window when it's visible, not minimised and on the Space you're in, else on the screen of the
    /// key window. Positions aren't remembered: a card opens over where you're working.
    private func place(_ window: NSWindow) {
        let hub = HubWindowController.shared.visibleWindow
        let screen = (hub?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = window.frame
        let origin = CardLayout.openingOrigin(size: (Double(frame.width), Double(frame.height)), over: hub.map { Self.frame($0.frame) },
                                              screen: Self.frame(screen))
        window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }

    private static func frame(_ rect: NSRect) -> CardLayout.Frame {
        CardLayout.Frame(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }

    private func bringForward(_ window: NSWindow, fromLink: Bool) {
        window.tabGroup?.selectedWindow = window
        guard !AppPaths.isDemo else { return window.orderFrontRegardless() }
        // In the Dock and in ⌘Tab while a card is open, as for the Binders window.
        NSApp.setActivationPolicy(.regular)
        if fromLink {
            // Any app can open a link: the card comes forward without taking what you're typing elsewhere.
            window.orderFrontRegardless()
            if NSApp.isActive { window.makeKey() }
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// With neither a card nor the Binders window open, Binders goes back to the menu bar.
    private func windowsChanged() {
        guard !AppPaths.isDemo, windows.isEmpty, !HubWindowController.shared.isOpen else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: NSWindowDelegate

    /// The first time a card's window is key, as when it's shown: the cursor out of a text field AppKit may have put it in
    /// (`open`), now and once the window has settled.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, unkeyed.remove(ObjectIdentifier(window)) != nil else { return }
        Self.outOfTextFields(window)
        DispatchQueue.main.async { Self.outOfTextFields(window) }
    }

    /// A text field's editor is a field editor; the composer and the description are text views of their own, left as they are.
    private static func outOfTextFields(_ window: NSWindow) {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { window.makeFirstResponder(nil) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, windows.values.contains(window) else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        AppDefaults.store.set(CardLayout.sizeString(width: Double(size.width), height: Double(size.height)), forKey: Self.sizeKey)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = windows.first(where: { $0.value === window })?.key else { return }
        windows[id] = nil
        fromLink.remove(id)
        unkeyed.remove(ObjectIdentifier(window))
        window.delegate = nil
        // The views go with the window, after the click that closed it is done. Kept alive, they would carry on observing.
        DispatchQueue.main.async { window.contentView = nil }
        windowsChanged()
    }
}

private struct CloseCardKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Closes the card: its window's, which `CardWindows` sets. Without one (a drawing), the view's own dismiss.
    var closeCard: (() -> Void)? {
        get { self[CloseCardKey.self] }
        set { self[CloseCardKey.self] = newValue }
    }
}
