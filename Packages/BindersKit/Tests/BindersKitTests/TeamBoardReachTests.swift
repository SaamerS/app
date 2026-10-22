import XCTest
@testable import BindersKit

/// Lane DB8: a board shared through a team database while the database is off or out of reach.
final class TeamBoardReachTests: XCTestCase {
    func testWhatTheDatabaseDecidesIsNeverQueuedAndTheRestIs() {
        let card = UUID()
        let deciding: [TeamCall] = [.claimCard(card), .moveCard(card, to: .ready), .moveCard(card, to: .done), .finish(card, summary: "Done."),
                                    .release(card), .decide(card, approve: true, device: "Mac"), .deleteCard(card),
                                    .moveCardToBinder(card, to: UUID(), keepSuggestion: false)]
        for call in deciding { XCTAssertTrue(TeamBoardWrites.decides(call), call.function) }
        let waiting: [TeamCall] = [.answer(card, text: "Looks good."), .report(card, progress: "Half way"), .ask(card, question: "Which one?"),
                                   .requestApproval(card, text: "Send it", agent: UUID()), .createCard(card, binder: UUID(), title: "New"),
                                   .assignCard(card, to: "Sam"), .addDependency(card, waitsFor: UUID()), .editCard(card, fields: ["title": "T"]),
                                   .logCard(card, .note, text: "A note"), .keepAlive(card)]
        for call in waiting { XCTAssertFalse(TeamBoardWrites.decides(call), call.function) }
    }

    func testAChangeSentLateKeepsNoClaimAliveFromWhenItArrives() throws {
        let card = UUID(), agent = UUID()
        let report = TeamCall.report(card, progress: "Drafted", links: ["https://example.com/pr/1"], agent: agent, renewing: true)
        let late = try XCTUnwrap(TeamBoardWrites.late(report))
        XCTAssertEqual(late.argument("p_renewing"), "false", "a report sent late doesn't renew the claim")
        XCTAssertEqual(late.operation, report.operation, "the same change, with the same operation id")
        XCTAssertEqual(late.argument("p_progress"), "Drafted")
        XCTAssertEqual(late.arguments.count, report.arguments.count)
        XCTAssertNil(TeamBoardWrites.late(.keepAlive(card, agent: agent)), "a check-in isn't sent late at all")
        let comment = TeamCall.answer(card, text: "On it.", agent: agent)
        XCTAssertEqual(TeamBoardWrites.late(comment), comment)
    }

    func testTheWordsSayWhyAndWhatToDo() {
        XCTAssertEqual(TeamBoardWrites.refusal(.claim, .unreachable, agent: true),
                       "This board is shared through your team's database, which this Mac can't reach right now, so the card can't be taken yet. Try again later.")
        XCTAssertEqual(TeamBoardWrites.refusal(.move(.review), .off, agent: true),
                       "This board is shared through your team's database, which is turned off on this Mac, so the card can't move to Review yet. Try again later.")
        XCTAssertEqual(TeamBoardWrites.refusal(.finish, .off, agent: false),
                       "This board is shared through your team's database, which is turned off on this Mac, so the card can't be finished yet. Turn team databases on again on this Mac first.")
        XCTAssertTrue(TeamBoardWrites.refusal(.decide, .unreachable, agent: false).hasSuffix("Check that your VPN (such as Covee) is connected, then try again."))
        XCTAssertEqual(TeamBoardWrites.refusal(.claim, .reachable, agent: true), "")
        XCTAssertEqual(TeamBoardWrites.withdrawn(.claimCard(UUID()), agent: true),
                       "The team's database didn't answer within 5 seconds, so this Mac took back the claim: nothing changed. Try again later.")
        XCTAssertTrue(TeamBoardWrites.unknown(.moveCard(UUID(), to: .done), agent: true).contains("whether the move to Done went through"))
        XCTAssertEqual(TeamRefusalLine.line(.finish(UUID(), summary: ""), by: "Agent A", reason: TeamBoardWrites.notSentLate),
                       "Agent A's finish didn't go through on the team's board: The team's database didn't answer in time, so Binders didn't send it again.")
        XCTAssertNil(TeamBoardWrites.boardLine(.reachable))
        XCTAssertNotNil(TeamBoardWrites.boardLine(.off))
        // Plain words: no exclamation marks, never "successfully".
        let all = [TeamBoardWrites.kept(.off), TeamBoardWrites.kept(.unreachable), TeamBoardWrites.notAnsweredYet, TeamBoardWrites.notSentLate,
                   TeamBoardWrites.boardLine(.off) ?? "", TeamBoardWrites.boardLine(.unreachable) ?? ""]
            + [TeamBoardWrite.claim, .move(.inProgress), .finish, .release, .decide, .answerApproval, .delete, .moveToBoard].flatMap {
                [TeamBoardWrites.refusal($0, .off, agent: true), TeamBoardWrites.refusal($0, .unreachable, agent: false)]
            }
        for words in all {
            XCTAssertFalse(words.contains("!"), words)
            XCTAssertFalse(words.lowercased().contains("successfully"), words)
        }
    }

    func testAnOutboxItemsTimeIsKeptAndAnEarlierOutboxStillReads() throws {
        let card = UUID()
        var outbox = TeamOutbox()
        let by = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(outbox.add(.claimCard(card), sendBy: by))
        XCTAssertTrue(outbox.add(.answer(card, text: "Hi")))
        let read = try TeamOutbox(data: outbox.encoded())
        XCTAssertEqual(read.items.first?.sendBy, by)
        XCTAssertNil(read.items.last?.sendBy)
        // An outbox an earlier Binders saved: no sendBy on its items.
        let call = try String(data: JSONEncoder().encode(TeamCall.answer(card, text: "Earlier")), encoding: .utf8)!
        let earlier = #"{"version":1,"items":[{"call":\#(call),"added":700000000,"attempts":0}]}"#
        let old = try TeamOutbox(data: Data(earlier.utf8))
        XCTAssertEqual(old.items.count, 1)
        XCTAssertNil(old.items.first?.sendBy)
        XCTAssertEqual(old.items.first?.call.argument("p_text"), "Earlier")
    }

    func testEveryConnectionEndsATransactionLeftOpenAndChecksItsPeer() {
        let setup = TeamQueries.sessionSetup
        XCTAssertTrue(setup.contains("'TimeZone', 'UTC'"))
        XCTAssertTrue(setup.contains("'idle_in_transaction_session_timeout', '30s'"))
        XCTAssertTrue(setup.contains("'tcp_keepalives_idle', '30'"))
        XCTAssertFalse(setup.contains(";"), "one statement: the extended protocol takes no more")
    }
}
