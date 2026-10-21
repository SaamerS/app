import XCTest
@testable import BindersKit

final class RequestLedgerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    func testARequestSentAgainGetsTheFirstAnswer() {
        var ledger = RequestLedger()
        let key = RequestLedger.key(action: "add_note", requestID: "8C1F", sender: "you")!
        XCTAssertNil(ledger.answer(for: key, now: start))
        ledger.remember(key, id: "N1", message: "Note “Booth” added to Work", at: start)
        let again = ledger.answer(for: key, now: start.addingTimeInterval(60))
        XCTAssertEqual(again?.id, "N1")
        XCTAssertEqual(again?.message, "Note “Booth” added to Work")
        XCTAssertEqual(ledger.entries.count, 1)
    }

    func testKeysKeepSendersAndActionsApart() {
        let yours = RequestLedger.key(action: "add_note", requestID: "same", sender: "you")
        XCTAssertNotEqual(yours, RequestLedger.key(action: "add_note", requestID: "same", sender: "agent:Claude Code"))
        XCTAssertNotEqual(yours, RequestLedger.key(action: "add_todo", requestID: "same", sender: "you"))
        XCTAssertNil(RequestLedger.key(action: "add_note", requestID: "  ", sender: "you"), "no id, nothing to remember")
        XCTAssertNil(RequestLedger.key(action: "add_note", requestID: String(repeating: "x", count: 129), sender: "you"))
        XCTAssertEqual(RequestLedger.key(action: "add_note", requestID: " abc ", sender: "you"), "add_note|you|abc")
    }

    func testItKeepsAWeekAndAtMostTheLimit() {
        var ledger = RequestLedger()
        let old = RequestLedger.key(action: "add_todo", requestID: "old", sender: "you")!
        ledger.remember(old, id: "T1", message: "To-do added", at: start)
        XCTAssertNotNil(ledger.answer(for: old, now: start.addingTimeInterval(RequestLedger.keptFor - 60)))
        XCTAssertNil(ledger.answer(for: old, now: start.addingTimeInterval(RequestLedger.keptFor + 1)), "a week later it's forgotten")
        ledger.remember(RequestLedger.key(action: "add_todo", requestID: "new", sender: "you")!, id: "T2", message: "",
                        at: start.addingTimeInterval(RequestLedger.keptFor + 1))
        XCTAssertEqual(ledger.entries.map(\.id), ["T2"], "and let go of when the next is kept")

        var full = RequestLedger(entries: (0..<(RequestLedger.limit + 9)).map {
            RequestLedger.Entry(key: "add_note|you|\($0)", id: "\($0)", message: "", at: start.addingTimeInterval(Double($0)))
        })
        full.remember("add_note|you|last", id: "last", message: "", at: start.addingTimeInterval(Double(RequestLedger.limit + 9)))
        XCTAssertEqual(full.entries.count, RequestLedger.limit)
        XCTAssertEqual(full.entries.first?.id, "10", "the oldest go first")
        XCTAssertNotNil(full.answer(for: "add_note|you|last", now: start.addingTimeInterval(Double(RequestLedger.limit + 10))))
    }

    func testItRoundTripsAsJSON() throws {
        var ledger = RequestLedger()
        ledger.remember("comment_task|you|A", id: "C1", message: "Comment added to “Booth”.", at: start)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(RequestLedger.self, from: encoder.encode(ledger)), ledger)
    }
}
