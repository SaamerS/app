import AppKit
import SwiftUI
import BindersKit

extension SelfTest {
    /// Settings in six pages: every part on exactly one page, in the order the page shows them, with the names links and
    /// the "settingsPage" setting use kept as they were; asking for a part (as a link, the quick switcher or a button on
    /// another page does) opens its page with that part's section at the top, or in view when it's the last on a short
    /// page; and Settings opens again where it was left. Each landing is drawn to `directory`, and two pages at the hub
    /// window's smallest size. Seeds the demo data, so only in a throwaway folder (BINDERS_DATA_DIR).
    @MainActor
    static func settingsSelfTest(directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this seeds the demo data")
            return 1
        }
        let failures = FailureCount()
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures.count += 1 }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        typealias Group = SettingsPage.Group
        // Settings remembers its part where the app keeps its preferences, which in a test run is a file in the throwaway
        // folder (AppDefaults), never the real app's.
        guard AppPaths.isDemo else { return 1 }
        let store = AppDefaults.store

        // The six pages and their parts.
        check(Group.allCases.map(\.title) == ["General", "Dictation and writing", "AI and knowledge", "Capture", "Agents and automations",
                                              "Devices and privacy"], "Settings has six pages, under the six headings it had")
        check(SettingsPage.allCases.map(\.rawValue) == ["general", "shortcuts", "dictation", "ai", "meetings", "allDay", "knowledge", "writing",
                                                         "automations", "mcp", "agents", "phone", "team", "privacy"],
              "the fourteen parts keep the names links, the switcher and the remembered page use")
        let homes = SettingsPage.allCases.map { part in Group.allCases.filter { $0.pages.contains(part) } }
        check(homes.allSatisfy { $0.count == 1 }, "every part is on exactly one page")
        check(SettingsPage.allCases.allSatisfy { $0.group.pages.contains($0) }, "each part's page is the one that holds it")
        check(Group.agents.pages == [.agents, .automations, .mcp] && Group.devices.pages == [.phone, .team, .privacy]
              && Group.general.pages == [.general, .shortcuts], "a page's parts come in the order of its name: Agents, then Automations and MCP")
        check(Group.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil }
              && SettingsPage.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil },
              "every page and part has a glyph that exists")
        check(Group.allCases.allSatisfy { !$0.summary.isEmpty && !$0.summary.contains("!") }
              && SettingsPage.allCases.allSatisfy { !$0.summary.isEmpty && !$0.summary.contains("!") },
              "every page and part says in a line what it holds, without exclaiming")
        check(Group.allCases.allSatisfy { $0.symbol != BindersTheme.agentSymbol } && SettingsPage.allCases.allSatisfy { $0.symbol != BindersTheme.agentSymbol },
              "no page or part wears the agents' sparkle")
        check(SettingsPage(rawValue: "automations")?.group == .agents && SettingsPage(rawValue: "phone")?.group == .devices,
              "binders://open?section=settings&page=automations names a part of the Agents and automations page")
        let phoneShown = SettingsPage.visible.contains(.phone)
        check(Group.allCases.allSatisfy { !$0.visiblePages.isEmpty }, "the list shows six rows, the iPhone's part \(phoneShown ? "shown" : "hidden") or not")
        if !phoneShown {
            check(Group.devices.visiblePages == [.team, .privacy] && !Group.devices.summary.contains("iPhone"),
                  "while the iPhone's part is hidden, its page shows Team and Privacy and doesn't mention the iPhone")
        }

        // Landing on each part, as a link or another page asks for it.
        let controller = DictationController()
        guard await DemoData.seed(knowledge: controller.knowledge) else { return 1 }
        AgentRegistry.shared.upsert(AgentProfile(name: "Pennant", wake: .board))
        let size = NSSize(width: 1120, height: 760)
        // The iPhone's part shows, as it does wherever the phone link is in use: the test doesn't depend on whether it is.
        store.set(true, forKey: "phoneLinkPreview")
        for part in SettingsPage.visible {
            let navigation = HubNavigation()
            navigation.selection = .settings
            navigation.pendingSettingsPage = part
            let shown = await showSettings(navigation, controller: controller, store: store, size: size, name: "settings-\(part.rawValue)",
                                           directory: directory)
            let top = shown.tops[part]
            let parts = Set(part.group.visiblePages)
            check(navigation.pendingSettingsPage == nil && store.string(forKey: "settingsPage") == part.rawValue,
                  "asking for \(part.title) opens it, and it's remembered as the part last opened")
            check(Set(shown.tops.keys) == parts, "\(part.title) opens the \(part.group.title) page, with all of its parts (\(shown.tops.keys.map(\.title).sorted()))")
            let first = part == part.group.visiblePages.first
            let atTop = top.map { first ? $0 > 0 && $0 < 60 : abs($0) <= 24 } ?? false
            let inView = top.map { $0 >= -1 && $0 < shown.formHeight - 80 } ?? false
            check(atTop || (shown.atEnd && inView),
                  "\(part.title)'s section \(first ? "starts the page" : shown.atEnd && !atTop ? "is in view, the page scrolled to its end" : "is brought to the top") (\(top.map { "\(Int($0)) pt from the top" } ?? "not drawn"))")
        }

        // Where it was left: the part last opened, and its page.
        store.set(SettingsPage.team.rawValue, forKey: "settingsPage")
        let reopened = HubNavigation()
        reopened.selection = .settings
        let again = await showSettings(reopened, controller: controller, store: store, size: size, name: "settings-reopened-team", directory: directory)
        // Whether the iPhone's part is above Team now, with the preview on (phoneShown was read before it was turned on).
        let teamFirst = Group.devices.visiblePages.first == .team
        check(Set(again.tops.keys) == Set(Group.devices.visiblePages) && (again.tops[.team].map { teamFirst ? $0 > 0 && $0 < 60 : abs($0) <= 24 || again.atEnd } ?? false),
              "Settings opens again on the part last opened, Team, on its page (\(again.tops[.team].map { "\(Int($0)) pt from the top" } ?? "not drawn"))")
        check(store.string(forKey: "settingsPage") == SettingsPage.team.rawValue,
              "opening Settings keeps the remembered part as it was (\(store.string(forKey: "settingsPage") ?? "none"))")

        // The hub window at its smallest: the list's names fit and the forms still read.
        let smallest = NSSize(width: 840, height: 560)
        for part in [SettingsPage.agents, .shortcuts] {
            let navigation = HubNavigation()
            navigation.selection = .settings
            navigation.pendingSettingsPage = part
            let shown = await showSettings(navigation, controller: controller, store: store, size: smallest, name: "settings-small-\(part.rawValue)",
                                           directory: directory)
            check(shown.tops[part] != nil, "at the window's smallest size, \(part.title) still opens on its page")
        }
        print(failures.count == 0 ? "SETTINGS_OK" : "SETTINGS_FAILED: \(failures.count)")
        return failures.count == 0 ? 0 : 1
    }

    /// The hub on Settings in an offscreen window, drawn to `name`.png once it has settled: where each section heading is
    /// from the top of the form's visible area, how tall that area is, and whether the form is scrolled to its end.
    @MainActor
    private static func showSettings(_ navigation: HubNavigation, controller: DictationController, store: UserDefaults, size: NSSize,
                                     name: String, directory: URL) async -> (tops: [SettingsPage: CGFloat], formHeight: CGFloat, atEnd: Bool) {
        SettingsHeading.tops = [:]
        let view = HubView().environment(navigation).environment(controller).environment(controller.meetings)
            .environment(controller.knowledge).environment(controller.team).environment(controller.capture)
            .environment(controller.commitments).environment(AppSettings.shared).modelContainer(Store.shared.container)
            .defaultAppStorage(store)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1600))
        capture(hosting, name: name, directory: directory)
        // The form is the scroll view furthest to the right.
        var scrolls: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { scrolls.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        let form = scrolls.max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        let visible = form?.contentView.bounds ?? .zero
        let documentHeight = form?.documentView?.frame.height ?? 0
        let atEnd = visible.maxY >= documentHeight - 2
        let tops = SettingsHeading.tops
        window.close()
        return (tops, visible.height, atEnd)
    }
}
