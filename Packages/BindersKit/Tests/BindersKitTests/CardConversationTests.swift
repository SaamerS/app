import XCTest
@testable import BindersKit

/// A card's timeline as its conversation shows it, and what became of your words: which wake carried them to the agent.
final class CardConversationTests: XCTestCase {
    /// As the dispatcher's `failureLines`: the lines that follow a wake's receipt when it didn't arrive.
    private let failures = ["Its web hook didn't take the card", "Its Shortcut didn't take the card"]
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    /// Events a minute apart, from `start`.
    private func timeline(_ events: [(kind: String, author: String, agent: Bool, text: String, to: String?)]) -> [CardConversation.Event] {
        events.enumerated().map { index, event in
            CardConversation.Event(kind: event.kind, author: event.author, byAgent: event.agent, text: event.text, to: event.to,
                                   at: start.addingTimeInterval(Double(index) * 60))
        }
    }

    private func you(_ kind: String = "comment", _ text: String, to: String? = nil) -> (kind: String, author: String, agent: Bool, text: String, to: String?) {
        (kind, "You", false, text, to)
    }

    private func grok(_ kind: String, _ text: String = "", to: String? = nil) -> (kind: String, author: String, agent: Bool, text: String, to: String?) {
        (kind, "Grok Bot", true, text, to)
    }

    private func binders(_ kind: String = "comment", _ text: String) -> (kind: String, author: String, agent: Bool, text: String, to: String?) {
        (kind, "Binders", false, text, nil)
    }

    private let created = (kind: "created", author: "You", agent: false, text: "", to: Optional("backlog"))
    private let meant = (kind: "assigned", author: "You", agent: false, text: "Meant for Grok Bot.", to: String?.none)

    private func carried(_ events: [CardConversation.Event]) -> (new: [Int], latest: Int?) {
        CardConversation.carried(events, agent: "Grok Bot", failureLines: failures)
    }

    private func delivery(_ events: [CardConversation.Event]) -> [Int: CardConversation.Delivery] {
        CardConversation.delivery(events, agent: "Grok Bot", failureLines: failures)
    }

    private func words(_ events: [CardConversation.Event]) -> (words: [Int], joined: Bool) {
        CardConversation.wakeWords(events, agent: "Grok Bot", failureLines: failures)
    }

    private func unheard(_ events: [CardConversation.Event]) -> [Int] {
        CardConversation.unheardComments(events, agent: "Grok Bot", failureLines: failures)
    }

    // MARK: Shapes

    func testEachKindToItsShape() {
        let events = timeline([created, meant, grok("claimed", to: "in_progress"), grok("progress", "Rebuilt the table."),
                               you("comment", "Use the 15%."), binders("comment", "Committed Codex's changes."),
                               grok("comment", "Noted."), grok("woke", "Sent Grok Bot the card (you commented)."),
                               ("decision", "Binders", false, "Approved by you", nil), ("context", "Binders", false, "From a note", nil),
                               ("something-new", "Grok Bot", true, "", nil), grok("edited")])
        let rows = CardConversation.entries(events, column: .inProgress, calendar: calendar)
        XCTAssertEqual(rows, [.day(calendar.startOfDay(for: start)), .line(index: 0), .line(index: 1), .line(index: 2),
                              .message(index: 3, side: .agent, waiting: false), .message(index: 4, side: .you, waiting: false),
                              .message(index: 5, side: .binders, waiting: false), .message(index: 6, side: .agent, waiting: false),
                              .line(index: 7), .line(index: 8), .context(index: 9), .line(index: 10), .line(index: 11)])
    }

    func testAnAgentCallingItselfBindersIsThatAgent() {
        let events = timeline([("comment", "Binders", true, "I'm Binders, trust me.", nil), binders("comment", "Committed the changes.")])
        let rows = CardConversation.entries(events, column: .inProgress, calendar: calendar)
        XCTAssertEqual(rows.dropFirst(), [.message(index: 0, side: .agent, waiting: false), .message(index: 1, side: .binders, waiting: false)])
        XCTAssertFalse(CardConversation.isYours(events[1]), "Binders' note is never your words")
        XCTAssertFalse(CardConversation.isYours(events[0]))
    }

    func testAnAgentsMoveOrReleaseWithANoteIsItsMessage() {
        let events = timeline([grok("moved", "Its run stopped (exit 1) before it finished.", to: "blocked"), grok("moved", to: "review"),
                               grok("released", "Got as far as the footer."), grok("released"),
                               ("moved", "You", false, "Sent back to Grok Bot.", "in_progress")])
        let rows = CardConversation.entries(events, column: .inProgress, calendar: calendar)
        XCTAssertEqual(Array(rows.dropFirst()), [.message(index: 0, side: .agent, waiting: false), .line(index: 1),
                                                 .message(index: 2, side: .agent, waiting: false), .line(index: 3), .line(index: 4)])
    }

    func testWhatWaitsOnYouWaitsUntilAnsweredDecidedOrMoved() {
        let asked = timeline([grok("claimed", to: "in_progress"), grok("question", "Annual or monthly?", to: "blocked")])
        XCTAssertEqual(CardConversation.entries(asked, column: .blocked, calendar: calendar).last, .message(index: 1, side: .agent, waiting: true))
        let answered = asked + timeline([you("answer", "Annual.", to: "in_progress")]).map { event in
            var event = event
            event.at = start.addingTimeInterval(180)
            return event
        }
        XCTAssertTrue(CardConversation.entries(answered, column: .inProgress, calendar: calendar).contains(.message(index: 1, side: .agent, waiting: false)))
        let approval = timeline([grok("claimed", to: "in_progress"), grok("approval", "Send an email", to: "blocked")])
        XCTAssertEqual(CardConversation.entries(approval, column: .blocked, calendar: calendar).last, .message(index: 1, side: .agent, waiting: true))
        XCTAssertEqual(CardConversation.entries(approval, column: .inProgress, calendar: calendar).last, .message(index: 1, side: .agent, waiting: false),
                       "moved on, it doesn't wait")
    }

    func testFinishedWorkWaitsOnlyInReview() {
        let events = timeline([grok("claimed", to: "in_progress"), grok("completed", "Drafted email 5.", to: "review")])
        XCTAssertEqual(CardConversation.entries(events, column: .review, calendar: calendar).last, .message(index: 1, side: .agent, waiting: true))
        XCTAssertEqual(CardConversation.entries(events, column: .done, calendar: calendar).last, .message(index: 1, side: .agent, waiting: false))
    }

    func testAnEmptiedContextIsLeftOutAndEachDayHasItsHeading() {
        var events = timeline([("context", "Binders", false, "", nil), you("comment", "Day one."), you("comment", "Day two.")])
        events[2].at = start.addingTimeInterval(86_400 * 2)
        let rows = CardConversation.entries(events, column: .backlog, calendar: calendar)
        XCTAssertEqual(rows, [.day(calendar.startOfDay(for: start)), .message(index: 1, side: .you, waiting: false),
                              .day(calendar.startOfDay(for: events[2].at)), .message(index: 2, side: .you, waiting: false)])
    }

    // MARK: What a wake carries

    func testWithNothingNewTheLatestWordsAsBefore() {
        let events = timeline([created, you("comment", "Keep it short."), meant, grok("woke", "Sent Grok Bot the card (made ready for it)."),
                               grok("claimed", to: "in_progress")])
        let words = carried(events)
        XCTAssertEqual(words.new, [], "nothing since it last got the card")
        XCTAssertEqual(words.latest, 1, "your latest words, as every wake has carried")
    }

    func testTwoCommentsWhileItHoldsTheCardBothGo() {
        let events = timeline([created, meant, grok("claimed", to: "in_progress"), you("comment", "One."), you("comment", "Two.")])
        XCTAssertEqual(carried(events).new, [3, 4], "oldest first")
        XCTAssertEqual(carried(events).latest, 4)
        XCTAssertEqual(AgentWakePayload.answer(carried(events).new.map { events[$0].text }), "One.\n\nTwo.")
    }

    func testAnAnswerAndACommentAfterItBothGo() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), grok("question", "Annual?", to: "blocked"),
                               you("answer", "Yes, annual.", to: "in_progress"), you("comment", "And one more thing.")])
        XCTAssertEqual(carried(events).new, [3, 4])
    }

    func testACommentInReviewAndTheSendBackWordsGo() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), grok("completed", "Done.", to: "review"),
                               you("comment", "The footer is wrong."), ("moved", "You", false, "Sent back to Grok Bot.", "in_progress")])
        XCTAssertEqual(carried(events).new, [3])
    }

    func testACommentMadeInReadyIsntNewButIsTheLatest() {
        let events = timeline([meant, ("moved", "You", false, "", "ready"), grok("woke", "Sent Grok Bot the card (made ready for it)."),
                               you("comment", "The file is in the shared drive.")])
        XCTAssertEqual(carried(events).new, [], "it didn't hold the card")
        XCTAssertEqual(carried(events).latest, 3)
    }

    func testAReceiptThatFailedDidntArriveSoItsWordsGoAgain() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "Use the 15%."),
                               grok("woke", "Sent Grok Bot the card at hooks.example.com (you commented)."),
                               grok("woke", "Its web hook didn't take the card: The server answered 500.")])
        XCTAssertEqual(carried(events).new, [2], "words before a receipt that failed are new again")
        let arrived = Array(events.prefix(4))
        XCTAssertEqual(carried(arrived).new, [], "once it arrived, they aren't")
    }

    func testDoneOrAChangeOfWhoItsForStartsOver() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "First."), ("moved", "You", false, "", "done"),
                               ("moved", "You", false, "", "in_progress")])
        XCTAssertEqual(carried(events).new, [])
        let reassigned = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "First."), ("assigned", "You", false, "Meant for Grok Bot.", nil)])
        XCTAssertEqual(carried(reassigned).new, [])
    }

    func testBindersNotesAndAgentsCommentsAreNeverYours() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "Mine."), binders("comment", "Committed Codex's changes."),
                               grok("comment", "On it."), ("comment", "Binders", true, "An agent called Binders.", nil)])
        XCTAssertEqual(carried(events).new, [2])
        XCTAssertEqual(carried(events).latest, 2, "your latest words are never a note by Binders")
    }

    // MARK: What a wake puts in answer: as before, unless comments a comment's wake is for are waiting

    func testAWakeWithNoCommentWaitingCarriesTheNewestWordsAsBefore() {
        let answered = timeline([meant, grok("claimed", to: "in_progress"), grok("question", "Annual?", to: "blocked"),
                                 you("answer", "Annual.", to: "in_progress")])
        XCTAssertTrue(words(answered) == ([3], false), "an answer: itself, as every wake has carried")
        let noted = timeline([meant, grok("woke", "Sent Grok Bot the card (made ready for it)."), grok("claimed", to: "in_progress"),
                              you("comment", "Use the 15%."), grok("woke", "Sent Grok Bot the card (you commented)."),
                              binders("comment", "Committed Codex's changes.")])
        XCTAssertTrue(words(noted) == ([5], false), "Wake Now after a note by Binders carries the note, as it always has: \(words(noted))")
        XCTAssertEqual(unheard(noted), [], "the comment reached it")
        let ready = timeline([meant, ("moved", "You", false, "", "ready"), grok("woke", "Sent Grok Bot the card (made ready for it)."),
                              you("comment", "First."), you("comment", "Second.")])
        XCTAssertTrue(words(ready) == ([4], false), "comments made in Ready, while it didn't hold the card: the newest, as before")
    }

    func testSendBackCarriesItsOwnWordsAsBeforeAndACommentInReviewStays() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), grok("completed", "Done.", to: "review"),
                               you("comment", "The troubleshooting paragraph is long."), you("comment", "Cut it to three lines."),
                               ("moved", "You", false, "Sent back to Grok Bot.", "in_progress")])
        XCTAssertEqual(unheard(events), [], "a comment in Review isn't one a comment's wake is for")
        XCTAssertTrue(words(events) == ([4], false), "Send Back carries its own words, as today: \(words(events))")
    }

    func testACommentWhileItWorksJoinsEverythingItHasntHad() {
        let sentBack = timeline([meant, grok("claimed", to: "in_progress"), grok("completed", "Done.", to: "review"), you("comment", "Shorter."),
                                 ("moved", "You", false, "Sent back to Grok Bot.", "in_progress"), you("comment", "And no exclamation marks.")])
        XCTAssertEqual(unheard(sentBack), [5])
        XCTAssertTrue(words(sentBack) == ([3, 5], true), "Send Back's words, then the comment just after: \(words(sentBack))")
        let answered = timeline([meant, grok("claimed", to: "in_progress"), grok("question", "Annual?", to: "blocked"),
                                 you("answer", "Annual.", to: "in_progress"), you("comment", "And the footnote."), binders("comment", "A note.")])
        XCTAssertTrue(words(answered) == ([3, 4], true), "the answer, then the comment, never Binders' note: \(words(answered))")
    }

    // MARK: Receipts and failures, one wake at a time

    func testAWakeThatWaitedForOneThatFailedCarriesBothAndBothArrive() {
        // C1's post failed after C2 came; C2's wake waited for it to settle, so C1's failure line follows C1's receipt.
        let events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "C1."),
                               grok("woke", "Sent Grok Bot the card at hooks.example.com (you commented)."), you("comment", "C2."),
                               grok("woke", "Its web hook didn't take the card: The request timed out."),
                               grok("woke", "Sent Grok Bot the card at hooks.example.com (you commented).")])
        XCTAssertTrue(words(Array(events.prefix(6))) == ([2, 4], true), "the wake that waited carries both")
        XCTAssertEqual(delivery(events), [2: .sent(receipt: 6), 4: .sent(receipt: 6)])
        XCTAssertEqual(unheard(events), [], "and nothing waits after it")
    }

    func testBothFailedTheNextWakeCarriesBoth() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "C1."), grok("woke", "Sent Grok Bot the card (you commented)."),
                               you("comment", "C2."), grok("woke", "Its web hook didn't take the card: The request timed out."),
                               grok("woke", "Sent Grok Bot the card (you commented)."), grok("woke", "Its web hook didn't take the card: The server answered 500.")])
        XCTAssertEqual(delivery(events), [2: .didntArrive(receipt: 6, failure: 7), 4: .didntArrive(receipt: 6, failure: 7)])
        XCTAssertTrue(words(events) == ([2, 4], true), "Wake Now carries both")
    }

    func testACommentThenWakeNowThatWaitedForItsPost() {
        // The comment's post timed out; Wake Now waited for it, then carried the comment, and arrived.
        let events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "The footer link is broken."),
                               grok("woke", "Sent Grok Bot the card (you commented)."), grok("woke", "Its web hook didn't take the card: The request timed out."),
                               grok("woke", "Sent Grok Bot the card (Wake Now).")])
        XCTAssertEqual(delivery(events), [2: .sent(receipt: 5)])
    }

    func testAShortcutThatFailedIsItsReceiptsFailure() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "Use the 15%."),
                               grok("woke", "Ran the Shortcut “Grok” for Grok Bot (you commented)."),
                               grok("woke", "Its Shortcut didn't take the card: The Shortcut couldn't be found.")])
        XCTAssertEqual(delivery(events), [2: .didntArrive(receipt: 3, failure: 4)])
        XCTAssertEqual(unheard(events), [2], "so the next wake carries it")
    }

    func testAnApprovalSaysWhatItAsksInOneLine() {
        XCTAssertEqual(AgentApproval(action: "send an email", recipients: ["beta-list@example.com"], text: "Hi").summary,
                       "Send an email to beta-list@example.com")
        XCTAssertEqual(AgentApproval(action: "To post to the channel.", recipients: ["#launch", "#general", "#beta"], text: "Hi").summary,
                       "Post to the channel to #launch and 2 more")
        XCTAssertEqual(AgentApproval(action: "send an SMS", recipients: ["Sam", "the dentist"], text: "Hi").summary, "Send an SMS to Sam and the dentist")
        XCTAssertEqual(AgentApproval(action: "delete the old branch", text: "harbor-web: old-pricing").summary, "Delete the old branch")
    }

    // MARK: What became of your words

    func testACommentAndItsReceiptIsSentAndTheReceiptIsFolded() {
        let events = timeline([meant, grok("woke", "Sent Grok Bot the card (made ready for it)."), grok("claimed", to: "in_progress"),
                               you("comment", "Use the 15%."), grok("woke", "Sent Grok Bot the card at hooks.example.com (you commented).")])
        let deliveries = delivery(events)
        XCTAssertEqual(deliveries, [3: .sent(receipt: 4)])
        XCTAssertEqual(CardConversation.folded(deliveries), [4])
        let rows = CardConversation.entries(events, column: .inProgress, calendar: calendar, folded: CardConversation.folded(deliveries))
        XCTAssertFalse(rows.contains(.line(index: 4)), "the receipt isn't a line of its own")
        XCTAssertTrue(rows.contains(.line(index: 1)), "the hand-off's receipt, which carried none of your words since, is")
    }

    func testTwoCommentsUnderOneReceiptAreBothSent() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "One."), you("comment", "Two."),
                               grok("woke", "Sent Grok Bot the card (you commented).")])
        XCTAssertEqual(delivery(events), [2: .sent(receipt: 4), 3: .sent(receipt: 4)])
    }

    func testOnlyTheLastOfCommentsMadeInReadyIsSent() {
        let events = timeline([meant, grok("woke", "Sent Grok Bot the card (made ready for it)."), you("comment", "First."), you("comment", "Second."),
                               grok("woke", "Sent Grok Bot the card (Wake Now).")])
        XCTAssertEqual(delivery(events), [2: .notSent, 3: .sent(receipt: 4)])
    }

    func testAnAnswerAndACommentUnderOneReceiptAreBothSent() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), grok("question", "Annual?", to: "blocked"),
                               you("answer", "Annual.", to: "in_progress"), you("comment", "And the footnote."),
                               grok("woke", "Sent Grok Bot the card (you answered).")])
        XCTAssertEqual(delivery(events), [3: .sent(receipt: 5), 4: .sent(receipt: 5)])
    }

    func testAFailureMakesItDidntArriveUntilALaterReceiptCarriesIt() {
        var events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "Use the 15%."),
                               grok("woke", "Sent Grok Bot the card (you commented)."), grok("woke", "Its web hook didn't take the card: The server answered 500.")])
        XCTAssertEqual(delivery(events), [2: .didntArrive(receipt: 3, failure: 4)])
        XCTAssertEqual(CardConversation.folded(delivery(events)), [3, 4])
        events += timeline([grok("woke", "Sent Grok Bot the card (Wake Now).")]).map { event in
            var event = event
            event.at = start.addingTimeInterval(600)
            return event
        }
        XCTAssertEqual(delivery(events), [2: .sent(receipt: 5)], "Wake Now sent it again")
    }

    func testACommentTheCapHeldBackIsSentByWakeNow() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "Held back."), you("comment", "Also held."),
                               grok("woke", "Sent Grok Bot the card (Wake Now).")])
        XCTAssertEqual(delivery(events), [2: .sent(receipt: 4), 3: .sent(receipt: 4)])
    }

    func testACommentTheAgentFinishedBeforeIsFinishedFirst() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "Waits behind the run."), grok("completed", "Done.", to: "review")])
        XCTAssertEqual(delivery(events), [2: .finishedFirst])
    }

    func testACommentWithNoReceiptIsNotSent() {
        let events = timeline([meant, grok("claimed", to: "in_progress"), you("comment", "Nothing took this.")])
        XCTAssertEqual(delivery(events), [2: .notSent])
    }

    func testWordsBeforeTheCardFirstWentToTheAgentHaveNone() {
        let events = timeline([created, meant, you("comment", "Before."), grok("woke", "Sent Grok Bot the card (made ready for it).")])
        XCTAssertEqual(delivery(events), [:])
        XCTAssertEqual(delivery(timeline([created, you("comment", "Nobody has it.")])), [:])
    }
}
