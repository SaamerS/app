import XCTest
@testable import BindersKit

final class NoteAuthorsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testWhoMadeAVersionInWords() {
        XCTAssertEqual(NoteAuthor.you.phrase, "you")
        XCTAssertEqual(NoteAuthor.you.label, "You")
        XCTAssertEqual(NoteAuthor.teammate("Sam").phrase, "Sam")
        XCTAssertEqual(NoteAuthor.agent("Claude Code").phrase, "Claude Code (your agent)")
        XCTAssertEqual(NoteAuthor.agent("Pennant", owner: "Sam").phrase, "Pennant (Sam's agent)")
        XCTAssertNil(NoteAuthor(name: "Sam", kind: .teammate, owner: "Kim").owner, "only an agent has an owner")
        XCTAssertTrue(NoteAuthor.agent("Claude Code").isAgent)
        XCTAssertTrue(NoteAuthor.you.isYou)
    }

    func testEachVersionIsByWhoeverWroteThatText() {
        var index = NoteVersionIndex()
        // You wrote the first draft; an agent's change lands: your draft is kept, as yours.
        index.current = .init(by: .you, since: start)
        XCTAssertTrue(index.authorChanges(to: .agent("Claude Code")))
        XCTAssertFalse(index.authorChanges(to: .you), "you again: the usual few minutes")
        index.kept("1", before: .agent("Claude Code"), at: start.addingTimeInterval(60))
        XCTAssertEqual(index.versions["1"]?.by, .you)
        XCTAssertEqual(index.current?.by, .agent("Claude Code"))
        // A teammate's change lands on the agent's: the agent's text is kept, as the agent's.
        index.kept("2", before: .teammate("Sam"), at: start.addingTimeInterval(120))
        XCTAssertEqual(index.versions["2"]?.by, .agent("Claude Code"))
        XCTAssertEqual(index.current?.by, .teammate("Sam"))
        // A name survives being kept again.
        index.versions["1"]?.name = "Approved"
        index.kept("1", before: .you, at: start.addingTimeInterval(180))
        XCTAssertEqual(index.versions["1"]?.name, "Approved")
    }

    func testPuttingAVersionBackAddsOne() {
        var index = NoteVersionIndex(current: .init(by: .agent("Claude Code"), since: start))
        // Putting back version "1": what's there now is kept, by the agent, and the text is yours, put back from "1".
        index.kept("2", before: .you, at: start.addingTimeInterval(60), restoring: "1")
        XCTAssertEqual(index.versions["2"]?.by, .agent("Claude Code"))
        XCTAssertEqual(index.current?.restoredFrom, "1")
        // Kept in its turn, the version says it was put back from "1".
        index.kept("3", before: .you, at: start.addingTimeInterval(120))
        XCTAssertEqual(index.versions["3"]?.by, .you)
        XCTAssertEqual(index.versions["3"]?.restoredFrom, "1")
        XCTAssertNil(index.current?.restoredFrom)
    }

    func testWhoLastChangedEachSection() {
        var index = NoteVersionIndex()
        let first = "# Spec\n\n## Auth flow\nPasswords.\n\n## Billing\nCards."
        XCTAssertEqual(Set(index.stamp(first, by: .you, at: start)), ["Auth flow", "Billing"])
        let second = "# Spec\n\n## Auth flow\nPasskeys.\n\n## Billing\nCards."
        XCTAssertEqual(index.stamp(second, by: .teammate("Sam"), at: start.addingTimeInterval(60)), ["Auth flow"])
        XCTAssertEqual(index.sections["Auth flow"]?.by, .teammate("Sam"))
        XCTAssertEqual(index.sections["Billing"]?.by, .you)
        XCTAssertEqual(index.stamp(second, by: .agent("Claude Code"), at: start.addingTimeInterval(120)), [], "nothing changed: nothing stamped")
    }

    func testHistoryListsEveryVersionWithWhatChanged() {
        var index = NoteVersionIndex(current: .init(by: .teammate("Sam"), since: start.addingTimeInterval(120)))
        index.versions["a"] = .init(by: .you, name: "v1")
        index.versions["b"] = .init(by: .agent("Claude Code"), distills: [UUID()])
        let a = "# Spec\n\n## Auth flow\nPasswords."
        let b = "# Spec\n\n## Auth flow\nPasswords.\n\n## Billing\nCards."
        let now = "# Spec\n\n## Auth flow\nPasskeys.\n\n## Billing\nCards."
        let entries = NoteVersions.entries(texts: [("b", start.addingTimeInterval(60), b), ("a", start, a)], now: now, index: index)
        XCTAssertEqual(entries.map(\.id), ["now", "b", "a"], "newest first, the note as it is now on top")
        XCTAssertEqual(entries[0].by, .teammate("Sam"))
        XCTAssertEqual(entries[0].sections, ["Auth flow"])
        XCTAssertEqual(entries[0].added, 1)
        XCTAssertEqual(entries[0].removed, 1)
        XCTAssertEqual(entries[1].by, .agent("Claude Code"))
        XCTAssertEqual(entries[1].sections, ["Billing"])
        XCTAssertEqual(entries[1].distills.count, 1)
        XCTAssertEqual(entries[2].name, "v1")
        // A note whose latest version is what it says now has no separate "now".
        XCTAssertEqual(NoteVersions.entries(texts: [("a", start, a)], now: a, index: index).map(\.id), ["a"])
        XCTAssertEqual(NoteVersions.counts(added: 3, removed: 1), "3 lines added, 1 removed")
        XCTAssertEqual(NoteVersions.counts(added: 0, removed: 0), "No change")
    }
}
