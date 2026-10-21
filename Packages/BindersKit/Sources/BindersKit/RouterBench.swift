import CryptoKit
import Foundation

/// The router bench that comes with Binders (Binders/Resources/RouterBench, copied byte for byte from the bench lane R1
/// measured Tev1 on): a made-up library of 21 binders and 12 agents, whose standard library offers 12 binders (General
/// left out) and 8 agents, and 278 made-up things said, 111 for dev and 167 for test, each with the binders and agents
/// that are right for it. The measure sorts them with the chosen decision model to find its bands and its score, and
/// --selftest-router-bench runs the same. Everyone and everything in it is invented; its names were checked by hand, and
/// `reviewedSHA256` holds the two files as they were checked.
///
/// The questions are the router's own (RouterQuestions), from the standard library as RouterInputs: each binder
/// described by What goes here and its titles, or by its titles alone; each agent by what it's for, taking its binders'
/// cards. This is the construction lane R1's --selftest-router-bench did inline; RouterBenchDataTests holds it to the
/// 834 question hashes that tool wrote before it moved here (Fixtures/router/bench-questions-r1.json).
public enum RouterBench {
    /// The SHA-256 of the two files as their names were checked (lane R2's LANE-NOTES): every person by a first name or as
    /// family, the organisations invented. A changed file needs that check again before its new hash goes here.
    public static let reviewedSHA256 = [
        "library.json": "39e5c3b489a42b79e11adf8310a7610d487324e867f0d14176db994dd47cfa0f",
        "routing.json": "fc742cfca0c64a1d281771dfc247f06c8c2f124f5343ec557fc0ff0d2b7afc91",
    ]
    /// The app bundle's copies of library.json and routing.json: its Resources are flattened, so they carry a prefix.
    public static let bundledLibrary = "router-bench-library"
    public static let bundledRouting = "router-bench-routing"

    public enum Split: String, Sendable, CaseIterable {
        case dev, test
    }

    /// The library's roles whose agents draft first and are woken by Binders: the only ones Auto hands anything to, so the
    /// only ones its level is counted on (MeasureRules.auto). Errands, outreach, scheduling and bookkeeping act for you,
    /// so they keep Give to.
    public static let draftsFirstRoles: Set<String> = ["coding", "research", "writing"]

    /// One made-up thing said, with its labels.
    public struct Item: Equatable, Sendable {
        public var id: String
        /// "dev" or "test".
        public var split: String
        public var text: String
        public var acceptableBinders: [String]
        public var acceptableAgents: [String]
        public var expectedBinder: String?
        public var expectedAgent: String?
        /// What it is (MomentKind's words: todo, idea, note), as the bench labels it.
        public var kind: String?
        /// The bench's category ("explicit_agent", "mentions_agent_no_work", "noisy_dictation", …).
        public var category: String?
    }

    /// The library as the measure's rules read it: the binder question's options in order (General left out), the agent
    /// question's in order (the agents, then nobody), and whose cards each agent takes.
    public struct Library: Equatable, Sendable {
        /// The default binder, where a card goes when the model's best binder is under the General threshold.
        public var general: String
        public var binders: [String]
        public var agents: [String]
        /// The binders whose cards each agent takes, by name, General among them when it's listed.
        public var takes: [String: Set<String>]
        /// The agents that take every binder's cards.
        public var takesEvery: Set<String>
        /// The agents that draft first and that Binders wakes (`draftsFirstRoles`): the only ones Auto hands anything to.
        public var draftsFirst: Set<String>

        public init(general: String, binders: [String], agents: [String], takes: [String: Set<String>], takesEvery: Set<String>,
                    draftsFirst: Set<String> = []) {
            self.general = general
            self.binders = binders
            self.agents = agents
            self.takes = takes
            self.takesEvery = takesEvery
            self.draftsFirst = draftsFirst
        }

        /// The agents that take a binder's cards, in the agent question's order.
        public func takers(_ binder: String) -> [String] {
            agents.filter { $0 != RouterQuestions.nobody && (takesEvery.contains($0) || takes[$0]?.contains(binder) == true) }
        }
    }

    /// One item's answers, as the measure's rules and the bench's scoring read them: its labels, and the model's
    /// probabilities for the binders and the agents in the library's order.
    public struct Answer: Equatable, Sendable {
        public var id: String
        public var acceptableBinders: [String]
        public var acceptableAgents: [String]
        /// The binder question's probabilities, in `Library.binders`' order.
        public var binders: [Double]
        /// The agent question's, in `Library.agents`' order: the agents, then nobody.
        public var agents: [Double]
        /// For a server: the model its answer said answered it.
        public var answeredBy: String?
        /// What was said, its kind (todo, idea, note) and the agent the bench expected (nobody when it's no agent's work):
        /// what Auto's level counts by (MeasureRules.auto). Nil where an answer was made without its item.
        public var text: String?
        public var kind: String?
        public var expectedAgent: String?

        public init(id: String, acceptableBinders: [String], acceptableAgents: [String], binders: [Double], agents: [Double], answeredBy: String? = nil,
                    text: String? = nil, kind: String? = nil, expectedAgent: String? = nil) {
            self.id = id
            self.acceptableBinders = acceptableBinders
            self.acceptableAgents = acceptableAgents
            self.binders = binders
            self.agents = agents
            self.answeredBy = answeredBy
            self.text = text
            self.kind = kind
            self.expectedAgent = expectedAgent
        }

        public init(item: Item, binders: [Double], agents: [Double], answeredBy: String? = nil) {
            self.init(id: item.id, acceptableBinders: item.acceptableBinders, acceptableAgents: item.acceptableAgents, binders: binders,
                      agents: agents, answeredBy: answeredBy, text: item.text, kind: item.kind, expectedAgent: item.expectedAgent)
        }
    }

    /// The bench's own scoring of a split.
    public struct Score: Equatable, Sendable {
        public var items: Int
        public var binderOK: Int
        public var agentOK: Int

        public init(items: Int, binderOK: Int, agentOK: Int) {
            self.items = items
            self.binderOK = binderOK
            self.agentOK = agentOK
        }

        /// (binders right + agents right) / (2 × items).
        public var score: Double { items == 0 ? 0 : Double(binderOK + agentOK) / Double(2 * items) }
    }

    /// The bench's own scoring: each item's first picks against its labels, the best binder (General never chosen) and
    /// the top agent (nobody among them), the first of equal maxima. Binders' own rules (MeasureRules.Pick) differ: they
    /// send an unsure card to General and name no agent under the suggest level.
    public static func score(_ answers: [Answer], library: Library) -> Score {
        var binderOK = 0, agentOK = 0
        for answer in answers {
            if let best = RouterMath.argmax(answer.binders), best < library.binders.count, answer.acceptableBinders.contains(library.binders[best]) {
                binderOK += 1
            }
            if let top = RouterMath.argmax(answer.agents), top < library.agents.count, answer.acceptableAgents.contains(library.agents[top]) {
                agentOK += 1
            }
        }
        return Score(items: answers.count, binderOK: binderOK, agentOK: agentOK)
    }

    /// The SHA-256 of a file's bytes, in lowercase hex, for `reviewedSHA256`.
    public static func sha256(_ data: Foundation.Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The same id for a binder or an agent of the bench every time, from its name (a version 4 UUID, as UUID() makes).
    public static func id(binder name: String) -> UUID { uuid("binders-router-bench/binder/\(name)") }
    public static func id(agent name: String) -> UUID { uuid("binders-router-bench/agent/\(name)") }

    private static func uuid(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Foundation.Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension RouterBench {
    /// The bench's two files, read: library.json (`binders-routing-library/2`) and routing.json (`binders-routing-bench/2`).
    public struct Data: Sendable {
        public struct Binder: Equatable, Sendable {
            public var name: String
            public var whatGoesHere: String
            public var titles: [String]
        }

        public struct Agent: Equatable, Sendable {
            public var name: String
            /// What it's for, as the library has it; nil when it says nothing.
            public var whatItsFor: String?
            /// The binders whose cards it takes; nil for every binder.
            public var binders: [String]?
            /// Its role in the made-up library: coding, research, writing, errands, outreach, scheduling, bookkeeping…
            public var role: String?

            /// It drafts first and Binders wakes it (`draftsFirstRoles`), so Auto may hand it a card.
            public var draftsFirst: Bool { role.map(RouterBench.draftsFirstRoles.contains) ?? false }
        }

        /// The default binder: General.
        public var general: String
        /// The standard library's binders (General among them) and agents, in its order.
        public var binderNames: [String]
        public var agentNames: [String]
        /// Every binder and agent the library describes, in its order (the small and large libraries' too).
        public var binders: [Binder]
        public var agents: [Agent]
        /// The things said, in routing.json's order.
        public var items: [Item]

        public init(library: Foundation.Data, routing: Foundation.Data) throws {
            let decoder = JSONDecoder()
            let file = try decoder.decode(LibraryFile.self, from: library)
            guard let standard = file.variants["standard"] else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "library.json has no standard library"))
            }
            general = file.defaultBinder ?? "General"
            binderNames = standard.binders
            agentNames = standard.agents
            binders = file.binders.map { Binder(name: $0.name, whatGoesHere: $0.whatGoesHere ?? "", titles: $0.titles ?? []) }
            agents = file.agents.map { Agent(name: $0.name, whatItsFor: $0.whatItsFor, binders: $0.binders, role: $0.role) }
            items = try decoder.decode(RoutingFile.self, from: routing).items.map {
                Item(id: $0.id, split: $0.split, text: $0.text, acceptableBinders: $0.acceptableBinders, acceptableAgents: $0.acceptableAgents,
                     expectedBinder: $0.expectedBinder, expectedAgent: $0.expectedAgent, kind: $0.kind, category: $0.category)
            }
        }

        /// A bench folder's library.json and routing.json.
        public init(folder: URL) throws {
            try self.init(library: Foundation.Data(contentsOf: folder.appendingPathComponent("library.json")),
                          routing: Foundation.Data(contentsOf: folder.appendingPathComponent("routing.json")))
        }

        public func items(_ split: Split) -> [Item] {
            items.filter { $0.split == split.rawValue }
        }

        /// The standard library as the router reads it, General left out: every binder by What goes here and its titles
        /// (`.both`), or by its titles alone (`.titles`, the form every binder starts in); every agent by what it's for,
        /// taking the cards of the binders it lists that the standard library has. Ids come from the names, so they're the
        /// same every time.
        public func inputs(_ form: RouterQuestions.Form) -> RouterInputs {
            let described = Dictionary(binders.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let purposes = Dictionary(agents.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            return RouterInputs(
                binders: binderNames.filter { $0 != general }.map { name in
                    RouterInputs.Binder(id: RouterBench.id(binder: name), name: name, whatGoesHere: form == .titles ? "" : described[name]?.whatGoesHere ?? "",
                                        titles: described[name]?.titles ?? [])
                },
                agents: agentNames.map { name in
                    RouterInputs.Agent(id: RouterBench.id(agent: name), name: name, description: purposes[name]?.whatItsFor,
                                       takes: purposes[name]?.binders.map { $0.filter(binderNames.contains).map { RouterBench.id(binder: $0) } })
                })
        }

        /// An item's two questions as the router asks them: the binder question with the binders in `form`, and the agent
        /// question, which doesn't depend on how binders are described. Nil when the library offers too few of either.
        public func questions(_ item: Item, form: RouterQuestions.Form) -> (binder: RouterQuestions.Binders, agent: RouterQuestions.Agents)? {
            guard let binder = RouterQuestions.binders(state: item.text, inputs: inputs(form)),
                  let agent = RouterQuestions.agents(state: item.text, inputs: inputs(.both)) else { return nil }
            return (binder, agent)
        }

        /// The library as the measure's rules read it, in the questions' own order.
        public var library: Library {
            let both = inputs(.both)
            let offered = RouterQuestions.binders(state: "", inputs: both)?.offered.map(\.name) ?? []
            let asked = RouterQuestions.agents(state: "", inputs: both)
            let names = Dictionary(binderNames.map { (RouterBench.id(binder: $0), $0) }, uniquingKeysWith: { first, _ in first })
            var takes: [String: Set<String>] = [:], every: Set<String> = []
            for agent in asked?.offered ?? [] {
                if let listed = agent.takes {
                    takes[agent.name] = Set(listed.compactMap { names[$0] })
                } else {
                    every.insert(agent.name)
                }
            }
            let draftsFirst = Set(agents.filter(\.draftsFirst).map(\.name)).intersection(asked?.offered.map(\.name) ?? [])
            return Library(general: general, binders: offered, agents: asked?.question.options.map(\.key) ?? [], takes: takes, takesEvery: every,
                           draftsFirst: draftsFirst)
        }
    }

    private struct LibraryFile: Decodable {
        struct Binder: Decodable {
            let name: String
            let whatGoesHere: String?
            let titles: [String]?
            enum CodingKeys: String, CodingKey { case name, titles, whatGoesHere = "what_goes_here" }
        }

        struct Agent: Decodable {
            let name: String
            let whatItsFor: String?
            let binders: [String]?
            let role: String?
            enum CodingKeys: String, CodingKey { case name, binders, role, whatItsFor = "what_its_for" }
        }

        struct Variant: Decodable {
            let binders: [String]
            let agents: [String]
        }

        let defaultBinder: String?
        let binders: [Binder]
        let agents: [Agent]
        let variants: [String: Variant]
        enum CodingKeys: String, CodingKey { case binders, agents, variants, defaultBinder = "default_binder" }
    }

    private struct RoutingFile: Decodable {
        struct Item: Decodable {
            let id: String
            let text: String
            let split: String
            let acceptableBinders: [String]
            let acceptableAgents: [String]
            let expectedBinder: String?
            let expectedAgent: String?
            let kind: String?
            let category: String?
            enum CodingKeys: String, CodingKey {
                case id, text, split, kind, category
                case acceptableBinders = "acceptable_binders", acceptableAgents = "acceptable_agents"
                case expectedBinder = "expected_binder", expectedAgent = "expected_agent"
            }
        }

        let items: [Item]
    }
}
