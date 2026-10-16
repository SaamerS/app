import XCTest

/// An iPhone with no Mac paired opens on pairing, with what works on this iPhone alone: Dictate, the Binders keyboard and
/// All-day capture. `-unpair YES` forgets the Simulator's Mac first, so pair it again (`-pairURL`) for the tests that need
/// one.
final class PairingTests: XCTestCase {
    func testWithoutAMacDictationTheKeyboardAndCaptureAreThere() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-unpair", "YES", "-captureSource", "silence"]
        app.launch()
        // Left on by an earlier run: it asks rather than starting by itself.
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }

        XCTAssertTrue(app.staticTexts["Pair with your Mac"].waitForExistence(timeout: 10), "It didn't open on pairing")
        let capture = app.buttons["aloneCapture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5), "No way into All-day capture without a Mac")
        XCTAssertTrue(app.buttons["aloneDictate"].exists, "No way to dictate without a Mac")
        XCTAssertTrue(app.buttons["aloneKeyboard"].exists, "No way to set up the keyboard without a Mac")
        attach("unpaired")

        capture.tap()
        XCTAssertTrue(app.switches["captureToggle"].waitForExistence(timeout: 10), "All-day capture didn't open")
        let onItsOwn = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'once you pair a Mac'")).firstMatch
        XCTAssertTrue(onItsOwn.waitForExistence(timeout: 5), "Capture still talks about a Mac that isn't paired")
        attach("capture without a Mac")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let keyboard = app.buttons["aloneKeyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 5), "The keyboard's setup didn't open")
        attach("keyboard setup")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["aloneDictate"].waitForExistence(timeout: 5), "It didn't come back to pairing")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
