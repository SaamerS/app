import XCTest
@testable import BindersKit

final class KeyboardTypingTests: XCTestCase {
    func testAHeldDeleteKeySpeedsUpThenTakesWords() {
        let start = KeyboardTyping.deleteStep(held: 0.5), later = KeyboardTyping.deleteStep(held: 1.4)
        XCTAssertEqual(start.unit, .character)
        XCTAssertLessThan(later.next, start.next, "faster the longer it's held")
        XCTAssertEqual(KeyboardTyping.deleteStep(held: 2).unit, .word)
    }

    func testDeletingAWordTakesItAndTheSpacesAfterIt() {
        XCTAssertEqual(KeyboardTyping.wordDeletionCount(before: "See you tomorrow  "), 10)
        XCTAssertEqual(KeyboardTyping.wordDeletionCount(before: "We don't"), 5, "an apostrophe is part of the word")
        XCTAssertEqual(KeyboardTyping.wordDeletionCount(before: "Really?!"), 2, "punctuation goes as a run")
        XCTAssertEqual(KeyboardTyping.wordDeletionCount(before: "line one\n"), 1, "a line break on its own")
        XCTAssertEqual(KeyboardTyping.wordDeletionCount(before: ""), 0)
    }

    func testFindsTheWordBeingTyped() {
        XCTAssertEqual(KeyboardTyping.currentWord(before: "I think we shoudl"), "shoudl")
        XCTAssertEqual(KeyboardTyping.currentWord(before: "it's 'dont"), "dont")
        XCTAssertEqual(KeyboardTyping.currentWord(before: "done. "), "")
    }

    func testOnlyCorrectsNearMisses() {
        XCTAssertTrue(KeyboardTyping.isSafeCorrection(of: "teh", to: "the"), "two letters swapped")
        XCTAssertTrue(KeyboardTyping.isSafeCorrection(of: "recieve", to: "receive"))
        XCTAssertFalse(KeyboardTyping.isSafeCorrection(of: "brb", to: "rub"), "too far for a short word")
        XCTAssertFalse(KeyboardTyping.isSafeCorrection(of: "Binders", to: "Binders"))
        XCTAssertFalse(KeyboardTyping.isSafeCorrection(of: "revi", to: "Levi"), "not a name for a lower-case word")
        XCTAssertTrue(KeyboardTyping.isSafeCorrection(of: "Teh", to: "The"))
        XCTAssertTrue(KeyboardTyping.isCheckable("shoudl"))
        XCTAssertFalse(KeyboardTyping.isCheckable("NASA"), "an acronym")
        XCTAssertFalse(KeyboardTyping.isCheckable("v2"))
        XCTAssertFalse(KeyboardTyping.isCheckable("a"))
    }

    func testCorrectionsKeepTheCase() {
        XCTAssertEqual(KeyboardTyping.matchingCase("the", like: "Teh"), "The")
        XCTAssertEqual(KeyboardTyping.matchingCase("the", like: "TEH"), "THE")
        XCTAssertEqual(KeyboardTyping.matchingCase("Monday", like: "monady"), "Monday", "a name keeps its capital")
    }
}
