import XCTest
@testable import BindersKit

final class TouchRulesTests: XCTestCase {
    func testTheFirstLookOnlyLearns() {
        var watch = NewlyWaiting()
        XCTAssertFalse(watch.look(["question|card-1", "capture|a"]), "what's there at the first look isn't new")
        XCTAssertFalse(watch.look(["question|card-1", "capture|a"]), "nor at the next")
    }

    func testSomethingThatJoinsIsNewEvenAsSomethingLeaves() {
        var watch = NewlyWaiting()
        _ = watch.look(["question|card-1"])
        XCTAssertTrue(watch.look(["question|card-1", "review|card-2"]))
        XCTAssertFalse(watch.look(["review|card-2"]), "one leaving isn't news")
        XCTAssertTrue(watch.look(["review|card-2", "give|card-3", "question|card-4"]))
        // One answered and another asked between two looks: the count stays, and it's still new.
        _ = watch.look(["question|card-1"])
        XCTAssertTrue(watch.look(["question|card-5"]))
        // The same card waiting again after it left is new again.
        _ = watch.look([])
        XCTAssertTrue(watch.look(["question|card-5"]))
    }

    func testSomethingYouSaidThatBindersOffersWarnsAndAnsweringItDoesnt() {
        // "Add to Personal?": the iPhone's Needs you lists the offer by its moment, as it lists cards and captures.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let offer = UUID()
        func waiting(_ state: String) -> Set<String> {
            let said = NeedsYou.offered([(id: offer, heard: now.addingTimeInterval(-30), state: state, actions: ["add", "not-now"])], now: now)
            return Set(["question|card-1"] + said.map { "moment|\($0.uuidString)" })
        }
        var watch = NewlyWaiting()
        _ = watch.look(waiting("working"))
        XCTAssertTrue(watch.look(waiting("offered")), "offered while Binders is open: a warning by touch")
        XCTAssertFalse(watch.look(waiting("acted")), "added: it leaves Needs you, with the success instead")
        XCTAssertFalse(watch.look(waiting("dismissed")))
    }

    func testNoCopyForgets() {
        var watch = NewlyWaiting()
        XCTAssertFalse(watch.look(nil))
        XCTAssertFalse(watch.look(["question|card-1"]), "the first real look still only learns")
        XCTAssertTrue(watch.look(["question|card-1", "capture|b"]))
        // Unpaired: the copy goes, and with it what was known. Whatever waits on the next Mac is only learned.
        XCTAssertFalse(watch.look(nil))
        XCTAssertFalse(watch.look(["question|other-mac-1", "review|other-mac-2"]))
        XCTAssertTrue(watch.look(["question|other-mac-1", "review|other-mac-2", "give|other-mac-3"]))
    }

    func testTouchesCloseTogetherAreOne() {
        var pacing = TouchPacing(apart: 5)
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(pacing.allows(at: start))
        XCTAssertFalse(pacing.allows(at: start.addingTimeInterval(1)))
        XCTAssertFalse(pacing.allows(at: start.addingTimeInterval(4.9)))
        XCTAssertTrue(pacing.allows(at: start.addingTimeInterval(5)))
        // Counted from the last that played, not the last asked for.
        XCTAssertFalse(pacing.allows(at: start.addingTimeInterval(9)))
        XCTAssertTrue(pacing.allows(at: start.addingTimeInterval(10.5)))
    }
}
