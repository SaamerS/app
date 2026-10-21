import XCTest
@testable import BindersKit

/// The calibration bench for things said to yourself: its phrases and 40 lines agree with the rules, and its scoring (the
/// voice threshold for 1% of other voices, the per-group counts, the line verdicts, the CSV) is what the iPhone shows.
final class MomentBenchTests: XCTestCase {
    private let heard = Date(timeIntervalSince1970: 1_790_000_000)

    private func read(_ said: String) -> MomentReading {
        MomentRules.read(said, binders: [], agents: [], heard: heard)
    }

    // MARK: Phrases and lines

    func testAboutAHundredAndFiftyPhrasesInSevenGroups() {
        // Outside Auto, as before; lane Y2's group without a cue and its 15 chatter phrases are said only in Auto.
        XCTAssertTrue((140...160).contains(MomentBench.phrases(inAuto: false).count), "\(MomentBench.phrases(inAuto: false).count)")
        let phrases = MomentBench.phrases
        XCTAssertEqual(phrases.count, MomentBench.phrases(inAuto: false).count + 45)
        XCTAssertEqual(Set(phrases.map(\.id)).count, phrases.count, "ids are unique")
        for group in MomentBench.Group.allCases {
            let inGroup = phrases.filter { $0.group == group }
            XCTAssertGreaterThanOrEqual(inGroup.count, 10, "\(group)")
            for (index, phrase) in inGroup.enumerated() {
                XCTAssertEqual(phrase.id, "\(group.rawValue)-\(String(format: "%02d", index + 1))", "ids go by place in the group")
            }
        }
        XCTAssertEqual(MomentBench.phrase("todo-01")?.text, "I need to book a doctor's appointment.")
        XCTAssertNil(MomentBench.phrase("todo-99"))
        XCTAssertNil(MomentBench.phrase(nil))
    }

    func testWhatShouldBeTakenHasACueAndReadsAsItsKind() {
        for phrase in MomentBench.phrases where phrase.group.shouldBeTaken {
            XCTAssertNotNil(MomentRules.cue(in: phrase.text), "\(phrase.id): \(phrase.text)")
            let kind = read(phrase.text).kind
            if phrase.group == .note {
                // Without the wake word the rules can't call anything a note: they read a to-do or can't tell, and Apple's
                // model decides.
                XCTAssertTrue(kind == .todo || kind == nil, "\(phrase.id): \(String(describing: kind))")
            } else {
                XCTAssertEqual(kind, phrase.group.kind, "\(phrase.id): \(phrase.text)")
            }
        }
    }

    func testChatterHasNoCueAndWhatIsntMeantMostlySoundsLikeOne() {
        for phrase in MomentBench.phrases where phrase.group == .chatter {
            XCTAssertNil(MomentRules.cue(in: phrase.text), "\(phrase.id): \(phrase.text)")
        }
        let notMeant = MomentBench.phrases.filter { $0.group == .notMeant }
        let cued = notMeant.filter { MomentRules.cue(in: $0.text) != nil }
        XCTAssertGreaterThanOrEqual(Double(cued.count) / Double(notMeant.count), 0.8, "hard negatives: they sound like cues")
        XCTAssertTrue(notMeant.allSatisfy { $0.hint != nil }, "each says how to say it")
    }

    func testTheFortyLinesAgreeWithTheRules() {
        let script = MomentBench.script
        XCTAssertEqual(script.count, 40)
        XCTAssertEqual(Set(script.map(\.id)).count, 40)
        XCTAssertEqual(script.first?.id, "line-01")
        XCTAssertEqual(script.last?.id, "line-40")
        for line in script {
            let wake = MomentRules.afterWakeWord(line.text)
            switch line.expected {
            case .taken(let kind):
                XCTAssertTrue(wake != nil || MomentRules.cue(in: line.text) != nil, "\(line.id) needs a cue: \(line.text)")
                if let kind {
                    let reading = MomentRules.read(wake ?? line.text, binders: [], agents: [], heard: heard, wake: wake != nil)
                    XCTAssertEqual(reading.kind, kind, "\(line.id): \(line.text)")
                }
            case .letGo(.noCue):
                XCTAssertNil(wake, line.id)
                XCTAssertNil(MomentRules.cue(in: line.text), "\(line.id): \(line.text)")
            case .letGo(.notMeant):
                // Only Apple's model can let these go: the rules find a cue.
                XCTAssertNotNil(MomentRules.cue(in: line.text), "\(line.id): \(line.text)")
                XCTAssertNotNil(line.hint, line.id)
            case .letGo(.detector):
                XCTAssertNotNil(line.hint, "\(line.id) says how to say it")
            }
        }
        let taken = script.filter { if case .taken = $0.expected { true } else { false } }
        XCTAssertTrue((20...26).contains(taken.count), "about half are taken: \(taken.count)")
        XCTAssertEqual(MomentBench.line("line-03")?.expected, .taken(.question))
        XCTAssertEqual(MomentBench.Expected.taken(.status).summary, "Taken, as a status request")
        XCTAssertEqual(MomentBench.Expected.letGo(.noCue).summary, "Let go: no cue")
    }

    // MARK: The binder named and the due date

    func testWhatPhrasesNameAndSayIsWhatTheRulesRead() throws {
        // A Monday morning and a Wednesday afternoon, so a day counts from when it was said.
        let calendar = Calendar(identifier: .gregorian)
        for heard in [heard, heard.addingTimeInterval(2 * 86_400 + 5 * 3_600)] {
            for (id, expects) in MomentBench.expectations {
                let text = try XCTUnwrap(MomentBench.phrase(id)?.text ?? MomentBench.line(id)?.text, id)
                let read = MomentBench.readBinderAndDue(text, heard: heard, calendar: calendar)
                XCTAssertEqual(read.binder, expects.binder ?? "", "\(id): \(text)")
                if let due = expects.due {
                    let day = try XCTUnwrap(MomentBench.date(read.due, calendar: calendar), "\(id) reads a day: \(text)")
                    XCTAssertTrue(due.matches(day, heard: heard, calendar: calendar), "\(id): \(read.due) for \(due.summary)")
                } else {
                    XCTAssertEqual(read.due, "", "\(id): \(text)")
                }
            }
            // The rest of what should be taken names no binder and says no day the rules read.
            for phrase in MomentBench.phrases where phrase.group.shouldBeTaken && MomentBench.expectations[phrase.id] == nil {
                let read = MomentBench.readBinderAndDue(phrase.text, heard: heard, calendar: calendar)
                XCTAssertEqual(read.binder, "", "\(phrase.id): \(phrase.text)")
                XCTAssertEqual(read.due, "", "\(phrase.id): \(phrase.text)")
            }
        }
        XCTAssertGreaterThanOrEqual(MomentBench.expectations.values.filter { $0.binder != nil }.count, 8)
        XCTAssertGreaterThanOrEqual(MomentBench.expectations.values.filter { $0.due != nil }.count, 12)
        XCTAssertEqual(MomentBench.phrase("todo-32")?.text, "I need to book the venue for Events by Friday.")
    }

    func testADueDayCountsFromWhenItWasSaid() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        func day(_ text: String) throws -> Date { try XCTUnwrap(MomentBench.date(text, calendar: calendar)) }
        // Monday 21 September 2026.
        let monday = try day("2026-09-21").addingTimeInterval(10 * 3_600)
        XCTAssertTrue(MomentBench.Due.days(0).matches(try day("2026-09-21"), heard: monday, calendar: calendar))
        XCTAssertFalse(MomentBench.Due.days(0).matches(try day("2026-09-22"), heard: monday, calendar: calendar))
        XCTAssertTrue(MomentBench.Due.days(1).matches(try day("2026-09-22"), heard: monday, calendar: calendar))
        XCTAssertTrue(MomentBench.Due.weekday(6).matches(try day("2026-09-25"), heard: monday, calendar: calendar))
        XCTAssertFalse(MomentBench.Due.weekday(6).matches(try day("2026-10-02"), heard: monday, calendar: calendar), "the next Friday, not the one after")
        XCTAssertFalse(MomentBench.Due.weekday(6).matches(try day("2026-09-18"), heard: monday, calendar: calendar), "never before it was said")
        let friday = try day("2026-09-25").addingTimeInterval(9 * 3_600)
        XCTAssertTrue(MomentBench.Due.weekday(6).matches(try day("2026-09-25"), heard: friday, calendar: calendar), "said on a Friday: that day")
        XCTAssertTrue(MomentBench.Due.weekday(6).matches(try day("2026-10-02"), heard: friday, calendar: calendar), "or the next")
        XCTAssertTrue(MomentBench.Due.thisWeek.matches(try day("2026-09-25"), heard: monday, calendar: calendar))
        XCTAssertFalse(MomentBench.Due.thisWeek.matches(try day("2026-10-02"), heard: monday, calendar: calendar))
        XCTAssertTrue(MomentBench.Due.beforeMonth(3).matches(try day("2027-02-28"), heard: monday, calendar: calendar))
        XCTAssertFalse(MomentBench.Due.beforeMonth(3).matches(try day("2027-03-01"), heard: monday, calendar: calendar))
        XCTAssertEqual(MomentBench.day(try day("2026-09-25"), calendar: calendar), "2026-09-25")
        XCTAssertNil(MomentBench.date("Friday", calendar: calendar))
        XCTAssertEqual(MomentBench.Due.weekday(6).summary, "by Friday")
        XCTAssertEqual(MomentBench.Due.days(1).summary, "tomorrow")
        XCTAssertEqual(MomentBench.Due.beforeMonth(3).summary, "before March")
    }

    func testTheBinderAndTheDayAreScoredBesideTheKind() throws {
        let calendar = Calendar(identifier: .gregorian)
        let read = MomentBench.readBinderAndDue("I need to book the venue for Events by Friday.", heard: heard, calendar: calendar)
        XCTAssertEqual(read.binder, "Events")
        func scored(_ run: MomentBench.Run, _ phrase: String, rules: String? = "todo", binder: String?, due: String?) -> MomentBench.Result {
            var made = result(run, phrase, rules: rules)
            made.binder = binder
            made.due = due
            return made
        }
        let right = scored(.phrases, "todo-32", binder: "events", due: read.due)
        XCTAssertEqual(MomentBench.binderRead(right), .right, "the name, whatever its case")
        XCTAssertEqual(MomentBench.dueRead(right, calendar: calendar), .right)
        let wrong = scored(.phrases, "todo-32", binder: "", due: "")
        XCTAssertEqual(MomentBench.binderRead(wrong), .wrong, "nothing read where one was named")
        XCTAssertEqual(MomentBench.dueRead(wrong, calendar: calendar), .wrong)
        let unasked = scored(.phrases, "todo-01", binder: "Home", due: "")
        XCTAssertEqual(MomentBench.binderRead(unasked), .unasked, "a binder read where none was named")
        XCTAssertNil(MomentBench.dueRead(unasked, calendar: calendar), "none asked and none read: nothing to score")
        let older = result(.phrases, "todo-32", rules: "todo")
        XCTAssertNil(MomentBench.binderRead(older), "a result from before the bench read binders isn't scored")
        XCTAssertNil(MomentBench.dueRead(older, calendar: calendar))
        XCTAssertEqual(MomentBench.kindRead(right), .right)
        XCTAssertEqual(MomentBench.kindRead(scored(.phrases, "question-01", binder: "", due: "")), .wrong, "read as a to-do")
        XCTAssertNil(MomentBench.kindRead(scored(.phrases, "note-01", binder: "", due: "")), "notes are Apple's model's to tell")
        XCTAssertNil(MomentBench.kindRead(scored(.phrases, "chatter-01", binder: "", due: "")))

        var store = MomentBench.Store()
        store.record(right)
        store.record(scored(.script, "line-13", binder: "", due: "2026-10-30"))
        store.record(scored(.phrases, "todo-01", binder: "Home", due: ""))
        // Someone else's, and things not meant for Binders, don't count for what was read.
        store.record(scored(.otherVoices, "todo-32", binder: "", due: ""))
        store.record(scored(.phrases, "notMeant-04", binder: "", due: "2026-09-21"))
        let report = MomentBench.report(store, threshold: 0.65, voicePrint: "abcd", calendar: calendar)
        XCTAssertEqual(report.binders, MomentBench.Score(right: 1, total: 1, unasked: 1))
        XCTAssertEqual(report.dues, MomentBench.Score(right: 1, total: 2, unasked: 0))
        XCTAssertEqual(report.kinds, MomentBench.Score(right: 3, total: 3, unasked: 0))

        let csv = MomentBench.csv(store, threshold: 0.65, calendar: calendar)
        let row = try XCTUnwrap(csv.split(separator: "\n").map(String.init).first { $0.contains(",todo-32,") && $0.hasPrefix("phrases,") })
        XCTAssertTrue(row.hasSuffix(",right,Events,events,right,by Friday,\(read.due),right,,"), row)
    }

    func testAResultFromBeforeTheBinderWasReadStillReads() throws {
        let json = #"{"id":"7C1A3F0E-2B5D-4C55-9E2A-1F6B7A0C9D11","run":"phrases","session":"0B0E9F55-8C66-4E9B-9C3E-5B3A2D1E4F70","heard":0,"rules":"todo","phrase":"todo-32"}"#
        let old = try JSONDecoder().decode(MomentBench.Result.self, from: Data(json.utf8))
        XCTAssertNil(old.binder)
        XCTAssertNil(old.due)
        var now = old
        now.binder = "Events"
        now.due = "2026-09-25"
        XCTAssertEqual(try JSONDecoder().decode(MomentBench.Result.self, from: JSONEncoder().encode(now)), now)
    }

    func testTheChecksAreInTheGatesOrder() {
        XCTAssertEqual(MomentGate.Check.allCases, [.inConversation, .resting, .notWrittenDown, .tooFewWords, .noVoicePrint, .noCue,
                                                   .voiceUnclear, .notYourVoice, .modelDisagreed])
        XCTAssertEqual(MomentGate.Check.noCue.reason, "No cue in the words")
    }

    // MARK: Words

    func testHowManyOfThePhrasesWordsWereHeard() {
        XCTAssertEqual(MomentBench.accuracy(heard: "i need to book a doctors appointment", said: "I need to book a doctor's appointment."), 1)
        XCTAssertEqual(MomentBench.accuracy(heard: "I need to cook a doctor's appointment", said: "I need to book a doctor's appointment."),
                       6.0 / 7.0, accuracy: 1e-9)
        XCTAssertEqual(MomentBench.accuracy(heard: "need to book appointment", said: "I need to book a doctor's appointment."),
                       4.0 / 7.0, accuracy: 1e-9)
        XCTAssertEqual(MomentBench.accuracy(heard: "", said: "Okay."), 0)
        XCTAssertEqual(MomentBench.accuracy(heard: "okay okay okay okay okay", said: "Okay."), 0, "never below nothing")
        XCTAssertEqual(MomentBench.editDistance(["a", "b", "c"], ["a", "c"]), 1)
        XCTAssertEqual(MomentBench.editDistance([], ["a"]), 1)
    }

    // MARK: The voice threshold

    func testTheThresholdLetsAboutOnePercentOfOthersThrough() throws {
        // 200 other voices, 0.000 to 0.995: two may get through, so it sits just above the third highest, 0.985.
        let others = (0..<200).map { Double($0) * 0.005 }
        let found = try XCTUnwrap(MomentBench.threshold(others: others))
        XCTAssertEqual(found.value, 0.99, accuracy: 1e-9)
        XCTAssertEqual(found.through, 2)
        XCTAssertEqual(found.others, 200)
        XCTAssertTrue(found.isEnough)
        XCTAssertGreaterThan(found.upperBound, 0.01, "two in 200 could still be more than 1%")
        XCTAssertLessThan(found.upperBound, 0.04)
    }

    func testAScoreOnAHundredthIsKeptOut() throws {
        // The highest that mustn't get through is exactly 0.70: 0.70 would let it, so 0.71.
        let found = try XCTUnwrap(MomentBench.threshold(others: [0.70, 0.2, 0.3]))
        XCTAssertEqual(found.value, 0.71, accuracy: 1e-9)
        XCTAssertEqual(found.through, 0)
        XCTAssertFalse(found.isEnough, "three say little about 1%")
        XCTAssertEqual(try XCTUnwrap(MomentBench.threshold(others: [0.704, 0.1])).value, 0.71, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(MomentBench.threshold(others: [0.999])).value, 1, accuracy: 1e-9, "never above 1")
        XCTAssertNil(MomentBench.threshold(others: []))
    }

    func testTiesAtTheEdgeAreAllKeptOut() throws {
        // 100 voices with the top three tied: one may get through, but it can't be told from the other two.
        let others = [0.8, 0.8, 0.8] + Array(repeating: 0.4, count: 97)
        let found = try XCTUnwrap(MomentBench.threshold(others: others))
        XCTAssertEqual(found.value, 0.81, accuracy: 1e-9)
        XCTAssertEqual(found.through, 0)
    }

    func testFewerOthersAreLessSure() throws {
        let few = try XCTUnwrap(MomentBench.threshold(others: Array(repeating: 0.3, count: 30)))
        let many = try XCTUnwrap(MomentBench.threshold(others: Array(repeating: 0.3, count: 300)))
        XCTAssertEqual(few.through, 0)
        XCTAssertEqual(many.through, 0)
        XCTAssertGreaterThan(few.upperBound, many.upperBound)
        XCTAssertGreaterThan(few.upperBound, 0.05)
        XCTAssertLessThan(many.upperBound, 0.015)
    }

    // MARK: Results

    private let session = UUID()

    private func result(_ run: MomentBench.Run, _ phrase: String?, voice: Double? = 0.7, seconds: Double? = 3, failures: [MomentGate.Check] = [],
                        detector: MomentBench.Detector = .onItsOwn, wake: Bool = false, rules: String? = nil, model: String? = nil,
                        voicePrint: String? = "abcd", heard offset: TimeInterval = 0, session: UUID? = nil) -> MomentBench.Result {
        MomentBench.Result(run: run, session: session ?? self.session, heard: heard.addingTimeInterval(offset), phrase: phrase, detector: detector,
                           seconds: seconds, wake: wake, voice: voice, threshold: 0.65, rules: rules, model: model, failures: failures, voicePrint: voicePrint)
    }

    func testAnotherThresholdJudgesTheVoiceAgainAndLeavesTheRest() {
        let passed = result(.phrases, "todo-01", voice: 0.70)
        XCTAssertTrue(passed.taken(at: 0.65))
        XCTAssertEqual(passed.failures(at: 0.72), [.notYourVoice])
        XCTAssertFalse(passed.taken(at: 0.72))

        let low = result(.phrases, "todo-02", voice: 0.60, failures: [.notYourVoice])
        XCTAssertFalse(low.taken(at: 0.65))
        XCTAssertTrue(low.taken(at: 0.55))

        let noCue = result(.phrases, "chatter-01", voice: 0.60, failures: [.noCue, .notYourVoice, .modelDisagreed])
        XCTAssertEqual(noCue.failures(at: 0.55), [.noCue, .modelDisagreed], "in the gate's order, the voice now passing")
        XCTAssertEqual(noCue.failures(at: 0.65), [.noCue, .notYourVoice, .modelDisagreed])

        let woke = result(.phrases, "todo-03", voice: 0.2, wake: true)
        XCTAssertTrue(woke.taken(at: 0.9), "Binders, … never goes by the voice")

        let unclear = result(.otherVoices, "todo-04", voice: nil, failures: [.voiceUnclear])
        XCTAssertFalse(unclear.taken(at: 0.1))

        let letGo = result(.phrases, "todo-05", voice: nil, failures: [], detector: .letGo)
        XCTAssertFalse(letGo.taken(at: 0.1), "let go by the detector, nothing was checked")
    }

    func testWhatTheIPhoneReadItAs() {
        XCTAssertEqual(result(.script, "line-01", rules: "todo", model: "question").kindRead, .todo, "the rules first")
        XCTAssertEqual(result(.script, "line-01", rules: "unsure", model: "note").kindRead, .note, "then Apple's model")
        XCTAssertNil(result(.script, "line-01", rules: "unsure", model: "unavailable").kindRead)
        XCTAssertNil(result(.script, "line-01", rules: "unsure", model: "noAnswer").kindRead)
    }

    func testAPhraseSaidAgainReplacesTheLastTimeInItsPass() {
        var store = MomentBench.Store()
        let other = UUID()
        store.record(result(.phrases, "todo-01", voice: 0.5))
        store.record(result(.phrases, "todo-01", voice: 0.8, heard: 10))
        store.record(result(.phrases, "todo-01", voice: 0.9, heard: 20, session: other))
        store.record(result(.media, nil))
        store.record(result(.media, nil))
        XCTAssertEqual(store.results.count, 4)
        XCTAssertEqual(store.results(in: session)["todo-01"]?.voice, 0.8)
        XCTAssertEqual(store.results(in: other)["todo-01"]?.voice, 0.9)
        store.sessions = [MomentBench.Session(id: session, run: .phrases, started: heard),
                          MomentBench.Session(id: other, run: .phrases, started: heard.addingTimeInterval(60))]
        XCTAssertEqual(store.latest(.phrases)?.id, other)
        XCTAssertNil(store.latest(.script))
    }

    func testTheReport() throws {
        var store = MomentBench.Store()
        let media = UUID()
        store.sessions = [MomentBench.Session(id: session, run: .phrases, started: heard),
                          MomentBench.Session(id: media, run: .media, started: heard, ended: heard.addingTimeInterval(1800))]
        // Yours: two to-dos (one through), a chatter line taken (a false accept), one let go.
        store.record(result(.phrases, "todo-01", voice: 0.80))
        store.record(result(.phrases, "todo-02", voice: 0.60, failures: [.notYourVoice]))
        store.record(result(.phrases, "chatter-01", voice: 0.75))
        store.record(result(.phrases, "notMeant-01", voice: 0.75, failures: [.modelDisagreed]))
        store.record(result(.phrases, "todo-03", voice: nil, detector: .letGo))
        // Someone else: one let through by everything, one held back by the voice.
        store.record(result(.otherVoices, "todo-01", voice: 0.66))
        store.record(result(.otherVoices, "todo-02", voice: 0.40, failures: [.notYourVoice]))
        // The TV: three clips, one on 6 s (not used for the voice), one against an earlier print.
        store.record(result(.media, nil, voice: 0.30, failures: [.noCue, .notYourVoice], session: media))
        store.record(result(.media, nil, voice: 0.90, seconds: 6, failures: [.noCue], session: media))
        store.record(result(.media, nil, voice: 0.50, failures: [.noCue, .notYourVoice], voicePrint: "old", session: media))
        // The 40 lines: one passed, one failed, then said again and passed.
        store.record(result(.script, "line-01", voice: 0.80, rules: "todo"))
        store.record(result(.script, "line-02", voice: 0.80, rules: "unsure", heard: 0))
        store.record(result(.script, "line-02", voice: 0.80, failures: [.noCue], rules: "unsure", heard: 30, session: UUID()))

        let report = MomentBench.report(store, threshold: 0.65, voicePrint: "abcd", notMe: [0.7, 0.5])
        XCTAssertEqual(report.yours[.todo], MomentBench.Tally(taken: 1, total: 3))
        XCTAssertEqual(report.yours[.chatter], MomentBench.Tally(taken: 1, total: 1))
        XCTAssertEqual(report.yours[.notMeant], MomentBench.Tally(taken: 0, total: 1))
        XCTAssertEqual(report.yourFalseAccepts, MomentBench.Tally(taken: 1, total: 2))
        XCTAssertEqual(report.others[.todo], MomentBench.Tally(taken: 1, total: 2))
        XCTAssertEqual(report.otherFalseAccepts, MomentBench.Tally(taken: 1, total: 2))
        XCTAssertEqual(report.media, MomentBench.Tally(taken: 0, total: 3))
        XCTAssertEqual(report.mediaSeconds, 1800)
        XCTAssertEqual(report.voice.yours.sorted(), [0.6, 0.75, 0.75, 0.8, 0.8, 0.8, 0.8])
        XCTAssertEqual(report.voice.others.sorted(), [0.3, 0.4, 0.66])
        XCTAssertEqual(report.earlierPrint, 1)
        XCTAssertEqual(report.voice.othersThrough(at: 0.65), 1)
        XCTAssertEqual(report.voice.yoursPassing(at: 0.65), 6)
        XCTAssertEqual(report.voice.notMeThrough(at: 0.65), 1)
        let suggestion = try XCTUnwrap(report.voice.suggestion)
        XCTAssertEqual(suggestion.value, 0.67, accuracy: 1e-9)
        XCTAssertEqual(report.script, ["line-01": .passed, "line-02": .passed])
        XCTAssertEqual(report.scriptPassed, 2)

        // Counted at a stricter threshold, the to-do someone else said is held back too.
        let stricter = MomentBench.report(store, threshold: 0.70, voicePrint: "abcd")
        XCTAssertEqual(stricter.otherFalseAccepts.taken, 0)
        XCTAssertEqual(stricter.yours[.todo]?.taken, 1)
    }

    func testEachLinesVerdict() throws {
        let todo = try XCTUnwrap(MomentBench.line("line-01"))
        XCTAssertEqual(MomentBench.verdict(result(.script, todo.id, rules: "todo"), for: todo, threshold: 0.65), .passed)
        XCTAssertEqual(MomentBench.verdict(result(.script, todo.id, rules: "question"), for: todo, threshold: 0.65), .failed, "the wrong kind")
        XCTAssertEqual(MomentBench.verdict(result(.script, todo.id, rules: "unsure", model: "unavailable"), for: todo, threshold: 0.65), .passed,
                       "no kind read on the iPhone: your Mac decides")
        XCTAssertEqual(MomentBench.verdict(result(.script, todo.id, voice: 0.6, failures: [.notYourVoice], rules: "todo"), for: todo,
                                           threshold: 0.65), .failed)

        let note = try XCTUnwrap(MomentBench.line("line-24"))
        XCTAssertEqual(note.expected, .taken(nil))
        XCTAssertEqual(MomentBench.verdict(result(.script, note.id, rules: "todo"), for: note, threshold: 0.65), .passed, "any kind")

        let noCue = try XCTUnwrap(MomentBench.line("line-02"))
        XCTAssertEqual(MomentBench.verdict(result(.script, noCue.id, failures: [.noCue]), for: noCue, threshold: 0.65), .passed)
        XCTAssertEqual(MomentBench.verdict(result(.script, noCue.id), for: noCue, threshold: 0.65), .failed)

        let notMeant = try XCTUnwrap(MomentBench.line("line-08"))
        XCTAssertEqual(notMeant.expected, .letGo(.notMeant))
        XCTAssertEqual(MomentBench.verdict(result(.script, notMeant.id, failures: [.modelDisagreed], model: "none"), for: notMeant, threshold: 0.65),
                       .passed)
        XCTAssertEqual(MomentBench.verdict(result(.script, notMeant.id, model: "unavailable"), for: notMeant, threshold: 0.65), .needsModel)
        XCTAssertEqual(MomentBench.verdict(result(.script, notMeant.id, model: "todo"), for: notMeant, threshold: 0.65), .failed)

        let short = try XCTUnwrap(MomentBench.line("line-10"))
        XCTAssertEqual(MomentBench.verdict(result(.script, short.id, voice: nil, detector: .letGo), for: short, threshold: 0.65), .passed)
    }

    // MARK: Keeping and sharing

    func testAResultWithOnlyItsRequiredFieldsReads() throws {
        let json = #"{"id":"7C1A3F0E-2B5D-4C55-9E2A-1F6B7A0C9D11","run":"phrases","session":"0B0E9F55-8C66-4E9B-9C3E-5B3A2D1E4F70","heard":0}"#
        let result = try JSONDecoder().decode(MomentBench.Result.self, from: Data(json.utf8))
        XCTAssertEqual(result.run, .phrases)
        XCTAssertNil(result.detector)
        XCTAssertNil(result.voice)
        XCTAssertFalse(result.taken(at: 0.65), "nothing known, nothing taken")
        let store = try JSONDecoder().decode(MomentBench.Store.self, from: Data(#"{"results":[\#(json)]}"#.utf8))
        XCTAssertEqual(store.results.count, 1)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(MomentBench.Store.self, from: Data("{}".utf8)).results.isEmpty)
    }

    func testResultsTravelAsJSON() throws {
        var store = MomentBench.Store()
        store.sessions = [MomentBench.Session(id: session, run: .otherVoices, started: heard, reader: 2)]
        store.record(result(.otherVoices, "idea-03", failures: [.noCue, .modelDisagreed]))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(MomentBench.Store.self, from: encoder.encode(store)), store)
    }

    func testTheCSVHasOneRowEachAndNoWords() throws {
        var store = MomentBench.Store()
        store.sessions = [MomentBench.Session(id: session, run: .phrases, started: heard)]
        store.record(result(.phrases, "idea-01", voice: 0.712, failures: [.modelDisagreed], rules: "idea", model: "none"))
        store.record(result(.script, "line-08", voice: 0.8, model: "todo", heard: 5))
        let csv = MomentBench.csv(store, threshold: 0.65)
        let rows = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].hasPrefix("run,speaker,pass,pass_started,reader,heard,phrase,group,text,expected,detector,seconds"))
        XCTAssertTrue(rows[1].hasPrefix("phrases,me,\(session.uuidString),"))
        XCTAssertTrue(rows[2].hasPrefix("script,me,"))
        XCTAssertTrue(rows[1].contains(",idea-01,idea,Idea for a feature for Binders: a weekly digest of my promises.,,onItsOwn,3.00,"),
                      "the script's text, as shown")
        XCTAssertTrue(rows[1].contains(",0.712,0.65,idea,none,modelDisagreed,no,no,0.65,"))
        XCTAssertTrue(rows[2].contains("\"Sam, we need to leave in five minutes.\",Let go: not meant for Binders,"))
        XCTAssertTrue(rows[2].contains(",yes,yes,0.65,failed,"))
        let columns = rows[0].split(separator: ",").count
        XCTAssertEqual(columns, 43)
        XCTAssertTrue(rows[0].hasSuffix(",line_verdict,voice_print,scored_later,kind_score,expected_binder,binder_read,binder_score,expected_due,due_read,due_score,uncued,uncued_model"),
                      "the old columns first, as they were, the new ones after")
        XCTAssertTrue(rows[1].hasSuffix(",abcd,,right,Binders,,,,,,,"), "a result from before the binder was read: expected, not scored")
        XCTAssertEqual(MomentBench.Run.otherVoices.speaker, "not me")
        XCTAssertEqual(MomentBench.Run.media.speaker, "tv")
        XCTAssertEqual(MomentBench.escaped("say \"hi\", then"), "\"say \"\"hi\"\", then\"")
        XCTAssertEqual(MomentBench.escaped("plain"), "plain")
    }

    func testANotMeOnAHandOverRaisesTheStartBar() {
        XCTAssertEqual(MomentBench.raisedStartBar(current: 0.83, notMe: 0.79), 0.83, "under the bar: it stays")
        XCTAssertEqual(MomentBench.raisedStartBar(current: 0.83, notMe: 0.86), 0.87, "at or above it: the next step above the score")
        XCTAssertEqual(MomentBench.raisedStartBar(current: 0.83, notMe: 0.83), 0.84, "at the bar itself")
        XCTAssertEqual(MomentBench.raisedStartBar(current: 0.83, notMe: 0.861), 0.87, "rounded as the start bar is")
        XCTAssertEqual(MomentBench.raisedStartBar(current: 0.83, notMe: 0.999), 1, "never above 1")
        XCTAssertEqual(MomentBench.raisedStartBar(current: 0.83, notMe: 1), 1)
        // As Calibrate would set it with that miss among its Not me's.
        let others = (0..<100).map { 0.2 + Double($0) / 1_000 }
        XCTAssertEqual(MomentBench.raisedStartBar(current: 0.83, notMe: 0.86),
                       MomentBench.startThreshold(others: others, notMe: [0.86], momentThreshold: 0.78))
    }
}
