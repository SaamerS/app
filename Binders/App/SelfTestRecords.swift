import Foundation
import BindersKit

extension SelfTest {
    /// Capture records as each iPhone build writes them still read in both directions: CaptureFiles.all() drops a record
    /// it can't read, so one wrong field would lose every capture. Writes nothing.
    static func captureRecordsSelfTest() -> Int32 {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        // As iPhone 2.0 (9) wrote one: no failures, appOnly, wrappedUp, outcome or steps.
        let first = #"""
        {"id":"3F2B7C1E-8D4A-4E59-9B21-6A7C0D5E4F31","started":782300000,"ended":782300600,"speech":312,"state":"sent",
         "spans":{"spans":[{"fileStart":0,"wallStart":782300000,"duration":600}]},"engine":"parakeet-v2","words":640,
         "speakers":{"Speaker 1":"You"},"audioDeleted":true}
        """#
        let old = try? JSONDecoder().decode(CapturedConversation.self, from: Data(first.utf8))
        check(old?.state == .sent && old?.words == 640 && old?.steps == nil && old?.outcome == nil && old?.wrappedUp == nil,
              "a record from iPhone 2.0 (9) reads")

        // One this build writes, with its timeline (and a step from a newer build), the Mac's outcome and a wrap-up.
        guard var record = old else { return 1 }
        record.wrappedUp = true
        record.outcome = "Filed in Events: Ignite booth plan · 2 to-dos"
        record.outcomeState = CaptureOutcome.States.filed
        record.note(CaptureStep.heard, at: record.started)
        record.note(CaptureStep.closed, "wrapped up", at: record.ended)
        record.note(CaptureStep.waiting, "the iPhone is warm")
        record.note(CaptureStep.waiting, "the iPhone is warm")
        record.steps?.append(CaptureStep(at: Date(), step: "something-newer", note: nil))
        check(record.steps?.count == 4, "a step that says what the last one did isn't added twice")
        guard let data = try? JSONEncoder().encode(record) else { return 1 }
        let again = try? JSONDecoder().decode(CapturedConversation.self, from: data)
        check(again == record, "and it reads back as it was, a step it doesn't know included")
        check(again?.waitingBecause == nil, "the last step isn't a wait, so the row gives no wait reason")

        // The same record read by iPhone 2.0's own decoder, which knew none of the new fields.
        struct FirstRecord: Decodable {
            enum State: String, Decodable { case recording, recorded, transcribing, labelling, queued, sent, failed }
            let id: UUID
            var started: Date
            var ended: Date
            var speech: TimeInterval
            var state: State
            var spans: CaptureSpans
            var engine: String?
            var words: Int?
            var audioDeleted = false
        }
        let read = try? JSONDecoder().decode(FirstRecord.self, from: data)
        check(read?.id == record.id && read?.state == .sent, "iPhone 2.0 still reads a record this build wrote")

        // Written down to nothing (noise, music, a language Parakeet can't read): not kept, with its row and timeline.
        var empty = CapturedConversation(id: UUID(), started: record.started, ended: record.ended, speech: 40, state: .labelling,
                                         spans: record.spans, engine: "parakeet-v2", words: 0, segments: [])
        empty.note(CaptureStep.transcribed, "0 words · parakeet-v2 · 2 s")
        empty.markNotKept(CapturedConversation.nothingToWriteDown, at: record.ended.addingTimeInterval(60))
        check(empty.state == .failed && empty.notKept == CapturedConversation.nothingToWriteDown
              && empty.failures == CapturedConversation.maxFailures && empty.segments == nil && empty.error == nil,
              "a capture with nothing to write down ends as not kept")
        check(empty.steps?.last?.step == CaptureStep.dropped && empty.steps?.last?.note == CapturedConversation.nothingToWriteDown,
              "and its timeline says why")
        check(!empty.canRetry(at: record.ended.addingTimeInterval(120)), "and it's never tried again")
        check(empty.failedAudioDue(at: record.ended.addingTimeInterval(120)), "and its audio is due to go at once")
        var keptForChecking = empty
        keptForChecking.keepAudioUntil = record.ended.addingTimeInterval(86_400)
        check(!keptForChecking.failedAudioDue(at: record.ended.addingTimeInterval(120)),
              "unless the developer setting keeps it for its day")
        guard let emptyData = try? JSONEncoder().encode(empty) else { return 1 }
        check((try? JSONDecoder().decode(CapturedConversation.self, from: emptyData)) == empty, "a not-kept record reads back as it was")
        let emptyRead = try? JSONDecoder().decode(FirstRecord.self, from: emptyData)
        check(emptyRead?.state == .failed, "iPhone 2.0 reads it as failed, so it never tries it again")
        // iPhone 2.0 (10), the first with tries counted: it reads one too, with no tries left.
        struct TenthRecord: Decodable {
            enum State: String, Decodable { case recording, recorded, transcribing, labelling, queued, sent, failed }
            let id: UUID
            var state: State
            var spans: CaptureSpans
            var audioDeleted = false
            var failures: Int?
        }
        let tenth = try? JSONDecoder().decode(TenthRecord.self, from: emptyData)
        check(tenth?.state == .failed && tenth?.failures == CapturedConversation.maxFailures, "iPhone 2.0 (10) reads it with no tries left")
        check(old?.notKept == nil, "an older record isn't taken for not kept")

        // Too short to keep: a row of its own, Not kept · too short, with its time and nothing else.
        var short = CapturedConversation(id: UUID(), started: record.started, ended: record.started.addingTimeInterval(50), speech: 8,
                                         state: .recording, spans: record.spans)
        short.note(CaptureStep.heard, at: short.started)
        short.markTooShort(at: short.ended)
        check(short.state == .failed && short.notKept == CapturedConversation.tooShort && short.failures == CapturedConversation.maxFailures,
              "a capture too short to keep ends as not kept, too short")
        check(short.audioDeleted && short.spans.spans.isEmpty && short.words == nil && short.engine == nil && short.transcript == nil
              && short.segments == nil && short.keepAudioUntil == nil,
              "and nothing of it is kept but its time: no audio, no spans, no words")
        check(short.started == record.started && short.speech == 8 && short.steps?.last?.step == CaptureStep.dropped
              && short.steps?.last?.note == CapturedConversation.tooShort, "its time stays, and its timeline says why")
        check(!short.canRetry(at: short.ended.addingTimeInterval(60)) && !short.failedAudioDue(at: short.ended.addingTimeInterval(60)),
              "it's never tried again, and there's no audio left to let go")
        let shortEntry = CaptureEntry(short, written: nil)
        // Failed with its audio gone: CaptureStore.tidy lets it go 30 days after it was heard, as the other not-kept rows.
        check(shortEntry.notKept == CapturedConversation.tooShort && shortEntry.state == .failed && shortEntry.audioDeleted,
              "its line in the index says not kept, too short, so its row does, until it expires like the others")
        guard let shortData = try? JSONEncoder().encode(short) else { return 1 }
        check((try? JSONDecoder().decode(CapturedConversation.self, from: shortData)) == short, "a too-short record reads back as it was")
        let shortFirst = try? JSONDecoder().decode(FirstRecord.self, from: shortData)
        let shortTenth = try? JSONDecoder().decode(TenthRecord.self, from: shortData)
        check(shortFirst?.state == .failed && shortFirst?.audioDeleted == true && shortTenth?.failures == CapturedConversation.maxFailures,
              "iPhone 2.0 reads it as failed, its audio gone and no tries left, so it never tries it again")

        // A failed capture's audio: kept while it has tries left, and gone once it has none.
        let heard = record.ended
        let hour = heard.addingTimeInterval(3_600)
        let fourDays = heard.addingTimeInterval(4 * 86_400)
        var failed = CapturedConversation(id: UUID(), started: record.started, ended: heard, speech: 300, state: .failed, spans: record.spans)
        // From iPhone 2.0 (6) or (9), before tries were counted: one try counted, so it's tried again within its three days.
        check(failed.canRetry(at: hour) && !failed.failedAudioDue(at: hour), "an uncounted failure keeps its audio while it can be tried again")
        check(!failed.canRetry(at: fourDays) && failed.failedAudioDue(at: fourDays), "and loses it after three days, like the others")
        failed.failures = 1
        check(failed.canRetry(at: hour) && !failed.failedAudioDue(at: hour), "one failed try keeps the audio for the next")
        failed.failures = CapturedConversation.maxFailures
        check(!failed.canRetry(at: hour) && failed.failedAudioDue(at: hour), "no tries left: the audio goes now, not on day three")
        failed.audioDeleted = true
        check(!failed.failedAudioDue(at: hour), "and only once")
        var queued = failed
        queued.state = .queued
        queued.audioDeleted = false
        check(!queued.failedAudioDue(at: fourDays), "a capture that didn't fail isn't touched by it")

        // Lane Y2's fields: a record with them reads with iPhone 2.0's decoder and back here; a verdict with a reason this
        // build doesn't know still reads (the record isn't lost); and the share sheet's file never carries a vouch.
        var solo = record
        solo.solo = SoloRule.Verdict(solo: false, hold: "a-new-reason", yours: ["A": 0.86], yourSpeech: 60, lowest: 0.86)
        solo.mode = "auto"
        solo.otherAudio = true
        solo.call = nil
        solo.continues = UUID()
        solo.keptForMoment = true
        solo.noticed = Date()
        solo.transcript = [TranscriptSegment(channel: .microphone, start: 0, end: 5, text: "The login times out.", speaker: "Speaker 1")]
        if let soloData = try? JSONEncoder().encode(solo) {
            let back = try? JSONDecoder().decode(CapturedConversation.self, from: soloData)
            check(back == solo && back?.solo?.reason == nil && back?.solo?.isOnlyYou == false,
                  "Solo: a record with Y2's fields, its verdict's hold a word this build doesn't know, reads back whole")
            check((try? JSONDecoder().decode(FirstRecord.self, from: soloData))?.id == solo.id, "Solo: and iPhone 2.0 still reads it")
        } else {
            check(false, "Solo: a record with Y2's fields encodes")
        }
        let shared = solo.payload(device: "iPhone")
        check(shared != nil && shared?.mode == nil && shared?.solo == nil && shared?.soloHold == nil && shared?.agreed == nil && shared?.soloMoments == nil
              && shared?.keptForMoment == nil, "Solo: the share sheet's Binders file holds none of Y2's fields")

        print(failures == 0 ? "CAPTURE_RECORDS_OK" : "CAPTURE_RECORDS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
