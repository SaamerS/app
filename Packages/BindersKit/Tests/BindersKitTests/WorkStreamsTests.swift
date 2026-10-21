import XCTest
@testable import BindersKit

final class WorkStreamsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func card(_ title: String, _ column: BoardColumn, _ who: String? = nil, agent: Bool = true, for meantFor: String? = nil,
                      question: String? = nil, minutesAgo: Double = 10, finishedMinutesAgo: Double? = nil) -> WorkStreams.Card {
        WorkStreams.Card(title: title, binder: "Harbor launch", column: column, assignee: who, assigneeIsAgent: agent && who != nil,
                         meantFor: meantFor, question: question, updated: now.addingTimeInterval(-minutesAgo * 60),
                         finished: finishedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) })
    }

    func testWhoIsWorkingOnWhatAndWhatWaitsOnYou() {
        let digest = WorkStreams.digest([
            card("Draft the changelog post", .inProgress, "Claude Code", minutesAgo: 5),
            card("Fix the import timeout", .inProgress, "Claude Code", minutesAgo: 2),
            card("Reply to Delphine", .inProgress, "Pennant"),
            card("Rewrite the status page", .inProgress, "You", agent: false),
            card("Update the pricing table", .blocked, "Cursor", question: "Should annual plans show the discount?"),
            card("Write onboarding email 5", .review, "Claude Code"),
            card("Book the venue", .ready, for: "Pennant"),
            card("Migrate billing", .done, "You", agent: false, finishedMinutesAgo: 30),
            card("Old launch plan", .done, "You", agent: false, finishedMinutesAgo: 3 * 24 * 60),
            card("Someday idea", .backlog),
        ], now: now)
        XCTAssertEqual(digest.streams.map(\.who), ["Claude Code", "Pennant", "You"], "agents first, busiest first, then people")
        XCTAssertEqual(digest.streams.first?.working, ["Fix the import timeout", "Draft the changelog post"], "most recent first")
        XCTAssertEqual(digest.questions.map(\.question), ["Should annual plans show the discount?"])
        XCTAssertEqual(digest.reviews.map(\.card), ["Write onboarding email 5"])
        XCTAssertEqual(digest.queued.map(\.who), ["Pennant"])
        XCTAssertEqual(digest.doneToday, ["Migrate billing"], "only what was finished today")
        let summary = digest.summary
        XCTAssertTrue(summary.hasPrefix("Claude Code is working on 2 cards: “Fix the import timeout” and “Draft the changelog post”."), summary)
        XCTAssertTrue(summary.contains("You are working on “Rewrite the status page”."), summary)
        XCTAssertTrue(summary.contains("Cursor asks about “Update the pricing table”: Should annual plans show the discount?"), summary)
        XCTAssertTrue(summary.contains("“Write onboarding email 5” is ready for you to check."), summary)
        XCTAssertTrue(summary.contains("“Book the venue” is waiting for Pennant to pick it up."), summary)
        XCTAssertTrue(summary.hasSuffix("1 card was finished today."), summary)
    }

    func testAQuestionNamesWhoAskedEvenOnACardNobodyHolds() {
        let free = WorkStreams.Card(title: "Pick a launch date", binder: "Harbor launch", column: .blocked, question: "Tuesday or Thursday?",
                                    asker: "Pennant", updated: now)
        XCTAssertTrue(WorkStreams.digest([free], now: now).summary.hasPrefix("Pennant asks about “Pick a launch date”: Tuesday or Thursday?"))
    }

    func testAQuietBoardSaysSo() {
        XCTAssertEqual(WorkStreams.digest([card("Someday idea", .backlog)], now: now).summary, "Nothing is moving on your boards right now.")
    }

    func testTheSameBoardsAlwaysGiveTheSameAnswer() {
        let cards = [card("A", .inProgress, "Codex"), card("B", .inProgress, "Claude Code"), card("C", .inProgress, "Pennant")]
        XCTAssertEqual(WorkStreams.digest(cards, now: now), WorkStreams.digest(cards.reversed(), now: now))
        XCTAssertEqual(WorkStreams.digest(cards, now: now).streams.map(\.who), ["Claude Code", "Codex", "Pennant"], "ties by name")
    }
}

final class WorkStreamsHeadlineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ title: String, _ column: BoardColumn, _ who: String? = nil, binder: String = "Harbor launch",
                      question: String? = nil) -> WorkStreams.Card {
        WorkStreams.Card(title: title, binder: binder, column: column, assignee: who, assigneeIsAgent: who != nil && who != "You",
                         question: question, updated: now, finished: column == .done ? now : nil)
    }

    func testTheHeadlineLeadsWithWhatNeedsYouAndStaysShort() {
        var cards = [card("Update the pricing table", .blocked, "Cursor", question: "Annual discount?"),
                     card("Write onboarding email 5", .review, "Claude Code"),
                     card("Migrate billing", .done, "You")]
        for index in 0..<12 { cards.append(card("A long card title number \(index) about the harbor launch plans", .inProgress, "Agent \(index)")) }
        let headline = WorkStreams.digest(cards, now: now).headline
        XCTAssertTrue(headline.hasPrefix("Cursor asks about “Update the pricing table”. “Write onboarding email 5” is ready for you to check."), headline)
        XCTAssertLessThanOrEqual(headline.count, 240)
        XCTAssertTrue(headline.hasSuffix("."))
    }

    func testTheHeadlineWithoutTitlesKeepsCountsAndWho() {
        let cards = [card("Book the dentist", .blocked, "Pennant", question: "Which day?"),
                     card("Call Sam about the venue", .blocked, "Pennant", question: "Which venue?"),
                     card("Plan the Ignite booth", .review, "Claude Code"),
                     card("Fix the login bug", .inProgress, "Claude Code"),
                     card("Migrate billing", .done, "You")]
        let headline = WorkStreams.digest(cards, now: now).headline
        let bare = WorkStreams.withoutTitles(headline)
        for title in cards.map(\.title) { XCTAssertFalse(bare.contains(title), "“\(bare)” names “\(title)”") }
        XCTAssertEqual(bare, "Pennant asks about a card, and 1 more question. A card is ready for you to check. Claude Code on 1 card. 1 finished today.")
        let several = WorkStreams.digest([card("A", .review, "Codex"), card("B", .review, "Codex")], now: now).headline
        XCTAssertEqual(WorkStreams.withoutTitles(several), several, "counts alone have nothing to take out")
        let long = WorkStreams.digest([card(String(repeating: "Look into the quarterly numbers ", count: 4), .review, "Pennant")], now: now).headline
        XCTAssertEqual(WorkStreams.withoutTitles(long), "A card is ready for you to check.", "a clipped title goes too")
        XCTAssertEqual(WorkStreams.withoutTitles("Nothing is moving on your boards right now."), "Nothing is moving on your boards right now.")
    }

    func testATitleWithQuotesOfItsOwnLeavesNothingOver() {
        let nested = WorkStreams.digest([card("Read “Dune” tonight", .review, "Pennant")], now: now).headline
        XCTAssertEqual(WorkStreams.withoutTitles(nested), "A card is ready for you to check.")
        XCTAssertEqual(WorkStreams.withoutTitles("“Say ”hi” is ready for you to check."), "A card is ready for you to check.", "a closing quote of its own")
        XCTAssertEqual(WorkStreams.withoutTitles("“Plan” is ready. Pennant asks about “Ask ”why” x”."), "A card is ready. Pennant asks about a card.",
                       "a stray closing quote takes back only its own title")
        XCTAssertEqual(WorkStreams.withoutTitles("Pennant asks about “Read “Dune tonight”. 1 finished today."), "Pennant asks about a card. 1 finished today.",
                       "an opening quote that never closes: up to the title's last closing quote")
        XCTAssertEqual(WorkStreams.withoutTitles("Pennant asks about “Read “Dune tonight"), "Pennant asks about a card")
        XCTAssertEqual(WorkStreams.withoutTitles("“A” and “B” are ready."), "A card and a card are ready.")
    }

    func testCountsPerBinderBusiestFirst() {
        let digest = WorkStreams.digest([card("A", .inProgress, "Codex", binder: "Personal"),
                                         card("B", .inProgress, "Codex", binder: "Harbor launch"),
                                         card("C", .review, "Codex", binder: "Harbor launch")], now: now)
        XCTAssertEqual(digest.byBinder.map(\.binder), ["Harbor launch", "Personal"])
        XCTAssertEqual(digest.byBinder.first?.reviews, 1)
    }

    func testOnlyWhatHasToDoWithOneAgent() {
        let cards = [card("A", .inProgress, "Claude Code · binders-io/app"), card("B", .inProgress, "Codex"),
                     WorkStreams.Card(title: "C", binder: "Personal", column: .ready, meantFor: "Claude Code", updated: now)]
        XCTAssertEqual(WorkStreams.involving("claude code", in: cards).map(\.title), ["A", "C"])
    }
}
