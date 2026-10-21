import XCTest
@testable import BindersKit

/// The named-agent matcher against the router bench (Fixtures/router/named.json): every bench item that names an agent,
/// or is meant to name none (explicit_agent, mentions_agent_no_work and the rest, in the standard and large libraries),
/// and hand-made cases: lowercase text, possessives, negations, "should be", get and make, a critic's probe. Every name in
/// it is made up.
final class NamedAgentsTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let id: String
            let library: String
            let category: String
            let text: String
            let expect: [String]
        }

        let agents: [String: [String]]
        let cases: [Case]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "named", withExtension: "json", subdirectory: "Fixtures/router"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testEveryCaseOfTheBench() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture.cases.count, 115)
        var wrong: [String] = []
        for item in fixture.cases {
            let agents = try XCTUnwrap(fixture.agents[item.library])
            let found = NamedAgents.find(in: [item.text], agents: agents)
            if found != item.expect { wrong.append("\(item.id) (\(item.library)): \(item.text) → \(found), expected \(item.expect)") }
        }
        XCTAssertTrue(wrong.isEmpty, wrong.joined(separator: "\n"))
        XCTAssertEqual(fixture.cases.filter { $0.category == "hand" }.count, 17)
    }

    func testTheSubstringRulesMistakes() {
        let agents = ["Coach", "Pennant", "Codex · pocketfold-site"]
        XCTAssertEqual(NamedAgents.find(in: ["Book the coach to the airport"], agents: agents), [], "the capitals don't match")
        XCTAssertEqual(NamedAgents.find(in: ["book the coach to the airport"], agents: agents), [], "book hands nothing over")
        XCTAssertEqual(NamedAgents.find(in: ["Pennant booked the wrong train last time"], agents: agents), [], "a mention")
        XCTAssertEqual(NamedAgents.find(in: ["Pennant's invoice came in, pay it Friday"], agents: agents), [],
                       "an agent's name in the words, with the work for you: a mention (Tev1 alone may still suggest it)")
        XCTAssertEqual(NamedAgents.find(in: ["Give the login bug to Codex"], agents: agents), ["Codex · pocketfold-site"])
        XCTAssertEqual(NamedAgents.find(in: ["remind me to give the booth plan to Pennant"], agents: agents), ["Pennant"])
        XCTAssertEqual(NamedAgents.find(in: ["I need to book the venue", "Give the venue list to Pennant"], agents: agents), ["Pennant"],
                       "any of the texts: what you said, or the rules' to-do")
        XCTAssertEqual(NamedAgents.find(in: [""], agents: agents), [])
        XCTAssertEqual(NamedAgents.short("Claude Code · binders-io/app"), "Claude Code")
    }

    // MARK: Mentioned, and heard (Auto's guards)

    func testEveryAgentFindNamesIsMentioned() throws {
        let fixture = try fixture()
        for item in fixture.cases {
            let agents = try XCTUnwrap(fixture.agents[item.library])
            let mentioned = NamedAgents.mentioned(in: [item.text], agents: agents)
            XCTAssertTrue(Set(NamedAgents.find(in: [item.text], agents: agents)).isSubset(of: mentioned), "\(item.id): \(item.text)")
            if item.category == "mentions_agent_no_work" {
                // Each has an agent in its words, and nothing there hands it work: only mentioned.
                XCTAssertFalse(mentioned.isEmpty, "\(item.id): \(item.text)")
                XCTAssertTrue(NamedAgents.find(in: [item.text], agents: agents).isEmpty, "\(item.id)")
            }
        }
        let standard = try XCTUnwrap(fixture.agents["standard"])
        let mentions: [(String, String)] = [("mention-03", "Claude Code · pocketfold-app"), ("mention-06", "Kestrel"), ("mention-12", "Grok Bot"),
                                            ("mention-14", "Grok Bot"), ("mention-16", "Codex · pocketfold-site")]
        for (id, agent) in mentions {
            let item = try XCTUnwrap(fixture.cases.first { $0.id == id && $0.library == "standard" }, id)
            XCTAssertEqual(NamedAgents.mentioned(in: [item.text], agents: standard), [agent], "\(id): \(item.text)")
            XCTAssertTrue(NamedAgents.find(in: [item.text], agents: standard).isEmpty, "\(id): mentioned, not given the work")
        }
    }

    func testMentionedAsWrittenOnly() {
        let agents = ["Coach", "Pennant", "Codex · pocketfold-site", "Claude Code · pocketfold-app"]
        XCTAssertEqual(NamedAgents.mentioned(in: ["Pennant's invoice came in, pay it Friday"], agents: agents), ["Pennant"], "a possessive too")
        XCTAssertEqual(NamedAgents.mentioned(in: ["Book the coach to the airport"], agents: agents), [], "not with other capitals")
        XCTAssertEqual(NamedAgents.mentioned(in: ["book the coach to the airport"], agents: agents), ["Coach"], "any case where there are no capitals")
        XCTAssertEqual(NamedAgents.mentioned(in: ["give this to codex"], agents: agents), ["Codex · pocketfold-site"])
        XCTAssertEqual(NamedAgents.mentioned(in: ["Look over what Claude Code changed"], agents: agents), ["Claude Code · pocketfold-app"])
        XCTAssertEqual(NamedAgents.mentioned(in: ["Codexes are old books"], agents: agents), [], "whole words")
        XCTAssertEqual(NamedAgents.mentioned(in: ["", " "], agents: agents), [])
    }

    func testHeardOnEveryBenchItem() throws {
        // heard_names.py's nine, on the bench's 278 items with the standard library's agents, and nothing else.
        let bench = try RouterBenchDataTests.bench()
        let agents = bench.agentNames
        var found: [String: [String]] = [:]
        for item in bench.items {
            let heard = NamedAgents.heard(in: [item.text], agents: agents)
            if !heard.isEmpty { found[item.id] = heard.map { "\(NamedAgents.short($0.agent)): \($0.words)" } }
        }
        XCTAssertEqual(found, [
            "noisy-01": ["Claude Code: cloud code"],
            "noisy-03": ["Codex: co decks"],
            "noisy-04": ["Pennant: pendant"],
            "noisy-05": ["Grok Bot: grok but"],
            "noisy-08": ["Inkwell: ink well"],
            "noisy-10": ["Abacus: a bacus"],
            "noisy-13": ["Kestrel: castrel"],
            "noisy-14": ["Hourglass: hour glass"],
            "explicit-11": ["Grok Bot: grok"],
        ])
        // Each is the agent the item meant.
        for (id, heard) in found {
            let item = try XCTUnwrap(bench.items.first { $0.id == id })
            let agent = try XCTUnwrap(agents.first { heard[0].hasPrefix(NamedAgents.short($0) + ":") })
            XCTAssertTrue(item.acceptableAgents.contains(agent), id)
        }
    }

    func testHeardNeverTakesACommonWordOrANameAsWritten() {
        let agents = ["Claude Code · app", "Codex · site", "Hourglass", "Grok Bot"]
        XCTAssertTrue(NamedAgents.heard(in: ["the code is broken"], agents: agents).isEmpty, "not code for Codex")
        XCTAssertTrue(NamedAgents.heard(in: ["Give the bug to Claude Code"], agents: agents).isEmpty, "the name as written isn't heard loosely")
        XCTAssertTrue(NamedAgents.heard(in: ["compra regalos para la boda"], agents: agents).isEmpty, "not regalos for Hourglass: another first sound")
        XCTAssertEqual(NamedAgents.heard(in: ["give it to clawed code"], agents: agents).map(\.agent), ["Claude Code · app"], "the same consonants")
        XCTAssertEqual(NamedAgents.heard(in: ["", "ask grok bot", "ask grok"], agents: agents).map(\.words), ["grok"],
                       "any of the texts; written exactly, Grok Bot isn't heard loosely there")
        XCTAssertEqual(NamedAgents.heard(in: ["Ask Grok Search to look"], agents: ["Grok Bot", "Grok Search"]).map(\.agent), [],
                       "never words in another agent's name as written")
    }

    func testAsHeardLetsFindAndMentionedReadTheName() {
        let agents = ["Claude Code · pocketfold-app", "Codex · pocketfold-site", "Pennant", "Grok Bot", "Kestrel", "Inkwell", "Hourglass", "Abacus"]
        let noisy = "um so can you give the the sync bug to cloud code"
        XCTAssertEqual(NamedAgents.find(in: [noisy], agents: agents), [], "as said")
        XCTAssertEqual(NamedAgents.asHeard(noisy, agents: agents), "um so can you give the the sync bug to claude code", "lowercase in a text without capitals")
        XCTAssertEqual(NamedAgents.find(in: [NamedAgents.asHeard(noisy, agents: agents)], agents: agents), ["Claude Code · pocketfold-app"])
        let capitals = "grok but can you find like the cheapest way to get to Porto"
        XCTAssertEqual(NamedAgents.asHeard(capitals, agents: agents), "Grok Bot can you find like the cheapest way to get to Porto")
        let mention = NamedAgents.asHeard("look over what cloud code changed", agents: agents)
        XCTAssertEqual(NamedAgents.mentioned(in: [mention], agents: agents), ["Claude Code · pocketfold-app"])
        XCTAssertEqual(NamedAgents.find(in: [mention], agents: agents), [], "only mentioned")
        XCTAssertEqual(NamedAgents.asHeard("tell co decks, the blog images don't load", agents: agents), "tell codex, the blog images don't load",
                       "the punctuation around it stays")
        XCTAssertEqual(NamedAgents.asHeard("nothing to hear here", agents: agents), "nothing to hear here")
    }
}
