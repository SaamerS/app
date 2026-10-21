import XCTest
@testable import BindersKit

final class AskStreamingTests: XCTestCase {
    // MARK: What's said while waiting

    func testEachWaitSaysWhatItsDoingAndWhatComesNext() {
        XCTAssertEqual(AskStage.waiting(nil, found: 0), "Searching your meetings, notes and dictations…")
        XCTAssertEqual(AskStage.waiting(.keywordHits, found: 3), "Found 3 passages with those words. Searching by meaning…")
        XCTAssertEqual(AskStage.waiting(.keywordHits, found: 1), "Found 1 passage with those words. Searching by meaning…")
        XCTAssertEqual(AskStage.waiting(.keywordHits, found: 0), "Nothing matches those words. Searching by meaning…")
        XCTAssertEqual(AskStage.waiting(.sources, found: 5), "Writing the answer from 5 passages…")
        XCTAssertNil(AskStage.waiting(.writing, found: 5), "the answer itself shows once it's being written")
    }

    func testThePhoneSaysWhatsTrueOfAnyMacUntilItsFirstUpdate() {
        // Binders 0.8.0 lists askProgress and never sends an update: its wait is the search and the writing both.
        XCTAssertEqual(AskStage.waitingForMac(nil, found: 0), "Your Mac is looking this up and writing the answer…")
        for stage in AskStage.allCases {
            XCTAssertEqual(AskStage.waitingForMac(stage, found: 3), AskStage.waiting(stage, found: 3), "then it says what the Mac said: \(stage)")
        }
    }

    // MARK: The wire

    func testTheTokenIsReadFromAskKnowledgesArguments() {
        XCTAssertEqual(LinkAskProgress.token(in: ["question": "When is the launch?", "progress_token": "abc"]), "abc")
        XCTAssertNil(LinkAskProgress.token(in: ["question": "When is the launch?"]), "MCP hosts and older phones send none")
        XCTAssertNil(LinkAskProgress.token(in: ["progress_token": ""]))
        XCTAssertNil(LinkAskProgress.token(in: ["progress_token": 42]))
        XCTAssertNil(LinkAskProgress.token(in: ["progress_token": String(repeating: "x", count: 101)]), "nothing long enough to be anything else")
    }

    func testAnUpdateSurvivesTheTripAsJSON() throws {
        let sources: [[String: Any]] = [["kind": "note", "source_id": "1", "title": "Launch date", "date": "2026-10-16T09:00:00Z",
                                         "binder": "Harbor launch", "text": "We moved the launch to Thursday."]]
        let params = LinkAskProgress.params(token: "t1", seq: 2, stage: .sources, sources: sources)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: params)) as? [String: Any])
        let update = try XCTUnwrap(LinkAskProgress.Update(params: decoded))
        XCTAssertEqual(update.token, "t1")
        XCTAssertEqual(update.seq, 2)
        XCTAssertEqual(update.stage, .sources)
        XCTAssertNil(update.text)
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(update.sources)) as? [[String: Any]])
        XCTAssertEqual(list.first?["title"] as? String, "Launch date")

        let writing = try XCTUnwrap(LinkAskProgress.Update(params: LinkAskProgress.params(token: "t1", seq: 3, stage: .writing, text: "The launch")))
        XCTAssertEqual(writing.text, "The launch")
        XCTAssertNil(writing.sources)
    }

    func testAnUpdateIsReadLeniently() throws {
        let later = try XCTUnwrap(LinkAskProgress.Update(params: ["token": "t1", "seq": 4, "stage": "something-new", "text": "Hi", "extra": [1, 2]]))
        XCTAssertNil(later.stage, "a stage this build doesn't know is left out")
        XCTAssertEqual(later.text, "Hi", "and the rest is still read")
        XCTAssertEqual(LinkAskProgress.Update(params: ["token": "t1", "seq": 5.0])?.seq, 5)
        XCTAssertNil(LinkAskProgress.Update(params: ["seq": 1, "stage": "writing", "text": "Hi"]), "no token: not one")
        XCTAssertNil(LinkAskProgress.Update(params: ["token": "t1", "stage": "writing"]), "no number: not one")
    }

    // MARK: Updates handled out of order

    func testUpdatesInOrderBuildTheAnswer() {
        var shown = LinkAskProgress.Shown<String>()
        XCTAssertTrue(shown.apply(seq: 1, stage: .keywordHits, sources: ["Launch date"], text: nil))
        XCTAssertTrue(shown.apply(seq: 2, stage: .sources, sources: ["Launch date", "Shipping plan"], text: nil))
        XCTAssertTrue(shown.apply(seq: 3, stage: .writing, sources: nil, text: "The launch"))
        XCTAssertTrue(shown.apply(seq: 4, stage: .writing, sources: nil, text: "The launch is on Thursday."))
        XCTAssertEqual(shown.stage, .writing)
        XCTAssertEqual(shown.sources, ["Launch date", "Shipping plan"])
        XCTAssertEqual(shown.text, "The launch is on Thursday.")
    }

    func testALateUpdateTakesNothingBack() {
        var shown = LinkAskProgress.Shown<String>()
        shown.apply(seq: 1, stage: .keywordHits, sources: ["Launch date"], text: nil)
        shown.apply(seq: 4, stage: .writing, sources: nil, text: "The launch is on Thursday.")
        // The sources (2) and an earlier piece of text (3) are handled after the newer text.
        XCTAssertTrue(shown.apply(seq: 2, stage: .sources, sources: ["Launch date", "Shipping plan"], text: nil),
                      "sources nobody has seen newer ones of still show")
        XCTAssertFalse(shown.apply(seq: 3, stage: .writing, sources: nil, text: "The launch"), "older text changes nothing")
        XCTAssertEqual(shown.stage, .writing, "and the stage doesn't go back")
        XCTAssertEqual(shown.sources, ["Launch date", "Shipping plan"])
        XCTAssertEqual(shown.text, "The launch is on Thursday.")
        XCTAssertFalse(shown.apply(seq: 1, stage: .keywordHits, sources: ["Launch date"], text: nil), "nor do older sources")
        XCTAssertEqual(shown.sources, ["Launch date", "Shipping plan"])
    }

    // MARK: Cleaning up a reply as it's written

    func testReasoningStaysHiddenWhileItsWritten() {
        XCTAssertEqual(OutputGuard.streaming("<think>The user asks about"), "")
        XCTAssertEqual(OutputGuard.streaming("<think>The user asks about the launch.</think>The launch"), "The launch")
        XCTAssertEqual(OutputGuard.streaming("<think>a</think>The launch is <think>b"), "The launch is")
        XCTAssertEqual(OutputGuard.streaming("<|channel>thought Let me look"), "")
        XCTAssertEqual(OutputGuard.streaming("<|channel>thought Let me look<channel|>It's Thursday"), "It's Thursday")
    }

    func testTheStartOfATagWaitsForTheNextPiece() {
        XCTAssertEqual(OutputGuard.streaming("<thi"), "")
        XCTAssertEqual(OutputGuard.streaming("The launch is on Thursday. <"), "The launch is on Thursday.")
        XCTAssertEqual(OutputGuard.streaming("The launch is on Thursday.</thi"), "The launch is on Thursday.")
        XCTAssertEqual(OutputGuard.streaming("If 3 < 5 then"), "If 3 < 5 then", "a < that isn't a tag shows")
        XCTAssertEqual(OutputGuard.streaming("x <b>bold"), "x <b>bold")
    }

    func testAFinishedReplyReadsAsSanitizeHasIt() {
        for reply in ["The launch is on **Thursday 14 November** [1].\n\n- Pricing review first [2]",
                      "<think>hmm</think>\nThe launch is on Thursday.", "  The launch moved.  \n"] {
            XCTAssertEqual(OutputGuard.streaming(reply), OutputGuard.sanitize(reply))
        }
    }

    func testAReplyThatClosesReasoningItNeverOpenedIsNoticed() {
        XCTAssertTrue(OutputGuard.opensInReasoning("Okay, the user asks about the launch.</think>The launch"))
        XCTAssertTrue(OutputGuard.opensInReasoning("Let me look<channel|>It's Thursday"))
        XCTAssertTrue(OutputGuard.opensInReasoning("Okay.</think>The launch <think>again</think>"), "the first close is what counts")
        XCTAssertFalse(OutputGuard.opensInReasoning("<think>The user asks.</think>The launch"), "one it opened")
        XCTAssertFalse(OutputGuard.opensInReasoning("<|channel>thought Let me look<channel|>It's Thursday"))
        XCTAssertFalse(OutputGuard.opensInReasoning("Okay, the user asks about the launch."), "nothing has closed yet")
        XCTAssertFalse(OutputGuard.opensInReasoning("The launch is on Thursday."))
    }

    func testAModelThatOpensInReasoningShowsNothingUntilItCloses() {
        let reply = "Okay, the user asks about the launch. The notes say Thursday.</think>The launch is on **Thursday** [1]."
        var shown: [String] = []
        for end in reply.indices.dropFirst() {
            let next = OutputGuard.streaming(String(reply[..<end]), opensInReasoning: true)
            if shown.last != next { shown.append(next) }
        }
        shown.append(OutputGuard.streaming(reply, opensInReasoning: true))
        XCTAssertEqual(shown.first, "", "nothing shows while it reasons")
        XCTAssertTrue(shown.allSatisfy { !$0.contains("user asks") && !$0.contains("notes say") && !$0.contains("think") }, "\(shown)")
        XCTAssertEqual(shown.last, OutputGuard.sanitize(reply), "and once it closes, what sanitize keeps")
        XCTAssertEqual(OutputGuard.streaming("Okay, the user asks</thi", opensInReasoning: true), "", "the start of the close waits too")

        // A reply that opens its reasoning after all, or has none, shows as before.
        XCTAssertEqual(OutputGuard.streaming("<think>a</think>The launch", opensInReasoning: true), "The launch")
        XCTAssertEqual(OutputGuard.streaming("The launch is on Thursday.", opensInReasoning: true), "",
                       "with none, nothing shows while it's written, and the finished reply is as sanitize has it")
        XCTAssertEqual(OutputGuard.streaming("Okay, the user asks", opensInReasoning: false), "Okay, the user asks",
                       "a model not known to open in reasoning shows its words as they come")
    }

    func testEachPieceOfAPlainReplyStartsTheNext() {
        let reply = "The launch moved to **Thursday 14 November** [1], after the pricing review [2].\n\n- Sam books the venue."
        var shown = ""
        for end in reply.indices.dropFirst() {
            let next = OutputGuard.streaming(String(reply[..<end]))
            XCTAssertTrue(next.hasPrefix(shown) || shown.hasPrefix(next.trimmingCharacters(in: .whitespacesAndNewlines)),
                          "“\(next)” after “\(shown)”")
            shown = next
        }
    }

    // MARK: The phone

    func testThisPhoneReadsAskProgressAndTheFirstPhoneDoesnt() {
        XCTAssertTrue(LinkFeatures.thisPhone.contains(LinkFeatures.notification(LinkFeatures.askProgressMethod)))
        XCTAssertFalse(LinkFeatures.firstPhone.contains(LinkFeatures.notification(LinkFeatures.askProgressMethod)))
    }
}
