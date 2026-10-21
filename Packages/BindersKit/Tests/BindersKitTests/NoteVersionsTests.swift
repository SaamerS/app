import XCTest
@testable import BindersKit

final class NoteVersionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testKeepsTheTextBeforeAnEditingSessionAndEveryFewMinutes() {
        XCTAssertTrue(NoteVersions.shouldKeep("Draft one", lastKept: nil, now: now), "the first change keeps what was there")
        XCTAssertFalse(NoteVersions.shouldKeep("Draft two", lastKept: (now.addingTimeInterval(-60), "Draft one"), now: now), "not every keystroke")
        XCTAssertTrue(NoteVersions.shouldKeep("Draft two", lastKept: (now.addingTimeInterval(-6 * 60), "Draft one"), now: now), "a few minutes on, yes")
        XCTAssertFalse(NoteVersions.shouldKeep("Draft one", lastKept: (now.addingTimeInterval(-6 * 60), "Draft one"), now: now), "not the same text twice")
        XCTAssertFalse(NoteVersions.shouldKeep("  \n", lastKept: nil, now: now), "nothing to keep")
    }

    func testForgetsOldVersionsButAlwaysKeepsTheLatest() {
        let day: TimeInterval = 86_400
        let recent = (0..<5).map { now.addingTimeInterval(-Double($0) * day) }
        let old = (40..<70).map { now.addingTimeInterval(-Double($0) * day) }
        let expired = NoteVersions.expired(recent + old, now: now)
        XCTAssertTrue(expired.allSatisfy { $0 < now.addingTimeInterval(-30 * day) })
        XCTAssertEqual(expired.count, 35 - NoteVersions.keepLatest, "the latest 20 stay, however old")
        XCTAssertTrue(NoteVersions.expired(old.prefix(10).map { $0 }, now: now).isEmpty, "a note with few versions keeps them all")
    }

    func testCountsTheLinesThatChanged() {
        let change = NoteVersions.change(from: "# Plan\nOne\nTwo", to: "# Plan\nOne\nThree\nFour")
        XCTAssertEqual(change.added, 2)
        XCTAssertEqual(change.removed, 1)
    }

    func testShowsWhatChangedLineByLine() {
        XCTAssertEqual(NoteVersions.lines(from: "# Plan\nOne\nTwo", to: "# Plan\nOne\nThree\nFour"),
                       [.same("# Plan"), .same("One"), .removed("Two"), .added("Three"), .added("Four")])
        // An agent's line appended to the end, as append_to_note does.
        XCTAssertEqual(NoteVersions.lines(from: "# Booth\nStand 14", to: "# Booth\nStand 14\n\nCalled the venue: confirmed."),
                       [.same("# Booth"), .same("Stand 14"), .added(""), .added("Called the venue: confirmed.")])
        // A line changed in the middle: what was there, then what replaced it, and the rest as it was.
        XCTAssertEqual(NoteVersions.lines(from: "a\nb\nc", to: "a\nB\nc"), [.same("a"), .removed("b"), .added("B"), .same("c")])
        XCTAssertEqual(NoteVersions.lines(from: "same", to: "same"), [.same("same")])
        XCTAssertEqual(NoteVersions.lines(from: "gone\nkept", to: "kept"), [.removed("gone"), .same("kept")])
    }
}
