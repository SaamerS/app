import XCTest
@testable import BindersKit

final class DistillProgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private typealias Card = DistillProgress.Card

    private func card(_ id: String, _ column: BoardColumn, assignee: String? = nil, agent: Bool = false, expires: Date? = nil,
                      meant: String? = nil, waits: [CardWaits.Wait] = [], finished: Date? = nil) -> Card {
        Card(id: id, title: "Card \(id)", column: column, assignee: assignee, assigneeIsAgent: agent, claimExpires: expires, meantFor: meant,
             waits: waits, updated: now, finished: finished)
    }

    func testEachCardIsInOneState() {
        let lease = now.addingTimeInterval(600)
        XCTAssertEqual(DistillProgress.state(card("1", .done), at: now), .done)
        XCTAssertEqual(DistillProgress.state(card("2", .inProgress, assignee: "Claude Code", agent: true, expires: lease), at: now), .inProgress)
        XCTAssertEqual(DistillProgress.state(card("3", .inProgress, assignee: "You"), at: now), .inProgress, "a person's claim doesn't lapse")
        XCTAssertEqual(DistillProgress.state(card("4", .blocked, assignee: "Claude Code", agent: true), at: now), .waitsOnYou)
        XCTAssertEqual(DistillProgress.state(card("5", .review, assignee: "Claude Code", agent: true), at: now), .waitsOnYou)
        XCTAssertEqual(DistillProgress.state(card("6", .ready), at: now), .notStarted)
        XCTAssertEqual(DistillProgress.state(card("7", .backlog, meant: "Pennant"), at: now), .notStarted)
    }

    func testALapsedClaimReadsAsNotStarted() {
        let lapsed = card("1", .inProgress, assignee: "Claude Code", agent: true, expires: now.addingTimeInterval(-1))
        XCTAssertEqual(DistillProgress.state(lapsed, at: now), .notStarted)
        let items = DistillProgress.items([lapsed], at: now)
        XCTAssertNil(items[0].who, "nobody holds it once the claim lapsed")
        let report = DistillProgress.report(note: "Spec", cards: [lapsed], since: nil, now: now)
        XCTAssertEqual(report.notStarted.first?.detail, "Claude Code went quiet on it")
    }

    func testACardWaitingOnAnotherIsHeldUp() {
        let first = card("1", .inProgress, assignee: "Claude Code", agent: true, expires: now.addingTimeInterval(600))
        let waiting = card("2", .ready, meant: "Claude Code", waits: [CardWaits.Wait(id: "1", title: "Card 1", column: .inProgress)])
        XCTAssertEqual(DistillProgress.state(waiting, at: now), .heldUp)
        var done = waiting
        done.waits = [CardWaits.Wait(id: "1", title: "Card 1", column: .done)]
        XCTAssertEqual(DistillProgress.state(done, at: now), .notStarted, "once what it waits for is Done, it's just not started")
        let report = DistillProgress.report(note: "Spec", cards: [first, waiting], since: nil, now: now)
        XCTAssertEqual(report.heldUp.first?.detail, "waits for “Card 1” (in progress)")
        XCTAssertEqual(DistillProgress.items([first, waiting], at: now)[1].waitsFor, ["Card 1"])
        // A person working on it while it waits: in progress, whatever it waits for.
        var taken = waiting
        taken.column = .inProgress
        taken.assignee = "You"
        XCTAssertEqual(DistillProgress.state(taken, at: now), .inProgress)
    }

    func testTheWorkBarCounts() {
        let cards = [card("1", .done), card("2", .done), card("3", .inProgress, assignee: "You"),
                     card("4", .review, assignee: "Claude Code", agent: true), card("5", .blocked, assignee: "Claude Code", agent: true),
                     card("6", .ready, waits: [CardWaits.Wait(id: "3", title: "Card 3", column: .inProgress)]), card("7", .backlog)]
        let counts = DistillProgress.counts(cards, at: now)
        XCTAssertEqual(counts, DistillProgress.Counts(total: 7, done: 2, inProgress: 1, waitsOnYou: 2, heldUp: 1, notStarted: 1))
        XCTAssertEqual(counts.line, "2 of 7 done · 1 in progress · 2 wait on you · 1 held up · 1 not started")
        XCTAssertEqual(DistillProgress.Counts(total: 12, done: 7, inProgress: 3, waitsOnYou: 1, notStarted: 1).line,
                       "7 of 12 done · 3 in progress · 1 waits on you · 1 not started", "the founder's example")
        XCTAssertEqual(DistillProgress.Counts().line, "No cards yet")
        XCTAssertEqual(DistillProgress.Counts(total: 3, done: 3).line, "3 of 3 done")
        XCTAssertTrue(DistillProgress.Counts(total: 3, done: 3).isDone)
        // A closed card counts nowhere.
        var closed = card("8", .done)
        closed.closed = true
        XCTAssertEqual(DistillProgress.counts(cards + [closed], at: now).total, 7)
    }

    func testTheReportSaysWhatsWaitingOnYouAndWhy() {
        var asked = card("1", .blocked, assignee: "Claude Code", agent: true)
        asked.question = "Should Amex be accepted?"
        asked.asker = "Claude Code"
        var approval = card("2", .blocked, assignee: "Pennant", agent: true)
        approval.question = "send the welcome email to the new starter"
        approval.asker = "Pennant"
        approval.approval = true
        var stopped = card("3", .blocked, assignee: "Codex", agent: true)
        stopped.blockedReason = "Its run stopped (exit 1) before it finished."
        let review = card("4", .review, assignee: "Claude Code", agent: true)
        let report = DistillProgress.report(note: "Checkout", cards: [asked, approval, stopped, review], since: nil, now: now)
        XCTAssertEqual(report.waiting.map(\.detail), ["Claude Code asks: Should Amex be accepted?",
                                                      "Pennant asks your approval to: send the welcome email to the new starter",
                                                      "blocked: Its run stopped (exit 1) before it finished.",
                                                      "ready for you to check, from Claude Code"])
        XCTAssertTrue(report.summary.contains("“Card 1” waits on you: Claude Code asks: Should Amex be accepted?"), report.summary)
    }

    func testFinishedSinceYouLastLookedAndWhoDidIt() {
        let looked = now.addingTimeInterval(-3_600)
        let before = card("1", .done, assignee: "Claude Code", agent: true, finished: now.addingTimeInterval(-7_200))
        let after = card("2", .done, assignee: "Claude Code", agent: true, finished: now.addingTimeInterval(-60))
        let yours = card("3", .done, assignee: "You", finished: now.addingTimeInterval(-30))
        let report = DistillProgress.report(note: "Spec", cards: [before, after, yours], since: looked, now: now)
        XCTAssertEqual(report.finished.map(\.title), ["Card 2", "Card 3"])
        XCTAssertEqual(report.finished.map(\.who), ["Claude Code", "you"])
        XCTAssertTrue(report.summary.contains("Since you last looked, Claude Code finished “Card 2”."), report.summary)
        XCTAssertTrue(report.summary.contains("You finished “Card 3”."), report.summary)
        XCTAssertTrue(report.summary.contains("Every card is done."))
        let never = DistillProgress.report(note: "Spec", cards: [before, after], since: nil, now: now)
        XCTAssertEqual(never.finished.count, 2, "never looked: everything finished counts")
        let quiet = DistillProgress.report(note: "Spec", cards: [before], since: looked, now: now)
        XCTAssertTrue(quiet.summary.contains("Nothing was finished since you last looked."))
    }

    func testInProgressSaysWhatTheAgentSaysAsItsWords() {
        var working = card("1", .inProgress, assignee: "Claude Code", agent: true, expires: now.addingTimeInterval(600))
        working.doing = "Running the tests"
        var reported = card("2", .inProgress, assignee: "Pennant", agent: true, expires: now.addingTimeInterval(600))
        reported.lastReport = "Drafted the email"
        reported.lastReportBy = "Pennant"
        let report = DistillProgress.report(note: "Spec", cards: [working, reported], since: nil, now: now)
        XCTAssertEqual(report.inProgress.map(\.detail), ["Running the tests", "Drafted the email"])
        XCTAssertTrue(report.summary.contains("Claude Code is working on “Card 1” and says: Running the tests."))
        XCTAssertTrue(report.markdown.contains("- “Card 1”: Claude Code, who says: Running the tests"))
    }

    func testSectionsChangedAndWhetherTheCardsCaughtUp() {
        var a = card("1", .inProgress, assignee: "Claude Code", agent: true, expires: now.addingTimeInterval(600))
        a.section = "Auth flow"
        a.sectionChange = DistillProgress.SectionChange(by: "Sam", at: now, added: 3, removed: 1, caughtUp: true)
        var b = card("2", .ready)
        b.section = "Auth flow"
        b.sectionChange = DistillProgress.SectionChange(by: "Sam", at: now, added: 3, removed: 1)
        let report = DistillProgress.report(note: "Spec", cards: [a, b], since: nil, now: now)
        XCTAssertEqual(report.sections.count, 1)
        XCTAssertEqual(report.sections[0].caughtUp, ["Card 1"])
        XCTAssertEqual(report.sections[0].behind, ["Card 2"])
        XCTAssertTrue(report.summary.contains("The Auth flow section changed after its cards were made, by Sam. “Card 1” caught up; “Card 2” hasn't yet."),
                      report.summary)
        XCTAssertTrue(report.markdown.contains("- Auth flow, by Sam: 3 lines added, 1 removed. Caught up: “Card 1”. Not yet: “Card 2”"), report.markdown)
        XCTAssertTrue(DistillProgress.items([a, b], at: now)[1].sectionChanged)
        XCTAssertFalse(DistillProgress.items([a, b], at: now)[0].sectionChanged)
    }

    func testTheReportIsTheSameEveryTime() {
        let cards = [card("1", .done, assignee: "You", finished: now), card("2", .ready, meant: "Pennant"), card("3", .backlog)]
        let one = DistillProgress.report(note: "Spec", cards: cards, since: nil, now: now)
        let two = DistillProgress.report(note: "Spec", cards: cards, since: nil, now: now)
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.notStarted.map(\.who), ["Pennant", nil])
        XCTAssertTrue(one.summary.hasPrefix("“Spec”: 1 of 3 done · 2 not started."))
        XCTAssertTrue(one.markdown.contains("- “Card 3”: for no one yet"))
        XCTAssertEqual(DistillProgress.report(note: "Empty", cards: [], since: nil, now: now).summary, "Nothing from “Empty” is on the board yet.")
    }

    func testAModelsWriteUpKeepsToTheReportsNumbers() {
        let cards = [card("1", .done, assignee: "You", finished: now), card("2", .ready)]
        let report = DistillProgress.report(note: "Spec", cards: cards, since: nil, now: now)
        XCTAssertTrue(DistillProgress.numbersHold("One of the two cards is done; 1 of 2.", report: report))
        XCTAssertFalse(DistillProgress.numbersHold("3 of 4 cards are done.", report: report), "a number the report doesn't have")
        XCTAssertTrue(DistillProgress.numbersHold("Half of it is done.", report: report))
    }

    func testTheReplyUsesSnakeCaseAndTheSavedCopyLeavesOutWhatRunsSay() throws {
        var working = card("1", .inProgress, assignee: "Claude Code", agent: true, expires: now.addingTimeInterval(600))
        working.doing = "Running the tests"
        let cards = [working]
        let report = DistillProgress.report(note: "Spec", cards: cards, since: nil, now: now)
        let progress = DistillProgress.Progress(note: "n", title: "Spec", binder: "Web", counts: report.counts, line: report.line,
                                                items: DistillProgress.items(cards, at: now), report: report, proposed: 2)
        let json = DistillProgress.json(progress)
        XCTAssertTrue(json.contains("\"in_progress\":"), json)
        XCTAssertTrue(json.contains("\"who_is_agent\":true"))
        XCTAssertTrue(json.contains("\"doing\":\"Running the tests\""))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertEqual(try decoder.decode(DistillProgress.Progress.self, from: Data(json.utf8)), progress, "the phone reads it back as it was")
        let kept = DistillProgress.keepable(json)
        XCTAssertFalse(kept.contains("Running the tests"), kept)
        XCTAssertNotNil(try? decoder.decode(DistillProgress.Progress.self, from: Data(kept.utf8)) as DistillProgress.Progress?)
    }

    func testAskingHowASpecIsGoing() {
        let titles = ["Checkout redesign", "Spec: New starter onboarding", "Offline mode"]
        XCTAssertEqual(DistillAsk.note(in: "How's the checkout spec going?", titles: titles), "Checkout redesign", "one word of the title is enough when it's the only match")
        XCTAssertEqual(DistillAsk.note(in: "how is the new starter onboarding going", titles: titles), "Spec: New starter onboarding")
        XCTAssertEqual(DistillAsk.note(in: "Where are we with offline mode?", titles: titles), "Offline mode")
        XCTAssertEqual(DistillAsk.note(in: "What's the status of the offline mode spec", titles: titles), "Offline mode")
        XCTAssertNil(DistillAsk.note(in: "What did we decide about checkout?", titles: titles), "not a progress question")
        XCTAssertNil(DistillAsk.note(in: "How's the pricing spec going?", titles: titles), "no such note")
    }
}
