import XCTest
@testable import BindersKit

/// Agents that could act in the world draft first: what one asks your approval for, how the card keeps it, what the Lock
/// Screen may say about it, your answer and its receipt, and what the agent is told.
final class AgentApprovalTests: XCTestCase {
    private let email = AgentApproval(action: "Send an email", recipients: ["sam@example.com", "Smith, Pat <pat@example.com>"],
                                      text: "Hi Sam,\n\nThe booth is 14 in Hall B.\n\nTo: everyone at the stand\nPat", link: "https://example.test/draft")

    // MARK: On the card

    func testWhatItAsksIsKeptReadableAndComesBackExactly() throws {
        XCTAssertEqual(email.timelineText, """
            Send an email
            To: sam@example.com
            To: Smith, Pat <pat@example.com>
            Link: https://example.test/draft

            Hi Sam,

            The booth is 14 in Hall B.

            To: everyone at the stand
            Pat
            """)
        XCTAssertEqual(AgentApproval(timeline: email.timelineText), email, "blank lines and a To: inside the text stay in the text")
        let bare = AgentApproval(action: "Delete the old drafts", text: "The 3 drafts in Mail from last week.")
        XCTAssertEqual(bare.timelineText, "Delete the old drafts\n\nThe 3 drafts in Mail from last week.")
        XCTAssertEqual(AgentApproval(timeline: bare.timelineText), bare, "no one to send it to, and no link")
    }

    func testEachFieldIsOneLineAndTheTextStaysAsItIs() {
        let messy = AgentApproval(action: "  Post\nin #general ", recipients: ["", " #general\n", "  "], text: "\n\n  Line one\n\n  Line two  \n", link: " https://x.test/a\n")
        XCTAssertEqual(messy.action, "Post in #general")
        XCTAssertEqual(messy.recipients, ["#general"])
        XCTAssertEqual(messy.text, "Line one\n\n  Line two", "only the space around it goes")
        XCTAssertEqual(messy.link, "https://x.test/a")
        XCTAssertEqual(AgentApproval(action: String(repeating: "a", count: 300), text: "x").action.count, AgentApproval.actionLimit)
        XCTAssertEqual(AgentApproval.recipients(from: "sam@example.com\n\nSmith, Pat <pat@example.com>\n"), ["sam@example.com", "Smith, Pat <pat@example.com>"],
                       "one per line, and a comma stays part of a name")
    }

    func testWhatCantBeAskedSaysWhy() {
        XCTAssertNil(email.problem)
        XCTAssertNotNil(AgentApproval(action: " ", text: "x").problem)
        XCTAssertNotNil(AgentApproval(action: "Send an email", text: "  ").problem)
        XCTAssertNotNil(AgentApproval(action: "Send an email", text: String(repeating: "a", count: AgentApproval.textLimit + 1)).problem,
                        "too long to approve is refused, never cut")
        XCTAssertNil(AgentApproval(action: "Send an email", text: String(repeating: "a", count: AgentApproval.textLimit)).problem)
        XCTAssertNotNil(AgentApproval(action: "Send an email", recipients: (0...AgentApproval.recipientLimit).map { "p\($0)@example.com" }, text: "x").problem)
    }

    func testAnythingElseOnACardIsntARequest() {
        XCTAssertNil(AgentApproval(timeline: "Please look at this"))
        XCTAssertNil(AgentApproval(timeline: "Send an email\nCc: sam@example.com\n\nHi"), "a line this build doesn't know")
        XCTAssertNil(AgentApproval(timeline: "\n\nHi"), "nothing it wants to do")
    }

    // MARK: What may be said where

    func testTheHeadlineIsSafeForTheLockScreen() {
        XCTAssertEqual(email.headline(by: "Claude Code"), "Claude Code asks to send an email")
        XCTAssertEqual(AgentApproval(action: "To post in #general.", text: "x").headline(by: "Pennant"), "Pennant asks to post in #general")
        XCTAssertEqual(AgentApproval(action: "SMS Sam", text: "x").headline(by: "Helper"), "Helper asks to SMS Sam", "a word in capitals keeps them")
        let long = AgentApproval(action: "buy two tickets for the Ignite conference in the spring and a hotel room near the venue", text: "x")
        let headline = long.headline(by: "Helper")
        XCTAssertTrue(headline.hasSuffix("…") && headline.count <= "Helper asks to ".count + 61, headline)
        XCTAssertFalse(email.headline(by: "Claude Code").contains("sam@") || email.headline(by: "Claude Code").contains("booth"),
                       "never who it goes to or what it says")
    }

    func testTheNoticeToTheIPhoneHoldsNoRecipientOrText() throws {
        let notice = AgentApproval.Notice(card: "C1", approval: "A1", agent: "Claude Code", headline: email.headline(by: "Claude Code"),
                                          title: "Email Sam about the booth", asked: "2026-10-17T10:00:00Z")
        let params = notice.params
        XCTAssertEqual(Set(params.keys), ["card", "approval", "agent", "headline", "title", "asked"])
        let flat = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        XCTAssertFalse(flat.contains("sam@example.com") || flat.contains("Hall B"))
        XCTAssertEqual(AgentApproval.Notice(params: params), notice)
        XCTAssertNil(AgentApproval.Notice(params: ["card": "C1", "agent": "Claude Code"]), "which request it is, or nothing")
        XCTAssertEqual(AgentApproval.Notice(params: ["card": "C1", "approval": "A1", "agent": "Helper"])?.headline, "Helper asks for your approval")
    }

    func testTheNotificationOpensTheCardWhereYouDecide() {
        let notice = AgentApproval.Notice(card: "C1", approval: "A1", agent: "Pennant", headline: email.headline(by: "Pennant"),
                                          title: "Email Sam about the booth", asked: "2026-10-17T10:00:00Z")
        let text = notice.notification
        XCTAssertEqual(text, NotificationText(title: "Pennant asks to send an email", subtitle: "Email Sam about the booth",
                                              body: "Open the card to see who it goes to and exactly what it says, then approve or decline."))
        let shown = [text.title, text.subtitle, text.body].joined(separator: " ")
        XCTAssertFalse(shown.contains("sam@example.com") || shown.contains("Hall B"), "never who it goes to or what it says")
        XCTAssertFalse(shown.localizedCaseInsensitiveContains("approve here"), "nor an invitation to decide without them")
    }

    // MARK: Your answer

    func testTheAnswerTheAgentReads() {
        XCTAssertEqual(AgentApproval.answer(approved: true), "Approved")
        XCTAssertEqual(AgentApproval.answer(approved: true, reason: "ignored"), "Approved")
        XCTAssertEqual(AgentApproval.answer(approved: false), "Declined")
        XCTAssertEqual(AgentApproval.answer(approved: false, reason: "  Not this week.  "), "Declined: Not this week.")
        XCTAssertEqual(AgentApproval.answer(approved: false, reason: String(repeating: "a", count: 2_000)).count, "Declined: ".count + AgentApproval.reasonLimit)
    }

    func testTheReceiptSaysWhoDecidedWhereWhenAndWhat() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let approved = email.receipt(approved: true, on: "Sam's iPhone", at: date)
        XCTAssertTrue(approved.hasPrefix("You approved this on Sam's iPhone, \(date.formatted(date: .abbreviated, time: .shortened))."), approved)
        XCTAssertTrue(approved.hasSuffix("\n" + email.timelineText), "and exactly what it was")
        let declined = email.receipt(approved: false, reason: "Not this week,\nmaybe next", on: "Studio Mac", at: date)
        XCTAssertTrue(declined.hasPrefix("You declined this on Studio Mac, ") && declined.contains(": Not this week, maybe next\n"), declined)
        XCTAssertTrue(email.receipt(approved: false, on: " ", at: date).contains("on a device of yours"))
    }

    func testADecisionAsThePhoneSendsIt() {
        let decision = AgentApproval.Decision(card: "C1", approval: "A1", approve: false, reason: "Not yet")
        XCTAssertEqual(AgentApproval.Decision(params: decision.params), decision)
        XCTAssertNil(AgentApproval.Decision(params: ["card": "C1", "approval": "A1"]), "a yes or a no, never a guess")
        XCTAssertNil(AgentApproval.Decision(params: ["card": "C1", "approve": true]))
        XCTAssertEqual(AgentApproval.Decision(params: ["card": "C1", "approval": "A1", "approve": true])?.reason, "")
    }

    // MARK: What the card waits on

    private func events(_ pairs: [(String, String)]) -> [(kind: String, to: String)] { pairs.map { (kind: $0.0, to: $0.1) } }

    func testWhatACardWaitsOnIsTheLastThingAsked() {
        let asked = events([("claimed", "in_progress"), ("approval", "blocked")])
        XCTAssertEqual(BoardRules.waitingApproval(in: asked), 1)
        XCTAssertNil(BoardRules.waitingQuestion(in: asked), "a request for approval isn't a question")
        XCTAssertEqual(TaskState(column: .blocked, timeline: asked), .inputRequired)
        let thenQuestion = asked + events([("question", "blocked")])
        XCTAssertEqual(BoardRules.waitingQuestion(in: thenQuestion), 2)
        XCTAssertNil(BoardRules.waitingApproval(in: thenQuestion), "a question asked since replaces it")
        let thenApproval = events([("question", "blocked"), ("approval", "blocked")])
        XCTAssertEqual(BoardRules.waitingApproval(in: thenApproval), 1)
        XCTAssertNil(BoardRules.waitingQuestion(in: thenApproval))
        let decided = asked + events([("decision", ""), ("answer", "in_progress")])
        XCTAssertNil(BoardRules.waitingAsk(in: decided), "answered, it waits no more")
        XCTAssertEqual(BoardRules.waitingApproval(in: asked + events([("decision", "")])), 1, "the receipt alone doesn't end it")
        XCTAssertEqual(TaskState(column: .inProgress, timeline: decided), .working)
        XCTAssertNil(BoardRules.waitingAsk(in: events([("moved", "blocked")])))
    }

    func testAskingAndTheReceiptWakeNoOneButYourAnswerDoes() {
        for column in BoardColumn.allCases {
            for kind in ["approval", "decision"] {
                XCTAssertNil(AgentWake.reason(kind: kind, from: .inProgress, to: .blocked, column: column, byPerson: false))
                XCTAssertNil(AgentWake.reason(kind: kind, from: nil, to: nil, column: column, byPerson: true))
            }
        }
        XCTAssertEqual(AgentWake.reason(kind: "answer", from: .blocked, to: .inProgress, column: .inProgress, byPerson: true), .answered)
    }

    // MARK: What the agent is told

    func testAnAgentDraftsFirstUnlessYouLetItActAndAnOldFileStaysAsItWas() throws {
        let old = #"{"agents": [{"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "name": "Pennant", "isEnabled": true, "report": "mcp", "wake": {"board": {}}}]}"#
        let read = try XCTUnwrap(AgentFile.decode(Data(old.utf8)).file.agents.first)
        XCTAssertNil(read.mayAct)
        XCTAssertTrue(read.draftsFirst)
        XCTAssertFalse(String(decoding: try AgentFile(agents: [read]).encoded(), as: UTF8.self).contains("mayAct"),
                       "saved again, it has no new key, so its fingerprint stays")
        var acting = read
        acting.mayAct = true
        let again = try XCTUnwrap(AgentFile.decode(AgentFile(agents: [acting]).encoded()).file.agents.first)
        XCTAssertEqual(again.mayAct, true)
        XCTAssertFalse(again.draftsFirst)
        acting.mayAct = false
        XCTAssertTrue(acting.draftsFirst)
        let payload = AgentWakePayload(event: "ready", agent: "Pennant", card: UUID(), title: "x", column: .ready, mayAct: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.json) as? [String: Any])
        XCTAssertEqual(json["may_act"] as? Bool, true)
        XCTAssertNil(payload.fields["may_act"], "never as a variable")
    }

    private func prompt(draftsFirst: Bool) -> String {
        ClaudeCodeLaunch.make(card: UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!, reason: .ready, boardName: "Claude Code · app",
                              wake: ClaudeCodeWake(repository: "/r"), binders: "/b", dataFolder: "/d", home: "/h", worktreeExists: false,
                              session: UUID(), draftsFirst: draftsFirst).prompt
    }

    func testThePromptTellsItToDraftAndAskFirst() {
        let drafting = prompt(draftsFirst: true)
        XCTAssertTrue(drafting.contains("6. Draft first.") && drafting.contains("call request_approval with what you want to do, the exact recipients and the exact text, and stop"),
                      drafting)
        XCTAssertTrue(drafting.contains("do it only if it says Approved"))
        let acting = prompt(draftsFirst: false)
        XCTAssertFalse(acting.contains("Draft first"))
        XCTAssertTrue(acting.contains("6. The user lets you send, post or buy for them"))
        for step in 1...8 {
            XCTAssertTrue(drafting.contains("\n\(step). ") && acting.contains("\n\(step). "), "step \(step)")
        }
        XCTAssertEqual(ClaudeCodeLaunch.make(card: UUID(), reason: .ready, boardName: "x", wake: ClaudeCodeWake(repository: "/r"), binders: "/b",
                                             dataFolder: "/d", home: "/h", worktreeExists: false, session: UUID()).prompt.contains("Draft first"), true,
                       "drafting first unless it's told otherwise")
    }

    func testLettingAnAgentActAsksTheIPhoneAgain() {
        let base = AgentProfile(name: "Helper", wake: .webhook(url: "https://hooks.example.test/a"))
        var off = base
        off.mayAct = false
        var on = base
        on.mayAct = true
        let fingerprint = AgentConsent.fingerprint(base, reads: .nothing)
        XCTAssertEqual(fingerprint, AgentConsent.fingerprint(off, reads: .nothing), "drafting first is how every agent starts")
        XCTAssertNotEqual(fingerprint, AgentConsent.fingerprint(on, reads: .nothing))
    }

    func testThisPhoneReadsApprovalsAndTheFirstOneDoesnt() {
        XCTAssertTrue(LinkFeatures.thisPhone.contains(LinkFeatures.notification(LinkFeatures.approvalMethod)))
        XCTAssertFalse(LinkFeatures.firstPhone.contains(LinkFeatures.notification(LinkFeatures.approvalMethod)))
        XCTAssertEqual(LinkFeatures.approvalMethod, "binders/approval")
        XCTAssertEqual(LinkFeatures.decisionMethod, "binders/decision")
    }
}
