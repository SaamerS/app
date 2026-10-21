import XCTest
@testable import BindersKit

/// Laya english's and Laya typed-decisions' bench runs (Fixtures/router/measure-laya.json, written by lane Y1's
/// make_laya_fixture.py from dm/results): titles alone, with General offered as an option, whose probability is kept apart;
/// the binders and agents in the order the app offers them. Everything in it is the bench's made-up library.
struct LayaFixture: Decodable {
    struct Run: Decodable {
        let dev: [MeasureFixture.Item]
        let test: [MeasureFixture.Item]
    }

    let general: String
    let binders: [String]
    let agents: [String]
    let takes: [String: [String]?]
    let models: [String: Run]

    static func load() throws -> LayaFixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "measure-laya", withExtension: "json", subdirectory: "Fixtures/router"))
        return try JSONDecoder().decode(LayaFixture.self, from: Data(contentsOf: url))
    }

    var library: RouterBench.Library { MeasureFixture.library(general: general, binders: binders, agents: agents, takes: takes) }
}

/// MeasureRules.auto: Auto's level for a model from its own measure, counting only what Auto would hand to an agent that
/// drafts first. On lane R1's Swift runs of Tev1 0.8B bf16 it must give 0.60 with dev 23 picks, 19 right, and test 31, all
/// right (lane Y1's DESIGN.md 3.1 and 10.2, auto_rule.py), and nothing for Laya's two runs.
final class MeasureAutoTests: XCTestCase {
    private func tev1(verdictBefore: (level: Double?, noAuto: MeasureRules.NoAuto?)? = nil) throws -> MeasureRules.AutoOutcome {
        let fixture = try MeasureFixture.load()
        return MeasureRules.auto(dev: try MeasureFixture.autoAnswers(fixture.devBoth), test: try MeasureFixture.autoAnswers(fixture.test),
                                 bands: fixture.measure().bands, library: fixture.library, verdictBefore: verdictBefore)
    }

    func testTev1sLevelIs060() throws {
        let auto = try tev1()
        XCTAssertEqual(auto.level, 0.60)
        XCTAssertNil(auto.noAuto)
        XCTAssertEqual(auto.countedAt, 0.60)
        XCTAssertEqual(auto.dev, DecisionMeasure.AutoCounts(picks: 23, right: 19, falseAssignments: 1, named: 4, namedRight: 4))
        XCTAssertEqual(auto.test, DecisionMeasure.AutoCounts(picks: 31, right: 31, falseAssignments: 0, named: 6, namedRight: 6))
        XCTAssertEqual(DecisionMeasure.Auto(dev: auto.dev, test: auto.test), DecisionBands.tev1?.auto, "the built-in entry's counts are the rule's")
        // Dev alone would have taken 0.50: test's picks in the band from 0.50 to 0.60 raised it, and that verdict holds.
        XCTAssertEqual(auto.devLevel, 0.50)
        XCTAssertEqual(auto.raisedTo, 0.60)
        XCTAssertNil(auto.tookAway)
        let verdict = auto.testVerdict(for: DecisionBands.tev1BF16, at: Date(timeIntervalSince1970: 1_792_431_731))
        XCTAssertEqual(verdict?.autoLevel, 0.60)
        XCTAssertNil(verdict?.noStart, "it says nothing about starting")
    }

    func testTheLeastSureBand() throws {
        let fixture = try MeasureFixture.load()
        let bands = fixture.measure().bands
        let picks = MeasureRules.autoPicks(try MeasureFixture.autoAnswers(fixture.devBoth) + MeasureFixture.autoAnswers(fixture.test),
                                           library: fixture.library, bands: bands).filter { !$0.named }
        func band(_ low: Double, _ high: Double) -> [Int] {
            let inside = picks.filter { $0.p >= low && $0.p < high }
            return [inside.count, inside.filter(\.right).count]
        }
        XCTAssertEqual(band(0.50, 0.60), [10, 6], "6 right in 10: no better than a coin, so not 0.50")
        XCTAssertEqual(band(0.60, 0.70), [12, 11], "11 in 12 holds at 0.60")
        XCTAssertEqual(band(0.70, 0.80), [14, 14])
        XCTAssertEqual(band(0.80, 0.90), [10, 8])
        XCTAssertEqual(band(0.90, 1.0001), [18, 17])
        // Every pick at the level or above goes to an agent that drafts first.
        XCTAssertTrue(picks.allSatisfy { MeasureFixture.benchDraftsFirst.contains($0.agent) })
        XCTAssertEqual(MeasureFixture.benchDraftsFirst, ["Claude Code · pocketfold-app", "Codex · pocketfold-site", "Grok Bot", "Inkwell"])
    }

    func testTheGuardsTakeAwayWhatTheAppWouldNotHandOver() throws {
        let fixture = try MeasureFixture.load()
        let picks = MeasureRules.autoPicks(try MeasureFixture.autoAnswers(fixture.devBoth) + MeasureFixture.autoAnswers(fixture.test),
                                           library: fixture.library, bands: fixture.measure().bands)
        let ids = Set(picks.map(\.id))
        // Only mentioned: "Codex did a nice job on the pricing table, tell Sam", "Let Chris know Grok Bot can do…", "Look over what
        // Claude Code changed…" (guard_effect.py: three false assignments, nothing right).
        for id in ["mention-16", "mention-14", "mention-03"] { XCTAssertFalse(ids.contains(id), id) }
        // Notes never get an agent.
        let notes = try MeasureFixture.autoAnswers(fixture.devBoth + fixture.test).filter { $0.kind == "note" }.map(\.id)
        XCTAssertFalse(notes.isEmpty)
        XCTAssertTrue(ids.isDisjoint(with: notes))
        // A name decides: test explicit-20 goes to Grok Bot, whatever the model's top; dev explicit-01's Codex doesn't take its binder.
        XCTAssertEqual(picks.first { $0.id == "explicit-20" }?.agent, "Grok Bot")
        XCTAssertEqual(picks.first { $0.id == "explicit-20" }?.named, true)
        XCTAssertFalse(ids.contains("explicit-01"))
        // The misspelt names: heard, never another agent's.
        let items = try RouterBenchDataTests.bench().items
        for pick in picks where pick.id.hasPrefix("noisy-") {
            let item = try XCTUnwrap(items.first { $0.id == pick.id })
            let heard = NamedAgents.heard(in: [item.text], agents: MeasureFixture.benchAgents).map(\.agent)
            XCTAssertTrue(heard.allSatisfy { $0 == pick.agent }, pick.id)
        }
    }

    func testLayasTwoRunsGetNoLevel() throws {
        let laya = try LayaFixture.load()
        XCTAssertEqual(laya.models.keys.sorted(), ["laya_english", "laya_typed_decisions"])
        XCTAssertEqual(laya.library, try RouterBenchDataTests.bench().library, "the options in the app's order")
        for (name, run) in laya.models.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual([run.dev.count, run.test.count], [111, 167], name)
            let dev = try MeasureFixture.autoAnswers(run.dev), test = try MeasureFixture.autoAnswers(run.test)
            // Its own measure's bands: titles alone was the only form run, so it stands for both.
            let measured = MeasureRules.measure(devBoth: dev, devTitles: dev, test: test, library: laya.library)
            let own = MeasureRules.auto(dev: dev, test: test, bands: measured.bands, library: laya.library)
            XCTAssertNil(own.level, name)
            XCTAssertEqual(own.noAuto, .devFew, "\(name): on dev it would hand an agent that drafts first nothing on its own judgment")
            XCTAssertEqual(own.dev, DecisionMeasure.AutoCounts(picks: 0, right: 0, falseAssignments: 0, named: 4, namedRight: 4), name)
            // At the suggest band auto_rule.py takes for every model, and every binder its best one, as Laya's runs were read:
            // on dev it hands an agent that drafts first fewer than 5 things on its own judgment.
            let script = RouterBands(start: nil, suggest: 0.50, generalBelow: 0, generalBelowTitlesOnly: 0)
            let atHalf = MeasureRules.auto(dev: dev, test: test, bands: script, library: laya.library)
            XCTAssertNil(atHalf.level, name)
            XCTAssertEqual(atHalf.noAuto, .devFew, name)
            XCTAssertEqual(atHalf.dev.picks, 0, name)
            XCTAssertEqual(atHalf.test.picks, 2, "\(name): as auto_rule.py counts it")
            XCTAssertNil(atHalf.testVerdict(for: DecisionBands.tev1BF16, at: Date()), "dev took it, not test: no verdict")
        }
    }

    func testAVerdictBefore() throws {
        let raised = try tev1(verdictBefore: (0.70, nil))
        XCTAssertEqual(raised.level, 0.70, "no lower than the level a test raised it to")
        XCTAssertEqual(raised.dev.picks, 16)
        XCTAssertEqual(raised.test.picks, 26)
        XCTAssertNil(raised.raisedTo, "this test raised nothing more")
        let took = try tev1(verdictBefore: (nil, .testShare))
        XCTAssertNil(took.level)
        XCTAssertEqual(took.noAuto, .testBefore)
        XCTAssertNil(took.testVerdict(for: DecisionBands.tev1BF16, at: Date()), "the verdict holds already")
    }

    func testTheRecordKeepsAutosLevelAndItsCounts() throws {
        let fixture = try MeasureFixture.load()
        let outcome = fixture.measure()
        let auto = try tev1()
        let at = Date(timeIntervalSince1970: 1_792_431_731)
        let record = DecisionMeasure(identity: DecisionBands.tev1BF16, outcome: outcome, at: at, build: "26", mac: "Mac17,6, Apple M5 Max",
                                     golden: DecisionBands.tev1?.golden, letterShare: nil, auto: auto)
        XCTAssertEqual(record.bands?.auto, 0.60)
        XCTAssertNil(record.noAuto)
        XCTAssertEqual(record.auto, DecisionBands.tev1?.auto)
        XCTAssertFalse(record.measuredBeforeAuto)
        XCTAssertEqual(DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures(measures: [record])).bands, DecisionBands.tev1?.bands)
        let without = DecisionMeasure(identity: DecisionBands.tev1BF16, outcome: outcome, at: at, build: nil, mac: nil, golden: nil, letterShare: nil)
        XCTAssertTrue(without.measuredBeforeAuto, "R2's callers write a record from before Auto mode")
        // One verdict with both parts.
        var wrong = try MeasureFixture.load()
        wrong.label(\.test, "explicit-06", agents: [RouterQuestions.nobody])
        let both = wrong.measure().testVerdict(for: DecisionBands.tev1BF16, at: at, auto: auto)
        XCTAssertEqual(both?.noStart, .testWrong)
        XCTAssertEqual(both?.level, 0.97)
        XCTAssertEqual(both?.autoLevel, 0.60)
        XCTAssertEqual(outcome.testVerdict(for: DecisionBands.tev1BF16, at: at, auto: auto)?.noStart, nil, "Auto's part alone")
        XCTAssertEqual(outcome.testVerdict(for: DecisionBands.tev1BF16, at: at, auto: auto)?.autoLevel, 0.60)
        XCTAssertNil(outcome.testVerdict(for: DecisionBands.tev1BF16, at: at, auto: nil))
    }

    // MARK: By hand, on the bench's library

    private let library = MeasureFixture.library(general: "General",
                                                 binders: ["Family", "Fundraising", "Garden", "Health", "Hiring", "Home", "Money", "Pocketfold", "Reading",
                                                           "Summit booth", "Travel", "Website"],
                                                 agents: MeasureFixture.benchAgents + [RouterQuestions.nobody],
                                                 takes: ["Claude Code · pocketfold-app": ["Pocketfold"], "Codex · pocketfold-site": ["Website"],
                                                         "Pennant": ["Family", "Garden", "Health", "Home", "Money", "Reading", "Travel"], "Grok Bot": nil,
                                                         "Kestrel": ["Fundraising", "Hiring", "Pocketfold", "Summit booth", "Website"],
                                                         "Inkwell": ["Fundraising", "Hiring", "Pocketfold", "Summit booth", "Website"],
                                                         "Hourglass": ["Fundraising", "Hiring", "Pocketfold", "Summit booth", "Website"], "Abacus": ["Money"]])
    private let bands = RouterBands(start: nil, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33)
    private var serial = 0

    /// A made-up to-do filed in `binder` (at 0.9), the model's top `agent` at `p`, the rest on nobody: right, wrong (Inkwell's
    /// work) or no agent's work (`nobody`).
    private func made(_ agent: String?, p: Double = 0.8, right: Bool = true, nobody: Bool = false, binder: String = "Website",
                               kind: String = "todo", text: String = "Fix the pricing table") -> RouterBench.Answer {
        serial += 1
        let binders = library.binders.map { $0 == binder ? 0.9 : 0.1 / Double(library.binders.count - 1) }
        let agents = library.agents.map { $0 == agent ? p : $0 == RouterQuestions.nobody ? (agent == nil ? 0.9 : 1 - p) : 0 }
        let expected = right ? (agent ?? RouterQuestions.nobody) : nobody ? RouterQuestions.nobody : "Inkwell"
        return RouterBench.Answer(id: "made-\(serial)", acceptableBinders: [binder], acceptableAgents: [expected], binders: binders,
                                  agents: agents.map { agent == nil && $0 == 0 ? 0.1 / Double(library.agents.count - 1) : $0 }, text: text, kind: kind,
                                  expectedAgent: expected)
    }

    private func many(_ count: Int, _ agent: String = "Grok Bot", p: Double = 0.8, right: Bool = true, nobody: Bool = false) -> [RouterBench.Answer] {
        (0..<count).map { _ in made(agent, p: p, right: right, nobody: nobody) }
    }

    private func level(dev: [RouterBench.Answer], test: [RouterBench.Answer], bands: RouterBands? = nil) -> MeasureRules.AutoOutcome {
        MeasureRules.auto(dev: dev, test: test, bands: bands ?? self.bands, library: library)
    }

    func testThreeInFourAtTheSuggestBandAndNineInTenAbove() {
        let dev = many(3, p: 0.55) + many(1, p: 0.55, right: false) + many(9, p: 0.65) + many(1, p: 0.65, right: false)
        let auto = level(dev: dev, test: many(5, p: 0.75))
        XCTAssertEqual(auto.level, 0.60, "3 in 4 under 0.60 is too few right; 9 in 10 above holds")
        XCTAssertEqual(auto.devLevel, 0.60)
        XCTAssertNil(auto.raisedTo, "dev alone put it there")
        XCTAssertEqual(auto.dev, DecisionMeasure.AutoCounts(picks: 10, right: 9))
    }

    func testNeverFourInFiveOnDevGivesNone() {
        let auto = level(dev: many(7) + many(3, right: false), test: many(5))
        XCTAssertNil(auto.level)
        XCTAssertEqual(auto.noAuto, .devShare)
        XCTAssertEqual(auto.countedAt, 0.50)
    }

    func testTwoFalseAssignmentsInTenToDosNobodysGivesNone() {
        let nobodys = many(2, right: false, nobody: true) + (0..<8).map { _ in made(nil, right: true) }
        let dev = many(18) + nobodys
        let auto = level(dev: dev, test: many(5))
        XCTAssertNil(auto.level, "18 in 20 right, but 2 of the 10 that were nobody's went to an agent")
        XCTAssertEqual(auto.noAuto, .devShare)
        XCTAssertEqual(auto.dev.falseAssignments, 2)
        let one = level(dev: many(18) + many(1, right: false, nobody: true) + (0..<9).map { _ in made(nil) }, test: many(5))
        XCTAssertEqual(one.level, 0.50, "one in ten is the cap")
    }

    func testDevFineAndTestThreeInFiveGivesNone() {
        let auto = level(dev: many(10), test: many(3, p: 0.95) + many(2, p: 0.95, right: false))
        XCTAssertNil(auto.level)
        XCTAssertEqual(auto.noAuto, .testShare)
        XCTAssertEqual(auto.tookAway, .testShare, "a verdict to keep")
        XCTAssertEqual(auto.devLevel, 0.50)
        XCTAssertEqual(auto.testVerdict(for: DecisionBands.tev1BF16, at: Date())?.noAuto, .testShare)
        XCTAssertNil(level(dev: many(10), test: []).level, "a test with nothing to hand over doesn't hold")
    }

    func testFewerThanFiveAtEveryLevelGivesNone() {
        let auto = level(dev: many(4), test: many(10))
        XCTAssertNil(auto.level)
        XCTAssertEqual(auto.noAuto, .devFew)
        XCTAssertEqual(auto.dev.picks, 4)
    }

    func testAModelThatNamesNoAgentGivesNone() {
        let auto = level(dev: many(10), test: many(10), bands: RouterBands(start: nil, suggest: RouterBands.never, generalBelow: 0.45,
                                                                                     generalBelowTitlesOnly: 0.33))
        XCTAssertNil(auto.level)
        XCTAssertEqual(auto.noAuto, .namesNone)
        XCTAssertNil(auto.countedAt)
    }

    func testOnlyWhatAutoWouldHandOverIsCounted() {
        var dev = many(10)
        dev.append(made("Grok Bot", p: 0.3, text: "Give the pricing table to Grok Bot"))                        // named: counted apart
        dev.append(made("Codex · pocketfold-site", p: 0.9, right: false, nobody: true,
                             text: "Codex did a nice job on the pricing table, tell Sam"))                           // only mentioned
        dev.append(made("Inkwell", p: 0.9, right: false, text: "give the pricing table to cloud code"))        // another name heard
        dev.append(made("Grok Bot", p: 0.9, kind: "note"))                                                     // a note
        dev.append(made("Grok Bot", p: 0.9, kind: "question"))                                                 // a question
        for (agent, binder) in [("Pennant", "Home"), ("Kestrel", "Website"), ("Hourglass", "Website"), ("Abacus", "Money")] {
            dev.append(made(agent, p: 0.95, binder: binder))                                                    // may act for you
        }
        dev.append(made("Codex · pocketfold-site", p: 0.95, binder: "Health"))                                // not a taker there
        let picks = MeasureRules.autoPicks(dev, library: library, bands: bands)
        XCTAssertEqual(picks.filter { !$0.named }.count, 10)
        XCTAssertEqual(picks.filter(\.named).map(\.agent), ["Grok Bot"])
        XCTAssertTrue(picks.allSatisfy { $0.agent == "Grok Bot" })
        let auto = level(dev: dev, test: many(5))
        XCTAssertEqual(auto.level, 0.50)
        XCTAssertEqual(auto.dev, DecisionMeasure.AutoCounts(picks: 10, right: 10, named: 1, namedRight: 1))
        XCTAssertEqual(MeasureRules.NoAuto.allCases.map(\.rawValue), ["namesNone", "devFew", "devShare", "testShare", "testBefore"])
        XCTAssertEqual([MeasureRules.autoLeast, MeasureRules.autoBandLeast], [5, 3])
        XCTAssertEqual([MeasureRules.autoShare, MeasureRules.autoFalse, MeasureRules.autoStep, MeasureRules.autoTop], [0.8, 0.1, 0.10, 0.90])
    }
}
