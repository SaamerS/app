import XCTest
@testable import BindersKit

/// Lane Y2's "only you" rule, case by case, as `scratch-Y2/bench/rev/solo_rule_rev.py` gives each one (DESIGN 2.2), and
/// its marks. Voice A is yours, the others someone else's; the start bar is 0.78.
final class SoloRuleTests: XCTestCase {
    private let bar = 0.78
    private let a = 0.86

    private func turns(_ list: [(String, Double, Double)]) -> [SpeakerTurn] {
        list.map { SpeakerTurn(speakerID: $0.0, start: $0.1, end: $0.2) }
    }

    private func facts(diarizer: SoloRule.Diarizer = .ran, _ list: [(String, Double, Double)], scores: [String: Double], printTaught: Bool = true,
                       bar: Double?? = nil, audio: Bool = false, call: Bool = false, continues: Bool? = nil,
                       segments: [(Double, Double, Int)] = []) -> SoloRule.Facts {
        SoloRule.Facts(diarizer: diarizer, turns: turns(list), scores: scores, printTaught: printTaught, startBar: bar ?? self.bar,
                       otherAudio: audio, call: call, continues: continues,
                       segments: segments.map { SoloRule.Span(start: $0.0, end: $0.1, words: $0.2) })
    }

    private func hold(_ facts: SoloRule.Facts) -> String {
        let verdict = SoloRule.verdict(facts)
        return verdict.isOnlyYou ? "only you" : (verdict.hold ?? "?")
    }

    func testTheCaseTable() {
        XCTAssertEqual(hold(facts([("A", 0, 40), ("A", 45, 120)], scores: ["A": a])), "only you", "one voice, yours past the bar")
        XCTAssertEqual(hold(facts(diarizer: .failed, [], scores: [:])), "diarizer", "the diarizer failed: one voice by fallback")
        XCTAssertEqual(hold(facts(diarizer: .noSpeech, [], scores: [:])), "diarizer", "no speech")
        XCTAssertEqual(hold(facts(diarizer: .skipped, [], scores: [:])), "diarizer", "skipped after it kept stopping Binders")
        XCTAssertEqual(hold(facts(diarizer: .missing, [("A", 0, 60)], scores: ["A": a])), "diarizer", "no diarizer on the phone")
        XCTAssertEqual(hold(facts([("A", 0, 60)], scores: [:], printTaught: false, bar: .some(nil))), "print", "no voice print")
        XCTAssertEqual(hold(facts([("A", 0, 60)], scores: ["A": a], bar: .some(nil))), "calibrate", "no start bar")
        XCTAssertEqual(hold(facts([("A", 0, 60)], scores: ["A": 0.70])), "voice", "under the start bar")
        XCTAssertEqual(hold(facts([("A", 0, 40), ("B", 41, 71), ("A", 72, 100)], scores: ["A": a, "B": 0.31])), "voices", "the other 30 s")
        XCTAssertEqual(hold(facts([("A", 0, 50), ("B", 52, 80)], scores: ["A": a, "B": 0.81])), "only you", "two voices, both yours")
        XCTAssertEqual(hold(facts([("A", 0, 40), ("B", 41, 80), ("A", 81, 120), ("B", 121, 160)], scores: ["A": a, "B": 0.81])), "only you",
                       "both yours, flipping 3 times")
        XCTAssertEqual(hold(facts([("A", 0, 60), ("B", 61, 63.5)], scores: ["A": a, "B": 0.40])), "voices", "another voice 2.5 s at a stretch")
        XCTAssertEqual(hold(facts([("A", 0, 60), ("B", 64, 66.2), ("A", 70, 120)], scores: ["A": a, "B": 0.70])), "voices",
                       "someone else's cued sentence, 2.2 s at 0.70")
        XCTAssertEqual(hold(facts([("A", 0, 8), ("B", 9, 15), ("A", 16, 25), ("B", 26, 30), ("A", 31, 40), ("B", 41, 47), ("A", 48, 60)],
                                  scores: ["A": a, "B": 0.80])), "dialogue", "two of yours taking turns like a dialogue")
        XCTAssertEqual(hold(facts([("A", 0, 60), ("B", 61, 61.9), ("A", 63, 90)], scores: ["A": a, "B": 0.22])), "only you", "excuse me, 0.9 s")
        XCTAssertEqual(hold(facts([("A", 0, 60), ("B", 70, 71.2), ("B", 95, 96.4), ("A", 97, 130)], scores: ["A": a, "B": 0.18])), "only you",
                       "a shop's speaker twice")
        XCTAssertEqual(hold(facts([("A", 0, 20), ("B", 21, 21.5), ("A", 22, 40), ("B", 41, 41.5), ("A", 42, 60), ("B", 61, 61.5), ("A", 62, 80),
                                   ("B", 81, 81.5), ("A", 82, 100), ("B", 101, 101.5)], scores: ["A": a, "B": 0.30])), "voices", "a listener's yeah five times")
        XCTAssertEqual(hold(facts([("A", 0, 60), ("B", 62, 63.8), ("C", 80, 81.6)], scores: ["A": a, "B": 0.2, "C": 0.3])), "voices", "3.4 s of two others")
        XCTAssertEqual(hold(facts([("A", 0, 60)], scores: ["A": a], audio: true)), "audio", "audio played while you spoke")
        XCTAssertEqual(hold(facts([("A", 0, 60)], scores: ["A": a], call: true)), "call", "a call while you spoke")
        XCTAssertEqual(hold(facts([("A", 0, 60)], scores: ["A": a], continues: true)), "only you", "continues one that was only you")
        XCTAssertEqual(hold(facts([("A", 0, 60)], scores: ["A": a], continues: false)), "continues", "continues one that wasn't")
        XCTAssertEqual(hold(facts([("A", 0, 40), ("A", 52, 90)], scores: ["A": a], segments: [(0, 20, 40), (20, 40, 40), (40, 52, 20), (52, 90, 0)])),
                       "unsure", "a fifth of the words unheard")
        XCTAssertEqual(hold(facts([("A", 0, 40), ("A", 44, 90)], scores: ["A": a], segments: [(0, 20, 50), (20, 40, 50), (40, 44, 5), (44, 90, 95)])),
                       "only you", "1 in 20 unheard")
        XCTAssertEqual(hold(facts([("A", 0, 1.5)], scores: ["A": 0.90])), "voice", "1.5 s of your voice: too little to score")
    }

    func testTheMarks() {
        func mark(_ span: (Double, Double), _ list: [(String, Double, Double)]) -> SoloRule.Mark {
            SoloRule.mark(SoloRule.Span(start: span.0, end: span.1), turns: turns(list), yours: ["A"])
        }
        XCTAssertEqual(mark((10, 25), [("A", 9.8, 25.3)]), .yours)
        XCTAssertEqual(mark((10, 25), [("A", 9.8, 17), ("B", 17.1, 18.0), ("A", 18.2, 25.3)]), .mixed)
        XCTAssertEqual(mark((10, 25), [("A", 9.8, 25.0), ("B", 24.8, 26.4)]), .yours)
        XCTAssertEqual(mark((40, 43), [("B", 40.2, 42.1)]), .other)
        XCTAssertEqual(mark((60, 64), []), .unsure)
        XCTAssertEqual(mark((0, 10), [("A", 0, 3), ("A", 4.5, 7), ("A", 8, 9.5)]), .yours, "pauses: 70% covered")
        XCTAssertEqual(mark((30.0, 32.6), [("A", 20, 40)]), .yours)
        XCTAssertEqual(mark((30.0, 32.6), [("A", 20, 30.4), ("B", 30.5, 31.0), ("A", 31.2, 40)]), .mixed)
        XCTAssertEqual(mark((50.0, 52.4), [("A", 20, 40)]), .unsure)
    }

    func testTheRestOfIt() throws {
        // A voice with no embedding is someone else's.
        XCTAssertEqual(hold(facts([("A", 0, 60), ("B", 61, 63)], scores: ["A": a])), "voices")
        // One voice's turns 0.5 s apart are one turn: two of 1.2 s are 2.9 s, at a stretch long enough to score.
        XCTAssertEqual(hold(facts([("A", 0, 60), ("B", 61, 62.2), ("B", 62.7, 63.9)], scores: ["A": a, "B": 0.2])), "voices")
        // The order of the holds.
        XCTAssertEqual(Array(SoloRule.Hold.allCases.map(\.rawValue)),
                       ["print", "calibrate", "diarizer", "audio", "call", "continues", "voice", "voices", "dialogue", "unsure"])
        XCTAssertEqual(hold(facts(diarizer: .failed, [], scores: [:], audio: true)), "diarizer", "the diarizer before audio")
        XCTAssertEqual(hold(facts([("A", 0, 60)], scores: ["A": 0.5], audio: true)), "audio", "audio before the voice")
        // The numbers.
        let verdict = SoloRule.verdict(facts([("A", 0, 50), ("B", 52, 80), ("C", 90, 90.9)], scores: ["A": a, "B": 0.81, "C": 0.2]))
        XCTAssertTrue(verdict.isOnlyYou)
        XCTAssertEqual(verdict.lowest, 0.81)
        XCTAssertEqual(verdict.otherSpeech, 0.9, accuracy: 0.001)
        XCTAssertEqual(Set(verdict.yours.keys), ["A", "B"])
        // It round-trips, and one with a reason this build doesn't know decodes and isn't only you.
        let data = try JSONEncoder().encode(verdict)
        XCTAssertEqual(try JSONDecoder().decode(SoloRule.Verdict.self, from: data), verdict)
        var newer = verdict
        newer.solo = true
        newer.hold = "a-new-reason"
        let read = try JSONDecoder().decode(SoloRule.Verdict.self, from: JSONEncoder().encode(newer))
        XCTAssertFalse(read.isOnlyYou)
        XCTAssertNil(read.reason)
        // The timeline's words: numbers, never words said.
        XCTAssertEqual(SoloRule.timeline(SoloRule.verdict(facts([("A", 0, 60)], scores: ["A": a]))), "one voice, yours (0.86): only you")
        XCTAssertEqual(SoloRule.timeline(SoloRule.verdict(facts([("A", 0, 60)], scores: ["A": 0.70])), best: 0.70),
                       "under the start bar (0.70): not only you")
    }

    func testWhileSpeaking() {
        let tick = Date()
        let before = tick.addingTimeInterval(-5)
        XCTAssertFalse(SoloRule.whileSpeaking(writtenUntil: tick.addingTimeInterval(-30), previousTick: before), "30 s after the last audio")
        XCTAssertTrue(SoloRule.whileSpeaking(writtenUntil: tick, previousTick: before), "during speech")
        XCTAssertTrue(SoloRule.whileSpeaking(writtenUntil: tick.addingTimeInterval(-2), previousTick: before), "3 s after the last word, the padding")
        XCTAssertFalse(SoloRule.whileSpeaking(writtenUntil: nil, previousTick: before))
    }

    func testContinuing() {
        let now = Date()
        let settings = ConversationSplitter.Settings()
        XCTAssertTrue(ConversationSplitter.continues(lastEnd: now.addingTimeInterval(-120), lastCut: now.addingTimeInterval(-120), start: now,
                                                     settings: settings), "a split 2 minutes before")
        XCTAssertTrue(ConversationSplitter.continues(lastEnd: now.addingTimeInterval(-30), lastCut: now.addingTimeInterval(-25), start: now),
                      "listening stopped 25 s before")
        XCTAssertFalse(ConversationSplitter.continues(lastEnd: now.addingTimeInterval(-200), lastCut: nil, start: now), "closed after quiet")
        XCTAssertFalse(ConversationSplitter.continues(lastEnd: now.addingTimeInterval(-30), lastCut: nil, start: now), "a Wrap Up is no cut")
        XCTAssertFalse(ConversationSplitter.continues(lastEnd: now.addingTimeInterval(-240), lastCut: now.addingTimeInterval(-240), start: now),
                       "a cut 4 minutes before")
    }

    func testFileTimeIsWallTimesInverse() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var spans = CaptureSpans()
        spans.append(wallStart: start, duration: 10)
        spans.append(wallStart: start.addingTimeInterval(60), duration: 20)
        for seconds in [0.0, 4.5, 9.9, 10.0, 15.0, 29.5] {
            let wall = try! XCTUnwrap(spans.wallTime(atFile: seconds))
            XCTAssertEqual(try! XCTUnwrap(spans.fileTime(atWall: wall)), seconds, accuracy: 0.0001, "\(seconds)")
        }
        XCTAssertEqual(spans.fileTime(atWall: start.addingTimeInterval(30)), 10, "between spans: the nearest edge")
        XCTAssertNil(CaptureSpans().fileTime(atWall: start))
    }
}

/// What a capture carries (SoloAgreement) and how it's sent later (SoloModes.asSent).
final class SoloAgreementTests: XCTestCase {
    private let only = SoloRule.Verdict(solo: true, yours: ["A": 0.86], yourSpeech: 60, lowest: 0.86)
    private let notOnly = SoloRule.Verdict(solo: false, hold: "voices")
    private let mac: Set<String> = [ConversationPayload.soloFeature, MomentPayload.autoFeature, MomentPayload.agreedFeature]
    private let consents = ["scribe": "fp-solo", "  ": "x", "empty": ""]

    func testAgreed() {
        XCTAssertEqual(SoloAgreement.agreed(only, mode: .auto, listed: true, macFeatures: mac, consents: consents), ["scribe": "fp-solo"])
        XCTAssertNil(SoloAgreement.agreed(only, mode: .add, listed: true, macFeatures: mac, consents: consents), "never in Add at Once")
        XCTAssertNil(SoloAgreement.agreed(notOnly, mode: .auto, listed: true, macFeatures: mac, consents: consents), "not only you")
        XCTAssertNil(SoloAgreement.agreed(only, mode: .auto, listed: false, macFeatures: mac, consents: consents), "before the sheet")
        for missing in mac {
            XCTAssertNil(SoloAgreement.agreed(only, mode: .auto, listed: true, macFeatures: mac.subtracting([missing]), consents: consents), missing)
        }
        XCTAssertNil(SoloAgreement.agreed(only, mode: .auto, listed: true, macFeatures: mac, consents: ["empty": ""]))
    }

    func testHold() {
        XCTAssertEqual(SoloAgreement.hold(notOnly, mode: .auto, listed: true, parts: 1), "voices")
        XCTAssertEqual(SoloAgreement.hold(only, mode: .add, listed: false, parts: 2), "parts")
        XCTAssertNil(SoloAgreement.hold(notOnly, mode: .suggest, listed: true, parts: 1), "Suggest")
        XCTAssertNil(SoloAgreement.hold(notOnly, mode: .auto, listed: false, parts: 1), "Auto before the sheet")
        XCTAssertNil(SoloAgreement.hold(only, mode: .auto, listed: true, parts: 1), "nothing holds it back")
        XCTAssertEqual(SoloAgreement.hold(notOnly, mode: .add, listed: false, parts: 1), "voices", "Add at Once needs no sheet")
    }

    private func payload(mode: String = "auto") -> ConversationPayload {
        ConversationPayload(started: Date(), ended: Date(), segments: [], device: "iPhone", engine: "parakeet-v2", mode: mode, solo: true,
                            agreed: ["scribe": "fp-solo", "hooky": "fp-old"], voice: 0.84, otherSpeech: 0.9, soloMoments: [UUID()])
    }

    private func isBare(_ sent: ConversationPayload) -> Bool {
        sent.mode == nil && sent.solo == nil && sent.soloHold == nil && sent.agreed == nil && sent.voice == nil && sent.otherSpeech == nil
            && sent.soloMoments == nil && sent.keptForMoment == nil
    }

    func testAsSent() {
        let now = ["scribe": "fp-solo", "hooky": "fp-old"]
        let sent = SoloModes.asSent(payload(), modeNow: .auto, listed: true, soloListed: true, macFeatures: mac, consents: now)
        XCTAssertEqual(sent, payload().with { $0.id = sent.id; $0.soloMoments = sent.soloMoments; $0.started = sent.started; $0.ended = sent.ended })
        let add = SoloModes.asSent(payload(), modeNow: .add, listed: true, soloListed: true, macFeatures: mac, consents: now)
        XCTAssertEqual(add.mode, "add")
        XCTAssertNil(add.agreed)
        XCTAssertEqual(add.solo, true)
        XCTAssertTrue(isBare(SoloModes.asSent(payload(), modeNow: .suggest, listed: true, soloListed: true, macFeatures: mac, consents: now)))
        XCTAssertTrue(isBare(SoloModes.asSent(payload(), modeNow: .auto, listed: true, soloListed: false, macFeatures: mac, consents: now)),
                      "Auto on, the new sheet not seen")
        XCTAssertTrue(isBare(SoloModes.asSent(payload(), modeNow: .auto, listed: true, soloListed: true,
                                              macFeatures: mac.subtracting([ConversationPayload.soloFeature]), consents: now)))
        XCTAssertEqual(SoloModes.asSent(payload(mode: "add"), modeNow: .auto, listed: true, soloListed: true, macFeatures: mac, consents: now).mode,
                       "add", "never up")
        let taken = SoloModes.asSent(payload(), modeNow: .auto, listed: true, soloListed: true, macFeatures: mac, consents: ["scribe": "fp-solo"])
        XCTAssertEqual(taken.agreed, ["scribe": "fp-solo"], "a yes taken back since it was queued")
    }

    func testStopAllAndNotOnlyMeLowerWhatsStillToCome() {
        var vouch = SoloVouch(mode: "auto", solo: true)
        XCTAssertEqual(vouch.modeNow, .auto)
        vouch.stoppedAll = true
        XCTAssertEqual(vouch.modeNow, .add)
        vouch.stoppedAll = nil
        vouch.notOnlyMe = true
        XCTAssertEqual(vouch.modeNow, .add)
        XCTAssertEqual(SoloVouch.decode(vouch.json)?.notOnlyMe, true)
        XCTAssertNil(SoloVouch.decode(#"{"mode":"auto","solo":true}"#)?.stoppedAll, "a vouch kept before reads")
        XCTAssertEqual(SoloVouch(mode: "add", solo: true, soloHold: nil).modeNow, .add)
    }

    func testAMomentAsSent() {
        let moment = MomentPayload(heard: Date(), text: "the export doesn't include the dates", agreed: ["scribe": "fp", "hooky": "old"],
                                   mode: "auto", fromTranscript: true, uncued: "fix")
        let older: Set<String> = [MomentPayload.autoFeature, MomentPayload.agreedFeature, MomentPayload.addsFeature]
        let toOlder = MomentModes.asSent(moment, modeNow: .auto, listed: true, addsNow: nil, macFeatures: older)
        XCTAssertNil(toOlder.fromTranscript)
        XCTAssertNil(toOlder.uncued)
        XCTAssertNil(toOlder.agreed, "an older Mac never gets a yes for what only Y2 sends")
        XCTAssertEqual(toOlder.mode, "suggest", "a sentence kept without a cue is only offered by an older Mac")
        XCTAssertNil(toOlder.adds)
        var transcript = moment
        transcript.uncued = nil
        let transcriptToOlder = MomentModes.asSent(transcript, modeNow: .auto, listed: true, addsNow: nil, macFeatures: older)
        XCTAssertNil(transcriptToOlder.mode, "a \u{201C}Binders, …\u{201D} found in a transcript goes with no mode, as before Y2")
        XCTAssertNil(transcriptToOlder.agreed)
        var plain = moment
        plain.uncued = nil
        plain.fromTranscript = nil
        XCTAssertEqual(MomentModes.asSent(plain, modeNow: .auto, listed: true, addsNow: nil, macFeatures: older).agreed, moment.agreed,
                       "no consents: kept as kept")
        let toY2 = MomentModes.asSent(moment, modeNow: .auto, listed: true, addsNow: nil, macFeatures: older.union(mac), consents: ["scribe": "fp"])
        XCTAssertEqual(toY2.uncued, "fix")
        XCTAssertEqual(toY2.fromTranscript, true)
        XCTAssertEqual(toY2.agreed, ["scribe": "fp"])
    }
}

private extension ConversationPayload {
    func with(_ change: (inout ConversationPayload) -> Void) -> ConversationPayload {
        var copy = self
        change(&copy)
        return copy
    }
}
