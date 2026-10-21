import XCTest
@testable import BindersKit

/// The router fixture (Fixtures/router/prompts.json): the bench library's inputs, and per case (40 dev items and 10
/// made-up ones) the state, the prompt Python built, its letter logits and probabilities, from lane R1's fixtures.json
/// (Tev1 0.8B, the chosen config). Every name in it is made up.
struct RouterFixture: Decodable {
    struct Prompt: Decodable {
        let system: String
        let templateParts: [String: String]
        let letters: String
        let letterTokenIDs: [Int]
        enum CodingKeys: String, CodingKey { case system, letters, templateParts = "template_parts", letterTokenIDs = "letter_token_ids" }
    }

    struct Binder: Decodable {
        let name: String
        let whatGoesHere: String
        let titles: [String]
        enum CodingKeys: String, CodingKey { case name, titles, whatGoesHere = "what_goes_here" }
    }

    struct Agent: Decodable {
        let name: String
        let whatItsFor: String
        enum CodingKeys: String, CodingKey { case name, whatItsFor = "what_its_for" }
    }

    struct Library: Decodable {
        let general: String
        let binders: [Binder]
        let agents: [Agent]
    }

    struct Question: Decodable {
        let prompt: String
        let logits: [Double]
        let probs: [Double]
        let argmax: String
    }

    struct Case: Decodable {
        let name: String
        let state: String
        let binder: Question
        let agent: Question
    }

    let prompt: Prompt
    let questions: [String: String]
    let library: Library
    let cases: [Case]

    static func load() throws -> RouterFixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "prompts", withExtension: "json", subdirectory: "Fixtures/router"))
        return try JSONDecoder().decode(RouterFixture.self, from: Data(contentsOf: url))
    }

    /// The library as the router reads it: binders by what goes in them and their titles, agents by what each is for.
    var inputs: RouterInputs {
        RouterInputs(binders: library.binders.map { RouterInputs.Binder(name: $0.name, whatGoesHere: $0.whatGoesHere, titles: $0.titles) },
                     agents: library.agents.map { RouterInputs.Agent(name: $0.name, description: $0.whatItsFor) })
    }
}

final class RouterPromptTests: XCTestCase {
    func testTheTemplateIsTheFixturesOwn() throws {
        let fixture = try RouterFixture.load()
        XCTAssertEqual(fixture.prompt.system, Tev1Prompt.system)
        XCTAssertEqual(fixture.prompt.templateParts["before_system"], Tev1Prompt.templateParts.beforeSystem)
        XCTAssertEqual(fixture.prompt.templateParts["between"], Tev1Prompt.templateParts.between)
        XCTAssertEqual(fixture.prompt.templateParts["after_user"], Tev1Prompt.templateParts.afterUser)
        XCTAssertEqual(fixture.prompt.letters, String(Tev1Prompt.letters))
        XCTAssertEqual(fixture.prompt.letterTokenIDs, Tev1Prompt.letterTokenIDs(count: 24))
        XCTAssertEqual(fixture.questions["binder"], RouterQuestions.binderQuestion)
        XCTAssertEqual(fixture.questions["agent"], RouterQuestions.agentQuestion)
    }

    func testEveryPromptIsRebuiltByteForByte() throws {
        let fixture = try RouterFixture.load()
        XCTAssertEqual(fixture.cases.count, 50)
        let inputs = fixture.inputs
        XCTAssertFalse(inputs.binders.contains { $0.name == fixture.library.general }, "General is left out of the question")
        var rebuilt = 0
        for item in fixture.cases {
            let binder = try XCTUnwrap(RouterQuestions.binders(state: item.state, inputs: inputs), item.name)
            let agent = try XCTUnwrap(RouterQuestions.agents(state: item.state, inputs: inputs), item.name)
            XCTAssertEqual(Array(Tev1Prompt.prompt(binder.question).utf8), Array(item.binder.prompt.utf8), "\(item.name) binder")
            XCTAssertEqual(Array(Tev1Prompt.prompt(agent.question).utf8), Array(item.agent.prompt.utf8), "\(item.name) agent")
            // The user JSON on its own: the prompt less the template's parts.
            let parts = Tev1Prompt.templateParts
            let head = parts.beforeSystem + Tev1Prompt.system + parts.between
            let json = Array(item.binder.prompt.utf8).dropFirst(head.utf8.count).dropLast(parts.afterUser.utf8.count)
            XCTAssertEqual(Array(Tev1Prompt.userJSON(binder.question).utf8), Array(json), "\(item.name) user JSON")
            XCTAssertTrue(item.binder.prompt.hasPrefix(head) && item.agent.prompt.hasSuffix(parts.afterUser), item.name)
            XCTAssertEqual(binder.form, .both)
            XCTAssertEqual(agent.question.options.last, DecisionOption(key: "nobody", description: "for you to do yourself; no agent's work"))
            rebuilt += 1
        }
        XCTAssertEqual(rebuilt, 50)
    }

    func testTwoPromptsThatSwiftCallsEqualDifferInBytes() throws {
        let fixture = try RouterFixture.load()
        let nfd = try XCTUnwrap(fixture.cases.first { $0.name == "nfd" })
        let twin = try XCTUnwrap(fixture.cases.first { $0.name == "nfc-twin" })
        XCTAssertEqual(nfd.binder.prompt, twin.binder.prompt, "Swift's == compares canonical equivalence")
        XCTAssertNotEqual(Array(nfd.binder.prompt.utf8), Array(twin.binder.prompt.utf8), "the bytes differ")
        let inputs = fixture.inputs
        let built = try XCTUnwrap(RouterQuestions.binders(state: nfd.state, inputs: inputs))
        XCTAssertEqual(Array(Tev1Prompt.prompt(built.question).utf8), Array(nfd.binder.prompt.utf8), "and the builder keeps nfd's own")
    }

    func testPythonsWhitespaceAndLines() {
        XCTAssertEqual(PythonText.oneLine("a\r\nb"), "a b", "\\r\\n is one break")
        XCTAssertEqual(PythonText.oneLine("a\n"), "a")
        XCTAssertEqual(PythonText.splitlines("a\n"), ["a"], "no empty last line")
        XCTAssertEqual(PythonText.splitlines("a\n\nb"), ["a", "", "b"])
        XCTAssertEqual(PythonText.splitlines(""), [])
        XCTAssertEqual(PythonText.splitlines("\n"), [""])
        XCTAssertEqual(PythonText.oneLine("a\u{2028}b"), "a b")
        XCTAssertEqual(PythonText.oneLine("a\u{0085}b"), "a b")
        XCTAssertEqual(PythonText.oneLine("a\u{1c}b"), "a b")
        XCTAssertEqual(PythonText.oneLine("a\u{1f}b"), "a\u{1f}b", "\\x1f isn't a line break")
        XCTAssertEqual(PythonText.strip("\u{a0} a \u{1f}"), "a", "NBSP and \\x1f are spaces")
        XCTAssertEqual(PythonText.strip("\u{200b}a"), "\u{200b}a", "a zero-width space isn't")
        XCTAssertEqual(PythonText.strip("\u{3000}a\u{202f}"), "a")
        XCTAssertEqual(PythonText.spaces.count, 29, "Python's isspace() set")
    }

    func testTitlesAreCutInCodePoints() {
        // e + a combining acute is two code points, one Character: Python's t[:80] counts code points.
        let marks = String(repeating: "e\u{301}", count: 50)
        XCTAssertEqual(PythonText.prefix(marks, codePoints: 80).unicodeScalars.count, 80)
        XCTAssertEqual(PythonText.prefix(marks, codePoints: 80).count, 40)
        let emoji = String(repeating: "\u{1F469}\u{200D}\u{1F4BB}", count: 30)
        XCTAssertEqual(PythonText.prefix(emoji, codePoints: 80).unicodeScalars.count, 80)
        XCTAssertEqual(PythonText.prefix(emoji, codePoints: 80).unicodeScalars.last, "\u{200D}", "cut inside an emoji, as Python cuts it")
        XCTAssertEqual(PythonText.prefix("short", codePoints: 80), "short")
        let description = RouterQuestions.binderDescription(whatGoesHere: "", titles: [marks])
        XCTAssertEqual(description.unicodeScalars.count, "recent: ".unicodeScalars.count + 80)
    }

    func testJSONAsPythonWritesIt() {
        XCTAssertEqual(PythonText.jsonString("\u{0}"), #""\u0000""#)
        XCTAssertEqual(PythonText.jsonString("\u{1f}\u{1b}"), #""\u001f\u001b""#, "lowercase hex")
        XCTAssertEqual(PythonText.jsonString("\u{7f}"), "\"\u{7f}\"", "DEL isn't escaped")
        XCTAssertEqual(PythonText.jsonString("a/b"), #""a/b""#, "nor a slash")
        XCTAssertEqual(PythonText.jsonString("\u{2029}\u{2028}"), "\"\u{2029}\u{2028}\"", "nor the line separators")
        XCTAssertEqual(PythonText.jsonString("\"\\\n\r\t\u{8}\u{c}"), #""\"\\\n\r\t\b\f""#)
        XCTAssertEqual(PythonText.jsonString("café 😀"), "\"café 😀\"", "nothing beyond ASCII")
    }

    func testDescriptionsAndLimits() {
        XCTAssertEqual(RouterQuestions.binderDescription(whatGoesHere: "", titles: []), "recent: nothing yet")
        XCTAssertEqual(RouterQuestions.binderDescription(whatGoesHere: "  The flat.\n Repairs  ", titles: ["Boiler", "Lease"]),
                       "The flat.  Repairs Recent: Boiler; Lease")
        XCTAssertEqual(RouterQuestions.binderDescription(whatGoesHere: "x", titles: (1...9).map { "t\($0)" }), "x Recent: t1; t2; t3; t4; t5; t6")
        // Fewer than 2 options: no question.
        let one = RouterInputs(binders: [RouterInputs.Binder(name: "Home")], agents: [])
        XCTAssertNil(RouterQuestions.binders(state: "x", inputs: one))
        let agents = try? XCTUnwrap(RouterQuestions.agents(state: "x", inputs: RouterInputs(binders: [], agents: [RouterInputs.Agent(name: "Pennant", description: "errands")])))
        XCTAssertEqual(agents?.question.options.map(\.key), ["Pennant", "nobody"])
        XCTAssertNil(RouterQuestions.agents(state: "x", inputs: RouterInputs(binders: [], agents: [])), "nobody alone isn't a question")
        XCTAssertNil(RouterQuestions.agents(state: "x", inputs: RouterInputs(binders: [], agents: [RouterInputs.Agent(name: "Pennant", description: "errands")],
                                                                              paused: true)), "paused: not asked")
        // Not offered: no description, a name that's nobody, a key twice, an empty one.
        let odd = RouterInputs(binders: [RouterInputs.Binder(name: "Home"), RouterInputs.Binder(name: "Home"), RouterInputs.Binder(name: " "),
                                         RouterInputs.Binder(name: "Work")],
                               agents: [RouterInputs.Agent(name: "Pennant", description: nil), RouterInputs.Agent(name: "Nobody", description: "x"),
                                        RouterInputs.Agent(name: "Kestrel", description: " \n "), RouterInputs.Agent(name: "Inkwell", description: "writing")])
        XCTAssertEqual(RouterQuestions.binders(state: "x", inputs: odd)?.offered.map(\.name), ["Home", "Work"])
        XCTAssertEqual(RouterQuestions.agents(state: "x", inputs: odd)?.question.options.map(\.key), ["Inkwell", "nobody"])
        // Each agent not offered is left out, so a start where it takes cards doesn't rest on numbers that lost its share.
        XCTAssertEqual(RouterQuestions.agents(state: "x", inputs: odd)?.leftOut.map(\.name), ["Pennant", "Nobody", "Kestrel"])
        let twice = RouterInputs(binders: [], agents: [RouterInputs.Agent(name: "Inkwell", description: "writing"), RouterInputs.Agent(name: "Inkwell", description: "posts")],
                                 unoffered: [RouterInputs.Agent(name: "Held", description: "x")])
        XCTAssertEqual(RouterQuestions.agents(state: "x", inputs: twice)?.leftOut.map(\.name), ["Held", "Inkwell"], "a name offered already, after the held ones")
        // The case the review found: Herald, with nothing saying what it's for, takes every binder; Inkwell would get its
        // share, so Inkwell can't start there.
        let herald = RouterInputs(binders: [], agents: [RouterInputs.Agent(name: "Inkwell", description: "writing: blog posts, release notes, newsletters"),
                                                        RouterInputs.Agent(name: "Herald", description: nil)])
        let asked = try? XCTUnwrap(RouterQuestions.agents(state: "Post the launch announcement on our social accounts", inputs: herald))
        XCTAssertEqual(asked?.question.options.map(\.key), ["Inkwell", "nobody"])
        XCTAssertEqual(asked?.leftOut.contains { $0.name == "Herald" && $0.takesCards(from: UUID()) }, true)
        // 30 binders: the 24 latest, kept in name order. 30 agents: the first 23, the rest left out.
        let now = Date()
        let many = RouterInputs(binders: (0..<30).map { RouterInputs.Binder(name: String(format: "B%02d", $0), latest: now.addingTimeInterval(Double($0))) },
                                agents: (0..<30).map { RouterInputs.Agent(name: String(format: "A%02d", $0), description: "work") })
        let binders = RouterQuestions.binders(state: "x", inputs: many)
        XCTAssertEqual(binders?.offered.map(\.name), (6..<30).map { String(format: "B%02d", $0) })
        XCTAssertEqual(binders?.leftOut.count, 6)
        let offered = RouterQuestions.agents(state: "x", inputs: many)
        XCTAssertEqual(offered?.question.options.count, 24)
        XCTAssertEqual(offered?.leftOut.map(\.name), (23..<30).map { String(format: "A%02d", $0) })
        XCTAssertEqual(binders?.form, .titles)
        // The state is kept as typed, at most 2,000 characters.
        XCTAssertEqual(RouterQuestions.binders(state: "  as typed \n", inputs: many)?.question.state, "  as typed \n")
        XCTAssertEqual(RouterQuestions.binders(state: String(repeating: "a", count: 2_500), inputs: many)?.question.state.count, 2_000)
    }

    /// What Settings names beside an agent's start switch: the agents left out of the question that take one of its
    /// binders, where it can never start on its own.
    func testTheAgentsLeftOutBesideAnAgentThatMayStart() {
        let website = UUID(), home = UUID()
        let scribe = RouterInputs.Agent(name: "Scribe", description: "the website: pages, copy and fixes", takes: [website])
        let herald = RouterInputs.Agent(name: "Herald", description: nil)
        let crier = RouterInputs.Agent(name: "Crier", description: " ", takes: [home])
        let held = RouterInputs.Agent(name: "Held", description: "the website's banners", takes: [website])
        let idle = RouterInputs.Agent(name: "Idle", description: nil, takes: [])
        let inputs = RouterInputs(binders: [], agents: [scribe, herald, crier, idle], unoffered: [held])
        XCTAssertEqual(RouterQuestions.leftOut(sharingBindersWith: scribe, inputs: inputs).map(\.name), ["Held", "Herald"],
                       "Herald takes every binder and Held takes Website; Crier takes only Home, and Idle none")
        var everywhere = scribe
        everywhere.takes = nil
        XCTAssertEqual(RouterQuestions.leftOut(sharingBindersWith: everywhere, inputs: inputs).map(\.name), ["Held", "Herald", "Crier"])
        XCTAssertEqual(RouterQuestions.leftOut(sharingBindersWith: herald, inputs: inputs).map(\.name), ["Held", "Crier"], "never itself")
        var paused = inputs
        paused.paused = true
        XCTAssertTrue(RouterQuestions.leftOut(sharingBindersWith: scribe, inputs: paused).isEmpty, "paused: no question, and no start anyway")
        XCTAssertTrue(RouterQuestions.leftOut(sharingBindersWith: scribe, inputs: RouterInputs(binders: [], agents: [scribe])).isEmpty)
        XCTAssertFalse(idle.sharesBinders(with: scribe) || scribe.sharesBinders(with: idle) || crier.sharesBinders(with: scribe))
        XCTAssertTrue(herald.sharesBinders(with: scribe) && scribe.sharesBinders(with: herald) && herald.sharesBinders(with: everywhere))
    }

    func testTheFormOfTheBinders() {
        let mixed = RouterInputs(binders: [RouterInputs.Binder(name: "Home", whatGoesHere: "The flat"), RouterInputs.Binder(name: "Work")], agents: [])
        XCTAssertEqual(RouterQuestions.binders(state: "x", inputs: mixed)?.form, .mixed)
        let tev1 = DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures()).bands
        XCTAssertEqual(tev1.generalThreshold(.mixed), 0.45, "a mix takes the What goes here threshold")
        XCTAssertEqual(tev1.generalThreshold(.titles), 0.33)
        XCTAssertEqual(tev1.generalThreshold(.both), 0.45)
    }
}

final class RouterMathTests: XCTestCase {
    func testSoftmaxAndArgmaxAreTheFixtures() throws {
        let fixture = try RouterFixture.load()
        let inputs = fixture.inputs
        var worst = 0.0
        for item in fixture.cases {
            for (question, keys) in [(item.binder, inputs.binders.map(\.name)), (item.agent, inputs.agents.map(\.name) + ["nobody"])] {
                let probs = RouterMath.softmax(question.logits)
                XCTAssertEqual(probs.count, question.probs.count)
                for (mine, theirs) in zip(probs, question.probs) { worst = max(worst, abs(mine - theirs)) }
                XCTAssertEqual(RouterMath.argmax(probs).map { keys[$0] }, question.argmax, item.name)
            }
        }
        XCTAssertLessThan(worst, 1e-12)
    }

    func testTheFirstOfEqualMaximaWins() {
        XCTAssertEqual(RouterMath.argmax([0.2, 0.4, 0.4]), 1)
        XCTAssertEqual(RouterMath.argmax([0.5]), 0)
        XCTAssertNil(RouterMath.argmax([]))
        XCTAssertEqual(RouterMath.softmax([]), [])
        XCTAssertEqual(RouterMath.softmax([1000, 1000]), [0.5, 0.5], "the maximum comes off first")
    }

    func testLettersAndTheirIDs() {
        for n in 2...24 {
            XCTAssertEqual(Tev1Prompt.letterTokenIDs(count: n), Array(32..<(32 + n)))
        }
        XCTAssertEqual(Tev1Prompt.letters.count, 24)
        XCTAssertEqual(Tev1Prompt.options, 2...24)
        XCTAssertFalse(Tev1Prompt.options.contains(1), "fewer than 2 is refused")
        XCTAssertFalse(Tev1Prompt.options.contains(25), "more than 24 is refused")
        let q = DecisionQuestion(state: "s", question: "q", options: [DecisionOption(key: "a", description: "x"), DecisionOption(key: "b", description: "y")])
        XCTAssertEqual(Tev1Prompt.userJSON(q),
                       #"{"state": "s", "question": "q", "options": [{"label": "A", "key": "a", "description": "x"}, {"label": "B", "key": "b", "description": "y"}]}"#)
    }
}

final class RouterBandsTests: XCTestCase {
    // Which model gets which bands is DecisionBandsTests' (by fingerprint and reader, never a folder's name); these are the
    // bands' own edges, on lane R1's numbers for Tev1 bf16.
    func testTheBandsEdges() {
        let bands = RouterBands(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33, auto: 0.60)
        XCTAssertEqual(bands, DecisionBands.tev1?.bands, "Tev1 bf16's, built in, with Auto's level")
        XCTAssertEqual(bands.band(0.4999), .none)
        XCTAssertEqual(bands.band(0.50), .suggest)
        XCTAssertEqual(bands.band(0.9699), .suggest)
        XCTAssertEqual(bands.band(0.97), .start)
        XCTAssertEqual(bands.band(1), .start)
        let noStart = RouterBands(start: nil, suggest: 0.5, generalBelow: 0.45, generalBelowTitlesOnly: 0.33)
        XCTAssertEqual(noStart.band(0.99), .suggest, "without a start bar, 0.99 is a suggestion")
    }
}

final class RouterRulesTests: XCTestCase {
    private let bands = RouterBands(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33)
    private let website = UUID(), home = UUID(), general = UUID(), llm = UUID()

    private func binder(_ p: Double, form: RouterQuestions.Form = .both, llm: UUID? = nil, named: UUID? = nil) -> BinderPick {
        RouterRules.binder(named: named, model: [(website, p), (home, p / 2)], form: form, bands: bands, llm: llm, fallback: general)
    }

    func testTheBinderSteps() {
        XCTAssertEqual(binder(0.99, named: home), BinderPick(id: home, how: .named), "one you named is final")
        XCTAssertEqual(binder(0.4501), BinderPick(id: website, how: .model, p: 0.4501))
        XCTAssertEqual(binder(0.45), BinderPick(id: website, how: .model, p: 0.45), "at the threshold")
        XCTAssertEqual(binder(0.4499), BinderPick(id: general, how: .fallback), "strictly below: General")
        XCTAssertEqual(binder(0.4499, llm: llm), BinderPick(id: llm, how: .llm), "or the LLM step's first")
        XCTAssertEqual(binder(0.3299, form: .titles), BinderPick(id: general, how: .fallback), "titles alone: 0.33")
        XCTAssertEqual(binder(0.33, form: .titles), BinderPick(id: website, how: .model, p: 0.33))
        XCTAssertEqual(binder(0.40, form: .mixed), BinderPick(id: general, how: .fallback), "a mix: 0.45")
        XCTAssertEqual(RouterRules.binder(named: nil, model: nil, form: .both, bands: bands, llm: llm, fallback: general), BinderPick(id: llm, how: .llm),
                       "Tev1 missing: the LLM step")
        XCTAssertEqual(RouterRules.binder(named: nil, model: [(website, 0.99)], form: .both, bands: nil, llm: nil, fallback: general).how, .fallback,
                       "an unmeasured backend's answer isn't used")
    }

    private func agent(_ model: [RankedOption]?, named: [String] = [], takers: [String] = ["Codex", "Claude Code", "Pennant"], listed: [String]? = nil,
                       kind: RouteKind = .todo, llmAgent: String? = nil, llmFits: String? = nil, agentFit: Bool = true) -> RouterRules.AgentOutcome {
        RouterRules.agent(kind: kind, named: named, model: model, bands: bands, takers: takers, listed: listed, llmAgent: llmAgent, llmFits: llmFits,
                          agentFit: agentFit)
    }

    private func answer(_ pairs: (String, Double)...) -> [RankedOption] { pairs.map { RankedOption(key: $0.0, p: $0.1) } }

    func testTheAgentSteps() {
        XCTAssertNil(agent(answer(("Codex", 0.99), ("nobody", 0.01)), kind: .note).pick, "a note never gets one")
        XCTAssertEqual(agent(answer(("Codex", 0.82), ("nobody", 0.18))).pick, AgentPick(name: "Codex", how: .model, p: 0.82))
        XCTAssertNil(agent(answer(("Codex", 0.30), ("nobody", 0.70))).pick, "nobody on top: none")
        XCTAssertNil(agent(answer(("Codex", 0.4999), ("Pennant", 0.30), ("nobody", 0.2001))).pick, "under 0.50: none")
        XCTAssertEqual(agent(answer(("Codex", 0.50), ("nobody", 0.50))).pick?.name, "Codex", "at 0.50, the first of equal maxima")
        // A non-taker on top gives none, never the second choice: Codex at 0.73 doesn't become the takers' 0.98.
        let notTaker = agent(answer(("Codex", 0.73), ("Pennant", 0.0146), ("nobody", 0.2554)), takers: ["Pennant"])
        XCTAssertNil(notTaker.pick)
        XCTAssertNil(notTaker.notTaker, "and Tev1's pick isn't one you named")
    }

    func testANamedAgentComesFirst() {
        XCTAssertEqual(agent(answer(("Pennant", 0.9), ("nobody", 0.1)), named: ["Codex"]).pick, AgentPick(name: "Codex", how: .named))
        let refused = agent(answer(("Pennant", 0.9), ("nobody", 0.1)), named: ["Kestrel"])
        XCTAssertNil(refused.pick, "no Give to the assign step would refuse")
        XCTAssertEqual(refused.notTaker, "Kestrel", "and the reason")
        // Two named: the one that takes the binder's cards; both take it, Tev1's top among them; else as if none.
        XCTAssertEqual(agent(nil, named: ["Claude Code · app", "Claude Code · site"], takers: ["Claude Code · site"]).pick?.name, "Claude Code · site")
        XCTAssertEqual(agent(answer(("Claude Code · app", 0.6), ("Claude Code · site", 0.3), ("nobody", 0.1)), named: ["Claude Code · app", "Claude Code · site"],
                             takers: ["Claude Code · app", "Claude Code · site"]).pick, AgentPick(name: "Claude Code · app", how: .named))
        // Named, the names decide: Tev1 never names, or starts, an agent you didn't name.
        XCTAssertEqual(agent(answer(("Pennant", 0.6), ("nobody", 0.4)), named: ["A", "B"], takers: ["A", "B", "Pennant"]),
                       RouterRules.AgentOutcome(), "two named that both take it, and Tev1's top is neither: none, never Tev1's")
        XCTAssertEqual(agent(nil, named: ["A", "B"], takers: ["A", "B", "Pennant"], llmFits: "b").pick, AgentPick(name: "B", how: .named),
                       "without Tev1, the LLM's FITS settles them, when it's one of them")
        XCTAssertNil(agent(nil, named: ["A", "B"], takers: ["A", "B", "Pennant"], llmFits: "Pennant").pick, "and never names a third")
        // The review's case: "Ask Pennant to email the venue and have Kestrel book the hotel" on the Summit booth board,
        // which neither takes, with Tev1 sure of Grok Bot, which takes every binder.
        let summit = agent(answer(("Pennant", 0.005), ("Kestrel", 0.005), ("Grok Bot", 0.98), ("nobody", 0.01)), named: ["Pennant", "Kestrel"],
                           takers: ["Grok Bot"])
        XCTAssertNil(summit.pick, "Grok Bot, never named, isn't named on Give to")
        XCTAssertEqual(summit.notTaker, "Pennant", "and the line names one you did, which doesn't take the binder's cards")
        let one = agent(answer(("Grok Bot", 0.98), ("nobody", 0.02)), named: ["Pennant"], takers: ["Grok Bot"])
        XCTAssertEqual(one, RouterRules.AgentOutcome(notTaker: "Pennant"), "as with one name")
    }

    func testANamedAgentThatCantTakeOneNow() {
        // Paused, held or changed outside Binders: it takes the binder's cards by its own list, but isn't a taker now.
        let paused = agent(answer(("Pennant", 0.9), ("nobody", 0.1)), named: ["Pennant"], takers: [], listed: ["Pennant", "Grok Bot"])
        XCTAssertEqual(paused, RouterRules.AgentOutcome(cantTakeNow: "Pennant"), "no Give to, and never the false 'doesn't take its cards'")
        XCTAssertEqual(agent(nil, named: ["Pennant"], takers: [], listed: []).notTaker, "Pennant", "one whose list leaves the binder out still gets that line")
        XCTAssertEqual(agent(nil, named: ["Kestrel", "Pennant"], takers: [], listed: ["Pennant"]).cantTakeNow, "Pennant",
                       "of two named, the one that takes the binder's cards")
    }

    func testWithoutTev1CardsAndCommandModeNameOnlyWhoYouNamed() {
        XCTAssertNil(agent(nil, takers: ["Claude Code"], agentFit: false).pick, "the only taker isn't a reason, without Tev1, outside moments")
        XCTAssertNil(agent(nil, takers: ["Pennant", "Codex"], llmFits: "Pennant", agentFit: false).pick)
        XCTAssertEqual(agent(nil, named: ["Codex"], takers: ["Codex"], agentFit: false).pick, AgentPick(name: "Codex", how: .named), "a name you said still counts")
        XCTAssertEqual(agent(answer(("Codex", 0.8), ("nobody", 0.2)), takers: ["Codex"], agentFit: false).pick, AgentPick(name: "Codex", how: .model, p: 0.8),
                       "and Tev1's answer is used as ever")
    }

    func testOnlyYourTypingNamesAnAgentOnACard() {
        XCTAssertEqual(RouteOrigin.allCases.filter(\.typedByYou), [.typedReady, .typedBacklog, .typedOther, .phone])
        XCTAssertFalse(RouteOrigin.mcp.typedByYou, "an agent's or a tool's words")
        XCTAssertFalse(RouteOrigin.capture.typedByYou, "what a capture heard")
        XCTAssertFalse(RouteOrigin.toBoard.typedByYou, "a to-do or a note, which may be anyone's")
    }

    func testWithoutTev1TodaysOfferStands() {
        XCTAssertEqual(agent(nil, takers: ["Pennant"]).pick, AgentPick(name: "Pennant", how: .onlyTaker), "the only taker, without Tev1")
        XCTAssertNil(agent(answer(("Pennant", 0.2), ("nobody", 0.8)), takers: ["Pennant"]).pick, "never once Tev1 answered: its nobody stands")
        XCTAssertEqual(agent(nil, takers: ["Pennant", "Codex"], llmFits: "pennant").pick, AgentPick(name: "Pennant", how: .llm), "the LLM's FITS among the takers")
        XCTAssertNil(agent(answer(("nobody", 0.9), ("Pennant", 0.1)), takers: ["Pennant", "Codex"], llmFits: "Pennant").pick, "FITS only without Tev1")
        XCTAssertNil(agent(nil, takers: ["Pennant", "Codex"], llmFits: "Kestrel").pick, "FITS must be a taker")
        XCTAssertEqual(agent(nil, takers: ["Pennant", "Codex"], llmAgent: "Codex").pick, AgentPick(name: "Codex", how: .named), "the LLM's AGENT is a name you said")
        XCTAssertEqual(agent(nil, takers: ["Pennant"], llmAgent: "Codex").notTaker, "Codex", "and one that doesn't take the binder gets the reason")
        XCTAssertEqual(agent(answer(("nobody", 0.9), ("Codex", 0.1)), takers: ["Codex"], llmAgent: "Codex").pick, nil,
                       "the LLM's AGENT counts only without Tev1")
    }

    // MARK: Starting

    private func check(_ change: (inout RouterRules.StartCheck) -> Void = { _ in }) -> RouterRules.NotStarted? {
        let now = Date()
        var check = RouterRules.StartCheck(agent: "Claude Code", how: .model, startsOnItsOwn: true, hasOwnPurpose: true, draftsFirst: true,
                                           checksBoard: false, bands: bands, numbersMatch: true, modelTop: RankedOption(key: "Claude Code", p: 0.98),
                                           takesBinder: true, takerNow: true, leftOutTakesBinder: false, origin: .moment, kind: .todo,
                                           phone: RouterRules.PhoneCheck(wake: true, engine: "parakeet-v2", conversation: nil, kind: nil, adds: nil,
                                                                         heard: now.addingTimeInterval(-60), now: now,
                                                                         agreed: ["claude code": "abc"], key: "claude code", fingerprint: "abc"),
                                           wouldWake: true)
        change(&check)
        return RouterRules.mayStart(check)
    }

    func testAStartNeedsEveryCondition() {
        XCTAssertNil(check(), "every condition holds")
        XCTAssertNil(check { $0.origin = .typedReady; $0.kind = .card; $0.phone = nil })
        XCTAssertNil(check { $0.origin = .commandMode; $0.phone = nil })
        XCTAssertNil(check { $0.how = .named }, "a name you said, with Tev1 at the bar: the rules and the model agree")
        XCTAssertNil(check { $0.named = ["Claude Code", "Codex"] }, "one of the agents you named")
        XCTAssertEqual(check { $0.named = ["Pennant", "Kestrel"] }, .notNamed, "never one you didn't name, when you named some")
        XCTAssertEqual(check { $0.startsOnItsOwn = false }, .switchOff)
        XCTAssertEqual(check { $0.hasOwnPurpose = false }, .purposeNotTyped, "kinds alone, or the coding default")
        XCTAssertEqual(check { $0.draftsFirst = false }, .mayAct)
        XCTAssertEqual(check { $0.checksBoard = true }, .checksBoard)
        XCTAssertEqual(check { $0.bands = RouterBands(start: nil, suggest: 0.5, generalBelow: 0.45, generalBelowTitlesOnly: 0.33) }, .noStartBar)
        XCTAssertEqual(check { $0.bands = nil }, .noStartBar, "an unmeasured backend")
        XCTAssertEqual(check { $0.numbersMatch = false }, .numbersDiffer)
        XCTAssertEqual(check { $0.modelTop = RankedOption(key: "Claude Code", p: 0.9699) }, .underBar)
        XCTAssertEqual(check { $0.modelTop = RankedOption(key: "Codex", p: 0.99) }, .notThePick, "not the agent suggested")
        XCTAssertEqual(check { $0.modelTop = nil }, .notThePick)
        XCTAssertEqual(check { $0.takesBinder = false }, .notATaker)
        XCTAssertEqual(check { $0.takerNow = false }, .notATaker)
        XCTAssertEqual(check { $0.leftOutTakesBinder = true }, .leftOutTaker)
        for origin in RouteOrigin.allCases where ![.moment, .commandMode, .typedReady].contains(origin) {
            XCTAssertEqual(check { $0.origin = origin }, .origin, origin.rawValue)
        }
        XCTAssertEqual(check { $0.kind = .idea }, .kind)
        XCTAssertEqual(check { $0.origin = .typedReady; $0.kind = .todo }, .kind)
    }

    func testAStartFromTheIPhone() {
        XCTAssertEqual(check { $0.phone?.engine = "siri" }, .notTheWake, "Tell Binders, even with agreed set")
        XCTAssertEqual(check { $0.phone?.engine = "test" }, .notTheWake)
        XCTAssertEqual(check { $0.phone?.conversation = UUID() }, .notTheWake, "a conversation's Binders, even with agreed set")
        XCTAssertEqual(check { $0.phone?.wake = false }, .notTheWake)
        XCTAssertEqual(check { $0.phone?.kind = "question" }, .notTheWake)
        XCTAssertEqual(check { $0.phone?.adds = ["todo"] }, .notTheWake)
        XCTAssertEqual(check { $0.phone = nil }, .notTheWake)
        XCTAssertEqual(check { $0.phone?.heard = Date().addingTimeInterval(-16 * 60) }, .stale, "heard 16 minutes ago")
        XCTAssertEqual(check { $0.phone?.agreed = nil }, .noYes, "agreed missing")
        XCTAssertEqual(check { $0.phone?.agreed = ["claude code": "made without starts"] }, .noYes)
        XCTAssertEqual(check { $0.phone?.fingerprint = ""; $0.phone?.agreed = ["claude code": ""] }, .noYes)
        XCTAssertEqual(check { $0.wouldWake = false }, .wouldNotWake)
        XCTAssertEqual(RouterRules.PhoneCheck.consentKey(" Claude Code "), "claude code")
    }

    func testPercentsRoundDown() {
        XCTAssertEqual(RouterRules.percent(0.9799), 97)
        XCTAssertEqual(RouterRules.percent(0.82), 82)
        XCTAssertEqual(RouterRules.percent(1), 100)
    }

    func testAStartTakesAYesGivenToEitherSentence() {
        // The yes the iPhone gave to the start sentence, or to the one that also names Auto, which holds it.
        XCTAssertNil(check { $0.phone?.autoFingerprint = "with auto"; $0.phone?.agreed = ["claude code": "with auto"] })
        XCTAssertNil(check { $0.phone?.autoFingerprint = "with auto" }, "the yes given before Auto mode still starts it")
        XCTAssertEqual(check { $0.phone?.autoFingerprint = "with auto"; $0.phone?.agreed = ["claude code": "something else"] }, .noYes)
        XCTAssertEqual(check { $0.phone?.autoFingerprint = ""; $0.phone?.agreed = ["claude code": ""] }, .noYes)
        XCTAssertNil(check { $0.wakeable = false }, "the start rule keeps wouldWake, which says more")
        XCTAssertEqual(check { $0.wakeable = true; $0.wouldWake = false }, .wouldNotWake, "past the hourly cap, the start rule starts nothing")
        XCTAssertEqual(check { $0.origin = .auto }, .origin, "nothing heard on its own in Auto starts by the start rule")
    }
}

/// Auto's rule (RouterRules.mayHandOver), case by case: every condition, each refusal with its reason, and the first one
/// when two fail, for the order the line can help most. Names are the bench's made-up agents and binders.
final class AutoRuleTests: XCTestCase {
    private let tev1 = RouterBands(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33, auto: 0.60)
    private let now = Date()
    /// How the iPhone keys its yes for the base's agent.
    private let key = RouterRules.PhoneCheck.consentKey("Claude Code · pocketfold-app")
    private static let standard = ["Claude Code · pocketfold-app", "Codex · pocketfold-site", "Pennant", "Grok Bot", "Kestrel", "Inkwell", "Hourglass",
                                   "Abacus"]

    /// From a base that hands over: Auto, heard on its own, a to-do, the Mac's Auto yes and the iPhone's for the "auto"
    /// fingerprint, Tev1's bands, the model's top the agent at 0.62, heard a minute ago, wakeable, the phone allowed.
    private func check(agent: String = "Claude Code · pocketfold-app",
                       _ change: (inout RouterRules.StartCheck, inout RouterRules.AutoCheck) -> Void = { _, _ in }) -> RouterRules.NotStarted? {
        let key = RouterRules.PhoneCheck.consentKey(agent)
        var check = RouterRules.StartCheck(agent: agent, how: .model, startsOnItsOwn: true, hasOwnPurpose: true, draftsFirst: true, checksBoard: false,
                                           bands: tev1, numbersMatch: true, modelTop: RankedOption(key: agent, p: 0.62), takesBinder: true, takerNow: true,
                                           leftOutTakesBinder: false, origin: .auto, kind: .todo,
                                           phone: RouterRules.PhoneCheck(wake: false, engine: "parakeet-v2", conversation: nil, kind: nil,
                                                                         adds: MomentModes.everyKind, heard: now.addingTimeInterval(-60), now: now,
                                                                         agreed: [key: "with auto"], key: key, fingerprint: "with starts",
                                                                         autoFingerprint: "with auto"),
                                           wouldWake: true, wakeable: true)
        var auto = RouterRules.AutoCheck(mode: .auto, phoneAllowed: true, levelNow: 0.60, startsInAuto: true)
        change(&check, &auto)
        return RouterRules.mayHandOver(check, auto: auto)
    }

    /// What the Mac fills in from the words (DESIGN.md 3.2): the names found exactly, those heard loosely, and whether the
    /// pick is only mentioned in the words as heard.
    private func names(_ text: String, pick: String) -> (named: [String], heard: [String], onlyMentioned: Bool) {
        let named = NamedAgents.find(in: [text], agents: Self.standard)
        guard named.isEmpty else { return (named, [], false) }
        let asHeard = NamedAgents.asHeard(text, agents: Self.standard)
        return ([], NamedAgents.heard(in: [text], agents: Self.standard).map(\.agent),
                !NamedAgents.mentioned(in: [asHeard], agents: [pick]).isEmpty && NamedAgents.find(in: [asHeard], agents: [pick]).isEmpty)
    }

    func testEveryConditionHolds() {
        XCTAssertNil(check(), "a to-do heard on its own")
        XCTAssertNil(check { c, _ in c.kind = .idea }, "an idea too")
        XCTAssertNil(check { c, _ in c.origin = .moment; c.phone?.wake = true }, "a Binders, … in Auto, a to-do")
        XCTAssertNil(check { c, _ in c.origin = .moment; c.phone?.wake = true; c.kind = .idea }, "and an idea")
        XCTAssertNil(check { c, _ in c.phone?.adds = nil }, "with or without adds")
    }

    func testWhereItCameFrom() {
        for mode in [nil, MomentMode.suggest, .add] {
            XCTAssertEqual(check { _, y in y.mode = mode }, .notAuto, mode?.rawValue ?? "no mode")
        }
        for origin in RouteOrigin.allCases where ![.moment, .auto, .solo].contains(origin) {
            XCTAssertEqual(check { c, _ in c.origin = origin }, .origin, origin.rawValue)
        }
        XCTAssertEqual(check { c, _ in c.kind = .note }, .kind)
        XCTAssertEqual(check { c, _ in c.kind = .card }, .kind)
        XCTAssertEqual(check { c, _ in c.phone?.engine = "siri" }, .notOnItsOwn)
        XCTAssertEqual(check { c, _ in c.phone?.engine = "Siri" }, .notOnItsOwn)
        XCTAssertEqual(check { c, _ in c.phone?.engine = "test" }, .notOnItsOwn, "the debug pretend")
        XCTAssertEqual(check { c, _ in c.phone?.conversation = UUID() }, .notOnItsOwn, "a conversation's words")
        XCTAssertEqual(check { c, _ in c.phone?.kind = "question" }, .notOnItsOwn, "Ask")
        XCTAssertEqual(check { c, _ in c.phone?.wake = true }, .notOnItsOwn, "heard on its own, but its wake says Binders, …")
        XCTAssertEqual(check { c, _ in c.origin = .moment; c.phone?.wake = false }, .notOnItsOwn, "a Binders, … the iPhone didn't hear as one")
        XCTAssertEqual(check { c, _ in c.phone = nil }, .notOnItsOwn)
        XCTAssertEqual(check { _, y in y.phoneAllowed = false }, .phoneNotAllowed)
        XCTAssertEqual(check { _, y in y.hold = "voice" }, .heldOnPhone)
        XCTAssertEqual(check { c, _ in c.phone?.heard = now.addingTimeInterval(-(12 * 3_600 + 1)) }, .tooLongAgo, "12 hours and a second")
        XCTAssertNil(check { c, _ in c.phone?.heard = now.addingTimeInterval(-12 * 3_600) }, "12 hours exactly")
        XCTAssertEqual(check { c, _ in c.phone?.heard = now.addingTimeInterval(12 * 3_600 + 60) }, .tooLongAgo, "12 hours and a minute ahead")
        // The first that fails, in order.
        XCTAssertEqual(check { c, y in y.mode = .suggest; c.origin = .conversation }, .notAuto)
        XCTAssertEqual(check { c, _ in c.origin = .siri; c.kind = .note }, .origin)
        XCTAssertEqual(check { c, _ in c.kind = .note; c.phone = nil }, .kind)
        XCTAssertEqual(check { c, y in c.phone?.conversation = UUID(); y.phoneAllowed = false }, .notOnItsOwn)
        XCTAssertEqual(check { _, y in y.phoneAllowed = false; y.hold = "voice" }, .phoneNotAllowed)
        XCTAssertEqual(check { c, y in y.hold = "audio"; c.bands = nil; y.levelNow = nil }, .heldOnPhone)
        XCTAssertEqual(check { c, _ in c.phone?.heard = now.addingTimeInterval(-13 * 3_600); c.bands = nil }, .tooLongAgo)
    }

    func testTheModel() {
        XCTAssertEqual(check { c, y in c.bands = nil; y.levelNow = nil }, .noAutoLevel, "Off: no bands, and no level now")
        XCTAssertEqual(check { c, y in c.bands = DecisionBands.unmeasured; y.levelNow = nil }, .noAutoLevel, "a model not measured")
        XCTAssertEqual(check { c, _ in c.bands = RouterBands(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33) }, .noAutoLevel,
                       "R1's bands, from before Auto mode")
        XCTAssertEqual(check { c, _ in c.bands = RouterBands(start: nil, suggest: RouterBands.never, generalBelow: 0.45, generalBelowTitlesOnly: 0.33) },
                       .noAutoLevel, "a model that names no agent")
        XCTAssertEqual(check { c, _ in c.bands = nil }, .noAnswer, "a level now, but no answer for this one")
        XCTAssertEqual(check { c, _ in c.numbersMatch = false }, .numbersDiffer)
        XCTAssertEqual(check { c, _ in c.numbersMatch = false; c.draftsFirst = false }, .numbersDiffer, "the model comes before the agent")
    }

    func testTheAgent() {
        XCTAssertEqual(check { c, _ in c.draftsFirst = false; c.startsOnItsOwn = false }, .mayAct, "never sent to a switch its editor doesn't have")
        XCTAssertEqual(check { c, _ in c.checksBoard = true; c.startsOnItsOwn = false }, .checksBoard)
        XCTAssertEqual(check { c, _ in c.startsOnItsOwn = false }, .switchOff)
        XCTAssertEqual(check { _, y in y.startsInAuto = false }, .switchBeforeAuto, "switched on before Auto mode")
        XCTAssertEqual(check { c, y in y.startsInAuto = false; c.hasOwnPurpose = false }, .switchBeforeAuto)
        XCTAssertEqual(check { c, _ in c.hasOwnPurpose = false }, .purposeNotTyped)
        XCTAssertEqual(check { c, _ in c.wakeable = false }, .wouldNotWake, "held, changed outside Binders, or off")
        XCTAssertEqual(check { c, _ in c.wakeable = nil; c.wouldWake = false }, .wouldNotWake, "from a caller before it: wouldWake stands for it")
        XCTAssertNil(check { c, _ in c.wakeable = nil }, "and when it would wake")
        XCTAssertNil(check { c, _ in c.wakeable = true; c.wouldWake = false }, "past the hourly cap it's still handed over, and waits in Ready")
        XCTAssertEqual(check { c, _ in c.takesBinder = false }, .notATaker, "not its binder")
        XCTAssertEqual(check { c, _ in c.takerNow = false }, .notATaker, "can't take one now")
        XCTAssertEqual(check { c, _ in c.leftOutTakesBinder = true }, .leftOutTaker)
        XCTAssertEqual(check { c, _ in c.leftOutTakesBinder = true; c.named = ["Codex · pocketfold-site"] }, .leftOutTaker, "before the names")
    }

    func testANameYouSaidDecides() {
        XCTAssertEqual(check { c, _ in c.named = ["Codex · pocketfold-site"] }, .notNamed)
        // Test explicit-20: "Get Grok Bot to write the intro for the October newsletter", the model's top Inkwell at 0.81.
        let said = names("Get Grok Bot to write the intro for the October newsletter", pick: "Grok Bot")
        XCTAssertEqual(said.named, ["Grok Bot"])
        XCTAssertNil(check(agent: "Grok Bot") { c, _ in c.how = .named; c.named = said.named; c.modelTop = RankedOption(key: "Inkwell", p: 0.81) },
                     "the model's top another agent")
        XCTAssertNil(check(agent: "Grok Bot") { c, _ in c.how = .named; c.named = said.named; c.modelTop = RankedOption(key: "Grok Bot", p: 0.15) },
                     "and at 0.15")
        XCTAssertNil(check(agent: "Grok Bot") { c, _ in c.how = .named; c.named = said.named; c.modelTop = nil }, "or with no agent answer")
        XCTAssertEqual(check(agent: "Grok Bot") { c, _ in c.named = said.named; c.bands = nil }, .noAnswer, "it still needs the model to answer")
        XCTAssertEqual(check(agent: "Grok Bot") { c, y in c.named = said.named; c.bands = DecisionBands.unmeasured; y.levelNow = nil }, .noAutoLevel,
                       "and an Auto level")
        XCTAssertEqual(check(agent: "Grok Bot") { c, _ in c.named = said.named; c.phone?.agreed = nil }, .noYes, "and your yes")
        XCTAssertEqual(check(agent: "Grok Bot") { c, _ in c.named = said.named; c.startsOnItsOwn = false }, .switchOff, "and its switch")
    }

    func testOtherNamesAndMentions() {
        XCTAssertEqual(check { _, y in y.namedSomeoneElse = true }, .namedSomeoneElse, "the AGENT line named Sam")
        XCTAssertNil(check { c, y in y.namedSomeoneElse = true; c.named = ["Claude Code · pocketfold-app"] }, "a name you said decides")
        // The bench's misspelt names: whoever the model's top is, only the agent heard may get it.
        let noisy: [(String, String)] = [
            ("um so can you give the the sync bug to cloud code", "Claude Code · pocketfold-app"),                 // noisy-01
            ("tell co decks the um the blog images don't load on the, on the new posts", "Codex · pocketfold-site"),  // noisy-03
            ("grok but can you find like the cheapest way to get to Porto", "Grok Bot"),                              // noisy-05
            ("ink well can do the blog post about, um, the new pricing I think", "Inkwell"),                          // noisy-08
        ]
        for (text, meant) in noisy {
            let other = meant == "Inkwell" ? "Grok Bot" : "Inkwell"
            let wrong = names(text, pick: other)
            XCTAssertEqual(wrong.named, [], text)
            XCTAssertEqual(wrong.heard, [meant], text)
            XCTAssertEqual(check(agent: other) { c, y in y.heard = wrong.heard; y.onlyMentioned = wrong.onlyMentioned }, .heardAnother, text)
            let right = names(text, pick: meant)
            XCTAssertFalse(right.onlyMentioned, text)
            XCTAssertNil(check(agent: meant) { c, y in y.heard = right.heard; y.onlyMentioned = right.onlyMentioned }, text)
        }
        // Only mentioned, as written (test mention-03) and as heard.
        let written = names("Look over what Claude Code changed in the sync code before I merge it", pick: "Claude Code · pocketfold-app")
        XCTAssertEqual(written.named, [])
        XCTAssertEqual(written.heard, [])
        XCTAssertTrue(written.onlyMentioned)
        XCTAssertEqual(check { _, y in y.onlyMentioned = written.onlyMentioned }, .onlyMentioned)
        let heard = names("look over what cloud code changed", pick: "Claude Code · pocketfold-app")
        XCTAssertEqual(heard.heard, ["Claude Code · pocketfold-app"])
        XCTAssertTrue(heard.onlyMentioned)
        XCTAssertEqual(check { _, y in y.heard = heard.heard; y.onlyMentioned = heard.onlyMentioned }, .onlyMentioned)
        // In order: someone who isn't an agent, then another agent heard, then only mentioned, then the pick.
        XCTAssertEqual(check { _, y in y.namedSomeoneElse = true; y.heard = ["Inkwell"] }, .namedSomeoneElse)
        XCTAssertEqual(check { _, y in y.heard = ["Inkwell"]; y.onlyMentioned = true }, .heardAnother)
        XCTAssertEqual(check { c, y in y.onlyMentioned = true; c.modelTop = nil }, .onlyMentioned)
    }

    func testThePickAndAutosBar() {
        XCTAssertEqual(check { c, _ in c.modelTop = nil }, .notThePick, "no agent answer")
        XCTAssertEqual(check { c, _ in c.modelTop = RankedOption(key: "Inkwell", p: 0.9) }, .notThePick)
        XCTAssertEqual(check { c, _ in c.modelTop = RankedOption(key: c.agent, p: 0.5999) }, .underAutoBar)
        XCTAssertNil(check { c, _ in c.modelTop = RankedOption(key: c.agent, p: 0.60) }, "at the bar")
        XCTAssertNil(check { c, _ in c.modelTop = RankedOption(key: c.agent, p: 0.55); c.bands?.auto = 0.55 }, "each model its own bar")
        XCTAssertEqual(check { c, _ in c.bands?.auto = 0.70; c.modelTop = RankedOption(key: c.agent, p: 0.6999) }, .underAutoBar)
        XCTAssertNil(check { c, _ in c.bands?.auto = 0.70; c.modelTop = RankedOption(key: c.agent, p: 0.70) })
        XCTAssertNil(check { c, _ in c.modelTop = RankedOption(key: c.agent, p: 0.62); c.bands?.start = nil }, "no start level needed")
    }

    func testYourYes() {
        XCTAssertEqual(check { c, _ in c.phone?.agreed = nil }, .noYes, "none")
        XCTAssertEqual(check { c, _ in c.phone?.agreed = [key: "with starts"] }, .noYes,
                       "a yes given before Auto mode, to the start sentence alone")
        XCTAssertNil(RouterRules.mayStart(startCheck { c in c.phone?.agreed = ["claude code": "with starts"] }), "which the start rule still takes")
        XCTAssertEqual(check { c, _ in c.phone?.autoFingerprint = nil }, .noYes, "no Auto fingerprint: a phone without a mode, or no Auto yes")
        XCTAssertEqual(check { c, _ in c.phone?.autoFingerprint = ""; c.phone?.agreed = [key: ""] }, .noYes, "an empty one")
        XCTAssertEqual(check { c, _ in c.phone?.agreed = ["someone else": "with auto"] }, .noYes, "a yes for another agent")
    }

    /// The same base, as a "Binders, …" the start rule may start: at the start level, fresh, with the start sentence's yes.
    private func startCheck(_ change: (inout RouterRules.StartCheck) -> Void) -> RouterRules.StartCheck {
        var check = RouterRules.StartCheck(agent: "Claude Code", how: .model, startsOnItsOwn: true, hasOwnPurpose: true, draftsFirst: true, checksBoard: false,
                                           bands: tev1, numbersMatch: true, modelTop: RankedOption(key: "Claude Code", p: 0.98), takesBinder: true,
                                           takerNow: true, leftOutTakesBinder: false, origin: .moment, kind: .todo,
                                           phone: RouterRules.PhoneCheck(wake: true, engine: "parakeet-v2", conversation: nil, kind: nil, adds: nil,
                                                                         heard: now.addingTimeInterval(-60), now: now, agreed: ["claude code": "with auto"],
                                                                         key: "claude code", fingerprint: "with starts", autoFingerprint: "with auto"),
                                           wouldWake: true)
        change(&check)
        return check
    }

    func testRepeatsAndHowManyAtOnce() {
        XCTAssertEqual(check { _, y in y.handedAlready = true }, .alreadyHanded)
        XCTAssertEqual(check { _, y in y.handedAlready = true; y.lateRecently = 9 }, .alreadyHanded, "before how many")
        func late(_ age: TimeInterval, _ recently: Int) -> RouterRules.NotStarted? {
            check { c, y in c.phone?.heard = now.addingTimeInterval(-age); y.lateRecently = recently }
        }
        XCTAssertEqual(late(20 * 60, 5), .tooManyAtOnce, "heard 20 minutes ago, with 5 late ones in the window")
        XCTAssertNil(late(20 * 60, 4), "the fifth goes")
        XCTAssertNil(late(15 * 60, 9), "15 minutes exactly is fresh: not counted")
        XCTAssertEqual(late(-3 * 60, 5), .tooManyAtOnce, "3 minutes in the future is late")
        XCTAssertNil(late(-2 * 60, 9), "2 minutes ahead is the clocks' slack")
        XCTAssertNil(late(11 * 3_600, 0), "hours late, the first goes")
    }

    func testTheStartRuleNeverTakesAutosOriginAndTheReasonsAreDistinct() {
        XCTAssertEqual(RouterRules.mayStart(startCheck { c in c.origin = .auto; c.phone?.wake = false }), .origin)
        XCTAssertFalse(RouteOrigin.auto.mayStart)
        XCTAssertFalse(RouteOrigin.auto.typedByYou)
        XCTAssertEqual(RouteOrigin.allCases.filter(\.mayHandOverInAuto), [.moment, .auto, .solo])
        XCTAssertEqual(RouteOrigin.auto.rawValue, "auto")
        let raw = RouterRules.NotStarted.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raw).count, raw.count, "every reason its own words in the log")
        XCTAssertEqual(RouterRules.NotStarted.tooManyAtOnce.rawValue, "too many at once")
        XCTAssertEqual(RouterRules.NotStarted.notAuto.rawValue, "not in Auto")
    }
}

final class SafetensorsCheckTests: XCTestCase {
    private func header(_ tensors: [String: [UInt64]]) -> Data {
        var object: [String: Any] = ["__metadata__": ["format": "mlx"]]
        for (name, offsets) in tensors { object[name] = ["dtype": "BF16", "shape": [2], "data_offsets": offsets] }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testAGoodHeader() {
        let data = header(["a": [0, 4], "b": [4, 10]])
        XCTAssertNil(SafetensorsCheck.problem(headerLength: UInt64(data.count), header: data, fileSize: 8 + UInt64(data.count) + 10))
    }

    func testAFileCutShort() {
        let data = header(["a": [0, 1_000_000]])
        let problem = SafetensorsCheck.problem(headerLength: UInt64(data.count), header: data, fileSize: 1_024)
        XCTAssertEqual(problem, "model.safetensors is shorter than its header says: 0 of 1 MB")
    }

    func testOffsetsThatOverlap() {
        let data = header(["a": [0, 6], "b": [4, 10]])
        XCTAssertEqual(SafetensorsCheck.problem(headerLength: UInt64(data.count), header: data, fileSize: 8 + UInt64(data.count) + 10),
                       "model.safetensors has tensors that overlap")
    }

    func testAHeaderPastTheEnd() {
        XCTAssertEqual(SafetensorsCheck.problem(headerLength: 5_000, header: Data(), fileSize: 1_000), "model.safetensors is shorter than its header says")
    }

    func testAHeaderThatIsntJSON() {
        let data = Data("not json at all".utf8)
        XCTAssertEqual(SafetensorsCheck.problem(headerLength: UInt64(data.count), header: data, fileSize: 1_000),
                       "model.safetensors has a header that can't be read")
    }
}

final class RouterLogTests: XCTestCase {
    func testOldLinesGoFirstThenTheCaps() {
        let now = Date()
        func line(_ age: TimeInterval) -> String { RouterLogEntry(at: now.addingTimeInterval(-age), origin: "moment", did: "filed").line()! }
        let old = line(91 * 86_400)
        let fresh = (0..<5_001).map { line(Double(5_001 - $0)) }
        let kept = RouterLog.trimmed([old] + fresh, now: now)
        XCTAssertEqual(kept.count, 4_000, "past 5,000 lines, the newest 4,000")
        XCTAssertEqual(kept.last, fresh.last)
        XCTAssertFalse(kept.contains(old), "a line from 91 days ago goes")
        XCTAssertEqual(RouterLog.trimmed([old, line(10)], now: now).count, 1, "old lines go even under the cap")
        XCTAssertEqual(RouterLog.trimmed(["not json", line(10)], now: now).count, 1, "and lines that don't read")
        XCTAssertEqual(RouterLog.trimmed(fresh.suffix(10).map { $0 }, now: now, maxBytes: 3 * (fresh[0].utf8.count + 1)).count, 3, "and the bytes")
    }

    func testAnEntryHoldsNoWordsAndNoNames() throws {
        let binder = UUID(), agent = UUID()
        let entry = RouterLogEntry(origin: RouteOrigin.moment.rawValue, kind: RouteKind.todo.rawValue, backend: DecisionReader.tev1.id, ms: 155, form: "both",
                                   binder: .init(id: binder.uuidString, how: "model", p: 0.912345,
                                                 top: [.init(id: binder.uuidString, p: 0.912345), .init(id: UUID().uuidString, p: 0.05)]),
                                   agent: .init(id: agent.uuidString, how: "model", p: 0.98, top: [.init(id: agent.uuidString, p: 0.98), .init(id: "nobody", p: 0.02)]),
                                   did: "started", card: UUID())
        let line = try XCTUnwrap(entry.line())
        for name in ["Zanzibar binder", "Quillfeather agent", "fix the login typo"] {
            XCTAssertFalse(line.contains(name), name)
        }
        XCTAssertTrue(line.contains("[\"\(binder.uuidString)\",0.9123]"), "ranked as [id, p] to 4 places: \(line)")
        XCTAssertEqual(RouterLogEntry.decode(line), RouterLogEntry.decode(line))
        XCTAssertEqual(RouterLogEntry.decode(line)?.agent?.top?.last?.id, "nobody")
        XCTAssertFalse(line.contains("\n"))
    }

    func testWhichModelAnsweredAndWhoseBands() throws {
        let entry = RouterLogEntry(at: Date(timeIntervalSince1970: 1_792_425_731), origin: RouteOrigin.typedReady.rawValue, kind: RouteKind.card.rawValue,
                                   backend: DecisionReader.tev1.id,
                                   model: DecisionBands.tev1BF16.fingerprint, bands: ResolvedBands.Source.builtIn.logName, ms: 80, did: "suggested",
                                   whyNotStarted: RouterRules.NotStarted.underBar.rawValue)
        let line = try XCTUnwrap(entry.line())
        XCTAssertTrue(line.contains(#""backend":"tev1.1/256""#), line)
        XCTAssertTrue(line.contains(#""model":"mlx1-b73a343455582c89eed2254a""#), line)
        XCTAssertTrue(line.contains(#""bands":"built-in""#), line)
        XCTAssertEqual(RouterLogEntry.decode(line), entry)
        XCTAssertEqual(RouterLogEntry.decode(line)?.model, "mlx1-b73a343455582c89eed2254a")
        XCTAssertEqual(ResolvedBands.Source.measured(Date()).logName, "measured")
        XCTAssertEqual(ResolvedBands.Source.unmeasured.logName, "unmeasured")
    }

    func testTheModelIsNamedByItsFingerprintOnly() throws {
        // A folder choice and a decision server: the log has the fingerprint, the reader and whose bands, nothing else of them.
        let folder = DecisionChoice.folder("/Users/sam/Models/Pocketfold Decider")
        let folderModel = DecisionIdentity(fingerprint: DecisionFingerprint.folder([.init(name: "model.safetensors", size: 10, sha256: "ab")]), reader: "chat.1/256")
        let server = DecisionIdentity(server: .init(address: "http://127.0.0.1:18708", names: ["kev-latest", "jev-latest"], fields: ["run=runs/kev-0.8b"],
                                                    answeredBy: ["jev-qwen T=1.1 shim=shim.py@0123456789ab"], probes: [[0.6, 0.4]]))
        for identity in [folderModel, server] {
            let entry = RouterLogEntry(origin: RouteOrigin.mcp.rawValue, kind: RouteKind.card.rawValue, backend: identity.reader, model: identity.fingerprint,
                                       bands: ResolvedBands.Source.unmeasured.logName, did: "filed")
            let line = try XCTUnwrap(entry.line())
            for kept in [folder.stored, "Pocketfold Decider", "/Users/sam", "mlx-community/Qwen3.5-4B-MLX-4bit", "127.0.0.1", "18708", "kev-latest",
                         "jev-latest", "runs/kev-0.8b", "jev-qwen", "shim.py"] {
                XCTAssertFalse(line.contains(kept), "\(kept) in \(line)")
            }
            XCTAssertTrue(line.contains(identity.fingerprint))
        }
    }

    func testLaneR1sLinesStillRead() throws {
        // As lane R1 wrote them: no model or bands, its backend id, and its words for a pick that wasn't Tev1's.
        let r1 = #"{"at":"2026-10-18T21:40:02Z","backend":"tev1-0.8b-mlx-bf16/256","did":"suggested","id":"6A1F3C1E-9D2B-4C55-8A0B-3E2F1D4C5B6A","#
            + #""kind":"card","ms":92,"origin":"typedReady","v":1,"whyNotStarted":"not Tev1's pick"}"#
        let entry = try XCTUnwrap(RouterLogEntry.decode(r1))
        XCTAssertNil(entry.model)
        XCTAssertNil(entry.bands)
        XCTAssertEqual(entry.backend, "tev1-0.8b-mlx-bf16/256")
        XCTAssertEqual(entry.whyNotStarted, "not Tev1's pick")
    }

    func testTheModeIsKeptAndAutosOriginReads() throws {
        let entry = RouterLogEntry(at: Date(timeIntervalSince1970: 1_792_431_731), origin: RouteOrigin.auto.rawValue, kind: RouteKind.idea.rawValue,
                                   did: "started", moment: UUID(), mode: MomentMode.auto.rawValue)
        let line = try XCTUnwrap(entry.line())
        XCTAssertTrue(line.contains(#""mode":"auto""#), line)
        XCTAssertTrue(line.contains(#""origin":"auto""#), line)
        XCTAssertEqual(RouterLogEntry.decode(line), entry)
        XCTAssertEqual(RouterLogEntry.decode(line)?.mode, "auto")
        XCTAssertFalse(try XCTUnwrap(RouterLogEntry(origin: "moment", did: "filed").line()).contains("mode"), "nil isn't written")
        // A line from before it.
        let before = #"{"at":"2026-10-18T21:40:02Z","did":"started","id":"6A1F3C1E-9D2B-4C55-8A0B-3E2F1D4C5B6A","kind":"todo","origin":"moment","v":1}"#
        XCTAssertNil(try XCTUnwrap(RouterLogEntry.decode(before)).mode)
    }

    func testWhyNotStartedNamesNoModel() throws {
        // The decision model is a choice now, so the words name none; R1's "not Tev1's pick" stays a string in its lines.
        XCTAssertEqual(RouterRules.NotStarted.notThePick.rawValue, "not the model's pick")
        XCTAssertEqual(RouterRules.NotStarted.modelChanged.rawValue, "the decision model changed")
        XCTAssertEqual(RouterRules.NotStarted.notConfirmed.rawValue, "the server didn't confirm its model")
        XCTAssertNil(RouterRules.NotStarted(rawValue: "not Tev1's pick"))
        let entry = RouterLogEntry(origin: RouteOrigin.typedReady.rawValue, kind: RouteKind.card.rawValue, did: "suggested",
                                   whyNotStarted: RouterRules.NotStarted.modelChanged.rawValue)
        let line = try XCTUnwrap(entry.line())
        XCTAssertEqual(RouterLogEntry.decode(line)?.whyNotStarted, "the decision model changed")
    }
}
