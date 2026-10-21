import XCTest

/// The Binders keyboard, typing into a note: the first dictation goes through the app, the next straight from the
/// keyboard while the microphone is ready. Needs the keyboard enabled with Full Access and chosen as the last keyboard
/// used (scripts/phone-keyboard-sim.sh), and a Mac paired or not: the words are cleaned up either way.
final class KeyboardTests: XCTestCase {
    func testDictatingWithTheKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-classicHome", "YES", "-open", "newnote", "-keyboardText", "Um so send the pricing deck by Thursday."]
        app.launch()

        let mic = app.descendants(matching: .any)["keyboard-mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15), "The Binders keyboard isn't showing")
        attach("keyboard")

        // First time: the app opens to listen and shows what it hears. You stop in the keyboard, which types it.
        mic.tap()
        XCTAssertTrue(app.staticTexts["Listening for the keyboard"].waitForExistence(timeout: 15), "The app didn't start listening")
        XCTAssertTrue(app.staticTexts["Um so send the pricing deck by Thursday."].waitForExistence(timeout: 10), "The words didn't show")
        attach("listening in the app")
        let stop = app.descendants(matching: .any)["keyboard-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "The keyboard doesn't know the app is listening")
        stop.tap()
        let note = app.textViews.firstMatch
        XCTAssertTrue(wait(for: note, toMatch: ".*pricing deck.*"), "Nothing was typed: \(note.value ?? "")")
        XCTAssertFalse((note.value as? String ?? "").hasPrefix("Um"), "It wasn't cleaned up: \(note.value ?? "")")
        attach("typed")

        // Again, with the microphone ready: the keyboard alone.
        mic.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "The keyboard didn't start listening")
        attach("listening in the keyboard")
        stop.tap()
        XCTAssertTrue(wait(for: note, toMatch: ".*pricing deck.*pricing deck.*"), "The second dictation wasn't typed: \(note.value ?? "")")
        attach("typed twice")

        // And it types: a capital after the full stop, two spaces for a full stop of its own.
        for key in ["space", "O", "k", "space", "space"] { app.buttons[key].tap() }
        XCTAssertTrue(wait(for: note, toMatch: ".*Thursday\\. Ok\\. $"), "Typing went wrong: \(note.value ?? "")")
        attach("typed by hand")
    }

    private func wait(for element: XCUIElement, toMatch pattern: String, timeout: TimeInterval = 30) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "(?s)" + pattern), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// Typing with the Binders keyboard: corrections at the space, put back with one delete, suggestions to tap, and a held
/// delete key that speeds up to whole words. Same setup as KeyboardTests.
final class KeyboardTypingTests: XCTestCase {
    func testCorrectsSuggestsAndDeletes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-classicHome", "YES", "-open", "newnote"]
        app.launch()
        if !app.descendants(matching: .any)["keyboard-mic"].waitForExistence(timeout: 8) {
            KeyboardSetup.enable()
            app.terminate()
            app.launch()
            // The keyboard in use is still the system's: the globe moves on to the next.
            let globe = app.buttons["Next keyboard"]
            if !app.descendants(matching: .any)["keyboard-mic"].waitForExistence(timeout: 5), globe.waitForExistence(timeout: 3) { globe.tap() }
        }
        XCTAssertTrue(app.descendants(matching: .any)["keyboard-mic"].waitForExistence(timeout: 15), "The Binders keyboard isn't showing")
        let note = app.textViews.firstMatch

        // A key shows a capital while shift is on.
        func type(_ letters: String) {
            for letter in letters {
                let key = app.buttons[letter == " " ? "space" : String(letter)]
                (key.exists ? key : app.buttons[String(letter).uppercased()]).tap()
            }
        }
        func shows(_ pattern: String) -> Bool {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "(?s)" + pattern), object: note)
            return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
        }

        type("teh ")
        XCTAssertTrue(shows("(?i)the $"), "a misspelling is corrected at the space: \(note.value ?? "")")
        app.buttons["Delete"].tap()
        XCTAssertTrue(shows("(?i)teh$"), "one delete puts back what was typed: \(note.value ?? "")")
        type(" ")
        XCTAssertTrue(shows("(?i)teh $"), "and it's left alone after that: \(note.value ?? "")")

        type("tomorr")
        let suggestion = app.buttons["tomorrow"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "typing offers ways to finish the word")
        attach(app, "suggestions")
        suggestion.tap()
        XCTAssertTrue(shows("(?i)teh tomorrow $"), "tapping one finishes the word: \(note.value ?? "")")

        type("we should send the pricing deck to the whole team before the review on friday ")
        let before = (note.value as? String ?? "").count
        app.buttons["Delete"].press(forDuration: 2.6)
        let after = (note.value as? String ?? "").count
        XCTAssertGreaterThan(before - after, 30, "holding delete speeds up and takes whole words: \(before) → \(after)")
        attach(app, "held delete")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// Turns the Binders keyboard on in Settings, with Full Access, when a Simulator hasn't got it: on iOS 26 the defaults
/// scripts/phone-keyboard-sim.sh writes aren't enough.
enum KeyboardSetup {
    static func enable() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        func tap(_ label: String, timeout: TimeInterval = 5) -> Bool {
            // A row first: the page's title can read the same.
            let named = NSPredicate(format: "identifier == %@ OR label == %@", label, label)
            let found = [settings.cells.containing(named).firstMatch, settings.cells.matching(named).firstMatch, settings.buttons.matching(named).firstMatch]
                .first { $0.waitForExistence(timeout: timeout) }
            guard let found else { return false }
            if !found.isHittable { settings.swipeUp() }
            found.tap()
            return true
        }
        _ = tap("General")
        _ = tap("Keyboard")
        _ = tap("Keyboards")
        if !settings.cells.containing(NSPredicate(format: "label == %@", "Binders")).firstMatch.waitForExistence(timeout: 2) {
            _ = tap("Add New Keyboard", timeout: 3) || tap("Add New Keyboard…", timeout: 1)
            _ = tap("Binders")
        }
        _ = tap("Binders")
        let access = settings.switches.firstMatch
        if access.waitForExistence(timeout: 5), access.value as? String != "1" {
            access.tap()
            _ = tap("Allow")
        }
        settings.terminate()
    }
}
