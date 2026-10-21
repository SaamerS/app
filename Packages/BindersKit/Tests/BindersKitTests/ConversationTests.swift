import XCTest
@testable import BindersKit

final class ConversationSplitterTests: XCTestCase {
    /// A run of decisions in 1-second steps: `speech` seconds of talk, then `quiet` seconds of nothing, and so on.
    private func decisions(_ pattern: [(speech: Int, quiet: Int)], from start: TimeInterval = 0) -> [(time: TimeInterval, speech: Bool, duration: TimeInterval)] {
        var result: [(time: TimeInterval, speech: Bool, duration: TimeInterval)] = []
        var time = start
        for stretch in pattern {
            for _ in 0..<stretch.speech { result.append((time, true, 1)); time += 1 }
            for _ in 0..<stretch.quiet { result.append((time, false, 1)); time += 1 }
        }
        return result
    }

    func testAGapShorterThanTheThresholdKeepsOneConversation() {
        let kept = ConversationSplitter.conversations(in: decisions([(30, 120), (30, 10)]))
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.start, 0)
        XCTAssertEqual(kept.first?.end, 180)
        XCTAssertEqual(kept.first?.speech, 60)
    }

    func testAGapLongerThanTheThresholdSplitsIt() {
        let kept = ConversationSplitter.conversations(in: decisions([(30, 200), (25, 10)]))
        XCTAssertEqual(kept.map(\.start), [0, 230])
        XCTAssertEqual(kept.map(\.end), [30, 255])
    }

    func testItClosesAsSoonAsTheSilenceIsLongEnough() {
        var splitter = ConversationSplitter()
        var events: [ConversationSplitter.Event] = []
        for decision in decisions([(30, 179)]) { events += splitter.add(speech: decision.speech, at: decision.time, duration: decision.duration) }
        XCTAssertEqual(events, [.opened(at: 0)])
        XCTAssertNotNil(splitter.current)
        events = splitter.add(speech: false, at: 209, duration: 1)
        XCTAssertEqual(events, [.closed(.init(start: 0, end: 30, speech: 30))])
        XCTAssertNil(splitter.current)
    }

    func testAConversationIsSplitAtItsMaximumLengthAndCarriesOn() {
        let settings = ConversationSplitter.Settings(silenceToClose: 180, maxLength: 600, minSpeech: 20)
        let kept = ConversationSplitter.conversations(in: decisions([(1000, 0)]), settings: settings)
        XCTAssertEqual(kept.map(\.start), [0, 600])
        XCTAssertEqual(kept.map(\.end), [600, 1000])
    }

    func testAShortBlipIsDropped() {
        var splitter = ConversationSplitter()
        var events: [ConversationSplitter.Event] = []
        for decision in decisions([(4, 200), (30, 0)]) { events += splitter.add(speech: decision.speech, at: decision.time, duration: decision.duration) }
        XCTAssertEqual(events.first, .opened(at: 0))
        XCTAssertEqual(events[1], .dropped(.init(start: 0, end: 4, speech: 4)))
        XCTAssertEqual(events.last, .opened(at: 204))
        XCTAssertEqual(ConversationSplitter.conversations(in: decisions([(4, 200), (30, 0)])).map(\.start), [204])
    }

    func testSpeechRightUpToTheEndOfTheInputIsKept() {
        var splitter = ConversationSplitter()
        for decision in decisions([(45, 0)], from: 1_000) { _ = splitter.add(speech: decision.speech, at: decision.time, duration: decision.duration) }
        XCTAssertEqual(splitter.finish(), [.closed(.init(start: 1_000, end: 1_045, speech: 45))])
        XCTAssertEqual(splitter.finish(), [])
    }

    func testWrappingUpClosesAtOnceAndKeepsAShortOne() {
        var splitter = ConversationSplitter()
        for decision in decisions([(8, 5)]) { _ = splitter.add(speech: decision.speech, at: decision.time, duration: decision.duration) }
        // Eight seconds of speech is under the 20 kept on its own, but you asked for it.
        XCTAssertEqual(splitter.wrapUp(keepingFrom: 3), [.closed(.init(start: 0, end: 8, speech: 8))])
        XCTAssertNil(splitter.current)
        XCTAssertEqual(splitter.wrapUp(keepingFrom: 3), [], "nothing open, nothing to wrap up")
        // The next speech opens a new one.
        XCTAssertEqual(splitter.add(speech: true, at: 20, duration: 1), [.opened(at: 20)])
        XCTAssertEqual(splitter.wrapUp(keepingFrom: 3), [.dropped(.init(start: 20, end: 21, speech: 1))], "a second of it isn't a conversation")
    }

    func testTheSameDecisionsAlwaysCutTheSameWay() {
        let day = decisions([(40, 30), (10, 300), (3, 400), (90, 5), (60, 1000)])
        XCTAssertEqual(ConversationSplitter.conversations(in: day), ConversationSplitter.conversations(in: day))
        XCTAssertEqual(ConversationSplitter.conversations(in: day).count, 2)
    }

    /// A listening glyph moves while speech is heard, through the gaps between words, and holds still in the quiet after,
    /// though the conversation stays open for minutes more.
    func testAListeningGlyphMovesOnlyWhileSpeechIsHeard() {
        var splitter = ConversationSplitter()
        for decision in decisions([(8, 20)], from: 1_000) { _ = splitter.add(speech: decision.speech, at: decision.time, duration: decision.duration) }
        let open = splitter.current
        XCTAssertEqual(open?.end, 1_008, "still open twenty seconds into the quiet, its last speech at 1008")
        let last = open.map { Date(timeIntervalSince1970: $0.end) }
        func speaking(_ time: TimeInterval) -> Bool { ConversationSplitter.isSpeaking(lastSpeech: last, now: Date(timeIntervalSince1970: time)) }
        XCTAssertTrue(speaking(1_008), "as the last word ends")
        XCTAssertTrue(speaking(1_008.9), "in the gap before the next word")
        XCTAssertFalse(speaking(1_009), "a second after the last word")
        XCTAssertFalse(speaking(1_028), "in the quiet, the conversation still open")
        XCTAssertFalse(ConversationSplitter.isSpeaking(lastSpeech: nil, now: Date()), "nothing heard since listening began")
        XCTAssertTrue(ConversationSplitter.isSpeaking(lastSpeech: Date().addingTimeInterval(0.2), now: Date()),
                      "audio stamped a moment ahead of the clock counts as now")
    }

    func testTheLoudnessGateHoldsThroughTheGapsBetweenWords() {
        var gate = LoudnessGate()
        let loud = [Float](repeating: 0.1, count: 1600), quiet = [Float](repeating: 0.0001, count: 1600)
        XCTAssertFalse(gate.isSpeech(quiet, duration: 0.1))
        XCTAssertTrue(gate.isSpeech(loud, duration: 0.1))
        for _ in 0..<5 { XCTAssertTrue(gate.isSpeech(quiet, duration: 0.1)) }
        XCTAssertFalse(gate.isSpeech(quiet, duration: 0.1))
    }

    func testSpansMapTheFileBackToTheTimeOfDay() {
        let morning = Date(timeIntervalSince1970: 1_760_000_000)
        var spans = CaptureSpans()
        spans.append(wallStart: morning, duration: 10)
        spans.append(wallStart: morning.addingTimeInterval(10), duration: 5)
        spans.append(wallStart: morning.addingTimeInterval(600), duration: 20)
        XCTAssertEqual(spans.spans.count, 2, "audio heard straight after the last span extends it")
        XCTAssertEqual(spans.fileDuration, 35)
        XCTAssertEqual(spans.wallTime(atFile: 3), morning.addingTimeInterval(3))
        XCTAssertEqual(spans.wallTime(atFile: 20), morning.addingTimeInterval(605))
        XCTAssertEqual(spans.wallTime(atFile: 40), morning.addingTimeInterval(625))
        let decoded = try? JSONDecoder().decode(CaptureSpans.self, from: JSONEncoder().encode(spans))
        XCTAssertEqual(decoded, spans)
    }
}

final class ConversationPayloadTests: XCTestCase {
    private func payload(segments: Int = 3) -> ConversationPayload {
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        let lines = (0..<segments).map { index in
            TranscriptSegment(channel: .microphone, start: Double(index) * 10, end: Double(index) * 10 + 8,
                              text: "Line \(index): I'll send the deck to Sam by Friday.", speaker: index.isMultiple(of: 2) ? "Speaker 1" : "Speaker 2")
        }
        return ConversationPayload(started: started, ended: started.addingTimeInterval(Double(segments) * 10), segments: lines,
                                   speakers: ["Speaker 1": "You"], device: "iPhone", engine: "parakeet-v2")
    }

    func testItSurvivesAJSONRoundTrip() throws {
        let original = payload()
        XCTAssertEqual(try ConversationPayload.decode(original.encoded()), original)
        XCTAssertEqual(try ConversationPayload(jsonObject: original.jsonObject()), original)
    }

    func testDatesTravelAsISO8601() throws {
        let object = try payload().jsonObject()
        XCTAssertEqual(object["started"] as? String, "2025-10-09T08:53:20Z")
        XCTAssertEqual((object["segments"] as? [[String: Any]])?.first?["speaker"] as? String, "Speaker 1")
    }

    func testASmallPayloadIsSentWhole() {
        let original = payload()
        XCTAssertEqual(original.parts(), [original])
    }

    func testAnOversizedPayloadIsSplitByTime() throws {
        let original = payload(segments: 40)
        let parts = original.parts(maxBytes: 2_000)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(try parts.allSatisfy { try $0.encoded().count <= 2_000 })
        XCTAssertEqual(parts.flatMap(\.segments).map(\.text), original.segments.map(\.text))
        XCTAssertEqual(parts.first?.started, original.started)
        XCTAssertEqual(parts.last?.ended, original.ended)
        XCTAssertEqual(parts[1].segments.first?.start, 0, "each part's times start at its own beginning")
        XCTAssertEqual(parts[1].started, original.started.addingTimeInterval(original.segments[parts[0].segments.count].start))
        XCTAssertEqual(Set(parts.map(\.id)).count, parts.count)
        XCTAssertEqual(original.parts(maxBytes: 2_000).map(\.id), parts.map(\.id), "a part sent again keeps its id")
    }

    func testWordCountAndDuration() {
        XCTAssertEqual(payload().wordCount, 30)
        XCTAssertEqual(payload().duration, 30)
    }
}

final class ConversationPromptTests: XCTestCase {
    func testTrivialIsRecognised() {
        XCTAssertTrue(ConversationPrompts.isTrivial("TRIVIAL"))
        XCTAssertTrue(ConversationPrompts.isTrivial("\n**Trivial.**\n"))
        XCTAssertFalse(ConversationPrompts.isTrivial("# Trivial pursuit night\n## Summary\nPlanning the game night."))
        XCTAssertFalse(ConversationPrompts.isTrivial("# Pricing with Sam\n## Summary\nTRIVIAL"))
    }

    func testTheConversationTemplateIsFoundButNotOfferedForMeetings() {
        XCTAssertEqual(MeetingTemplate.template(id: "conversation").id, "conversation")
        XCTAssertFalse(MeetingTemplate.all.contains(.conversation))
        XCTAssertTrue(ConversationPrompts.summarySystemPrompt().contains("## Promises"))
    }

    func testRoutingPicksABinderByItsName() {
        let names = ["General", "Harbor launch", "Café"]
        XCTAssertEqual(ConversationPrompts.parseRouting("BINDER: harbor launch\nREASON: talks about the launch email", names: names).binder, "Harbor launch")
        XCTAssertEqual(ConversationPrompts.parseRouting("**BINDER:** \"Cafe\"\nREASON: the menu", names: names).binder, "Café")
        XCTAssertEqual(ConversationPrompts.parseRouting("BINDER: Harbor launch\nREASON: the launch", names: names).reason, "the launch")
        XCTAssertNil(ConversationPrompts.parseRouting("BINDER: none\nREASON: small talk", names: names).binder)
        XCTAssertNil(ConversationPrompts.parseRouting("BINDER: Groceries", names: names).binder)
        XCTAssertNil(ConversationPrompts.parseRouting("I think it belongs in Harbor launch.", names: names).binder)
    }

    func testTheRoutingPromptListsTheBindersWithTheirTitles() {
        let prompt = ConversationPrompts.routingUserPrompt(binders: [.init(name: "Harbor launch", titles: ["Launch review"])],
                                                           title: "Pricing", summary: "Beta pricing for a year.")
        XCTAssertTrue(prompt.contains("- Harbor launch\n  - Launch review"))
        XCTAssertTrue(prompt.contains("The conversation: Pricing"))
    }
}

final class BindersTransferTests: XCTestCase {
    private func conversation(at seconds: TimeInterval) -> ConversationPayload {
        let started = Date(timeIntervalSince1970: seconds)
        return ConversationPayload(started: started, ended: started.addingTimeInterval(60),
                                   segments: [TranscriptSegment(channel: .microphone, start: 1, end: 4, text: "I'll send the deck by Friday.", speaker: "Speaker 1")],
                                   speakers: ["Speaker 1": "You"], device: "iPhone", engine: "parakeet-v2")
    }

    func testAFileSurvivesTheTrip() throws {
        let transfer = BindersTransfer(conversations: [conversation(at: 1_760_000_000), conversation(at: 1_760_003_600)])
        XCTAssertEqual(try BindersTransfer.decode(transfer.encoded()), transfer)
    }

    func testOtherFilesAreRefused() {
        XCTAssertThrowsError(try BindersTransfer.decode(Data("{\"conversations\":[]}".utf8))) { XCTAssertEqual($0 as? BindersTransfer.Failure, .notBinders) }
        XCTAssertThrowsError(try BindersTransfer.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try BindersTransfer.decode(Data("{\"format\":\"binders\",\"version\":9,\"conversations\":[]}".utf8))) {
            XCTAssertEqual($0 as? BindersTransfer.Failure, .newer(9))
        }
    }

    func testFileNamesSayWhatsInThem() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(BindersTransfer.fileName(for: [conversation(at: 1_760_000_000)], timeZone: utc), "Capture 2025-10-09 08.53.binders")
        XCTAssertEqual(BindersTransfer.fileName(for: [conversation(at: 1_760_003_600), conversation(at: 1_760_000_000)], timeZone: utc),
                       "2 captures 2025-10-09.binders")
    }
}

final class CaptureTranscriptTests: XCTestCase {
    private func segment(_ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(channel: .microphone, start: start, end: end, text: "words", speaker: CaptureTranscript.unlabelled)
    }

    func testVoicesAreLabelledInTheOrderTheyFirstSpeak() {
        let turns = [SpeakerTurn(speakerID: "B", start: 0, end: 5), SpeakerTurn(speakerID: "A", start: 5, end: 9)]
        let result = CaptureTranscript.label([segment(0, 4), segment(5.5, 8.5), segment(20, 22)], turns: turns)
        XCTAssertEqual(result.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 2"], "the last one takes its nearest neighbour's")
        XCTAssertEqual(result.labels, ["B": "Speaker 1", "A": "Speaker 2"])
    }

    func testWithoutVoicesItsOneSpeaker() {
        XCTAssertEqual(CaptureTranscript.label([segment(0, 2), segment(3, 4)], turns: []).segments.map(\.speaker), ["Speaker 1", "Speaker 1"])
    }

    func testFileTimesGoBackOnTheClock() {
        let started = Date(timeIntervalSince1970: 1_000)
        var spans = CaptureSpans()
        spans.append(wallStart: started.addingTimeInterval(-1), duration: 10)
        spans.append(wallStart: started.addingTimeInterval(120), duration: 10)
        let clock = CaptureTranscript.onTheClock([segment(0, 3), segment(12, 15)], spans: spans, started: started, ended: started.addingTimeInterval(128))
        XCTAssertEqual(clock.map(\.start), [0, 122], "the second before the first word clamps to the start")
        XCTAssertEqual(clock.map(\.end), [2, 125])
    }
}

final class ConversationSuggestionTests: XCTestCase {
    private let conversation = UUID(uuidString: "3A02EC85-6FEF-4AF9-9231-14713C1AEB2F")!

    func testYourOpenPromisesBecomeCardOffers() {
        let summary = """
        ## Promises
        - [ ] You — send the final pricing email to Sam by Friday
        - [ ] Speaker 2 — update the plan names on the website
        - [x] You — book the room
        - [ ] Check the import test results
        """
        let offers = SuggestionPrompts.cardCandidates(summary: summary, conversation: conversation)
        XCTAssertEqual(offers.map(\.text), ["send the final pricing email to Sam by Friday", "Check the import test results"])
        XCTAssertEqual(offers.first?.todo, BoardTaskReference(place: .meeting, id: conversation, text: "send the final pricing email to Sam by Friday").string)
        // Not knowing which voice is yours, anyone's might be.
        XCTAssertEqual(SuggestionPrompts.cardCandidates(summary: summary, conversation: conversation, youKnown: false).count, 3)
    }

    func testQuestionsAreParsed() {
        let output = "Q: When does the Harbor launch go live?\n- Q: What price did we agree for beta customers?\nQ: ok?\nQ: When does the Harbor launch go live?"
        XCTAssertEqual(SuggestionPrompts.parseQuestions(output), ["When does the Harbor launch go live?", "What price did we agree for beta customers?"])
        XCTAssertEqual(SuggestionPrompts.parseQuestions("NONE"), [])
    }

    func testAnAnswerIsOnlyAnAnswerWhenTheSourcesHoldOne() {
        XCTAssertNil(SuggestionPrompts.parseAnswer("NO ANSWER"))
        XCTAssertNil(SuggestionPrompts.parseAnswer("**No answer.**"))
        XCTAssertEqual(SuggestionPrompts.parseAnswer("Harbor launches on November 12 [1]."), "Harbor launches on November 12 [1].")
    }

    func testSuggestionsKeepTheirIdsAndTravelAsJSON() {
        let card = ConversationSuggestion(conversation: conversation, kind: .card, text: "send the deck", binder: "Harbor launch", todo: "meeting:x:1")
        let again = ConversationSuggestion(conversation: conversation, kind: .card, text: "Send the deck.", binder: "Harbor launch", todo: "meeting:x:1")
        XCTAssertEqual(card.id, again.id, "the same offer made twice is the same offer")
        let answer = ConversationSuggestion(conversation: conversation, kind: .answer, text: "When is the launch?", binder: "Harbor launch",
                                            answer: "November 12 [1].", sources: ["Launch date"])
        XCTAssertNotEqual(card.id, answer.id)
        XCTAssertEqual(ConversationSuggestion.decodeList(ConversationSuggestion.encodeList([card, answer])), [card, answer])
        XCTAssertEqual(card.notification.title, "Put this on the Harbor launch board?")
        XCTAssertEqual(answer.notification.title, "You asked: When is the launch?")
    }
}
