import XCTest
@testable import BindersKit

/// What a wake carries of your words (`answer`), and the wake for a comment.
final class AgentWakeAnswerTests: XCTestCase {
    func testOneTextAsItIs() {
        XCTAssertEqual(AgentWakePayload.answer(["Use the 15% from the new price sheet."]), "Use the 15% from the new price sheet.")
        XCTAssertEqual(AgentWakePayload.answer([]), "")
    }

    func testTwoOldestFirstABlankLineBetween() {
        XCTAssertEqual(AgentWakePayload.answer(["Annual, please.", "And keep the footnote to one line."]),
                       "Annual, please.\n\nAnd keep the footnote to one line.")
    }

    func testOverTheLimitTheOldestGoFirstAndTheLastStays() {
        let big = String(repeating: "a", count: 20 * 1024)
        let joined = AgentWakePayload.answer([big, big, "Latest."])
        XCTAssertTrue(joined.hasSuffix("\n\nLatest."), "your latest words always go")
        XCTAssertLessThanOrEqual(joined.utf8.count, AgentWakePayload.answerLimit)
        XCTAssertEqual(joined, big + "\n\nLatest.", "only the oldest went")
    }

    func testOneTextOverTheLimitIsCutAtItsEndOnACharacter() {
        let long = String(repeating: "é", count: 20 * 1024)    // 2 bytes each: 40 KB
        let cut = AgentWakePayload.answer([long])
        XCTAssertEqual(cut.utf8.count, AgentWakePayload.answerLimit)
        XCTAssertTrue(long.hasPrefix(cut), "the start is kept, at a character's edge")
        let odd = "a" + long
        let oddCut = AgentWakePayload.answer([odd])
        XCTAssertEqual(oddCut.utf8.count, AgentWakePayload.answerLimit - 1, "never half a character")
    }

    func testACommentsWakeSaysSoWithYourWords() throws {
        let card = UUID()
        let payload = AgentWakePayload(event: AgentWake.Reason.commented.rawValue, agent: "Grok Bot", card: card, title: "Update the pricing table",
                                       column: .inProgress, answer: AgentWakePayload.answer(["Use the 15%.", "Keep the footnote short."]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.json) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "commented")
        XCTAssertEqual(object["answer"] as? String, "Use the 15%.\n\nKeep the footnote short.")
        XCTAssertEqual(object["column"] as? String, "in_progress")
        XCTAssertEqual(payload.fields["event"], "commented", "a command reads it as BINDERS_EVENT")
        XCTAssertNil(payload.fields["answer"], "your words go on standard input, never in a variable")
    }
}
