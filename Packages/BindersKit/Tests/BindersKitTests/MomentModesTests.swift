import XCTest
@testable import BindersKit

/// The modes for what you say on your own (Suggest, Add at Once, Auto), as the iPhone keeps them and says them.
final class MomentModeTests: XCTestCase {
    func testTheStoredModeReadsAsSuggestUnlessItsKnown() {
        for mode in MomentMode.allCases {
            XCTAssertEqual(MomentMode(stored: mode.rawValue), mode, "round-trips")
        }
        XCTAssertEqual(MomentMode.allCases.map(\.rawValue), ["suggest", "add", "auto"])
        for stored in [nil, "", "Auto", "AUTO", " auto", "Suggest"] {
            XCTAssertEqual(MomentMode(stored: stored), .suggest, stored ?? "nil")
        }
    }

    func testEachModesNameAndLine() {
        XCTAssertEqual(MomentMode.allCases.map(\.name), ["Suggest", "Add at Once", "Auto"])
        XCTAssertEqual(MomentMode.suggest.summary,
                       "Offers each thing you say on your own, with Add and Not Now. A kind you add nearly every time is then added at once with Undo.")
        XCTAssertEqual(MomentMode.add.summary, "Adds to-dos, ideas and notes at once, with Undo. Work for an agent is offered, with Give to.")
        XCTAssertEqual(MomentMode.auto.summary,
                       "Adds them at once, and hands a to-do or an idea to the agent Binders picks, without asking first. Binders skips only its own "
                       + "question: each agent keeps its own permission checks, and is told to ask your approval before it sends, posts or buys.")
        for mode in MomentMode.allCases {
            AutoTextTests.assertPlain(mode.name)
            AutoTextTests.assertPlain(mode.summary)
        }
    }
}

/// A moment kept while the Mac was out of reach goes as the mode you have now, never up.
final class MomentModeSendingTests: XCTestCase {
    private let heard = Date(timeIntervalSince1970: 1_792_431_731)
    private let id = UUID()
    private let conversation = UUID()
    private let autoMac: Set<String> = [MomentPayload.feature, MomentPayload.addsFeature, MomentPayload.agreedFeature, MomentPayload.autoFeature]
    private let olderMac: Set<String> = [MomentPayload.feature, MomentPayload.addsFeature, MomentPayload.agreedFeature]

    /// Heard on its own in Auto, to a Mac that hands over in Auto: every kind added, your yes, its conversation set aside.
    private func inAuto(wake: Bool = false, hold: String? = nil) -> MomentPayload {
        MomentPayload(id: id, heard: heard, text: "I need to fix the login timeout on the website", device: "iPhone", engine: "parakeet-v2", wake: wake,
                      seconds: 3.1, cue: wake ? nil : "need to", voice: 0.86, conversation: conversation, asrMillis: 410,
                      adds: wake ? nil : MomentModes.everyKind, agreed: ["claude code · app": "3f2a9c41d0e7b815"], mode: "auto", autoHold: hold,
                      alone: true)
    }

    private func sent(_ payload: MomentPayload, now: MomentMode, listed: Bool = true, addsNow: [String]? = ["todo"], to mac: Set<String>? = nil)
        -> MomentPayload {
        MomentModes.asSent(payload, modeNow: now, listed: listed, addsNow: addsNow, macFeatures: mac ?? autoMac)
    }

    func testAutoStillOnSendsItAsItWas() {
        XCTAssertEqual(sent(inAuto(), now: .auto), inAuto())
        XCTAssertEqual(sent(inAuto(hold: "voice"), now: .auto), inAuto(hold: "voice"), "its hold too, for the line")
    }

    func testAutoOffSinceSendsItAsTheModeYouHaveNow() {
        let suggest = sent(inAuto(), now: .suggest)
        XCTAssertEqual(suggest.mode, "suggest")
        XCTAssertNil(suggest.agreed, "it loses its yes: nothing more is handed over once Auto is off")
        XCTAssertEqual(suggest.adds, ["todo"], "the kinds that have graduated")
        XCTAssertNil(sent(inAuto(), now: .suggest, addsNow: nil).adds, "none graduated, or not known: offered")
        XCTAssertNil(sent(inAuto(), now: .suggest, addsNow: []).adds)
        XCTAssertEqual(suggest.conversation, conversation, "as kept")
        XCTAssertEqual(suggest.alone, true)
        XCTAssertEqual(suggest.text, inAuto().text)
        let add = sent(inAuto(hold: "audio"), now: .add)
        XCTAssertEqual(add.mode, "add")
        XCTAssertNil(add.agreed)
        XCTAssertNil(add.autoHold, "the hold says why Auto didn't hand it over, which no longer applies")
        XCTAssertEqual(add.adds, ["todo", "idea", "note"])
    }

    func testAutoOnButTheSheetNotSeenGoesAsAddAtOnce() {
        let notListed = sent(inAuto(), now: .auto, listed: false)
        XCTAssertEqual(notListed.mode, "add")
        XCTAssertNil(notListed.agreed)
        XCTAssertEqual(notListed.adds, MomentModes.everyKind)
    }

    func testABindersSaidInAutoKeepsItsYes() {
        let asked = sent(inAuto(wake: true), now: .suggest)
        XCTAssertEqual(asked.mode, "suggest")
        XCTAssertEqual(asked.agreed, ["claude code · app": "3f2a9c41d0e7b815"], "for the start rule, whatever the mode")
        XCTAssertNil(asked.adds, "a Binders, … carries no adds")
    }

    func testAMacWithoutAutoGetsTodaysFields() {
        let older = sent(inAuto(hold: "voice"), now: .auto, to: olderMac)
        XCTAssertNil(older.mode)
        XCTAssertNil(older.autoHold)
        XCTAssertNil(older.alone, "an older Mac never gets alone")
        XCTAssertNil(older.agreed, "nor a yes for something heard on its own")
        XCTAssertEqual(older.adds, MomentModes.everyKind, "it's Add at Once there")
        XCTAssertEqual(older.conversation, conversation, "the conversation's id, as today")
        let neither = sent(inAuto(), now: .auto, to: [MomentPayload.feature])
        XCTAssertNil(neither.adds, "a Mac that doesn't add at once is offered each one")
        XCTAssertEqual(sent(inAuto(wake: true), now: .auto, to: olderMac).agreed, ["claude code · app": "3f2a9c41d0e7b815"],
                       "a Binders, … keeps its yes there too")
    }

    func testNeverUp() {
        var suggest = inAuto()
        suggest.mode = "suggest"
        suggest.agreed = nil
        suggest.adds = nil
        suggest.autoHold = nil
        XCTAssertEqual(sent(suggest, now: .auto), suggest, "heard in Suggest, Auto on now: as it was")
        XCTAssertEqual(sent(suggest, now: .auto, addsNow: ["todo", "idea"]), suggest, "and not the kinds graduated since")
        var add = suggest
        add.mode = "add"
        add.adds = MomentModes.everyKind
        XCTAssertEqual(sent(add, now: .auto), add)
        XCTAssertEqual(sent(add, now: .suggest).adds, ["todo"], "but down to Suggest, it's offered as Suggest offers now")
        var older = inAuto()
        older.mode = nil
        XCTAssertEqual(sent(older, now: .suggest), older, "no mode: an older build's, or built for an older Mac, as kept")
        XCTAssertEqual(sent(older, now: .auto, to: olderMac), older)
    }
}

/// Auto's limits.
final class AutoRulesTests: XCTestCase {
    func testLate() {
        XCTAssertTrue(AutoRules.isLate(15 * 60 + 1), "15 minutes and a second old")
        XCTAssertFalse(AutoRules.isLate(15 * 60), "15 minutes exactly")
        XCTAssertTrue(AutoRules.isLate(-(2 * 60 + 1)), "2 minutes and a second ahead")
        XCTAssertFalse(AutoRules.isLate(-2 * 60))
        XCTAssertFalse(AutoRules.isLate(0))
        XCTAssertEqual(AutoRules.lateAfter, RouterRules.freshFor, "the start rule's 15 minutes")
        XCTAssertEqual(AutoRules.horizon, 12 * 3_600)
        XCTAssertEqual([AutoRules.lateAtOnce, Int(AutoRules.lateWindow), Int(AutoRules.repeatWithin)], [5, 600, 1_800])
        XCTAssertEqual([AutoRules.notMeToTurnOff, AutoRules.notMeWindow], [2, 10])
    }

    func testTheSameThing() {
        XCTAssertTrue(AutoRules.sameThing("Fix the login timeout", "fix the login time-out"))
        XCTAssertTrue(AutoRules.sameThing("Fix the login timeout.", "fix the login timeout"))
        XCTAssertFalse(AutoRules.sameThing("Fix the login timeout", "Fix the signup timeout"))
        XCTAssertFalse(AutoRules.sameThing("Fix the login timeout", "Book the dentist"))
        XCTAssertFalse(AutoRules.sameThing("", ""), "nothing isn't the same thing")
    }
}

/// Two Not me's among Auto's last ten hand-overs turn it off.
final class AutoWatchTests: XCTestCase {
    func testASecondNotMeInTheWindowTurnsAutoOff() {
        var watch = AutoWatch()
        let ids = (0..<4).map { _ in UUID() }
        ids.forEach { watch.handedOver($0) }
        XCTAssertFalse(watch.notMe(ids[0]), "one doesn't")
        XCTAssertFalse(watch.notMe(ids[0]), "the same one twice is still one")
        XCTAssertTrue(watch.notMe(ids[2]), "a second does")
        XCTAssertEqual(watch.recent.filter(\.notMe).count, 2)
    }

    func testABindersHandOverCountsToo() {
        var watch = AutoWatch()
        let asked = UUID(), heard = UUID()
        watch.handedOver(asked)   // a "Binders, …" handed over in Auto
        watch.handedOver(heard)
        XCTAssertFalse(watch.notMe(heard))
        XCTAssertTrue(watch.notMe(asked))
    }

    func testTheWindowIsTheLastTen() {
        var watch = AutoWatch()
        let ids = (0..<11).map { _ in UUID() }
        watch.handedOver(ids[0])
        XCTAssertFalse(watch.notMe(ids[0]))
        ids.dropFirst().forEach { watch.handedOver($0) }
        XCTAssertEqual(watch.recent.count, 10, "an eleventh pushes the oldest out")
        XCTAssertEqual(watch.recent.first?.moment, ids[1])
        XCTAssertFalse(watch.notMe(ids[5]), "the first Not me went out of the window with it")
        XCTAssertFalse(watch.notMe(UUID()), "one outside the window doesn't count")
        XCTAssertTrue(watch.notMe(ids[9]))
        watch.handedOver(ids[5])
        XCTAssertEqual(watch.recent.count, 10, "handed over once only")
    }

    func testResetCountsAfreshAndItRoundTrips() throws {
        var watch = AutoWatch()
        let ids = (0..<3).map { _ in UUID() }
        ids.forEach { watch.handedOver($0) }
        XCTAssertFalse(watch.notMe(ids[1]))
        let read = try JSONDecoder().decode(AutoWatch.self, from: JSONEncoder().encode(watch))
        XCTAssertEqual(read, watch)
        watch.reset()
        XCTAssertEqual(watch, AutoWatch())
        watch.handedOver(ids[2])
        XCTAssertFalse(watch.notMe(ids[2]), "chosen again, it counts afresh")
        let text = String(decoding: try JSONEncoder().encode(watch), as: UTF8.self)
        XCTAssertFalse(text.contains("login"), "ids and verdicts only")
    }
}
