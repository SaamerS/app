import XCTest

/// Something said to yourself while capture listens, as if heard (`-sayMoment`, as the Simulator can't listen): the Mac
/// acts on it, the capture screen says what it did, and Undo takes it back. Needs a Mac to pair with: BINDERS_PAIR_URL
/// from a throwaway Mac (`--selftest-link-serve`); skipped without.
final class MomentTests: XCTestCase {
    func testAMomentIsActedOnAndTakenBack() throws {
        guard let link = ProcessInfo.processInfo.environment["BINDERS_PAIR_URL"] else {
            throw XCTSkip("Needs BINDERS_PAIR_URL from a Mac serving the demo data")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-classicHome", "YES", "-open", "capture", "-captureSource", "silence", "-pairURL", link,
                               "-captureMoments", "YES", "-momentsExplained", "YES", "-momentMode", "suggest",
                               "-sayMoment", "Binders, remind me to call Sam tomorrow at 3"]
        app.launch()
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        XCTAssertTrue(app.switches["momentsToggle"].waitForExistence(timeout: 20), "The capture screen didn't open")
        let said = app.staticTexts["“remind me to call Sam tomorrow at 3”"]
        XCTAssertTrue(said.waitForExistence(timeout: 40), "The moment isn't listed")
        let done = app.staticTexts["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 40), "The Mac didn't act on it")
        attach("acted on")

        said.press(forDuration: 1.2)
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "No Undo on the moment")
        undo.tap()
        XCTAssertTrue(app.staticTexts["Taken back"].waitForExistence(timeout: 20), "Undo didn't take it back")
        attach("taken back")
    }

    /// Auto chosen under Mode shows what it does before anything changes: the sheet's heading and, under How it works, what it can't hear,
    /// a "Say yes to …" label on each Review…, and Not Now leaves Mode on Suggest.
    func testChoosingAutoShowsWhatItDoes() throws {
        guard let link = ProcessInfo.processInfo.environment["BINDERS_PAIR_URL"] else {
            throw XCTSkip("Needs BINDERS_PAIR_URL from a Mac serving the demo data")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-classicHome", "YES", "-open", "capture", "-captureSource", "silence", "-pairURL", link,
                               "-captureMoments", "YES", "-momentsExplained", "YES", "-momentMode", "suggest"]
        app.launch()
        let notNowAlert = app.alerts.buttons["Not Now"]
        if notNowAlert.waitForExistence(timeout: 3) { notNowAlert.tap() }

        let mode = app.buttons["momentMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 20), "No Mode menu under Said to yourself")
        mode.tap()
        let auto = app.buttons["Auto"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5), "No Auto in the Mode menu")
        auto.tap()

        XCTAssertTrue(app.staticTexts["Hand what you say to agents without asking?"].waitForExistence(timeout: 10), "The sheet didn't show")
        // What it hears is under How it works. A Mac that reads what you think out loud (lane Y2) gets the line on what Auto
        // hears in its place.
        let how = app.buttons["autoHowItWorks"].exists ? app.buttons["autoHowItWorks"] : app.buttons["How it works"]
        XCTAssertTrue(how.waitForExistence(timeout: 5), "No How it works on the sheet")
        how.tap()
        let cantHear = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Say each thing on its own", "It hears what you say on its own")).firstMatch
        XCTAssertTrue(cantHear.waitForExistence(timeout: 5), "The sheet doesn't say what Auto can't hear")
        for review in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "autoReview-")).allElementsBoundByIndex {
            XCTAssertTrue(review.label.hasPrefix("Say yes to "), "Review… without its label: \(review.label)")
        }
        attach("Auto's sheet")

        app.buttons["autoNotNow"].tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.label.contains("Suggest") || (mode.value as? String)?.contains("Suggest") == true,
                      "Not Now changed the mode: \(mode.label)")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// The Auto sheet and its yes page with a stand-in Mac's agents, one in each state (`-autoSheetSample`), in light and dark,
/// at the default text size and at AX3: PNGs written to BINDERS_AUTO_SHOTS. Skipped unless asked for:
///
///     TEST_RUNNER_BINDERS_AUTO_SHOTS=<folder> xcodebuild test-without-building … -only-testing:BindersPhoneUITests/AutoSheetShots
final class AutoSheetShots: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BINDERS_AUTO_SHOTS"] else { throw XCTSkip("Only when taking the Auto sheet's screenshots") }
        folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        continueAfterFailure = true
    }

    func testTheSheetAndItsYesPage() throws {
        for (look, size) in [("light", "default"), ("dark", "default"), ("light", "AX3"), ("dark", "AX3")] {
            shoot(sample: "mixed", look: look, size: size, yesPage: true)
        }
        shoot(sample: "none", look: "light", size: "default", yesPage: false)
        shoot(sample: "none", look: "dark", size: "default", yesPage: false)
    }

    private func shoot(sample: String, look: String, size: String, yesPage: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-autoSheetSample", sample, "-appearance", look]
        if size == "AX3" { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] }
        app.launch()
        let name = "\(sample)-\(look)-\(size)"
        XCTAssertTrue(app.buttons["autoNotNow"].waitForExistence(timeout: 15), "The sheet didn't show: \(name)")
        sleep(1)
        save("\(name)-1-top")
        // Pennant's reason, behind its info button.
        let more = app.buttons["autoMore-Pennant"]
        if scroll(app, to: more) { more.tap() }
        sleep(1)
        save("\(name)-2-agents")
        var page = 3
        for _ in 0..<(size == "AX3" ? 6 : 2) {
            let before = app.buttons["autoUse"].isHittable
            app.swipeUp(velocity: .slow)
            sleep(1)
            save("\(name)-\(page)-scrolled")
            page += 1
            if before { break }
        }
        let stopMore = app.buttons["autoStopMore"].exists ? app.buttons["autoStopMore"] : app.buttons["More"]
        if stopMore.exists, stopMore.isHittable {
            stopMore.tap()
            sleep(1)
            app.swipeUp(velocity: .slow)
            sleep(1)
            save("\(name)-\(page)-stop-more")
        }
        guard yesPage else { return }
        // Again from the top: swiping down a sheet at its top closes it.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["autoNotNow"].waitForExistence(timeout: 15), "The sheet didn't show again: \(name)")
        let review = app.buttons["autoReview-Grok Bot"]
        XCTAssertTrue(scroll(app, to: review), "No Review… for Grok Bot: \(name)")
        XCTAssertTrue(review.label.hasPrefix("Say yes to "), review.label)
        review.tap()
        let yes = app.buttons["autoSayYes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5), "The yes page didn't open: \(name)")
        XCTAssertTrue(yes.isHittable, "Say Yes is out of reach: \(name)")
        sleep(1)
        save("\(name)-yes-1-top")
        for index in 2...(size == "AX3" ? 8 : 3) {
            app.swipeUp(velocity: .slow)
            sleep(1)
            save("\(name)-yes-\(index)")
            XCTAssertTrue(yes.isHittable, "Say Yes scrolled out of reach: \(name)")
            if app.otherElements["autoYes-starts"].exists, app.otherElements["autoYes-starts"].isHittable, index > 2 { break }
        }
        yes.tap()
        XCTAssertTrue(app.buttons["autoNotNow"].waitForExistence(timeout: 5))
        sleep(1)
        save("\(name)-after-yes")
        app.terminate()
    }

    @discardableResult
    private func scroll(_ app: XCUIApplication, to element: XCUIElement) -> Bool {
        for _ in 0..<10 {
            if element.exists, element.isHittable { return true }
            app.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
