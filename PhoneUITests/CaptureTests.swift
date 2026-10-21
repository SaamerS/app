import XCTest

/// All-day capture's switch and Mute button, with a silent source standing in for the microphone (the Simulator has
/// none). Works paired or not: `-open capture` opens the capture screen from either home.
final class CaptureTests: XCTestCase {
    func testTurningCaptureOnMutingAndOff() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-classicHome", "YES", "-open", "capture", "-captureSource", "silence"]
        app.launch()

        // Left on by an earlier run: it asks rather than starting by itself.
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }

        let toggle = app.switches["captureToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "The capture screen didn't open")
        if toggle.value as? String == "1" { flip(toggle) }
        XCTAssertFalse(app.staticTexts["captureStatus"].exists, "It shows a status while off")
        attach("off")

        flip(toggle)
        // The first time, it asks you to let the people around you know.
        let turnOn = app.alerts.buttons["Turn It On"]
        if turnOn.waitForExistence(timeout: 3) {
            attach("asks first")
            turnOn.tap()
        }
        allowNotificationsIfAsked()
        let status = app.staticTexts["captureStatus"]
        XCTAssertTrue(wait(for: status, label: "Listening"), "It didn't start listening: \(status.label)")
        attach("listening")

        let mute = app.buttons["captureMute"]
        mute.tap()
        XCTAssertTrue(wait(for: status, label: "Muted"), "Mute didn't stop it: \(status.label)")
        XCTAssertTrue(mute.label.contains("Unmute"), "The button doesn't offer to unmute: \(mute.label)")
        attach("muted")
        mute.tap()
        XCTAssertTrue(wait(for: status, label: "Listening"), "Unmute didn't start it again: \(status.label)")

        flip(toggle)
        XCTAssertTrue(waitUntilGone(status), "It's still on")
        XCTAssertEqual(toggle.value as? String, "0")
        attach("off again")
    }

    /// While capture is on, its Live Activity shows on the Home Screen and the Lock Screen, and goes when it's off.
    func testTheLiveActivityShowsWhileCaptureIsOn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-classicHome", "YES", "-open", "capture", "-captureSource", "silence"]
        app.launch()
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
        let toggle = app.switches["captureToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "The capture screen didn't open")
        if toggle.value as? String != "1" {
            flip(toggle)
            let turnOn = app.alerts.buttons["Turn It On"]
            if turnOn.waitForExistence(timeout: 3) { turnOn.tap() }
            allowNotificationsIfAsked()
        }
        XCTAssertTrue(wait(for: app.staticTexts["captureStatus"], label: "Listening"), "It didn't start listening")
        XCUIDevice.shared.press(.home)
        sleep(3)
        attach("home screen, listening")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The Lock Screen shows it in full, with its buttons.
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)
        attach("lock screen, listening")
        let shown = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'All-day capture'")).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "The Live Activity isn't on the Lock Screen")
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        app.activate()
        if toggle.waitForExistence(timeout: 10), toggle.value as? String == "1" { flip(toggle) }
    }

    /// The sample recording, written down on the phone (the speech model must be downloaded), then read: who said what.
    func testReadingAConversation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-classicHome", "YES", "-open", "capture", "-captureSource", "silence", "-processSample", "YES"]
        app.launch()
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }

        let row = app.buttons.matching(identifier: "conversationRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The sample didn't show up")
        let written = NSPredicate(format: "label CONTAINS[c] 'harbor launch'")
        let transcribed = XCTNSPredicateExpectation(predicate: written, object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [transcribed], timeout: 240), .completed, "It wasn't written down: \(row.label)")
        attach("written down")
        row.tap()
        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 10), "The transcript didn't open")
        let line = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'pricing for the beta customers'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "The transcript isn't there")
        XCTAssertTrue(app.staticTexts["Speaker 1"].exists && app.staticTexts["Speaker 2"].exists, "The voices aren't told apart")
        attach("transcript")
        app.buttons["conversationMenu"].tap()
        XCTAssertTrue(app.buttons["Share…"].waitForExistence(timeout: 5), "It can't be shared")
        attach("share")
    }

    /// What the Mac offered about the newest conversation, said yes to from the iPhone: the card goes on the board. Needs
    /// the paired Mac to have written the conversation up (run testReadingAConversation first, with the Mac reachable).
    func testAddingASuggestedCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-classicHome", "YES", "-openConversation", "latest", "-captureSource", "silence"]
        app.launch()
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
        let add = app.buttons["Add to Board"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 30), "Nothing was offered")
        attach("offered")
        add.tap()
        let done = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'On the' OR label BEGINSWITH 'Already on the'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20), "The Mac didn't say it was on the board")
        attach("added")
    }

    /// The capture screen stays short with made-up captures (`-sampleCaptures YES`, Debug builds only): today's kept and
    /// waiting ones, the ones not kept in one row, the earlier days on a page of their own, and the settings a tap from
    /// the toolbar. The Dictate control never covers the last row. Light, dark and the third accessibility size; with
    /// `TEST_RUNNER_CAPTURE_SHOTS=<folder>` the screenshots are saved there as well.
    func testTheCaptureScreenStaysShort() throws {
        let looks: [(name: String, arguments: [String])] = [
            ("light", ["-appearance", "light"]),
            ("dark", ["-appearance", "dark"]),
            ("ax3", ["-appearance", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]),
        ]
        for look in looks {
            let app = XCUIApplication()
            app.launchArguments = ["-open", "capture", "-captureSource", "silence", "-sampleCaptures", "YES"] + look.arguments
            app.launch()
            let notNow = app.alerts.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 3) { notNow.tap() }
            // With the tabs (a paired iPhone on iOS 26), capture is a tab of its own.
            let tab = app.tabBars.buttons["Capture"]
            if tab.waitForExistence(timeout: 3) { tab.tap() }
            XCTAssertTrue(app.switches["captureToggle"].waitForExistence(timeout: 15), "The capture screen didn't open")
            save(look.name + "-1-top")

            let earlier = app.buttons["captureEarlier"]
            for _ in 0..<8 where !(earlier.exists && earlier.isHittable) { app.swipeUp() }
            XCTAssertTrue(earlier.isHittable, "No way to the earlier days at the end of today's captures")
            app.swipeUp()
            sleep(1)
            save(look.name + "-2-bottom")
            let talk = app.descendants(matching: .any)["talkControl"]
            if talk.exists {
                XCTAssertLessThanOrEqual(earlier.frame.maxY, talk.frame.minY + 1, "The Dictate control covers the last row")
            }
            XCTAssertTrue(app.buttons["captureNotKeptToday"].exists, "Today's captures not kept aren't folded into one row")
            let notKeptRow = app.buttons.matching(identifier: "conversationRow").matching(NSPredicate(format: "label BEGINSWITH 'Not kept'"))
            XCTAssertEqual(notKeptRow.count, 0, "A capture not kept has a row of its own on the capture screen")
            guard look.name == "light" else { continue }

            app.buttons["captureNotKeptToday"].tap()
            XCTAssertTrue(app.buttons.matching(identifier: "conversationRow").firstMatch.waitForExistence(timeout: 5), "The ones not kept didn't open")
            save("light-3-not-kept")
            app.navigationBars.buttons.element(boundBy: 0).tap()

            XCTAssertTrue(earlier.waitForExistence(timeout: 5))
            earlier.tap()
            let day = app.buttons.containing(NSPredicate(format: "label CONTAINS 'captures'")).firstMatch
            XCTAssertTrue(day.waitForExistence(timeout: 5), "The earlier days aren't listed")
            save("light-4-earlier")
            day.tap()
            XCTAssertTrue(app.buttons.matching(identifier: "conversationRow").firstMatch.waitForExistence(timeout: 5), "A day didn't open")
            save("light-5-day")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()

            let settings = app.buttons["captureSettings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5), "No settings in the toolbar")
            settings.tap()
            XCTAssertTrue(app.switches["lockScreenWords"].waitForExistence(timeout: 5), "The capture settings didn't open")
            save("light-6-settings")
        }
    }

    /// Attached, and saved to TEST_RUNNER_CAPTURE_SHOTS's folder when it's set.
    private func save(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if let folder = ProcessInfo.processInfo.environment["CAPTURE_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    /// A SwiftUI toggle in a list takes the tap on its switch.
    private func flip(_ toggle: XCUIElement) {
        let before = toggle.value as? String
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        if toggle.value as? String == before { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
    }

    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
    }

    private func wait(for element: XCUIElement, label: String, timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
