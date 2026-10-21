import XCTest
@testable import BindersKit

/// What lane R1's --selftest-router-bench built from the bench before lane R2 moved its construction into BindersKit
/// (Fixtures/router/bench-questions-r1.json, written by its --dump-questions): the SHA-256 of Tev1Prompt's prompt for
/// every item's binder question in both forms and its agent question, the whole questions of dev short-02 and fr-06, and
/// lane R1's Tev1Backend warm-up with its golden. Everything in the bench is made up.
struct BenchQuestionsFixture: Decodable {
    struct Item: Decodable {
        let id: String
        let split: String
        let binderBoth: String
        let binderTitles: String
        let agent: String
        enum CodingKeys: String, CodingKey { case id, split, agent, binderBoth = "binder_both", binderTitles = "binder_titles" }
    }

    struct Question: Decodable {
        struct Option: Decodable {
            let key: String
            let description: String
        }

        let state: String
        let question: String
        let options: [Option]

        var decision: DecisionQuestion {
            DecisionQuestion(state: state, question: question, options: options.map { DecisionOption(key: $0.key, description: $0.description) })
        }
    }

    struct WarmUp: Decodable {
        let question: Question
        let promptSHA256: String
        let golden: [Double]
        enum CodingKeys: String, CodingKey { case question, golden, promptSHA256 = "prompt_sha256" }
    }

    let schema: String
    let bench: [String: String]
    let count: Int
    let warmUpR1: WarmUp
    let full: [String: [String: Question]]
    let items: [Item]
    enum CodingKeys: String, CodingKey { case schema, bench, count, full, items, warmUpR1 = "warm_up_r1" }

    static func load() throws -> BenchQuestionsFixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "bench-questions-r1", withExtension: "json", subdirectory: "Fixtures/router"))
        return try JSONDecoder().decode(BenchQuestionsFixture.self, from: Data(contentsOf: url))
    }
}

/// The bench the Mac app bundles (Binders/Resources/RouterBench), read from the repo, and what RouterBench builds from it.
final class RouterBenchDataTests: XCTestCase {
    /// Binders/Resources/RouterBench in this checkout.
    static var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BindersKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BindersKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // the repo
            .appendingPathComponent("Binders/Resources/RouterBench", isDirectory: true)
    }

    static func file(_ name: String) throws -> Data {
        try Data(contentsOf: resources.appendingPathComponent("\(name).json"))
    }

    static func bench() throws -> RouterBench.Data {
        try RouterBench.Data(library: file(RouterBench.bundledLibrary), routing: file(RouterBench.bundledRouting))
    }

    static func sha256(_ text: String) -> String { DecisionFingerprint.sha256Hex(text) }

    func testTheBundledFilesAreTheOnesReviewed() throws {
        XCTAssertEqual(RouterBench.sha256(try Self.file(RouterBench.bundledLibrary)), RouterBench.reviewedSHA256["library.json"],
                       "a changed library.json needs its names checked again before its hash goes in")
        XCTAssertEqual(RouterBench.sha256(try Self.file(RouterBench.bundledRouting)), RouterBench.reviewedSHA256["routing.json"],
                       "a changed routing.json needs its names checked again before its hash goes in")
        XCTAssertEqual(try BenchQuestionsFixture.load().bench, RouterBench.reviewedSHA256, "the bench lane R1's tool read")
    }

    func testTheBenchsShape() throws {
        let bench = try Self.bench()
        XCTAssertEqual(bench.items.count, 278)
        XCTAssertEqual(bench.items(.dev).count, 111)
        XCTAssertEqual(bench.items(.test).count, 167)
        XCTAssertEqual(Set(bench.items.map(\.id)).count, 278, "every id once")
        XCTAssertEqual(bench.binders.count, 21)
        XCTAssertEqual(bench.agents.count, 12)
        XCTAssertEqual(bench.general, "General")
        let both = bench.inputs(.both), titles = bench.inputs(.titles)
        XCTAssertEqual(both.binders.count, 12, "the standard library's binders, General left out")
        XCTAssertFalse(both.binders.contains { $0.name == bench.general })
        XCTAssertEqual(both.agents.count, 8)
        let asked = try XCTUnwrap(RouterQuestions.agents(state: "", inputs: both))
        XCTAssertEqual(asked.question.options.count, 9, "8 agents and nobody")
        XCTAssertEqual(asked.question.options.last?.key, RouterQuestions.nobody)
        XCTAssertTrue(asked.leftOut.isEmpty)
        // The two forms differ only in What goes here.
        XCTAssertEqual(both.agents, titles.agents)
        XCTAssertEqual(both.binders.map(\.id), titles.binders.map(\.id))
        XCTAssertEqual(both.binders.map(\.name), titles.binders.map(\.name))
        XCTAssertEqual(both.binders.map(\.titles), titles.binders.map(\.titles))
        XCTAssertTrue(both.binders.allSatisfy { !$0.whatGoesHere.isEmpty })
        XCTAssertTrue(titles.binders.allSatisfy(\.whatGoesHere.isEmpty))
        XCTAssertEqual(try XCTUnwrap(RouterQuestions.binders(state: "x", inputs: both)).form, .both)
        XCTAssertEqual(try XCTUnwrap(RouterQuestions.binders(state: "x", inputs: titles)).form, .titles)
        // The same ids every time.
        XCTAssertEqual(try Self.bench().inputs(.both), both)
    }

    /// Every question RouterBench builds is the one lane R1's bench tool built: 834 hashes, item by item.
    func testEveryQuestionIsTheOneR1Built() throws {
        let bench = try Self.bench()
        let fixture = try BenchQuestionsFixture.load()
        XCTAssertEqual(fixture.count, 834)
        XCTAssertEqual(fixture.items.map(\.id), bench.items.map(\.id), "in routing.json's order")
        XCTAssertEqual(fixture.items.map(\.split), bench.items.map(\.split))
        var same = 0
        for (item, held) in zip(bench.items, fixture.items) {
            let both = try XCTUnwrap(bench.questions(item, form: .both), item.id)
            let titles = try XCTUnwrap(bench.questions(item, form: .titles), item.id)
            for (built, want, what) in [(both.binder.question, held.binderBoth, "binder, both"), (titles.binder.question, held.binderTitles, "binder, titles"),
                                        (both.agent.question, held.agent, "agent")] {
                if Self.sha256(Tev1Prompt.prompt(built)) == want { same += 1 } else { XCTFail("\(item.id) \(what): not the question R1 built") }
            }
            XCTAssertEqual(Array(Tev1Prompt.prompt(titles.agent.question).utf8), Array(Tev1Prompt.prompt(both.agent.question).utf8),
                           "\(item.id): the agent question doesn't depend on how binders are described")
        }
        XCTAssertEqual(same, 834)
    }

    func testTheWarmUpsAreR1s() throws {
        let fixture = try BenchQuestionsFixture.load()
        let bench = try Self.bench()
        XCTAssertEqual(RouterQuestions.warmUps.count, 3)
        // The first is lane R1's Tev1Backend warm-up, byte for byte, and its golden is R1's.
        let first = RouterQuestions.warmUps[0]
        XCTAssertEqual(Array(Tev1Prompt.prompt(first).utf8), Array(Tev1Prompt.prompt(fixture.warmUpR1.question.decision).utf8))
        XCTAssertEqual(Self.sha256(Tev1Prompt.prompt(first)), fixture.warmUpR1.promptSHA256)
        XCTAssertEqual(first.options.count, 11)
        XCTAssertEqual(DecisionBands.tev1?.golden.first, fixture.warmUpR1.golden, "R1's warm-up golden, moved into the built-in entry")
        // The second and third are the bench's agent questions for dev short-02 and fr-06, as R1's tool built them.
        for (index, id) in [(1, "short-02"), (2, "fr-06")] {
            let item = try XCTUnwrap(bench.items.first { $0.id == id })
            XCTAssertEqual(item.split, "dev")
            let built = try XCTUnwrap(bench.questions(item, form: .both)).agent.question
            let literal = RouterQuestions.warmUps[index]
            XCTAssertEqual(Array(Tev1Prompt.prompt(literal).utf8), Array(Tev1Prompt.prompt(built).utf8), "\(id): what RouterBench builds")
            let whole = try XCTUnwrap(fixture.full[id]?["agent"]).decision
            XCTAssertEqual(Array(Tev1Prompt.prompt(literal).utf8), Array(Tev1Prompt.prompt(whole).utf8), "\(id): what R1's tool built")
            XCTAssertEqual(Self.sha256(Tev1Prompt.prompt(literal)), fixture.items.first { $0.id == id }?.agent)
        }
        XCTAssertTrue(RouterQuestions.warmUps[2].state.unicodeScalars.contains("\u{e9}") && RouterQuestions.warmUps[2].state.unicodeScalars.contains("\u{e0}"),
                      "é and à, as single code points")
    }

    func testTheBuiltInAgentGoldensAreR1sDevAnswers() throws {
        let fixture = try MeasureFixture.load()
        let golden = try XCTUnwrap(DecisionBands.tev1?.golden)
        XCTAssertEqual(golden.count, 3)
        XCTAssertEqual(golden[1], fixture.devBoth.first { $0.id == "short-02" }?.agents, "short-02's agent answer, R1's dev run")
        XCTAssertEqual(golden[2], fixture.devBoth.first { $0.id == "fr-06" }?.agents, "fr-06's agent answer, R1's dev run")
        XCTAssertEqual(golden.map(\.count), RouterQuestions.warmUps.map(\.options.count))
    }

    func testTheBenchsScoring() throws {
        let library = try Self.bench().library
        XCTAssertEqual(library.binders.count, 12)
        XCTAssertEqual(library.agents.last, RouterQuestions.nobody)
        XCTAssertEqual(library.takers("Website"), ["Codex · pocketfold-site", "Grok Bot", "Kestrel", "Inkwell", "Hourglass"])
        XCTAssertEqual(library.takers("General"), ["Grok Bot"], "only an agent that takes every binder's cards")
        let answer = RouterBench.Answer(id: "x", acceptableBinders: ["Website"], acceptableAgents: [RouterQuestions.nobody],
                                        binders: library.binders.map { $0 == "Website" ? 0.3 : 0.7 / 11 }, agents: library.agents.map { $0 == RouterQuestions.nobody ? 0.2 : 0.1 })
        // First picks: Website at 0.3 is right (General never chosen); the top agent is nobody's 0.2.
        XCTAssertEqual(RouterBench.score([answer], library: library), RouterBench.Score(items: 1, binderOK: 1, agentOK: 1))
        XCTAssertEqual(RouterBench.Score(items: 167, binderOK: 147, agentOK: 118).score, 265.0 / 334)
        XCTAssertEqual(RouterBench.Score(items: 0, binderOK: 0, agentOK: 0).score, 0)
    }

    /// Which agents Auto's level is counted on: the ones whose role drafts first, read from the library it already copies
    /// byte for byte (its reviewed hash is unchanged).
    func testTheAgentsThatDraftFirst() throws {
        let bench = try Self.bench()
        let roles = Dictionary(uniqueKeysWithValues: bench.agents.map { ($0.name, $0.role ?? "") })
        XCTAssertEqual(roles["Claude Code · pocketfold-app"], "coding")
        XCTAssertEqual(roles["Pennant"], "errands")
        for name in ["Claude Code · pocketfold-app", "Codex · pocketfold-site", "Grok Bot", "Inkwell"] {
            XCTAssertEqual(bench.agents.first { $0.name == name }?.draftsFirst, true, name)
        }
        for name in ["Pennant", "Kestrel", "Hourglass", "Abacus"] {
            XCTAssertEqual(bench.agents.first { $0.name == name }?.draftsFirst, false, name)
        }
        XCTAssertEqual(bench.library.draftsFirst, ["Claude Code · pocketfold-app", "Codex · pocketfold-site", "Grok Bot", "Inkwell"],
                       "the standard library's, as offered")
        XCTAssertEqual(RouterBench.draftsFirstRoles, ["coding", "research", "writing"])
        XCTAssertEqual(RouterBench.sha256(try Self.file(RouterBench.bundledLibrary)), RouterBench.reviewedSHA256["library.json"])
    }

    /// What the Auto rule reads of each item travels with its answer.
    func testAnItemsKindAndWordsTravelWithItsAnswer() throws {
        let bench = try Self.bench()
        let item = try XCTUnwrap(bench.items.first { $0.id == "explicit-01" })
        XCTAssertEqual(item.kind, "todo")
        XCTAssertEqual(item.category, "explicit_agent")
        let answer = RouterBench.Answer(item: item, binders: [], agents: [])
        XCTAssertEqual(answer.text, "Give the login bug to Codex")
        XCTAssertEqual(answer.kind, "todo")
        XCTAssertEqual(answer.expectedAgent, "Codex · pocketfold-site")
        XCTAssertEqual(Set(bench.items.compactMap(\.kind)), ["todo", "idea", "note"])
        XCTAssertEqual(bench.items.filter { $0.kind == nil }.count, 0)
    }
}

