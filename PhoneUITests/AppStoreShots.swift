import XCTest

/// The All-day capture screenshots for the App Store, on a Simulator paired with a demo Mac
/// (`BINDERS_DATA_DIR=<empty folder> Binders --selftest-link-serve`: fictional data only). Skipped unless asked for:
///
///     TEST_RUNNER_BINDERS_SHOTS=1 xcodebuild test -scheme BindersPhone -only-testing:BindersPhoneUITests/AppStoreShots …
///
/// The other screens open from launch arguments (`-open board`, `-openFirst YES`, `-open ask -ask "…"`), so a
/// `simctl io screenshot` takes them.
final class AppStoreShots: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BINDERS_SHOTS"] != nil, "Only when taking App Store screenshots")
    }

    func testCaptureScreens() throws {
        // The speech model first, so the sample is written down the way it is on a phone.
        var app = launch(["-open", "capture", "-captureSource", "silence"], resume: true)
        let download = app.buttons["Download the speech model (about 500 MB)"]
        if download.waitForExistence(timeout: 5) {
            download.tap()
            let downloading = app.staticTexts["Downloading the speech model…"]
            _ = downloading.waitForExistence(timeout: 10)
            let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: downloading)
            XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 900), .completed, "The speech model didn't download")
        }

        var row = app.buttons.matching(identifier: "conversationRow").firstMatch
        if !row.waitForExistence(timeout: 5) {
            app = launch(["-open", "capture", "-captureSource", "silence", "-processSample", "YES"])
            row = app.buttons.matching(identifier: "conversationRow").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), "The sample didn't show up")
            let written = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] 'harbor launch'"), object: row)
            XCTAssertEqual(XCTWaiter().wait(for: [written], timeout: 300), .completed, "It wasn't written down: \(row.label)")
        }

        let toggle = app.switches["captureToggle"]
        if toggle.value as? String != "1" {
            toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
            let turnOn = app.alerts.buttons["Turn It On"]
            if turnOn.waitForExistence(timeout: 3) {
                save("5-notice")
                turnOn.tap()
            }
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            if springboard.alerts.buttons["Allow"].waitForExistence(timeout: 4) { springboard.alerts.buttons["Allow"].tap() }
        }
        XCTAssertTrue(app.staticTexts["captureStatus"].waitForExistence(timeout: 15))
        // Long enough for a notification banner to go.
        sleep(8)
        save("5-capture")

        // The conversation, once the Mac has written it up and offered a card.
        row.tap()
        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 10), "The transcript didn't open")
        XCTAssertTrue(app.buttons["Add to Board"].firstMatch.waitForExistence(timeout: 300), "The Mac offered nothing")
        sleep(8)
        save("6-conversation")
        app.swipeUp()
        sleep(1)
        save("7-conversation-transcript")
    }

    /// The App Review video's first part: the iPhone on its own, before a Mac is paired. It forgets the Simulator's Mac,
    /// so testReviewTour pairs again, from `TEST_RUNNER_BINDERS_PAIR_URL` (the demo Mac's link).
    func testAloneTour() throws {
        let app = launch(["-unpair", "YES", "-captureSource", "silence"])
        XCTAssertTrue(app.staticTexts["Pair with your Mac"].waitForExistence(timeout: 10), "It didn't open on pairing")
        pause(4)
        app.swipeUp()
        pause(3)
        app.buttons["aloneCapture"].tap()
        pause(5)
        back(app)
        app.buttons["aloneKeyboard"].tap()
        pause(4)
        app.buttons["Done"].tap()
        pause(2)
    }

    /// A slow walk through every screen, for the App Review video: record it with `simctl io recordVideo` while it runs.
    func testReviewTour() throws {
        var arguments = ["-captureSource", "silence", "-ask", "What did I promise Jonas this week?"]
        if let link = ProcessInfo.processInfo.environment["BINDERS_PAIR_URL"] { arguments += ["-pairURL", link] }
        let app = launch(arguments, resume: true)
        _ = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'To-dos'")).firstMatch.waitForExistence(timeout: 20)
        pause()
        open(app, "To-dos")
        app.swipeUp()
        pause()
        back(app)
        open(app, "Board")
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Update the pricing'")).firstMatch.tap()
        pause(4)
        back(app)
        back(app)
        open(app, "Harbor launch")
        for tab in ["Board", "Meetings", "Notes", "To-dos"] {
            app.buttons[tab].firstMatch.tap()
            pause(2)
        }
        back(app)
        app.buttons["Ask"].tap()
        _ = app.staticTexts["Sources"].waitForExistence(timeout: 90)
        // With a Mac that streams, Sources shows while the answer is still being written: the tour waits for it to finish.
        let written = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.activityIndicators.firstMatch)
        _ = XCTWaiter.wait(for: [written], timeout: 90)
        pause(4)
        app.buttons["Done"].tap()
        pause(1)
        app.swipeUp()
        app.buttons["captureRow"].tap()
        pause(4)
        app.buttons.matching(identifier: "conversationRow").firstMatch.tap()
        pause(3)
        let add = app.buttons["Add to Board"].firstMatch
        if add.waitForExistence(timeout: 30) {
            add.tap()
            _ = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'On the'")).firstMatch.waitForExistence(timeout: 20)
        }
        pause(3)
        app.swipeUp()
        pause(3)
        back(app)
        back(app)
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Dictate in Any App'")).firstMatch.tap()
        pause(5)
    }

    private func open(_ app: XCUIApplication, _ row: String) {
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", row)).firstMatch.tap()
        pause()
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
    }

    private func pause(_ seconds: UInt32 = 3) { sleep(seconds) }

    /// Capture left on by an earlier run asks to resume: `resume` says yes.
    private func launch(_ arguments: [String], resume: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        // The screens these shots were framed on: the home before the tabs.
        app.launchArguments = ["-classicHome", "YES"] + arguments
        app.launch()
        let answer = app.alerts.buttons[resume ? "Resume" : "Not Now"]
        if answer.waitForExistence(timeout: 3) { answer.tap() }
        return app
    }

    private func save(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
