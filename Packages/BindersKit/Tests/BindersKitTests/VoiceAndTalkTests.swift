import Foundation
import XCTest
@testable import BindersKit

/// A short clip made ready for its voice to be scored (the reason every Calibrate phrase came back "not close enough to
/// your voice"), and the Dictate bar's touches, a hold taken away by iOS among them (the reason hold to ask stopped
/// listening after a second).
final class VoiceAndTalkTests: XCTestCase {
    /// A tone at 16 kHz, loud enough to be speech to the trim.
    private func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    private func quiet(seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

    // MARK: Voice

    func testTheQuietAtEitherEndIsTrimmed() {
        let speech = tone(seconds: 2)
        let clip = quiet(seconds: 1) + speech + quiet(seconds: 1)
        let trimmed = AudioMath.trimmedQuiet(clip)
        // To the frame (30 ms) on either side.
        XCTAssertEqual(Double(trimmed.count), Double(speech.count), accuracy: 2 * 480)
        XCTAssertEqual(Double(trimmed.startIndex), 16_000, accuracy: 480)
        XCTAssertGreaterThan(AudioMath.rms(trimmed), 0.2)
    }

    func testQuietTrimKeepsAllOfSilenceOrATinyClip() {
        XCTAssertEqual(AudioMath.trimmedQuiet(quiet(seconds: 1)).count, 16_000)
        XCTAssertEqual(AudioMath.trimmedQuiet([0.1, 0.2]).count, 2)
        XCTAssertEqual(AudioMath.trimmedQuiet([]).count, 0)
    }

    func testAShortClipFillsTheDiarizersWindowWithItsOwnSpeech() {
        let speech = tone(seconds: 3)
        let filled = AudioMath.filledForVoice(quiet(seconds: 1) + speech + quiet(seconds: 1))
        XCTAssertEqual(filled.count, AudioMath.voiceWindow)
        XCTAssertEqual(AudioMath.voiceWindow, 160_000)
        // No stretch of the silence the diarizer would have padded it with: every second is speech.
        for second in 0..<10 {
            let slice = filled[(second * 16_000)..<((second + 1) * 16_000)]
            XCTAssertGreaterThan(AudioMath.rms(slice), 0.1, "Second \(second) is quiet")
        }
        // It's the clip's own speech, again from its start.
        let trimmed = Array(AudioMath.trimmedQuiet(quiet(seconds: 1) + speech + quiet(seconds: 1)))
        XCTAssertEqual(Array(filled.prefix(trimmed.count)), trimmed)
        XCTAssertEqual(Array(filled[trimmed.count..<(2 * trimmed.count)]), trimmed)
    }

    func testALongClipComesBackTrimmedAsItIs() {
        let speech = tone(seconds: 12)
        let filled = AudioMath.filledForVoice(quiet(seconds: 1) + speech + quiet(seconds: 1))
        XCTAssertEqual(Double(filled.count), Double(speech.count), accuracy: 2 * 480)
        XCTAssertEqual(AudioMath.filledForVoice([]), [])
    }

    // MARK: The Dictate bar

    func testATapDictatesAndASwipeDoesNot() {
        var talk = TalkTouch()
        talk.down()
        XCTAssertEqual(talk.up(travelled: 4), .dictate)
        XCTAssertEqual(talk.phase, .idle)
        talk.down()
        XCTAssertEqual(talk.up(travelled: 80), .none)
        XCTAssertFalse(talk.isAsking)
    }

    func testAHoldListensAndLettingGoAsks() {
        var talk = TalkTouch()
        talk.down()
        XCTAssertEqual(talk.held(), .listen)
        XCTAssertTrue(talk.isListening)
        XCTAssertEqual(talk.up(travelled: 120), .ask, "Moving while held still asks")
        XCTAssertEqual(talk.phase, .finishing)
        XCTAssertTrue(talk.isAsking)
        XCTAssertFalse(talk.isListening)
        // Another touch waits for the question: it neither dictates nor listens.
        talk.down()
        XCTAssertEqual(talk.held(), .none)
        XCTAssertEqual(talk.up(travelled: 0), .none)
        talk.reset()
        XCTAssertEqual(talk.phase, .idle)
    }

    func testAHoldTakenAwayByIOSKeepsListeningUntilATap() {
        var talk = TalkTouch()
        talk.down()
        XCTAssertEqual(talk.held(), .listen)
        // The tab bar takes the touch: not a let go.
        XCTAssertEqual(talk.cancelled(travelled: 0), .none)
        XCTAssertEqual(talk.phase, .loose)
        XCTAssertTrue(talk.isListening)
        // The next tap asks, and isn't a dictation.
        talk.down()
        XCTAssertEqual(talk.phase, .looseTapping)
        XCTAssertEqual(talk.held(), .none, "A long tap doesn't start listening again")
        XCTAssertEqual(talk.up(travelled: 0), .ask)
        XCTAssertEqual(talk.phase, .finishing)
    }

    func testThatTapTakenAwayTooStillListens() {
        var talk = TalkTouch()
        talk.down()
        _ = talk.held()
        _ = talk.cancelled(travelled: 0)
        talk.down()
        XCTAssertEqual(talk.cancelled(travelled: 0), .none)
        XCTAssertEqual(talk.phase, .loose)
    }

    func testATouchTakenAwayBeforeItWasHeldIsATapAsBefore() {
        var talk = TalkTouch()
        talk.down()
        XCTAssertEqual(talk.cancelled(travelled: 2), .dictate)
        XCTAssertEqual(talk.phase, .idle)
    }

    func testListeningEndsAtTheLongestWhateverTheTouch() {
        var held = TalkTouch()
        held.down()
        _ = held.held()
        XCTAssertEqual(held.timedOut(), .ask)
        XCTAssertEqual(held.phase, .finishing)

        var loose = TalkTouch()
        loose.down()
        _ = loose.held()
        _ = loose.cancelled(travelled: 0)
        XCTAssertEqual(loose.timedOut(), .ask)

        var idle = TalkTouch()
        XCTAssertEqual(idle.timedOut(), .none)
        XCTAssertEqual(idle.phase, .idle)
        XCTAssertEqual(TalkTouch.longest, 60)
    }
}
