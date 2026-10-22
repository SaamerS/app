import XCTest
@testable import BindersKit

/// The shared board cases (Fixtures/team/board-cases.json) against the Swift rules, BoardRules, as BoardService applies
/// them: the lapse written first where BoardService.lapseIfQuiet writes it, and the timeline lines TaskEvent gets. The
/// Mac's `--selftest-teamdb-cases` runs the same cases against the team database's SQL functions.
///
/// The cases marked `waits` are about cards that wait for others: BoardRules and the SQL both have that rule, and both
/// run every case.
final class TeamBoardCasesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func load() throws -> TeamBoardCases {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "board-cases", withExtension: "json", subdirectory: "Fixtures/team"))
        return try TeamBoardCases.load(url)
    }

    func testTheFixtureReadsAndAgreesWithTheRules() throws {
        let cases = try load()
        XCTAssertEqual(cases.schema, "binders-board-cases/1")
        XCTAssertEqual(cases.lease, BoardRules.lease, "the cases' lease is the board's")
        XCTAssertEqual(Set(cases.actors.values.map(\.name)).count, cases.actors.count, "every actor has a name of its own")
        XCTAssertGreaterThanOrEqual(cases.cases.count, 80)
        XCTAssertEqual(Set(cases.cases.map(\.name)).count, cases.cases.count, "every case has a name of its own")
        // Every action is in it, and every refusal the board has.
        let actions = Set(cases.cases.map { String(describing: $0.action).prefix(while: { $0 != "(" }) })
        XCTAssertEqual(actions, ["claim", "move", "report", "keepAlive", "ask", "answer", "requestApproval", "decide", "release", "finish"])
        let refusals = Set(cases.cases.compactMap { $0.expect.refused?.code })
        XCTAssertTrue(refusals.isSuperset(of: ["claimed_by", "agents_cannot_finish", "not_yours", "finished", "waits_for", "not_an_agent",
                                               "nothing_waits", "changed", "not_you", "not_yours_to_decide"]), "\(refusals)")
        for item in cases.cases {
            XCTAssertNotNil(cases.actor(item.by), "\(item.name): who acts")
            if let holder = item.card.holder { XCTAssertNotNil(cases.actor(holder), "\(item.name): who holds it") }
            if let meant = item.card.meantFor { XCTAssertNotNil(cases.actor(meant), "\(item.name): who it's for") }
            for line in item.expect.events { XCTAssertNotNil(cases.actor(line.by), "\(item.name): who wrote \(line)") }
        }
        // Every agent belongs to a person, as every agent in the team does: who decides on what it asks approval for.
        for (key, actor) in cases.actors where actor.kind == .agent {
            XCTAssertEqual(actor.owner.flatMap { cases.actors[$0]?.kind }, .person, "\(key) has an owner")
        }
    }

    func testTheSwiftRulesGiveEveryCasesResult() throws {
        let cases = try load()
        var ran = 0
        for item in cases.cases {
            ran += 1
            let outcome = SwiftBoard(cases: cases, now: now).run(item)
            let expected = item.expect
            XCTAssertEqual(outcome.refusal, expected.refused, "\(item.name): the refusal")
            let card = expected.card ?? (expected.refused != nil ? item.card : nil)
            if let card {
                XCTAssertEqual(outcome.state.column, card.column, "\(item.name): the column")
                XCTAssertEqual(outcome.state.assignee, card.holder.flatMap { cases.actor($0)?.name }, "\(item.name): who holds it")
                XCTAssertEqual(outcome.state.assigneeIsAgent, card.holder.flatMap { cases.actor($0)?.isAgent } ?? false,
                               "\(item.name): whether an agent holds it")
                XCTAssertEqual(outcome.state.claimExpires, card.lease.map { now.addingTimeInterval($0) }, "\(item.name): the lease")
            }
            XCTAssertEqual(outcome.events, expected.events, "\(item.name): the timeline")
        }
        XCTAssertGreaterThan(ran, 80)
        XCTAssertGreaterThan(cases.cases.filter(\.waits).count, 0)
        print("TeamBoardCasesTests: \(ran) cases against BoardRules, waiting cards included")
    }
}

/// BoardService's use of BoardRules, for the cases: the same rules in the same order, with the lines the timeline gets.
struct SwiftBoard {
    struct Outcome {
        var state: CardState
        var events: [TeamBoardCase.Line]
        var refusal: TeamBoardCase.Refusal?
    }

    let cases: TeamBoardCases
    let now: Date

    func run(_ item: TeamBoardCase) -> Outcome {
        let actor = cases.actor(item.by)!
        let holder = item.card.holder.flatMap { cases.actor($0) }
        var state = CardState(column: item.card.column, assignee: holder?.name, assigneeIsAgent: holder?.isAgent ?? false,
                              claimExpires: item.card.lease.map { now.addingTimeInterval($0) })
        var events: [TeamBoardCase.Line] = []
        let timeline = item.card.timeline.map { (kind: $0.kind, to: $0.to ?? "") }
        // What it still waits for, as BoardService passes it: one name for each card it waits for that isn't Done.
        let waitingOn = item.card.waitsFor.filter { $0 != .done }.map(\.rawValue)

        func line(_ kind: String, _ author: String, from: BoardColumn? = nil, to: BoardColumn? = nil, _ text: String = "") {
            events.append(TeamBoardCase.Line(kind: kind, by: author, from: from?.rawValue, to: to?.rawValue, text: text))
        }
        func refused(_ code: String, holder: String? = nil, until: Date? = nil, deciders: [String]? = nil) -> Outcome {
            Outcome(state: state, events: events, refusal: TeamBoardCase.Refusal(
                code: code, holder: holder.flatMap { cases.key(named: $0) }, until: until.map { $0.timeIntervalSince(now) }, deciders: deciders))
        }
        /// Whether whoever acts decides on the approval the card waits on, when that's what it waits on (BoardRules.deciders):
        /// on someone else's, their words are a comment. Nil when nothing waits for an approval.
        func deciders() -> [String]? {
            guard state.column == .blocked, let index = BoardRules.waitingApproval(in: timeline) else { return nil }
            return cases.deciders(of: item.card, askedBy: item.card.timeline[index].by)
        }
        func refused(_ error: Error) -> Outcome {
            switch error as? BoardError {
            case .claimedBy(let name, let until): refused("claimed_by", holder: name, until: until)
            case .agentsCannotFinish: refused("agents_cannot_finish")
            case .notYours(let name): refused("not_yours", holder: name)
            case .finished: refused("finished")
            case .waitsFor: refused("waits_for")
            case nil: refused("unknown: \(error)")
            }
        }
        // BoardService.lapseIfQuiet: a card whose agent went quiet is let go before someone else acts on it.
        func lapseIfQuiet() {
            guard state.assignee != actor.name, let next = BoardRules.expire(state, at: now) else { return }
            let who = state.assignee ?? "The agent"
            let before = state.column
            state = next
            line("lapsed", cases.key(named: who) ?? who, from: before, to: state.column,
                 "\(who) went quiet for \(Int(BoardRules.lease / 60)) minutes, so the card is free again.")
        }
        let by = item.by

        do {
            switch item.action {
            case .claim:
                let before = state.column
                let from = BoardRules.isClaimed(state, at: now) ? state.assignee.flatMap { $0 == actor.name ? nil : $0 } : nil
                state = try BoardRules.claim(state, by: actor, at: now, waitingOn: waitingOn)
                line("claimed", by, from: before, to: state.column, from.map { "Took it over from \($0)." } ?? "")
            case .move(let column):
                guard state.column != column else { break }
                lapseIfQuiet()
                let before = state.column
                guard before != column else { break }
                state = try BoardRules.move(state, to: column, by: actor, agentsMayFinish: item.agentsMayFinish, at: now, waitingOn: waitingOn)
                let sentBack = !actor.isAgent && before == .review && column == .inProgress && state.assigneeIsAgent
                line("moved", by, from: before, to: column, sentBack ? "Sent back to \(state.assignee ?? "the agent")." : "")
            case .report(let text, let links, let renewing):
                let added = links.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if renewing { state = BoardRules.renew(state, by: actor, at: now) }
                var words = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !added.isEmpty { words += (words.isEmpty ? "" : "\n") + added.map { "→ \($0)" }.joined(separator: "\n") }
                line("progress", by, words)
            case .keepAlive:
                state = BoardRules.renew(state, by: actor, at: now)
            case .ask(let question):
                lapseIfQuiet()
                let before = state.column
                state = try BoardRules.ask(state, by: actor, at: now)
                line("question", by, from: before, to: state.column, question)
            case .answer(let text):
                let before = state.column
                let decides = deciders().map { $0.contains(by) } ?? true
                state = BoardRules.answered(BoardRules.renew(state, by: actor, at: now), by: actor, at: now, decides: decides)
                let answered = before == .blocked && state.column != .blocked
                line(answered ? "answer" : "comment", by, from: answered ? before : nil, to: answered ? state.column : nil, text)
            case .requestApproval(let text):
                guard actor.isAgent else { return refused("not_an_agent") }
                lapseIfQuiet()
                let before = state.column
                state = try BoardRules.ask(state, by: actor, at: now)
                line("approval", by, from: before, to: state.column, text)
            case .decide(let approve, let reason, let approval, let receipt):
                guard !actor.isAgent else { return refused("not_you") }
                guard state.column == .blocked, let index = BoardRules.waitingApproval(in: timeline), let deciders = deciders() else {
                    return refused("nothing_waits")
                }
                guard deciders.contains(by) else { return refused("not_yours_to_decide", deciders: deciders) }
                if approval == .stale { return refused("changed") }
                line("decision", "Binders", receipt ?? item.card.timeline[index].text)
                let before = state.column
                state = BoardRules.answered(state, by: actor, at: now)
                line("answer", by, from: before, to: state.column, AgentApproval.answer(approved: approve, reason: reason))
            case .release(let note):
                let before = state.column
                state = try BoardRules.release(state, by: actor, at: now)
                line("released", by, from: before, to: state.column, note)
            case .finish(let summary):
                let before = state.column
                state = try BoardRules.complete(state, by: actor, agentsMayFinish: item.agentsMayFinish, at: now, waitingOn: waitingOn)
                line("completed", by, from: before, to: state.column, summary)
            }
        } catch {
            return refused(error)
        }
        return Outcome(state: state, events: events, refusal: nil)
    }
}
