import AVFoundation
import BindersKit
import FluidAudio
import Foundation

extension SelfTest {
    /// All-day capture's worker says when loudness stands in for the voice detector: from the first chunk it has to, not
    /// only after forty failed ones, once rather than every chunk, and again whenever listening starts over or a detector
    /// is handed over; nothing while the detector is still loading. With Silero already on this Mac, also that it says so
    /// once the detector reads a chunk again. And that it says when speech was last heard, which the listening glyphs move
    /// with (the iPhone's capture screen, and All-day capture's waveform in the Mac's Settings): just now while someone
    /// speaks, still in the quiet after, nothing once listening stops. Besides a second of a loud tone, which opens a
    /// conversation too short to keep, it hears only silence, so nothing is kept.
    ///
    /// Then the calibration bench's worker, which keeps no conversation: what's said on its own still comes out as a
    /// moment, nothing at all is written to the capture folder, a blip is counted as let go, and capture's own worker
    /// still opens a conversation for the same speech, and lets it go as too short with a record for its row (Not kept · too
    /// short) that keeps only its time, its audio deleted. It hears a tone by loudness, in this throwaway folder.
    ///
    /// Then a moment said on its own, as capture's own worker hands it on: the conversation that opened at its first word
    /// is set aside at once, so two moments a few seconds apart both go, and speech after one can't undo it; speech before
    /// one keeps it in its conversation; and one not kept comes back as the conversation it was, so a moment ten seconds
    /// later isn't on its own, nor one handed on before it was settled, and a second one not kept joins it, its audio in
    /// the order it was said.
    ///
    ///     Binders --selftest-capture-worker
    static func captureWorkerSelfTest() async -> Int32 {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        /// What the worker said about the voice detector, in order: true when it read the chunk, false when loudness did.
        final class Told: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Bool] = []
            func add(_ value: Bool) { lock.withLock { values.append(value) } }
            var all: [Bool] { lock.withLock { values } }
        }
        let told = Told()
        let worker = CaptureWorker { event in
            if case .voiceDetector(let byVoice) = event { told.add(byVoice) }
        }
        let quiet = [Float](repeating: 0, count: CaptureWorker.chunk)
        var heard = Date()
        func hear(_ chunks: Int) async {
            for _ in 0..<chunks {
                await worker.append(quiet, at: heard)
                heard = heard.addingTimeInterval(CaptureWorker.chunkSeconds)
            }
        }

        await hear(4)
        check(told.all.isEmpty, "while the voice detector is still loading, nothing is said: \(told.all)")
        await worker.useDetector(nil)
        await hear(4)
        check(told.all == [false], "without it, the first chunk says loudness stands in, and only once: \(told.all)")
        await worker.finish()
        await hear(2)
        check(told.all == [false, false], "listening again, it's said again: \(told.all)")
        await worker.useDetector(nil)
        await hear(2)
        check(told.all == [false, false, false], "and again when the detector is tried again and still missing: \(told.all)")

        // When speech was last heard, by loudness here: what the iPhone's listening glyph moves with.
        check(await worker.lastSpeech == nil, "before anyone speaks, no speech was heard")
        let tone = (0..<CaptureWorker.chunk).map { Float(sin(Double($0) * 0.2) * 0.1) }
        for _ in 0..<4 {
            await worker.append(tone, at: heard)
            heard = heard.addingTimeInterval(CaptureWorker.chunkSeconds)
        }
        let speaking = await worker.lastSpeech.map { heard.timeIntervalSince($0) }
        check(speaking.map { abs($0) < 0.01 } ?? false, "while someone speaks, speech was heard just now: \(speaking.map { "\($0) s ago" } ?? "never")")
        await hear(12)
        let after = await worker.lastSpeech.map { heard.timeIntervalSince($0) }
        check(after.map { $0 > 2 } ?? false, "in the quiet after, it holds still: \(after.map { "\($0) s ago" } ?? "never")")
        await worker.finish()
        check(await worker.lastSpeech == nil, "once listening stops, no speech is heard")
        check(told.all == [false, false, false], "and the tone was heard by loudness without a word more about it: \(told.all)")
        for result in await allDayWaveformChecks() { check(result.passed, result.label) }

        if let detector = try? await VadManager(config: VadConfig(defaultThreshold: 0.6)) {
            await worker.useDetector(detector)
            await hear(4)
            check(told.all == [false, false, false, true], "once the voice detector reads a chunk, that's said, once: \(told.all)")
            await worker.finish()
            await hear(2)
            check(told.all.last == true && told.all.count == 5, "and said again when listening starts over: \(told.all)")
        } else {
            print("SKIP: Silero couldn't load on this Mac, so the voice detector reading again wasn't checked")
        }

        await benchWorkerChecks(check)
        await setAsideChecks(check)
        await soloChecks(check)
        print(failures == 0 ? "CAPTURE_WORKER_OK" : "CAPTURE_WORKER_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// All-day capture on this Mac, fed the same tone without the microphone: its waveform in Settings moves while someone
    /// speaks, holds still in the quiet of the conversation that's still open, and asks nothing of a capture that isn't
    /// listening. The tone opens a conversation too short to keep, which is let go. The results, to check.
    @MainActor
    private static func allDayWaveformChecks() async -> [(passed: Bool, label: String)] {
        let allDay = AllDayCaptureService(controller: DictationController())
        let quiet = [Float](repeating: 0, count: CaptureWorker.chunk)
        let tone = (0..<CaptureWorker.chunk).map { Float(sin(Double($0) * 0.2) * 0.1) }
        var clock = Date().addingTimeInterval(-30)
        func hear(_ samples: [Float], chunks: Int) async {
            for _ in 0..<chunks {
                await allDay.hear(samples, at: clock)
                clock = clock.addingTimeInterval(CaptureWorker.chunkSeconds)
            }
        }
        await hear(tone, chunks: 4)
        let speaking = await allDay.speechHeard(now: clock)
        let notListening = await allDay.hearsSpeech(now: clock)
        await hear(quiet, chunks: 12)
        // What the worker tells it reaches it on the main actor.
        for _ in 0..<40 where !allDay.inConversation { try? await Task.sleep(for: .milliseconds(25)) }
        let open = allDay.inConversation
        let inTheQuiet = await allDay.speechHeard(now: clock)
        await allDay.finishHearing()
        for _ in 0..<40 where allDay.inConversation { try? await Task.sleep(for: .milliseconds(25)) }
        return [
            (speaking, "on this Mac, All-day capture's waveform in Settings moves while someone speaks"),
            (open && !inTheQuiet, "and holds still in the quiet after, though the conversation is still open (\(open ? "open" : "not open"))"),
            (!notListening, "and asks nothing of a capture that isn't listening"),
            (!allDay.inConversation, "the tone, too short to keep, is let go"),
        ]
    }

    /// The calibration bench's worker (CaptureWorker with keepsConversations off), by loudness on a tone.
    private static func benchWorkerChecks(_ check: (Bool, String) -> Void) async {
        final class Heard: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [CaptureWorker.Event] = []
            func add(_ event: CaptureWorker.Event) { lock.withLock { events.append(event) } }
            var all: [CaptureWorker.Event] { lock.withLock { events } }
            var moments: [CaptureWorker.MomentClip] { all.compactMap { if case .moment(let clip) = $0 { clip } else { nil } } }
            var conversations: Int { all.filter { if case .opened = $0 { true } else { false } }.count }
        }
        let chunk = CaptureWorker.chunk
        let quiet = [Float](repeating: 0, count: chunk)
        let tone = (0..<chunk).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000)) * 0.1 }
        func feed(_ worker: CaptureWorker, _ plan: [(speech: Bool, seconds: Double)], from start: Date) async -> Date {
            var heard = start
            for stretch in plan {
                for _ in 0..<Int((stretch.seconds / CaptureWorker.chunkSeconds).rounded()) {
                    await worker.append(stretch.speech ? tone : quiet, at: heard)
                    heard = heard.addingTimeInterval(CaptureWorker.chunkSeconds)
                }
            }
            return heard
        }
        let folder = CaptureFiles.folder
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])

        let heard = Heard()
        let bench = CaptureWorker(keepsConversations: false) { heard.add($0) }
        await bench.useMoments(MomentDetector.Settings())
        await bench.useDetector(nil)
        var clock = await feed(bench, [(false, 4), (true, 2.5)], from: Date().addingTimeInterval(-60))
        check(await bench.hearingMoment, "the bench's worker hears something being said")
        clock = await feed(bench, [(false, 5)], from: clock)
        let moments = heard.moments
        check(moments.count == 1 && moments.first?.checkFirst == nil, "said on its own, it comes out as a moment, as in capture: \(moments.count)")
        if let clip = moments.first {
            check(clip.speech > 2.5 && clip.speech < 3.5, "with the speech the detector heard: \(clip.speech)")
            check(clip.samples.count > Int(2.5 * 16_000), "and its audio, to score: \(clip.samples.count) samples")
        }
        check(heard.conversations == 0, "it opens no conversation")
        check(await !bench.hearingMoment, "and has nothing in hand after it")
        clock = await feed(bench, [(true, 0.5), (false, 5)], from: clock)
        let letGo = await bench.momentsLetGo
        check(letGo == 1, "a blip is let go, and counted: \(letGo)")
        check(heard.moments.count == 1, "and isn't a moment")
        await bench.finish()
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        check(after == before, "nothing at all is written to the capture folder: \(after.subtracting(before).sorted())")

        // Capture's own worker, as before: the same speech opens a conversation.
        let captured = Heard()
        let capture = CaptureWorker { captured.add($0) }
        await capture.useDetector(nil)
        _ = await feed(capture, [(false, 4), (true, 2.5), (false, 5)], from: Date().addingTimeInterval(-30))
        check(captured.conversations == 1, "capture's worker still opens a conversation for it: \(captured.conversations)")
        await capture.finish()
        let left = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).subtracting(before)
        check(left.isEmpty, "and lets it go as too short, its files with it: \(left.sorted())")
        let dropped = captured.all.compactMap { if case .dropped(let record) = $0 { record } else { nil } }
        check(dropped.count == 1, "it says the conversation was too short to keep: \(dropped.count)")
        if let record = dropped.first {
            check(record.notKept == CapturedConversation.tooShort && record.state == .failed && record.audioDeleted,
                  "with a record for its row: Not kept · too short, its audio gone")
            check(record.spans.spans.isEmpty && record.words == nil && record.transcript == nil && record.speech > 2 && record.speech < 3.5
                  && record.ended > record.started,
                  "keeping only its time and the speech heard, nothing of what was said: \(record.speech) s")
            check(!FileManager.default.fileExists(atPath: CaptureFiles.audioURL(record.id).path)
                  && !FileManager.default.fileExists(atPath: CaptureFiles.recordURL(record.id).path),
                  "and its audio is deleted at once; the iPhone keeps the row, a Mac nothing")
        }
    }

    /// Lane Y2, by capture's own worker, by loudness on a tone: other audio or a call marks the open conversation only while
    /// it writes speech; one opened just after a cut carries it on, after quiet or a Wrap Up it doesn't; the mode is stamped
    /// at open and only lowered; a short conversation that holds a moment kept in Auto is kept, for its vouch.
    private static func soloChecks(_ check: (Bool, String) -> Void) async {
        final class Heard: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [CaptureWorker.Event] = []
            func add(_ event: CaptureWorker.Event) { lock.withLock { events.append(event) } }
            var all: [CaptureWorker.Event] { lock.withLock { events } }
            var opened: [CapturedConversation] { all.compactMap { if case .opened(let record) = $0 { record } else { nil } } }
            var closed: [CapturedConversation] { all.compactMap { if case .closed(let record) = $0 { record } else { nil } } }
            var dropped: [CapturedConversation] { all.compactMap { if case .dropped(let record) = $0 { record } else { nil } } }
            var moments: [CaptureWorker.MomentClip] { all.compactMap { if case .moment(let clip) = $0 { clip } else { nil } } }
        }
        let chunk = CaptureWorker.chunk
        let quiet = [Float](repeating: 0, count: chunk)
        let tone = (0..<chunk).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000)) * 0.1 }
        var clock = Date().addingTimeInterval(-3_600)
        func listening(moments: Bool = false) async -> (worker: CaptureWorker, heard: Heard) {
            let heard = Heard()
            let worker = CaptureWorker { heard.add($0) }
            if moments { await worker.useMoments(MomentDetector.Settings()) }
            await worker.useDetector(nil)
            return (worker, heard)
        }
        func feed(_ worker: CaptureWorker, _ plan: [(speech: Bool, seconds: Double)]) async {
            for stretch in plan {
                for _ in 0..<Int((stretch.seconds / CaptureWorker.chunkSeconds).rounded()) {
                    await worker.append(stretch.speech ? tone : quiet, at: clock)
                    clock = clock.addingTimeInterval(CaptureWorker.chunkSeconds)
                }
            }
        }
        let folder = CaptureFiles.folder
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])

        // Other audio, and a call, while it writes speech; and a tick 20 s after the last tone, which doesn't count.
        let audio = await listening()
        await audio.worker.useMode("auto")
        await feed(audio.worker, [(true, 3)])
        await audio.worker.heard(otherAudio: true, call: false, previousTick: clock.addingTimeInterval(-5))
        await audio.worker.useMode("add")
        await audio.worker.useMode("auto")
        await audio.worker.finish()
        let marked = audio.heard.dropped.last
        check(marked?.otherAudio == true && marked?.call == nil, "Solo: other audio told at a tick while it writes speech marks the open conversation")
        check(audio.heard.opened.first?.mode == "auto" && marked?.mode == "add",
              "Solo: the mode is on the record as it opens, lowered while open, never raised again: \(marked?.mode ?? "none")")
        clock = clock.addingTimeInterval(60)
        let late = await listening()
        await feed(late.worker, [(true, 3), (false, 20)])
        await late.worker.heard(otherAudio: true, call: true, previousTick: clock.addingTimeInterval(-5))
        await late.worker.finish()
        check(late.heard.dropped.last?.otherAudio == nil && late.heard.dropped.last?.call == nil,
              "Solo: told 20 s after the last tone, with nothing written since the tick before: not marked")
        clock = clock.addingTimeInterval(60)
        let call = await listening()
        await feed(call.worker, [(true, 3)])
        await call.worker.heard(otherAudio: false, call: true, previousTick: clock.addingTimeInterval(-5))
        await call.worker.finish()
        check(call.heard.dropped.last?.call == true && call.heard.dropped.last?.otherAudio == nil, "Solo: a call the same")

        // Continuing: closed by listening stopping, another opened 30 s later carries it on; after quiet, or a Wrap Up, not.
        clock = clock.addingTimeInterval(60)
        let cut = await listening()
        await feed(cut.worker, [(true, 21)])
        await cut.worker.finish()
        clock = clock.addingTimeInterval(30)
        await feed(cut.worker, [(true, 2)])
        let firstCut = cut.heard.closed.first
        check(firstCut != nil && cut.heard.opened.last?.continues == firstCut?.id,
              "Solo: a conversation opened 30 s after listening stopped carries on the one cut")
        await cut.worker.finish()
        clock = clock.addingTimeInterval(60)
        let quietly = await listening()
        await feed(quietly.worker, [(true, 21), (false, 185), (true, 2)])
        check(quietly.heard.closed.count == 1 && quietly.heard.opened.last?.continues == nil, "Solo: after 3 minutes of quiet, it doesn't")
        await quietly.worker.finish()
        clock = clock.addingTimeInterval(60)
        let wrapped = await listening()
        await feed(wrapped.worker, [(true, 21)])
        await wrapped.worker.wrapUp()
        clock = clock.addingTimeInterval(20)
        await feed(wrapped.worker, [(true, 2)])
        check(wrapped.heard.closed.first?.wrappedUp == true && wrapped.heard.opened.last?.continues == nil, "Solo: after a Wrap Up, it doesn't")
        await wrapped.worker.finish()

        // A short conversation that holds a moment kept in Auto: kept, for its vouch; without it, dropped as today.
        for joins in [true, false] {
            clock = clock.addingTimeInterval(240)
            let short = await listening(moments: true)
            await short.worker.useMode("auto")
            await feed(short.worker, [(false, 4), (true, 1), (false, 5), (true, 2.5), (false, 5)])
            let clip = short.heard.moments.last
            if let clip { await short.worker.settleMoment(clip.id, kept: true, in: nil, joins: joins ? clip.conversation : nil) }
            await feed(short.worker, [(false, 185)])
            await short.worker.finish()
            if joins {
                let kept = short.heard.closed.last
                check(clip?.conversation != nil && kept?.id == clip?.conversation && kept?.keptForMoment == true
                      && kept?.steps?.contains { $0.step == CaptureStep.closed && $0.note == CaptureWorker.keptForMomentNote } == true,
                      "Solo: a moment kept in a short conversation in Auto keeps it, with its timeline line: \(short.heard.moments.count) moment")
            } else {
                check(short.heard.closed.isEmpty && short.heard.dropped.contains { $0.id == clip?.conversation },
                      "Solo: without joining, the same conversation is dropped as today")
            }
        }
        // The files this section left.
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        for name in after.subtracting(before) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    /// Moments said on their own, by capture's own worker, by loudness on a tone: the conversation that opened at a
    /// moment's first word is set aside when the moment is handed on, not once it's written down, so what's said next
    /// can't spoil it.
    private static func setAsideChecks(_ check: (Bool, String) -> Void) async {
        final class Heard: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [CaptureWorker.Event] = []
            func add(_ event: CaptureWorker.Event) { lock.withLock { events.append(event) } }
            var all: [CaptureWorker.Event] { lock.withLock { events } }
            var moments: [CaptureWorker.MomentClip] { all.compactMap { if case .moment(let clip) = $0 { clip } else { nil } } }
            var opened: [UUID] { all.compactMap { if case .opened(let record) = $0 { record.id } else { nil } } }
            var absorbed: [UUID] { all.compactMap { if case .absorbed(let id) = $0 { id } else { nil } } }
            var dropped: [CapturedConversation] { all.compactMap { if case .dropped(let record) = $0 { record } else { nil } } }
            var closed: Int { all.filter { if case .closed = $0 { true } else { false } }.count }
        }
        let chunk = CaptureWorker.chunk
        let quiet = [Float](repeating: 0, count: chunk)
        let tone = (0..<chunk).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000)) * 0.1 }
        func listening(_ settings: ConversationSplitter.Settings = .init()) async -> (worker: CaptureWorker, heard: Heard) {
            let heard = Heard()
            let worker = CaptureWorker(settings: settings) { heard.add($0) }
            await worker.useMoments(MomentDetector.Settings())
            await worker.useDetector(nil)
            return (worker, heard)
        }
        var clock = Date().addingTimeInterval(-600)
        func feed(_ worker: CaptureWorker, _ plan: [(speech: Bool, seconds: Double)], gap: TimeInterval = 60) async {
            for stretch in plan {
                for _ in 0..<Int((stretch.seconds / CaptureWorker.chunkSeconds).rounded()) {
                    await worker.append(stretch.speech ? tone : quiet, at: clock)
                    clock = clock.addingTimeInterval(CaptureWorker.chunkSeconds)
                }
            }
            // A gap before the next run, so no run reads another's audio as its own (none: the same run goes on).
            clock = clock.addingTimeInterval(gap)
        }
        /// Settles `clip` (nil when it wasn't handed on): kept or not, with `why` on its conversation's timeline when not.
        func settle(_ worker: CaptureWorker, _ clip: CaptureWorker.MomentClip?, kept: Bool, why: String? = nil, conversationToo: Bool = false) async -> Bool? {
            guard let clip else { return nil }
            return await worker.settleMoment(clip.id, kept: kept, why: why, in: conversationToo ? clip.conversation : nil)
        }
        func filesGone(_ id: UUID) -> Bool {
            !FileManager.default.fileExists(atPath: CaptureFiles.audioURL(id).path) && !FileManager.default.fileExists(atPath: CaptureFiles.recordURL(id).path)
        }
        let folder = CaptureFiles.folder
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])

        // One moment on its own: its conversation is set aside as it's handed on, files and all, and absorbed once kept.
        let one = await listening()
        await feed(one.worker, [(false, 4), (true, 2.5), (false, 5)])
        let first = one.heard.moments.first
        check(one.heard.moments.count == 1 && first?.alone == true && first?.checkFirst == nil && first?.conversation != nil
              && first?.conversation == one.heard.opened.first,
              "a moment said on its own is handed on alone, with the id of the conversation that opened at its first word: \(one.heard.moments.count) moment")
        let openAfterOne = await one.worker.lastSpeech != nil
        check(first?.conversation.map(filesGone) == true && one.heard.absorbed.isEmpty && !openAfterOne,
              "that conversation is set aside as the moment is handed on, before it's written down: its files are gone, and nothing is open")
        let oneAlone = await settle(one.worker, first, kept: true) ?? false
        check(one.heard.absorbed == [first?.conversation].compactMap { $0 } && one.heard.dropped.isEmpty && one.heard.closed == 0 && oneAlone,
              "kept, it's absorbed, and it's still said on its own: \(one.heard.absorbed.count) absorbed")
        await one.worker.finish()

        // Two moments five seconds apart, the first settled only once the second is handed on: both go.
        let two = await listening()
        await feed(two.worker, [(false, 4), (true, 2.5), (false, 5), (true, 2.5), (false, 5)])
        let pair = two.heard.moments
        check(pair.count == 2 && pair.allSatisfy { $0.alone && $0.conversation != nil } && Set(pair.compactMap(\.conversation)).count == 2
              && Set(pair.compactMap(\.conversation)) == Set(two.heard.opened),
              "two moments said five seconds apart are both alone, each with a conversation of its own: \(pair.map(\.alone))")
        var pairAlone: [Bool] = []
        for clip in pair { pairAlone.append(await two.worker.settleMoment(clip.id, kept: true)) }
        let openAfterTwo = await two.worker.lastSpeech != nil
        check(Set(two.heard.absorbed) == Set(pair.compactMap(\.conversation)) && two.heard.absorbed.count == 2 && !openAfterTwo
              && two.heard.dropped.isEmpty && two.heard.closed == 0 && pairAlone == [true, true],
              "settled after the second was handed on, both are absorbed, both still on their own, and no conversation is left open: \(pairAlone)")
        await two.worker.finish()

        // Speech after the moment, before it's settled: the moment stays alone, and the speech opens a conversation of its own.
        let after = await listening()
        await feed(after.worker, [(false, 4), (true, 2.5), (false, 4), (true, 1), (false, 1)])
        let spoken = after.heard.moments.first
        let later = after.heard.opened.dropFirst().first
        let spokenAlone = await settle(after.worker, spoken, kept: true) ?? false
        check(after.heard.moments.count == 1 && spoken?.alone == true && spokenAlone && after.heard.absorbed == [spoken?.conversation].compactMap { $0 },
              "a moment with speech four seconds after it, before it's settled, stays alone and is absorbed")
        let openAfterSpeech = await after.worker.lastSpeech != nil
        check(later != nil && later != spoken?.conversation && openAfterSpeech && later.map(filesGone) == false,
              "and that speech opened a conversation of its own, still open")
        await after.worker.finish()

        // Speech before it: the conversation it opened holds the moment's words too, so the moment isn't alone.
        let blip = await listening()
        await feed(blip.worker, [(false, 4), (true, 0.5), (false, 6), (true, 2.5), (false, 5)])
        let held = blip.heard.moments.first
        if let held { await blip.worker.settleMoment(held.id, kept: true) }
        check(blip.heard.moments.count == 1 && held?.alone == false && held?.conversation != nil && held?.conversation == blip.heard.opened.first
              && blip.heard.opened.count == 1,
              "after a half-second blip and six seconds of quiet, the moment isn't alone: it keeps the id of the conversation the blip opened")
        let openAfterBlip = await blip.worker.lastSpeech != nil
        check(blip.heard.absorbed.isEmpty && openAfterBlip && held?.conversation.map(filesGone) == false,
              "nothing is absorbed, and that conversation is still open, its files kept")
        await blip.worker.finish()

        // Not kept, a set-aside one comes back as the conversation it was, open, with why on its timeline: so someone's
        // remark the gate turns down keeps what's said ten seconds later in a conversation, as before the set-aside.
        let letGo = await listening()
        await feed(letGo.worker, [(false, 4), (true, 2.5), (false, 5)], gap: 0)
        let notKept = letGo.heard.moments.first
        let notKeptAlone = await settle(letGo.worker, notKept, kept: false, why: "Apple's model read it as small talk", conversationToo: true)
        let cameBack = notKept?.conversation.flatMap { CaptureFiles.read($0) }
        let openAfterLetGo = await letGo.worker.lastSpeech != nil
        check(notKept?.alone == true && notKeptAlone == false && letGo.heard.absorbed.isEmpty && letGo.heard.dropped.isEmpty && openAfterLetGo
              && letGo.heard.opened.count == 2 && Set(letGo.heard.opened) == Set([notKept?.conversation].compactMap { $0 })
              && notKept?.conversation.map(filesGone) == false && cameBack?.steps?.contains { $0.step == CaptureStep.notAMoment } == true
              && cameBack?.spans.spans.count == 1,
              "not kept, a set-aside one comes back open, under its own id, its files written again, with why on its timeline")
        await feed(letGo.worker, [(false, 5), (true, 2.5), (false, 5)], gap: 0)
        let next = letGo.heard.moments.dropFirst().first
        let nextAlone = await settle(letGo.worker, next, kept: true)
        check(letGo.heard.moments.count == 2 && next?.checkFirst == nil && next?.alone == false && nextAlone == false
              && next?.conversation == notKept?.conversation && letGo.heard.absorbed.isEmpty,
              "a moment ten seconds after one not kept isn't on its own: it's in that conversation, which keeps its words")
        await letGo.worker.finish()
        let letGoDropped = letGo.heard.dropped
        check(letGoDropped.count == 1 && letGoDropped.first?.id == notKept?.conversation && letGoDropped.first?.speech ?? 0 > 4.5
              && notKept?.conversation.map(filesGone) == true,
              "and that conversation, with both, closes as any does: too short, here, its files gone (\(letGoDropped.first?.speech ?? 0) s)")

        // Two handed on before either is settled: the first not kept comes back, so the second, kept, isn't on its own.
        let early = await listening()
        await feed(early.worker, [(false, 4), (true, 2.5), (false, 5), (true, 2.5), (false, 5)], gap: 0)
        let firstOfTwo = early.heard.moments.first, secondOfTwo = early.heard.moments.dropFirst().first
        _ = await settle(early.worker, firstOfTwo, kept: false)
        let secondAlone = await settle(early.worker, secondOfTwo, kept: true)
        let openAfterEarly = await early.worker.lastSpeech != nil
        check(firstOfTwo?.alone == true && secondOfTwo?.alone == true && secondAlone == false && openAfterEarly
              && early.heard.absorbed == [secondOfTwo?.conversation].compactMap { $0 } && early.heard.opened.last == firstOfTwo?.conversation,
              "the first not kept comes back open; the second, kept, is absorbed but isn't on its own")
        await early.worker.finish()
        // The other way round: the second settled first, kept, while the first is still being written down: not on its own.
        let wait = await listening()
        await feed(wait.worker, [(false, 4), (true, 2.5), (false, 5), (true, 2.5), (false, 5)], gap: 0)
        let laterFirst = await settle(wait.worker, wait.heard.moments.dropFirst().first, kept: true)
        _ = await settle(wait.worker, wait.heard.moments.first, kept: true)
        check(wait.heard.moments.count == 2 && laterFirst == false && wait.heard.absorbed.count == 2,
              "kept while the one before it is still being written down, a moment isn't counted on its own")
        await wait.worker.finish()

        // Both not kept: the second joins the first, which keeps its id, the audio of both in the order it was said.
        let both = await listening(.init(minSpeech: 3))
        await feed(both.worker, [(false, 4), (true, 2.5), (false, 5), (true, 2.5), (false, 5)], gap: 0)
        let bothClips = both.heard.moments
        for clip in bothClips { _ = await both.worker.settleMoment(clip.id, kept: false) }
        let joined = bothClips.first?.conversation.flatMap { CaptureFiles.read($0) }
        let joinedSpans = joined?.spans.spans ?? []
        check(bothClips.count == 2 && both.heard.absorbed == [bothClips.last?.conversation].compactMap { $0 } && both.heard.dropped.isEmpty
              && joinedSpans.count == 2 && joinedSpans.first.map { $0.wallStart < joinedSpans[1].wallStart } == true
              && bothClips.last?.conversation.map(filesGone) == true,
              "two not kept are one conversation under the first's id, its two stretches in order: \(joinedSpans.map(\.duration))")
        await both.worker.finish()
        var closedRecord: CapturedConversation?
        for case .closed(let record) in both.heard.all { closedRecord = record }
        let frames = closedRecord.flatMap { try? AVAudioFile(forReading: CaptureFiles.audioURL($0.id)) }.map { Double($0.length) / 16_000 } ?? 0
        check(closedRecord?.id == bothClips.first?.conversation && closedRecord.map { abs($0.spans.fileDuration - frames) < 0.05 && $0.speech > 4.5 } == true,
              "closed, with both in it, its file as long as its stretches: \(frames) s")
        if let closedRecord {
            try? FileManager.default.removeItem(at: CaptureFiles.audioURL(closedRecord.id))
            try? FileManager.default.removeItem(at: CaptureFiles.recordURL(closedRecord.id))
        }

        let left = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).subtracting(before)
        check(left.isEmpty, "and nothing of these is left in the capture folder: \(left.sorted())")
    }
}
