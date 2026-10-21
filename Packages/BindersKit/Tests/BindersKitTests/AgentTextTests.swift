import XCTest
@testable import BindersKit

final class AgentTextTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16, noon UTC

    func testWhoseWordsTheNoteSays() throws {
        let date = day.formatted(date: .abbreviated, time: .omitted)
        XCTAssertEqual(AgentMark(madeBy: "Claude Code").noteLine, "Claude Code wrote this note.")
        XCTAssertEqual(AgentMark(editedBy: "Codex", editedAt: day).noteLine, "Codex edited this note on \(date).")
        XCTAssertEqual(AgentMark(madeBy: "Claude Code", editedBy: "Codex", editedAt: day).noteLine,
                       "Claude Code wrote this note, and Codex edited it on \(date).")
        XCTAssertEqual(AgentMark(editedBy: "Codex").noteLine, "Codex edited this note.", "an edit with no date still names the agent")
        XCTAssertEqual(AgentMark(madeBy: "Codex", editedBy: "Codex", editedAt: day).noteLine, "Codex wrote this note.",
                       "an agent changing its own note is still just its note")
        XCTAssertNil(AgentMark().noteLine)
    }

    func testShortLabels() {
        XCTAssertEqual(AgentMark(madeBy: "Claude Code").label, "By Claude Code")
        XCTAssertEqual(AgentMark(editedBy: "Codex", editedAt: day).label, "Edited by Codex")
        XCTAssertEqual(AgentMark(madeBy: "Claude Code", editedBy: "Codex").label, "By Claude Code, edited by Codex")
        XCTAssertNil(AgentMark().label)
    }

    func testBlankNamesAreNoAgent() {
        let blank = AgentMark(madeBy: "  ", editedBy: "", editedAt: day)
        XCTAssertTrue(blank.isEmpty)
        XCTAssertNil(blank.editedAt, "no editor, no edit date")
        XCTAssertEqual(AgentMark(madeBy: " Claude Code \n").madeBy, "Claude Code")
        XCTAssertFalse(AgentMark(editedBy: "Codex").isEmpty)
    }

    func testWhichChangesMarkANote() {
        XCTAssertTrue(AgentMark.marksEdit(by: "Claude Code", madeBy: nil), "your note, changed by an agent")
        XCTAssertTrue(AgentMark.marksEdit(by: "Claude Code", madeBy: "Codex"), "another agent's note")
        XCTAssertFalse(AgentMark.marksEdit(by: "Claude Code", madeBy: "Claude Code"), "its own note is its already")
        XCTAssertFalse(AgentMark.marksEdit(by: "Claude Code ", madeBy: " Claude Code"))
        XCTAssertTrue(AgentMark.marksEdit(by: "", madeBy: "Claude Code"), "an agent with no name isn't the one that wrote it")
    }
}
