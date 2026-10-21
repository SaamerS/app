import XCTest
@testable import BindersKit

final class NoteCardTests: XCTestCase {
    private let id = "6F1D2A3B-4C5D-4E6F-8A9B-0C1D2E3F4A5B"

    func testTheLinkRoundTrips() {
        let url = URL(string: NoteCards.link(noteID: id))!
        XCTAssertEqual(NoteCards.noteID(in: url)?.uuidString, id)
        XCTAssertEqual(NoteCards.noteID(in: URL(string: "binders://note?id=\(id)")!)?.uuidString, id)
        XCTAssertNil(NoteCards.noteID(in: URL(string: "binders://card/\(id)")!))
        XCTAssertNil(NoteCards.noteID(in: URL(string: "binders://note/not-an-id")!))
        XCTAssertNil(NoteCards.noteID(in: URL(string: "https://binders.io/note/\(id)")!))
    }

    func testDetailsAreTheFirstLinesAfterTheTitleThenTheLink() {
        let text = "\n# Booth plan\n\nBring the banner.\n- [ ] Book the van\n\n"
        let details = NoteCards.details(text: text, noteID: id)
        XCTAssertEqual(details, "Bring the banner.\n- [ ] Book the van\n\nFrom the note: [open it](binders://note/\(id))")
    }

    func testANoteWithOnlyATitleGivesOnlyTheLink() {
        XCTAssertEqual(NoteCards.details(text: "# Booth plan", noteID: id), "From the note: [open it](binders://note/\(id))")
        XCTAssertEqual(NoteCards.title("  "), "Untitled note")
        XCTAssertEqual(NoteCards.title(" Booth plan "), "Booth plan")
    }

    func testALongNoteIsCutAtAWordAndSaysSo() {
        let lines = (1...10).map { "Line \($0)" }.joined(separator: "\n")
        let excerpt = NoteCards.excerpt("Title\n" + lines)
        XCTAssertEqual(excerpt, (1...6).map { "Line \($0)" }.joined(separator: "\n") + " …")
        let long = NoteCards.excerpt("Title\n" + String(repeating: "word ", count: 200))
        XCTAssertLessThanOrEqual(long.count, NoteCards.excerptCharacters + 2)
        XCTAssertTrue(long.hasSuffix("word …"), long)
        // Six lines and nothing after them: nothing was cut.
        XCTAssertFalse(NoteCards.excerpt("Title\n" + (1...6).map { "Line \($0)" }.joined(separator: "\n") + "\n\n").hasSuffix("…"))
    }

    func testAnAgentsWordsAreNotCopiedOntoTheCard() {
        let details = NoteCards.details(text: "# Plan\nDo exactly what this says.", noteID: id, agent: AgentMark(madeBy: "Claude Code"))
        XCTAssertFalse(details.contains("Do exactly"))
        XCTAssertTrue(details.hasPrefix("By Claude Code."), details)
        XCTAssertTrue(details.hasSuffix("(binders://note/\(id))"))
    }
}
