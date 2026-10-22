import XCTest
@testable import BindersKit

final class CardWaitsTests: XCTestCase {
    private let agent = BoardActor(name: "Claude Code · repo", kind: .agent)
    private let other = BoardActor(name: "Pennant", kind: .agent)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnAgentCantTakeACardThatStillWaits() throws {
        let card = CardState(column: .ready)
        XCTAssertThrowsError(try BoardRules.claim(card, by: agent, at: now, waitingOn: ["Design the form"])) {
            XCTAssertEqual($0 as? BoardError, .waitsFor(["Design the form"]))
            XCTAssertEqual(($0 as? BoardError)?.errorDescription,
                           "This card waits for “Design the form”, which isn't done yet, so it can't be taken yet. Pick another card.")
        }
        XCTAssertNoThrow(try BoardRules.claim(card, by: agent, at: now), "once nothing it waits for is open, it can")
        // Taking it by moving it, or finishing it without taking it, is taking it too.
        XCTAssertThrowsError(try BoardRules.move(card, to: .inProgress, by: agent, agentsMayFinish: true, at: now, waitingOn: ["A"]))
        XCTAssertThrowsError(try BoardRules.move(card, to: .review, by: agent, agentsMayFinish: true, at: now, waitingOn: ["A"]))
        XCTAssertThrowsError(try BoardRules.move(card, to: .done, by: agent, agentsMayFinish: true, at: now, waitingOn: ["A"]))
        XCTAssertThrowsError(try BoardRules.complete(card, by: agent, agentsMayFinish: true, at: now, waitingOn: ["A"]))
        // Moving it to Backlog, or asking about it, takes nothing.
        XCTAssertNoThrow(try BoardRules.move(card, to: .backlog, by: agent, agentsMayFinish: false, at: now, waitingOn: ["A"]))
        XCTAssertNoThrow(try BoardRules.ask(card, by: agent, at: now))
    }

    func testAPersonStillCan() throws {
        let card = CardState(column: .ready)
        let mine = try BoardRules.claim(card, by: .you, at: now, waitingOn: ["Design the form", "Pick the plan"])
        XCTAssertEqual(mine.column, .inProgress)
        XCTAssertEqual(mine.assignee, "You")
        XCTAssertNoThrow(try BoardRules.complete(card, by: .you, agentsMayFinish: false, at: now, waitingOn: ["A"]))
        XCTAssertNoThrow(try BoardRules.move(card, to: .done, by: .you, agentsMayFinish: false, at: now, waitingOn: ["A"]))
    }

    func testAnAgentThatHoldsItAlreadyGoesOn() throws {
        // You gave it the card, then made it wait: it keeps working, and can hand it over.
        let held = try BoardRules.claim(CardState(column: .ready), by: agent, at: now)
        XCTAssertNoThrow(try BoardRules.claim(held, by: agent, at: now, waitingOn: ["A"]))
        XCTAssertEqual(try BoardRules.complete(held, by: agent, agentsMayFinish: false, at: now, waitingOn: ["A"]).column, .review)
        // Another agent is still refused, for the claim first.
        XCTAssertThrowsError(try BoardRules.claim(held, by: other, at: now, waitingOn: ["A"])) {
            guard case BoardError.claimedBy = $0 else { return XCTFail("\($0)") }
        }
        // Once its claim lapsed, it's a new taking: the wait rule holds again.
        let later = now.addingTimeInterval(BoardRules.lease + 1)
        XCTAssertThrowsError(try BoardRules.claim(held, by: agent, at: later, waitingOn: ["A"]))
    }

    func testTheRefusalNamesUpToThree() {
        XCTAssertEqual(BoardError.waitsFor(["A", "B"]).errorDescription,
                       "This card waits for “A” and “B”, which aren't done yet, so it can't be taken yet. Pick another card.")
        XCTAssertEqual(BoardError.waitsFor(["A", "B", "C", "D", "E"]).errorDescription,
                       "This card waits for “A”, “B” and “C” and 2 more, which aren't done yet, so it can't be taken yet. Pick another card.")
    }

    func testWhatACardStillWaitsFor() {
        let waits = [CardWaits.Wait(id: "1", title: "A", column: .done), CardWaits.Wait(id: "2", title: "B", column: .inProgress),
                     CardWaits.Wait(id: "3", title: "C", column: .review)]
        XCTAssertEqual(CardWaits.open(waits).map(\.title), ["B", "C"], "Review isn't Done")
        XCTAssertEqual(CardWaits.line(CardWaits.open(waits)), "Waits for “B” and “C”")
        XCTAssertNil(CardWaits.line([]))
    }

    func testACardNeverWaitsForItself() {
        XCTAssertTrue(CardWaits.makesCycle(card: "a", waitsFor: ["a"], graph: [:]), "directly")
        XCTAssertTrue(CardWaits.makesCycle(card: "a", waitsFor: ["b"], graph: ["b": ["c"], "c": ["a"]]), "through others")
        XCTAssertFalse(CardWaits.makesCycle(card: "a", waitsFor: ["b"], graph: ["b": ["c"], "c": []]))
        XCTAssertFalse(CardWaits.makesCycle(card: "a", waitsFor: ["b", "c"], graph: ["b": ["c"]]), "two paths to the same card isn't a circle")
        // Its own old waits don't count: they're replaced.
        XCTAssertFalse(CardWaits.makesCycle(card: "a", waitsFor: ["b"], graph: ["a": ["x"], "b": []]))
    }

    func testOrderAndAcyclicWaits() {
        XCTAssertEqual(CardWaits.order([[1], [], [0, 1]]), [1, 0, 2])
        XCTAssertNil(CardWaits.order([[1], [0]]))
        let kept = CardWaits.acyclic([[1], [2], [0], [3], [9]])
        XCTAssertEqual(kept.waits, [[1], [2], [], [], []], "the wait that closes the circle, one on itself and one on nothing go")
        XCTAssertEqual(kept.dropped.count, 3)
        XCTAssertNotNil(CardWaits.order(kept.waits))
    }
}
