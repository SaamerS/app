import XCTest
@testable import BindersKit

final class BoardTests: XCTestCase {
    private let agentA = BoardActor(name: "Claude Code · repo", kind: .agent)
    private let agentB = BoardActor(name: "Cursor", kind: .agent)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClaimingStartsWorkAndALease() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        XCTAssertEqual(card.column, .inProgress)
        XCTAssertEqual(card.assignee, agentA.name)
        XCTAssertEqual(card.claimExpires, now.addingTimeInterval(BoardRules.lease))
        let mine = try BoardRules.claim(CardState(column: .backlog), by: .you, at: now)
        XCTAssertNil(mine.claimExpires, "people's claims don't lapse")
    }

    func testOnlyOneOwnerAtATime() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        XCTAssertThrowsError(try BoardRules.claim(card, by: agentB, at: now.addingTimeInterval(60))) {
            guard case BoardError.claimedBy(let name, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(name, self.agentA.name)
        }
        XCTAssertNoThrow(try BoardRules.claim(card, by: agentA, at: now.addingTimeInterval(60)), "claiming again renews")
        // Once the lease lapses, anyone can take it.
        XCTAssertNoThrow(try BoardRules.claim(card, by: agentB, at: now.addingTimeInterval(BoardRules.lease + 1)))
    }

    func testAgentsHandOverForReview() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        XCTAssertThrowsError(try BoardRules.move(card, to: .done, by: agentA, agentsMayFinish: false, at: now)) {
            XCTAssertEqual($0 as? BoardError, .agentsCannotFinish)
        }
        let handed = try BoardRules.complete(card, by: agentA, agentsMayFinish: false, at: now)
        XCTAssertEqual(handed.column, .review)
        XCTAssertEqual(handed.assignee, agentA.name, "keeps who did it")
        XCTAssertNil(handed.claimExpires)
        XCTAssertEqual(try BoardRules.complete(card, by: agentA, agentsMayFinish: true, at: now).column, .done)
        XCTAssertEqual(try BoardRules.move(handed, to: .done, by: .you, agentsMayFinish: false, at: now).column, .done, "you approve")
    }

    func testAgentsCantTouchSomeoneElsesCard() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        XCTAssertThrowsError(try BoardRules.move(card, to: .review, by: agentB, agentsMayFinish: true, at: now))
        XCTAssertThrowsError(try BoardRules.release(card, by: agentB, at: now))
        XCTAssertThrowsError(try BoardRules.complete(card, by: agentB, agentsMayFinish: true, at: now))
        // You can always take over.
        let released = try BoardRules.release(card, by: .you, at: now)
        XCTAssertNil(released.assignee)
        XCTAssertEqual(released.column, .ready)
    }

    func testAskingBlocksUntilAPersonAnswers() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        let asked = try BoardRules.ask(card, by: agentA, at: now.addingTimeInterval(600))
        XCTAssertEqual(asked.column, .blocked)
        XCTAssertNil(asked.claimExpires, "the claim holds while it waits")
        let later = now.addingTimeInterval(600 + 3 * BoardRules.lease)
        XCTAssertNil(BoardRules.expire(asked, at: later), "an unanswered question doesn't send the card back to Ready")
        XCTAssertTrue(BoardRules.isClaimed(asked, at: later))
        XCTAssertThrowsError(try BoardRules.claim(asked, by: agentB, at: later), "another agent can't take it while it waits")
        XCTAssertEqual(BoardRules.renew(asked, by: agentA, at: later), asked, "reporting in while it waits changes nothing")
        XCTAssertEqual(BoardRules.answered(asked, by: agentB, at: later).column, .blocked, "only a person's answer unblocks")
        let answered = BoardRules.answered(asked, by: .you, at: later)
        XCTAssertEqual(answered.column, .inProgress)
        XCTAssertEqual(answered.assignee, agentA.name)
        XCTAssertEqual(answered.claimExpires, later.addingTimeInterval(BoardRules.lease), "the answer starts a fresh lease")
        XCTAssertEqual(BoardRules.answered(try BoardRules.ask(CardState(column: .ready), by: agentA, at: now), by: .you, at: now).column, .ready,
                       "a question nobody holds goes back to Ready")
    }

    func testBlockedCardsFromBeforeKeepTheirAgent() throws {
        // Asked before the claim held in Blocked: the old lease is long gone.
        let asked = CardState(column: .blocked, assignee: agentA.name, assigneeIsAgent: true, claimExpires: now)
        let later = now.addingTimeInterval(86_400)
        XCTAssertNil(BoardRules.expire(asked, at: later))
        XCTAssertTrue(BoardRules.isClaimed(asked, at: later))
        XCTAssertEqual(BoardRules.answered(asked, by: .you, at: later).claimExpires, later.addingTimeInterval(BoardRules.lease))
    }

    func testYouCanTakeOverAnyCard() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        let mine = try BoardRules.claim(card, by: .you, at: now.addingTimeInterval(60))
        XCTAssertEqual(mine.assignee, "You")
        XCTAssertFalse(mine.assigneeIsAgent)
        XCTAssertNil(mine.claimExpires, "people's claims don't lapse")
        XCTAssertEqual(mine.column, .inProgress)
        XCTAssertThrowsError(try BoardRules.claim(mine, by: agentA, at: now.addingTimeInterval(120)), "the agent can't take it back")
        // Taking over a card that waits for an answer means working on it.
        let asked = try BoardRules.ask(card, by: agentA, at: now)
        XCTAssertEqual(try BoardRules.claim(asked, by: .you, at: now).column, .inProgress)
    }

    func testSendingBackRestartsTheAgentsLease() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        let handed = try BoardRules.complete(card, by: agentA, agentsMayFinish: false, at: now)
        let sentAt = now.addingTimeInterval(3_600)
        let sentBack = try BoardRules.move(handed, to: .inProgress, by: .you, agentsMayFinish: false, at: sentAt)
        XCTAssertEqual(sentBack.column, .inProgress)
        XCTAssertEqual(sentBack.assignee, agentA.name, "it goes back to the agent that did it")
        XCTAssertEqual(sentBack.claimExpires, sentAt.addingTimeInterval(BoardRules.lease))
        // An agent that doesn't pick it up again lets it go.
        let lapsed = BoardRules.expire(sentBack, at: sentAt.addingTimeInterval(BoardRules.lease))
        XCTAssertEqual(lapsed?.column, .ready)
        XCTAssertNil(lapsed?.assignee)
        // Moved to Blocked by hand, the agent's claim holds there too.
        let waiting = try BoardRules.move(sentBack, to: .blocked, by: .you, agentsMayFinish: false, at: sentAt)
        XCTAssertNil(waiting.claimExpires)
        XCTAssertNil(BoardRules.expire(waiting, at: sentAt.addingTimeInterval(86_400)))
    }

    func testReviewWaitsOnYouHoweverItGotThere() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        // Handed over and reported on after, dragged to Review by you, or handed over before Review held its agent.
        let reported = BoardRules.renew(try BoardRules.complete(card, by: agentA, agentsMayFinish: false, at: now), by: agentA, at: now)
        let dragged = try BoardRules.move(card, to: .review, by: .you, agentsMayFinish: false, at: now)
        let older = CardState(column: .review, assignee: agentA.name, assigneeIsAgent: true, claimExpires: now)
        XCTAssertNil(reported.claimExpires, "reporting on a card in Review starts no clock")
        XCTAssertNil(dragged.claimExpires)
        let later = now.addingTimeInterval(2 * BoardRules.lease)
        for waiting in [reported, dragged, older] {
            XCTAssertTrue(BoardRules.isClaimed(waiting, at: later), "Review waits on you, so the agent keeps it")
            XCTAssertNil(BoardRules.expire(waiting, at: later))
            XCTAssertThrowsError(try BoardRules.claim(waiting, by: agentB, at: later), "another agent can't take it")
            let sentBack = try BoardRules.move(waiting, to: .inProgress, by: .you, agentsMayFinish: false, at: later)
            XCTAssertEqual(sentBack.assignee, agentA.name, "Send Back goes to the agent that did it")
            XCTAssertEqual(sentBack.claimExpires, later.addingTimeInterval(BoardRules.lease))
        }
        XCTAssertNil(try BoardRules.claim(reported, by: agentA, at: later).claimExpires, "taking its own card in Review again starts no clock")
    }

    func testAgentsAskOnlyAboutCardsThatAreFreeOrTheirs() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        XCTAssertThrowsError(try BoardRules.ask(card, by: agentB, at: now)) {
            guard case BoardError.claimedBy(let name, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(name, self.agentA.name)
        }
        XCTAssertEqual(try BoardRules.ask(card, by: agentA, at: now).column, .blocked)
        XCTAssertEqual(try BoardRules.ask(CardState(column: .ready), by: agentB, at: now).column, .blocked, "a free card can be asked about")
        let asked = try BoardRules.ask(card, by: agentA, at: now)
        XCTAssertNil(try BoardRules.claim(asked, by: agentA, at: now).claimExpires, "taking its own card again while it waits starts no clock")
    }

    func testRefusalsNameTheUser() {
        XCTAssertEqual(BoardError.claimedBy("You", until: nil).errorDescription, "The user has this. Pick another card, or ask them to release it.")
        XCTAssertEqual(BoardError.claimedBy(agentA.name, until: nil).errorDescription?.hasPrefix(agentA.name), true)
        XCTAssertEqual(BoardError.notYours("You").errorDescription?.hasPrefix("The user has this card"), true)
    }

    func testTheQuestionACardWaitsOn() {
        func events(_ pairs: [(String, String)]) -> [(kind: String, to: String)] { pairs.map { (kind: $0.0, to: $0.1) } }
        XCTAssertEqual(BoardRules.waitingQuestion(in: events([("created", "ready"), ("claimed", "in_progress"), ("question", "blocked"),
                                                              ("progress", ""), ("comment", "")])), 2)
        XCTAssertNil(BoardRules.waitingQuestion(in: events([("question", "blocked"), ("answer", "in_progress"), ("moved", "blocked")])),
                     "answered, then moved back to Blocked by hand")
        XCTAssertNil(BoardRules.waitingQuestion(in: events([("question", "blocked"), ("claimed", "in_progress"), ("moved", "blocked")])),
                     "taken over, then moved back")
        XCTAssertEqual(BoardRules.waitingQuestion(in: events([("question", "blocked"), ("answer", "in_progress"), ("question", "blocked")])), 2,
                       "asked again")
        XCTAssertNil(BoardRules.waitingQuestion(in: events([("moved", "blocked")])), "blocked without a question")
    }

    func testAQuestionsKeyIgnoresTheMacsTimeZone() {
        XCTAssertEqual(BoardRules.questionKey(card: "C", asked: "2026-10-16T10:00:00+02:00"), BoardRules.questionKey(card: "C", asked: "2026-10-16T08:00:00Z"))
        XCTAssertNotEqual(BoardRules.questionKey(card: "C", asked: "2026-10-16T08:00:00Z"), BoardRules.questionKey(card: "C", asked: "2026-10-16T08:00:01Z"))
        XCTAssertNotEqual(BoardRules.questionKey(card: "C", asked: "2026-10-16T08:00:00Z"), BoardRules.questionKey(card: "D", asked: "2026-10-16T08:00:00Z"))
        XCTAssertEqual(BoardRules.questionKey(card: "C", asked: "soon"), "C|soon", "a time it can't read is kept as it is")
    }

    func testQuestionKeysShareOneParser() {
        // The iPhone works out a key for every agent's question it looks at, and its own dates go through the same parser.
        XCTAssertEqual(BoardRules.isoParser.formatOptions, .withInternetDateTime, "the options everything that shares it reads by")
        let asked = "2026-10-16T10:00:00+02:00"
        let instant = BoardRules.isoParser.date(from: asked)?.timeIntervalSince1970
        XCTAssertEqual(instant, 1_792_137_600)
        // Shared by every caller at once, it reads each the same.
        var keys = [String](repeating: "", count: 200)
        keys.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: 200) { index in
                base[index] = BoardRules.questionKey(card: "C\(index % 4)", asked: index % 2 == 0 ? asked : "2026-10-16T08:00:00Z")
            }
        }
        XCTAssertEqual(Set(keys), ["C0|1792137600", "C1|1792137600", "C2|1792137600", "C3|1792137600"])
    }

    func testQuietAgentsLoseTheirCard() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        XCTAssertNil(BoardRules.expire(card, at: now.addingTimeInterval(60)))
        let lapsed = BoardRules.expire(card, at: now.addingTimeInterval(BoardRules.lease))
        XCTAssertEqual(lapsed?.column, .ready)
        XCTAssertNil(lapsed?.assignee)
        let reported = BoardRules.renew(card, by: agentA, at: now.addingTimeInterval(20 * 60))
        XCTAssertNil(BoardRules.expire(reported, at: now.addingTimeInterval(BoardRules.lease)), "reporting in extends the lease")
        let mine = try BoardRules.claim(CardState(column: .ready), by: .you, at: now)
        XCTAssertNil(BoardRules.expire(mine, at: now.addingTimeInterval(86_400)))
    }

    func testMovingBackToTheQueueLetsGo() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        let back = try BoardRules.move(card, to: .ready, by: agentA, agentsMayFinish: false, at: now)
        XCTAssertNil(back.assignee)
        let started = try BoardRules.move(CardState(column: .ready), to: .inProgress, by: .you, agentsMayFinish: false, at: now)
        XCTAssertEqual(started.assignee, "You", "starting work means taking it")
        XCTAssertThrowsError(try BoardRules.claim(CardState(column: .done), by: .you, at: now))
    }

    func testLooseColumnNamesAndAgentNames() {
        XCTAssertEqual(BoardColumn(loose: "In Progress"), .inProgress)
        XCTAssertEqual(BoardColumn(loose: "in_progress"), .inProgress)
        XCTAssertEqual(BoardColumn(loose: "doing"), .inProgress)
        XCTAssertEqual(BoardColumn(loose: "Ready for review"), .review)
        XCTAssertNil(BoardColumn(loose: "someday maybe"))
        XCTAssertEqual(BoardRules.agentName(fromClient: "claude-code"), "Claude Code")
        XCTAssertEqual(BoardRules.agentName(fromClient: ""), "AI agent")
    }

    func testANameAndItsParticularForms() {
        XCTAssertTrue(BoardRules.isNamed("Claude Code", as: "Claude Code"))
        XCTAssertTrue(BoardRules.isNamed("Claude Code · binders-io/app", as: "claude code"))
        XCTAssertFalse(BoardRules.isNamed("Claude Codex", as: "Claude Code"))
        XCTAssertFalse(BoardRules.isNamed("Claude Code", as: ""))
    }

    func testNoAgentGoesByTheUsersName() {
        XCTAssertTrue(BoardRules.isReserved("You"))
        XCTAssertTrue(BoardRules.isReserved(" you "))
        XCTAssertTrue(BoardRules.isReserved("You · helper"))
        XCTAssertFalse(BoardRules.isReserved("Your assistant"))
        XCTAssertEqual(BoardRules.agentName(fromClient: "you"), "AI agent")
    }

    func testWhatsWorthTellingYouAboutACard() {
        func news(_ before: BoardColumn?, _ now: BoardColumn, byAgent: Bool = true, for meantFor: String? = nil, confirmed: Bool = false) -> BoardNews? {
            BoardRules.news(before: before, now: now, byAgent: byAgent, meantFor: meantFor, confirmed: confirmed)
        }
        // Picked up: an agent took a card you handed it.
        XCTAssertEqual(news(.ready, .inProgress, for: "Claude Code", confirmed: true), .pickedUp, "an agent claims a card you meant for it")
        XCTAssertEqual(news(.backlog, .inProgress, for: "Claude Code", confirmed: true), .pickedUp)
        XCTAssertEqual(news(nil, .inProgress, for: "Claude Code", confirmed: true), .pickedUp, "first seen already picked up")
        XCTAssertNil(news(.ready, .inProgress), "a card nobody was meant to have")
        XCTAssertNil(news(.ready, .inProgress, for: "Claude Code", confirmed: false), "only an agent's suggestion")
        XCTAssertNil(news(.ready, .inProgress, for: " ", confirmed: true))
        XCTAssertNil(news(.blocked, .inProgress, for: "Claude Code", confirmed: true), "back to work after an answer")
        XCTAssertNil(news(.inProgress, .inProgress, for: "Claude Code", confirmed: true), "claiming its own card again")
        // Ready for review: an agent finished.
        XCTAssertEqual(news(.inProgress, .review), .review, "an agent completes a card")
        XCTAssertEqual(news(nil, .review), .review)
        XCTAssertEqual(news(.inProgress, .review, for: "Claude Code", confirmed: true), .review)
        XCTAssertNil(news(.review, .review), "nothing moved")
        // Your own moves, and the rest.
        XCTAssertNil(news(.inProgress, .review, byAgent: false), "your own move")
        XCTAssertNil(news(.ready, .inProgress, byAgent: false, for: "Pennant", confirmed: true))
        XCTAssertNil(news(.review, .inProgress, for: "Claude Code", confirmed: true), "Review back to In progress")
        XCTAssertNil(news(.review, .inProgress, byAgent: false, for: "Claude Code", confirmed: true))
        XCTAssertNil(news(.inProgress, .done))
        XCTAssertNil(news(.inProgress, .blocked))
    }
}
