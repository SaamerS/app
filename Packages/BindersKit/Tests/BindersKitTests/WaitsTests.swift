import XCTest
@testable import BindersKit

/// Every wait names its reason and the next step: a capture waiting to be written down, and something you said waiting
/// on your Mac.
final class WaitsTests: XCTestCase {
    /// The ways on a wait can name: Binders open, the charger, or the capture ahead of it.
    private func namesTheWayOn(_ reason: String) -> Bool {
        ["with Binders open", "open Binders", "while charging", "the one before it"].contains { reason.contains($0) }
    }

    func testEveryCaptureWaitNamesItsReasonAndTheNextStep() {
        // Every mix of what can stand in its way, with the charger taking the task and refusing it.
        for bits in 0..<(1 << 11) {
            for blocked in [nil, "Background App Refresh is off for Binders"] {
                func bit(_ index: Int) -> Bool { bits & (1 << index) != 0 }
                let facts = CaptureWait.Facts(inFront: bit(0), mayInferInBackground: bit(1), appOnly: bit(2), writesDownWhileLocked: bit(3),
                                              backgroundPaused: bit(4), modelsReady: bit(5), staysAlive: bit(6), warm: bit(7), lowPowerMode: bit(8),
                                              lowBattery: bit(9), long: bit(10), chargingBlocked: blocked)
                let reason = CaptureWait.reason(facts)
                XCTAssertTrue(namesTheWayOn(reason), "“\(reason)” doesn't say what gets it going")
                if blocked != nil { XCTAssertFalse(reason.contains("while charging"), "“\(reason)” offers a charger that can't help") }
            }
        }
    }

    func testTheWaitsThatOnlyGaveAReason() {
        let ready = CaptureWait.Facts()
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(staysAlive: false)), "capture isn't listening, so with Binders open or while charging")
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(warm: true)), "the iPhone is warm, so with Binders open or while charging")
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(lowPowerMode: true)), "Low Power Mode is on, so with Binders open or while charging")
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(lowBattery: true)), "the battery is under 20%, so with Binders open or while charging")
        XCTAssertEqual(CaptureWait.reason(ready), "the iPhone is busy, so with Binders open or while charging")
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(warm: true, chargingBlocked: "Background App Refresh is off for Binders")),
                       "the iPhone is warm, so with Binders open (the charger can't help: Background App Refresh is off for Binders)")
    }

    func testTheFirstThingInItsWayIsTheOneSaid() {
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(inFront: true, warm: true)), "the one before it first", "open: it's next")
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(mayInferInBackground: false, warm: true)), "only with Binders open on this iPhone")
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(appOnly: true, chargingBlocked: "off")),
                       "something went wrong in the background, so with Binders open", "the charger doesn't take one that stopped Binders")
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(writesDownWhileLocked: false, lowBattery: true)),
                       "writing down while locked is off, so with Binders open or while charging")
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(backgroundPaused: true)),
                       "something went wrong in the background, so with Binders open or while charging", "the charging task still runs")
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(modelsReady: false, staysAlive: false)), "the speech models aren't ready yet: open Binders once")
        XCTAssertEqual(CaptureWait.reason(CaptureWait.Facts(long: true)), "over 15 minutes of speech, so with Binders open or while charging")
    }

    func testSomethingYouSaidSaysWhyItWaitsAndWhatComesNext() {
        XCTAssertEqual(MomentWait.line(state: "kept", outcome: nil), "Kept on this iPhone. It goes to your Mac when it's back.")
        XCTAssertEqual(MomentWait.line(state: "sent", outcome: nil), "Sent. Your Mac says what it made of it shortly.")
        XCTAssertEqual(MomentWait.line(state: "sent", outcome: "working"), "Your Mac is working on it, and says what it made of it shortly.",
                       "never just “Working on it”")
        XCTAssertNil(MomentWait.line(state: "refused", outcome: nil), "not a wait: your Mac couldn't read it")
        for done in ["offered", "acted", "answered", "nothing", "undone", "dismissed", "pondered"] {
            XCTAssertNil(MomentWait.line(state: "sent", outcome: done), "\(done): the Mac has said what it made of it")
        }
        for line in [MomentWait.kept, MomentWait.sent, MomentWait.working] {
            XCTAssertTrue(line.localizedCaseInsensitiveContains("your Mac"), "“\(line)” says what it waits on")
            XCTAssertTrue(line.contains("when it's back") || line.contains("shortly"), "“\(line)” says what comes next")
        }
        // Under a word that already says why ("Waiting for your Mac", "Sent"), only what comes next.
        XCTAssertEqual(MomentWait.next(state: "kept", outcome: nil), "It goes to your Mac when it's back.")
        XCTAssertEqual(MomentWait.next(state: "sent", outcome: nil), "Your Mac says what it made of it shortly.")
        XCTAssertEqual(MomentWait.next(state: "sent", outcome: "working"), "Your Mac says what it made of it shortly.")
        XCTAssertNil(MomentWait.next(state: "refused", outcome: nil))
        XCTAssertNil(MomentWait.next(state: "sent", outcome: "acted"))
    }
}

/// Calibrate's level meter, like the dictation meter, moves only while you speak, and under Reduce Motion holds still.
final class LevelMeterLookTests: XCTestCase {
    func testItGrowsWithTheVoice() {
        XCTAssertEqual(LevelMeterLook(level: 0, reduceMotion: false), LevelMeterLook(level: -1, reduceMotion: false), "still in the quiet")
        XCTAssertEqual(LevelMeterLook(level: 0.4, reduceMotion: false).fill, 0.4)
        XCTAssertEqual(LevelMeterLook(level: 3, reduceMotion: false).fill, 1)
        XCTAssertEqual(LevelMeterLook(level: .nan, reduceMotion: false).fill, 0)
    }

    func testUnderReduceMotionItHoldsStillAndBrightensInstead() {
        let levels = stride(from: 0.0, through: 1.0, by: 0.1).map { LevelMeterLook(level: $0, reduceMotion: true) }
        XCTAssertEqual(Set(levels.map(\.fill)), [1], "the same length whatever the level")
        XCTAssertEqual(levels.map(\.brightness), levels.map(\.brightness).sorted(), "brighter as the voice is louder")
        XCTAssertGreaterThan(levels.first!.brightness, 0, "still there in the quiet: the microphone is live")
        XCTAssertEqual(levels.last!.brightness, 1, accuracy: 1e-9)
    }
}
