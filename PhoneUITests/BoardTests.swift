import XCTest

/// An agent's question on the Mac rings on the iPhone, its card opens from the notification, and the answer sends the
/// card back to work. Run by scripts/phone-board-test.sh, which serves a throwaway Mac (`--selftest-link-serve`), has an
/// agent ask when this test says it's ready, and checks the Mac's side; on its own, it's skipped.
final class BoardTests: XCTestCase {
    func testAnAgentsQuestionRingsAndIsAnswered() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let link = environment["BINDERS_PAIR_URL"], let signals = environment["BINDERS_SIGNALS"] else {
            throw XCTSkip("Run by scripts/phone-board-test.sh, which serves the Mac")
        }
        func signal(_ name: String) { FileManager.default.createFile(atPath: "\(signals)/\(name)", contents: nil) }
        let app = XCUIApplication()
        app.launchArguments = ["-classicHome", "YES", "-captureSource", "silence", "-pairURL", link]
        app.launch()
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }

        let board = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Board'")).firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 30), "Home didn't open")
        // The toolbar's Your Mac button says how the link is doing to VoiceOver; the status pill is gone once connected.
        let connected = app.buttons.matching(NSPredicate(format: "label == 'Your Mac' AND value == 'Connected'")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 30), "It didn't connect to the Mac")
        let pillGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["macStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [pillGone], timeout: 5), .completed, "The status pill shows while connected")

        // The demo board's question from before the iPhone first looked doesn't ring, as a banner or in Notification
        // Center. A ring would ask to allow notifications first: allowing lets one show.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        sleep(2)
        let old = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '15% discount'")).firstMatch
        XCTAssertFalse(old.exists, "A question from before the iPhone first looked rang")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.005))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.7)))
        sleep(1)
        attach("notification center")
        XCTAssertFalse(old.exists, "A question from before the iPhone first looked is in Notification Center")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertTrue(board.waitForExistence(timeout: 10), "Notification Center didn't close")
        sleep(2)
        signal("connected")

        // A moment in the background keeps the link: the script checks the Mac heard no second hello.
        XCUIDevice.shared.press(.home)
        sleep(4)
        app.activate()
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        sleep(2)
        signal("ready")

        // The script has an agent ask now.
        let question = "Which staging database should the 50k import test use?"
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", question)).firstMatch
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !banner.exists {
            if allow.exists { allow.tap() }
            sleep(1)
        }
        XCTAssertTrue(banner.exists, "The agent's question didn't ring")
        attach("rang")
        banner.tap()

        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 15), "Tapping it didn't open the card")
        attach("card")
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        field.typeText("Use the second one")
        app.buttons["Send answer"].tap()
        XCTAssertTrue(app.staticTexts["In progress"].waitForExistence(timeout: 15), "The answer didn't send the card back to work")
        attach("answered")
        signal("answered")

        // With Binders in the background, the next question is answered in the notification itself.
        XCUIDevice.shared.press(.home)
        sleep(2)
        signal("away")
        let second = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'mention annual plans'")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 30), "The second question didn't ring with Binders in the background")
        attach("rang in the background")
        // A long press shows Answer and Open; Answer opens the box to type in.
        second.press(forDuration: 1.5)
        let answer = springboard.buttons["Answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5), "The notification has no Answer")
        attach("expanded")
        answer.tap()
        // The keyboard's one-time tip about sliding to type, on a fresh Simulator.
        let tip = springboard.buttons["Continue"]
        if tip.waitForExistence(timeout: 2) { tip.tap() }
        let typed = NSPredicate(format: "placeholderValue == 'Your answer'")
        let box = springboard.textViews.matching(typed).firstMatch.waitForExistence(timeout: 5)
            ? springboard.textViews.matching(typed).firstMatch : springboard.textFields.matching(typed).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5), "Answer didn't open a box to type in")
        box.typeText("Yes, in one line")
        attach("typed")
        let send = springboard.buttons["Send"]
        XCTAssertTrue(send.isEnabled, "Send stayed off: the answer wasn't typed")
        send.tap()
        sleep(6)
        signal("replied")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
