import XCTest
@testable import BindersKit

final class NeedsYouTests: XCTestCase {
    func testLinesInTheBoardsOwnWords() {
        XCTAssertEqual(NeedsYou.Kind.questions.line(1), "1 waiting for your answer")
        XCTAssertEqual(NeedsYou.Kind.handOffs.line(1), "Give 1 card to an agent?")
        XCTAssertEqual(NeedsYou.Kind.handOffs.line(3), "Give 3 cards to agents?")
        XCTAssertEqual(NeedsYou.Kind.captures.line(2), "2 captures to look at")
        XCTAssertEqual(NeedsYou.Kind.moments.line(1), "Add 1 thing you said?", "yours to decide: a question")
        XCTAssertEqual(NeedsYou.Kind.moments.line(2), "Add 2 things you said?")
    }

    func testTheSummaryIsCountsOnly() {
        XCTAssertEqual(NeedsYou(questions: 2, reviews: 1, handOffs: 1, captures: 3).summary, "2 questions · 1 to check · 1 to give · 3 captures")
        XCTAssertEqual(NeedsYou(questions: 1, moments: 2, captures: 1).summary, "1 question · 2 to add · 1 capture")
        XCTAssertEqual(NeedsYou(reviews: 1).summary, "1 to check")
        XCTAssertTrue(NeedsYou().isEmpty)
        XCTAssertEqual(NeedsYou().summary, "Nothing waits on you")
    }

    func testThingsYouSaidWaitOnYouAsMuchAsTheRest() {
        let needs = NeedsYou(questions: 1, moments: 2)
        XCTAssertEqual(needs.total, 3, "an offer waiting for Add or Not Now is in the count the widgets and the Live Activity show")
        XCTAssertFalse(NeedsYou(moments: 1).isEmpty)
        XCTAssertEqual(needs.count(.moments), 2)
        XCTAssertEqual(NeedsYou.Kind.allCases, [.questions, .reviews, .handOffs, .moments, .captures])
        XCTAssertEqual(NeedsYou.Kind.moments.symbol, "text.bubble")
    }

    func testCountsWrittenBeforeThingsYouSaidStillRead() throws {
        let old = #"{"questions":1,"reviews":0,"handOffs":2,"captures":3}"#
        let read = try JSONDecoder().decode(NeedsYou.self, from: Data(old.utf8))
        XCTAssertEqual(read, NeedsYou(questions: 1, handOffs: 2, captures: 3))
        XCTAssertEqual(read.moments, 0)
        let new = NeedsYou(questions: 1, moments: 4)
        XCTAssertEqual(try JSONDecoder().decode(NeedsYou.self, from: JSONEncoder().encode(new)), new)
    }

    func testOnlyUnansweredOffersFromTheLastThreeDaysWait() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (0..<8).map { _ in UUID() }
        let said: [(id: UUID, heard: Date, state: String?, actions: [String]?)] = [
            (ids[0], now.addingTimeInterval(-600), "offered", ["add", "not-now"]),        // "Add to Personal?", just now
            (ids[1], now.addingTimeInterval(-3_600), "acted", ["undo"]),                  // added
            (ids[2], now.addingTimeInterval(-60), "dismissed", nil),                      // Not Now
            (ids[3], now.addingTimeInterval(-120), "working", nil),                       // the Mac is deciding
            (ids[4], now.addingTimeInterval(-120), nil, nil),                             // not with the Mac yet
            (ids[5], now.addingTimeInterval(-2 * 86_400), "offered", ["add", "not-now"]), // the day before yesterday
            (ids[6], now.addingTimeInterval(-4 * 86_400), "offered", ["add", "not-now"]), // too long ago to nag about
            (ids[7], now.addingTimeInterval(-300), "offered", nil),                       // a Mac that didn't list its actions
        ]
        XCTAssertEqual(NeedsYou.offered(said, now: now), [ids[7], ids[0], ids[5]], "newest first")
        let answered: [(id: UUID, heard: Date, state: String?, actions: [String]?)] = [(ids[0], now, "offered", ["not-now"])]
        XCTAssertEqual(NeedsYou.offered(answered, now: now), [], "an offer that can't be added any more doesn't wait on you")
    }
}
