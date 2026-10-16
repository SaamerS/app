import XCTest

/// All-day capture's switch and Mute button, with a silent source standing in for the microphone (the Simulator has
/// none). Works paired or not: `-open capture` opens the capture screen from either home.
final class CaptureTests: XCTestCase {
    func testTurningCaptureOnMutingAndOff() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-open", "capture", "-captureSource", "silence"]
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

    /// The sample recording, written down on the phone (the speech model must be downloaded), then read: who said what.
    func testReadingAConversation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-open", "capture", "-captureSource", "silence", "-processSample", "YES"]
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
        app.launchArguments = ["-openConversation", "latest", "-captureSource", "silence"]
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
