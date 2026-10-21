import XCTest

/// The home on iOS 26 and later: Today with what needs you, then Binders and Capture, and the Dictate control at the
/// bottom. Needs a Mac to pair with: BINDERS_PAIR_URL from a throwaway Mac (`--selftest-link-serve`); skipped without.
final class HomeTabsTests: XCTestCase {
    func testTodayBindersAndCapture() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The tabs are iOS 26 and later") }
        guard let link = ProcessInfo.processInfo.environment["BINDERS_PAIR_URL"] else {
            throw XCTSkip("Needs BINDERS_PAIR_URL from a Mac serving the demo data")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-captureSource", "silence", "-pairURL", link]
        app.launch()
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 30), "Today didn't open first")
        let waiting = app.buttons["needsYou-questions"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 30), "Needs you doesn't show the agent's question")
        XCTAssertFalse(app.buttons["needsYou-handOffs"].exists, "Cards meant for no one aren't hand-offs")
        XCTAssertTrue(app.descendants(matching: .any)["talkControl"].exists, "The Dictate control isn't at the bottom")
        attach("today")

        app.tabBars.buttons["Binders"].tap()
        let board = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Board'")).firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 10), "The Binders tab doesn't show the binders")
        XCTAssertFalse(app.buttons["Dictate"].exists && app.buttons["Dictate"].frame.minY < app.tabBars.firstMatch.frame.minY - 120,
                       "The Binders tab shows a second Dictate button")
        attach("binders")

        app.tabBars.buttons["Capture"].tap()
        XCTAssertTrue(app.switches["captureToggle"].waitForExistence(timeout: 10), "The Capture tab doesn't show capture")
        attach("capture")

        app.tabBars.buttons["Today"].tap()
        waiting.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        attach("the waiting card")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
