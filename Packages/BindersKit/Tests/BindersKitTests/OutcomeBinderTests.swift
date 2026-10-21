import XCTest
@testable import BindersKit

final class OutcomeBinderTests: XCTestCase {
    private let binders = ["Events", "Events Team", "Personal", "General"]

    func testTheBinderAFiledLineNames() {
        XCTAssertEqual(CaptureOutcome.filedBinder(in: "Filed in Events: Ignite booth plan · 2 to-dos", among: binders), "Events")
        XCTAssertEqual(CaptureOutcome.filedBinder(in: "Filed in Personal · 1 to-do", among: binders), "Personal")
        // A placeholder title and no to-dos: the binder alone.
        XCTAssertEqual(CaptureOutcome.filedBinder(in: "Filed in General", among: binders), "General")
    }

    func testTheLongestNameThatFits() {
        XCTAssertEqual(CaptureOutcome.filedBinder(in: "Filed in Events Team: Standup", among: binders), "Events Team")
        // "Events" begins "Eventsy", which isn't a binder this iPhone knows.
        XCTAssertNil(CaptureOutcome.filedBinder(in: "Filed in Eventsy: Standup", among: binders))
        // Nor is "Events Teamwork", though "Events" and "Events Team" both begin it.
        XCTAssertNil(CaptureOutcome.filedBinder(in: "Filed in Events Teamwork: Standup", among: binders))
    }

    func testOtherLinesNameNoBinder() {
        XCTAssertNil(CaptureOutcome.filedBinder(in: "Not kept: small talk", among: binders))
        XCTAssertNil(CaptureOutcome.filedBinder(in: "Couldn't write up: the model stopped", among: binders))
        XCTAssertNil(CaptureOutcome.filedBinder(in: "Being written up on the Mac", among: binders))
        XCTAssertNil(CaptureOutcome.filedBinder(in: "Filed in Events: plan", among: []))
        XCTAssertNil(CaptureOutcome.filedBinder(in: "Filed in : plan", among: [""]))
    }
    func testAFiledLineInItsParts() throws {
        let filed = try XCTUnwrap(CaptureOutcome.filedParts(in: "Filed in Events: Ignite booth plan · 2 to-dos", among: binders))
        XCTAssertEqual(filed.binder, "Events")
        XCTAssertEqual(filed.title, "Ignite booth plan")
        XCTAssertEqual(filed.rest, ["2 to-dos"])
        // A binder this iPhone hasn't heard of: what comes before the colon.
        let unknown = try XCTUnwrap(CaptureOutcome.filedParts(in: "Filed in Studio: Pricing page review · 2 handed to agents · 1 added", among: binders))
        XCTAssertEqual(unknown.binder, "Studio")
        XCTAssertEqual(unknown.title, "Pricing page review")
        XCTAssertEqual(unknown.rest, ["2 handed to agents", "1 added"])
        // A title with a colon in it, in a binder it knows.
        XCTAssertEqual(CaptureOutcome.filedParts(in: "Filed in Events Team: Standup: the plan", among: binders)?.title, "Standup: the plan")
        let untitled = try XCTUnwrap(CaptureOutcome.filedParts(in: "Filed in Personal · 1 to-do", among: []))
        XCTAssertEqual(untitled.binder, "Personal")
        XCTAssertNil(untitled.title)
        XCTAssertEqual(untitled.rest, ["1 to-do"])
        XCTAssertEqual(CaptureOutcome.filedParts(in: "Filed in General", among: [])?.binder, "General")
        XCTAssertNil(CaptureOutcome.filedParts(in: "Not kept: small talk", among: binders))
        XCTAssertNil(CaptureOutcome.filedParts(in: "Filed in : plan", among: []))
    }
}
