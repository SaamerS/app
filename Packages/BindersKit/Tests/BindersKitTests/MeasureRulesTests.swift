import XCTest
@testable import BindersKit

/// Lane R1's Swift bench runs of Tev1 0.8B bf16 (256-token pieces, the app's runtime), as lane R2's make_measure_fixture.py
/// wrote them (Fixtures/router/measure-tev1-bf16.json): each item's labels and the model's probabilities, binders and
/// agents in the order the app offers them, for dev with What goes here, dev with titles alone, and test. Everything in it
/// is the bench's made-up library.
struct MeasureFixture: Decodable {
    struct Item: Decodable {
        var id: String
        var acceptableBinders: [String]
        var acceptableAgents: [String]
        var binders: [Double]
        var agents: [Double]
        enum CodingKeys: String, CodingKey {
            case id, binders, agents, acceptableBinders = "acceptable_binders", acceptableAgents = "acceptable_agents"
        }
    }

    let general: String
    let binders: [String]
    let agents: [String]
    let takes: [String: [String]?]
    var devBoth: [Item]
    var devTitles: [Item]
    var test: [Item]
    enum CodingKeys: String, CodingKey { case general, binders, agents, takes, test, devBoth = "dev_both", devTitles = "dev_titles" }

    static func load() throws -> MeasureFixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "measure-tev1-bf16", withExtension: "json", subdirectory: "Fixtures/router"))
        return try JSONDecoder().decode(MeasureFixture.self, from: Data(contentsOf: url))
    }

    var library: RouterBench.Library {
        Self.library(general: general, binders: binders, agents: agents, takes: takes)
    }

    /// The library from a fixture's lists. Which agents draft first comes from the bench library's roles, which the
    /// fixtures don't copy.
    static func library(general: String, binders: [String], agents: [String], takes: [String: [String]?]) -> RouterBench.Library {
        var takesCards: [String: Set<String>] = [:], every: Set<String> = []
        for (agent, listed) in takes {
            if let listed { takesCards[agent] = Set(listed) } else { every.insert(agent) }
        }
        return RouterBench.Library(general: general, binders: binders, agents: agents, takes: takesCards, takesEvery: every, draftsFirst: benchDraftsFirst)
    }

    static let benchDraftsFirst: Set<String> = (try? RouterBenchDataTests.bench().library.draftsFirst) ?? []
    /// The standard library's agents, in its order.
    static let benchAgents: [String] = (try? RouterBenchDataTests.bench().agentNames) ?? []
    /// The bench's items by id, read once.
    static let benchItems: [String: RouterBench.Item]? = (try? RouterBenchDataTests.bench()).map { bench in
        Dictionary(uniqueKeysWithValues: bench.items.map { ($0.id, $0) })
    }

    static func answers(_ items: [Item]) -> [RouterBench.Answer] {
        items.map { RouterBench.Answer(id: $0.id, acceptableBinders: $0.acceptableBinders, acceptableAgents: $0.acceptableAgents, binders: $0.binders, agents: $0.agents) }
    }

    /// The same answers with what the Auto rule reads of each item, which the fixtures don't copy: its words, its kind and
    /// the agent the bench expected, from the bench's routing.json by id.
    static func autoAnswers(_ items: [Item]) throws -> [RouterBench.Answer] {
        let bench = try XCTUnwrap(benchItems, "the bench in Binders/Resources/RouterBench")
        return try answers(items).map { answer in
            let item = try XCTUnwrap(bench[answer.id], answer.id)
            var answer = answer
            answer.text = item.text
            answer.kind = item.kind
            answer.expectedAgent = item.expectedAgent
            return answer
        }
    }

    func measure(testBefore: Bool = false) -> MeasureRules.Outcome {
        MeasureRules.measure(devBoth: Self.answers(devBoth), devTitles: Self.answers(devTitles), test: Self.answers(test), library: library,
                             testBefore: testBefore)
    }

    /// check_measure_fixture.py's `lowered`: these items' top agent moved down to `p` (0.90: no start), the rest of its
    /// probability to nobody.
    mutating func lower(_ split: WritableKeyPath<MeasureFixture, [Item]>, _ ids: [String], to p: Double = 0.90) {
        for index in self[keyPath: split].indices where ids.contains(self[keyPath: split][index].id) {
            var item = self[keyPath: split][index]
            guard let top = RouterMath.argmax(item.agents) else { continue }
            let gone = item.agents[top] - p
            item.agents[top] = p
            item.agents[item.agents.count - 1] += gone
            self[keyPath: split][index] = item
        }
    }

    /// These items' top agent raised to `p`, the other options scaled down to share what's left.
    mutating func raise(_ split: WritableKeyPath<MeasureFixture, [Item]>, _ ids: [String], to p: Double) {
        for index in self[keyPath: split].indices where ids.contains(self[keyPath: split][index].id) {
            var item = self[keyPath: split][index]
            guard let top = RouterMath.argmax(item.agents), item.agents[top] < p else { continue }
            let scale = (1 - p) / (1 - item.agents[top])
            item.agents = item.agents.indices.map { $0 == top ? p : item.agents[$0] * scale }
            self[keyPath: split][index] = item
        }
    }

    /// An item's agent labels changed, so its pick is right or wrong as a case needs.
    mutating func label(_ split: WritableKeyPath<MeasureFixture, [Item]>, _ id: String, agents: [String]) {
        for index in self[keyPath: split].indices where self[keyPath: split][index].id == id {
            self[keyPath: split][index].acceptableAgents = agents
        }
    }

    /// The titles-alone run shares the agent answers (and the labels), so what moved in the What goes here run moves there too.
    mutating func shareAgents() {
        let both = Dictionary(uniqueKeysWithValues: devBoth.map { ($0.id, $0) })
        for index in devTitles.indices {
            guard let twin = both[devTitles[index].id] else { continue }
            devTitles[index].agents = twin.agents
            devTitles[index].acceptableAgents = twin.acceptableAgents
        }
    }
}

final class MeasureRulesTests: XCTestCase {
    func testRsNumbersGiveRsBands() throws {
        let fixture = try MeasureFixture.load()
        XCTAssertEqual([fixture.devBoth.count, fixture.devTitles.count, fixture.test.count], [111, 111, 167])
        let outcome = fixture.measure()
        XCTAssertEqual(outcome.dev.general, 0.45)
        XCTAssertEqual(outcome.dev.generalTitlesOnly, 0.33)
        XCTAssertEqual(outcome.dev.suggest, 0.50)
        XCTAssertEqual(outcome.dev.start, 0.97)
        XCTAssertNil(outcome.dev.noStart)
        XCTAssertEqual(outcome.dev.starts.map(\.id), ["coding-13", "fr-04", "de-05"])
        XCTAssertEqual(outcome.dev.starts.map(\.agent), ["Codex · pocketfold-site", "Inkwell", "Grok Bot"])
        XCTAssertTrue(outcome.dev.starts.allSatisfy(\.right))
        XCTAssertEqual(outcome.test.starts.map(\.id), ["explicit-06", "writing-11", "long-14", "de-03"])
        XCTAssertTrue(outcome.test.starts.allSatisfy(\.right), "none wrong on test")
        XCTAssertEqual(outcome.dev.starts.count + outcome.test.starts.count, 7)
        XCTAssertEqual(outcome.test.start, 0.97)
        XCTAssertNil(outcome.noStart)
        XCTAssertNil(outcome.verdict)
        XCTAssertEqual(outcome.bands, RouterBands(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33))
        // With Auto's level from the same answers (MeasureAutoTests), the built-in entry.
        var bands = outcome.bands
        bands.auto = MeasureRules.auto(dev: try MeasureFixture.autoAnswers(fixture.devBoth), test: try MeasureFixture.autoAnswers(fixture.test),
                                       bands: outcome.bands, library: fixture.library).level
        XCTAssertEqual(bands, DecisionBands.tev1?.bands, "the measure's rules give R1's bands, the built-in entry")
        // The bench's own scoring: dev 0.7703, test 0.7934, 147 and 118 of 167.
        XCTAssertEqual(outcome.dev.score, RouterBench.Score(items: 111, binderOK: 98, agentOK: 73))
        XCTAssertEqual(outcome.dev.score.score, 0.7703, accuracy: 0.00005)
        XCTAssertEqual(outcome.dev.titlesBinderOK, 92)
        XCTAssertEqual(outcome.test.score, RouterBench.Score(items: 167, binderOK: 147, agentOK: 118))
        XCTAssertEqual(outcome.test.score.score, 0.7934, accuracy: 0.00005)
    }

    func testTheHighestWrongPickOnDevIsNamed13() throws {
        let fixture = try MeasureFixture.load()
        let library = fixture.library
        let wrong = MeasureFixture.answers(fixture.devBoth).map { (id: $0.id, pick: MeasureRules.pick($0, library: library, general: 0.45, suggest: 0.50)) }
            .filter { $0.pick.agent != nil && !$0.pick.agentRight }.max { $0.pick.p < $1.pick.p }
        XCTAssertEqual(wrong?.id, "named-13")
        XCTAssertEqual(wrong?.pick.agent, "Codex · pocketfold-site")
        XCTAssertEqual(wrong?.pick.p ?? 0, 0.9602, accuracy: 0.00005, "0.0098 under 0.97: the reason R1's bar isn't 0.96")
    }

    func testBindersOwnRulesOnTest() throws {
        // app_counts.py: at Tev1's bands Binders' rules file 147 binders right and name the right agent, or none, for 117.
        let fixture = try MeasureFixture.load()
        let picks = MeasureFixture.answers(fixture.test).map { MeasureRules.pick($0, library: fixture.library, general: 0.45, suggest: 0.50) }
        XCTAssertEqual(picks.filter(\.binderRight).count, 147)
        XCTAssertEqual(picks.filter(\.agentRight).count, 117)
    }

    // The four cases of check_measure_fixture.py, first.

    func testTwoDevStartsAndNoTestStartGiveNone() throws {
        var fixture = try MeasureFixture.load()
        fixture.lower(\.devBoth, ["coding-13"])
        fixture.lower(\.test, ["explicit-06", "writing-11", "long-14", "de-03"])
        fixture.shareAgents()
        let outcome = fixture.measure()
        XCTAssertEqual(outcome.dev.start, 0.97, "dev alone would start at 0.97, with 2")
        XCTAssertEqual(outcome.dev.starts.count, 2)
        XCTAssertNil(outcome.bands.start)
        XCTAssertEqual(outcome.noStart, .testFew)
        XCTAssertEqual(outcome.verdict, .testFew, "and the verdict is kept for the model")
    }

    func testThreeDevStartsAndOneTestStartGiveNone() throws {
        var fixture = try MeasureFixture.load()
        fixture.lower(\.test, ["writing-11", "long-14", "de-03"])
        let outcome = fixture.measure()
        XCTAssertEqual(outcome.test.starts.count, 1)
        XCTAssertNil(outcome.bands.start, "4 in all, under 5")
        XCTAssertEqual(outcome.noStart, .testFew)
    }

    func testThreeDevStartsAndTwoTestStartsKeep097() throws {
        var fixture = try MeasureFixture.load()
        fixture.lower(\.test, ["long-14", "de-03"])
        let outcome = fixture.measure()
        XCTAssertEqual(outcome.test.starts.count, 2)
        XCTAssertEqual(outcome.bands.start, 0.97, "5 in all")
        XCTAssertNil(outcome.noStart)
    }

    func testOneDevStartGivesNone() throws {
        var fixture = try MeasureFixture.load()
        fixture.lower(\.devBoth, ["fr-04", "de-05"])
        fixture.shareAgents()
        let outcome = fixture.measure()
        XCTAssertNil(outcome.dev.start)
        XCTAssertEqual(outcome.noStart, .fewStarts)
        XCTAssertNil(outcome.verdict, "dev took it, not test")
        XCTAssertEqual(outcome.dev.level, 0.95, "its starts are counted at the lowest level the rules try")
    }

    // Then the rest of the rules.

    func testAWrongStartAt097MovesItTo098() throws {
        var fixture = try MeasureFixture.load()
        fixture.label(\.devBoth, "de-05", agents: [RouterQuestions.nobody])   // Grok Bot at 0.9742 is now wrong
        fixture.raise(\.devBoth, ["fr-04"], to: 0.985)                         // and Inkwell clears 0.98
        fixture.raise(\.test, ["writing-11", "long-14", "de-03"], to: 0.985)   // three test starts at 0.98: 2 + 3 = 5
        fixture.shareAgents()
        let outcome = fixture.measure()
        XCTAssertEqual(outcome.dev.start, 0.98)
        XCTAssertEqual(outcome.dev.starts.map(\.id), ["coding-13", "fr-04"])
        XCTAssertEqual(outcome.test.starts.count, 3)
        XCTAssertEqual(outcome.bands.start, 0.98)
    }

    func testAWrongPickJustUnderTheBarKeepsItFrom097() throws {
        var fixture = try MeasureFixture.load()
        fixture.raise(\.devBoth, ["named-13"], to: 0.966)   // its wrong Codex, from 0.9602 to inside 0.965 ..< 0.97
        fixture.shareAgents()
        let outcome = fixture.measure()
        XCTAssertNotEqual(outcome.dev.start, 0.97)
        XCTAssertNil(outcome.bands.start, "at 0.98 only one dev start is left")
        XCTAssertEqual(outcome.noStart, .fewStarts)
    }

    func testAWrongTestStartMeansNone() throws {
        var fixture = try MeasureFixture.load()
        fixture.label(\.test, "explicit-06", agents: [RouterQuestions.nobody])
        let outcome = fixture.measure()
        XCTAssertEqual(outcome.dev.start, 0.97)
        XCTAssertNil(outcome.bands.start)
        XCTAssertEqual(outcome.noStart, .testWrong)
        XCTAssertEqual(outcome.verdict, .testWrong)
        XCTAssertEqual(outcome.test.level, 0.97, "its starts are counted at the level dev found")
        XCTAssertEqual(outcome.test.starts.filter { !$0.right }.map(\.id), ["explicit-06"])
        XCTAssertEqual(outcome.bands.suggest, 0.50, "it still names agents")
        XCTAssertEqual(outcome.bands.generalBelow, 0.45, "and files cards")
    }

    func testAVerdictHoldsOnACleanTest() throws {
        let outcome = try MeasureFixture.load().measure(testBefore: true)
        XCTAssertEqual(outcome.test.start, 0.97, "this test is clean")
        XCTAssertNil(outcome.bands.start)
        XCTAssertEqual(outcome.noStart, .testBefore)
        XCTAssertNil(outcome.verdict, "this test took nothing away")
        XCTAssertEqual(outcome.bands, RouterBands(start: nil, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33))
    }

    func testAnswersFromTwoModelsStartNothing() throws {
        let fixture = try MeasureFixture.load()
        // A server that routes by language: ASCII states to one checkpoint, the rest to another.
        func routed(_ items: [MeasureFixture.Item]) -> [RouterBench.Answer] {
            MeasureFixture.answers(items).map { answer in
                var answer = answer
                answer.answeredBy = ["fr-", "de-", "es-", "pt-"].contains { answer.id.hasPrefix($0) } ? "multilingual" : "english"
                return answer
            }
        }
        let outcome = MeasureRules.measure(devBoth: routed(fixture.devBoth), devTitles: routed(fixture.devTitles), test: routed(fixture.test),
                                           library: fixture.library)
        XCTAssertEqual(outcome.noStart, .severalModels)
        XCTAssertEqual(outcome.bands, RouterBands(start: nil, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33),
                       "filing and naming bands, no start")
        // One model throughout keeps its start.
        func one(_ items: [MeasureFixture.Item]) -> [RouterBench.Answer] {
            MeasureFixture.answers(items).map { var answer = $0; answer.answeredBy = "english"; return answer }
        }
        XCTAssertEqual(MeasureRules.measure(devBoth: one(fixture.devBoth), devTitles: one(fixture.devTitles), test: one(fixture.test),
                                            library: fixture.library).bands.start, 0.97)
    }

    func testNoLevelOfSevenInTenNamesNone() throws {
        var fixture = try MeasureFixture.load()
        for index in fixture.devBoth.indices { fixture.devBoth[index].acceptableAgents = [RouterQuestions.nobody] }
        fixture.shareAgents()
        let outcome = fixture.measure()
        XCTAssertNil(outcome.dev.suggest)
        XCTAssertEqual(outcome.noStart, .namesNone)
        XCTAssertEqual(outcome.bands.suggest, RouterBands.never, "it names no agent")
        XCTAssertNil(outcome.bands.start, "and starts none")
        XCTAssertEqual(outcome.bands.band(0.999), .none)
        XCTAssertEqual(outcome.bands.generalBelow, 0.45, "its binders still file")
    }

    func testEveryLevelWrongIsNoLevel() throws {
        var fixture = try MeasureFixture.load()
        // A model sure of a wrong agent at 0.995: no bar from 0.95 to 0.99 is clean.
        fixture.raise(\.devBoth, ["named-13"], to: 0.995)
        fixture.shareAgents()
        let outcome = fixture.measure()
        XCTAssertEqual(outcome.noStart, .noLevel)
        XCTAssertNil(outcome.bands.start)
        XCTAssertEqual(outcome.dev.level, 0.95)
        XCTAssertEqual(outcome.dev.starts.filter { !$0.right }.map(\.id), ["named-13"], "counted at 0.95, the wrong one included")
    }

    func testGeneralsHighestRun() {
        XCTAssertEqual(MeasureRules.general(curve: [1, 3, 3, 1, 3, 3, 3, 1]), 0.05, "two runs at the top: the higher one's middle")
        XCTAssertEqual(MeasureRules.general(curve: [0, 2, 2, 2, 2, 0]), 0.02, "a run of even length: the lower middle")
        XCTAssertEqual(MeasureRules.general(curve: [0, 0, 5, 0]), 0.02, "one point")
        XCTAssertEqual(MeasureRules.general(curve: [9, 1, 1]), 0.00, "the top at 0")
        XCTAssertEqual(MeasureRules.general(curve: [9, 9, 1]), 0.00)
        XCTAssertEqual(MeasureRules.general(curve: [1, 2, 2]), 0.01, "a run that reaches the end")
        XCTAssertEqual(MeasureRules.general(curve: []), 0)
        XCTAssertEqual(MeasureRules.generalGrid.count, 91)
        XCTAssertEqual(MeasureRules.generalGrid.last, 0.90)
        XCTAssertEqual(MeasureRules.suggestGrid, [0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90])
    }

    func testTheRecordOfAMeasure() throws {
        let outcome = try MeasureFixture.load().measure()
        let at = Date(timeIntervalSince1970: 1_792_431_731)
        let record = DecisionMeasure(identity: DecisionBands.tev1BF16, outcome: outcome, at: at, build: "25", mac: "Mac17,6, Apple M5 Max",
                                     golden: DecisionBands.tev1?.golden, letterShare: [0.9998, 0.9996, 0.9993], ms: .init(p50: 80, p95: 86))
        XCTAssertEqual(record.key, "mlx1-b73a343455582c89eed2254a tev1.1/256")
        XCTAssertEqual(record.bands, DecisionMeasure.Bands(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33))
        XCTAssertNil(record.noStart)
        // The same numbers R1's run gave, which the built-in entry holds.
        XCTAssertEqual(record.dev, DecisionBands.tev1?.dev)
        XCTAssertEqual(record.test, DecisionBands.tev1?.test)
        XCTAssertNil(outcome.testVerdict(for: DecisionBands.tev1BF16, at: at))
        var wrong = try MeasureFixture.load()
        wrong.label(\.test, "explicit-06", agents: [RouterQuestions.nobody])
        let verdict = wrong.measure().testVerdict(for: DecisionBands.tev1BF16, at: at)
        XCTAssertEqual(verdict, DecisionMeasure.TestVerdict(key: DecisionBands.tev1BF16.key, at: at, level: 0.97, noStart: .testWrong))
    }

    func testTheFixturesLibraryIsTheBenchsOwn() throws {
        // The fixture's order is the order the app's questions offer the options in.
        let fixture = try MeasureFixture.load()
        XCTAssertEqual(try RouterBenchDataTests.bench().library, fixture.library)
    }
}
