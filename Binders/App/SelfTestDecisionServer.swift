import Foundation
import Network
import BindersKit

// --selftest-router's decision server and measure checks: a stand-in decision server on 127.0.0.1 and a spare port, with
// canned answers, reached through the real JevDecisionBackend and LoopbackHTTP; and the measure (DecisionMeasureRun)
// through DecisionModels, over a stand-in backend and over the stand-in server, answering the bench's made-up cards with
// lane R1's own answers (the kit's measure fixture). No model, no real server, nothing beyond this Mac's loopback.

/// A decision server on this Mac for the self-test, built as SelfTestAsk's model server is: an NWListener on 127.0.0.1
/// only. It answers GET /v1/models as Kev does (its card's fixed fields, and counters that grow on every call), refuses
/// /v1/version, and answers POST /v1/systemone from its tables, writing each answer's probabilities with the keys in the
/// reverse of the order asked. It keeps every request it got. It can be slow, stall its probes, ask for a key, not be a
/// decision server, send bad sums or leave a key out, answer chunked, name the model each answer came from as Laya's
/// router does, answer its probes a little differently on every second ask, or be stopped and started again.
final class DecisionServerStandIn: @unchecked Sendable {
    /// One request, as it came.
    struct Request: Sendable {
        var method: String
        var path: String
        /// By lowercased name.
        var headers: [String: String]
        var body: Data

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var state: String? { json["state"] as? String }
        /// One of the three warm-up questions, as the backend probes it.
        var isProbe: Bool {
            guard path == JevAPI.systemOnePath, let q1 = (json["questions"] as? [String: Any])?["q1"] as? [String: Any],
                  let criteria = q1["criteria"] as? [String: String] else { return false }
            return DecisionServerStandIn.probe(state: state ?? "", instructions: q1["instructions"] as? String ?? "", keys: Array(criteria.keys)) != nil
        }
    }

    enum Mode: Sendable { case answers, wantsKey, notADecisionServer, badSums, missingKey }

    /// What a question is answered with, by its words: its state, its instructions and its options' keys and descriptions.
    typealias Lookup = @Sendable (_ state: String, _ instructions: String, _ criteria: [String: String]) -> [String: Double]?

    /// Which warm-up question a question is, by its state, its instructions and its options' keys.
    static func probe(state: String, instructions: String, keys: [String]) -> Int? {
        RouterQuestions.warmUps.firstIndex { $0.state == state && $0.question == instructions && Set($0.options.map(\.key)) == Set(keys) }
    }
    /// The probes as the measured model answers them: lane R1's goldens for Tev1 0.8B bf16, in option order.
    static let probesA: [[Double]] = DecisionBands.tev1?.golden ?? []

    private let queue = DispatchQueue(label: "io.binders.selftest.decision-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var _port: UInt16 = 0
    private var _mode = Mode.answers
    private var _slow: Duration = .zero
    private var _stallProbes = false
    private var _chunked = false
    private var _names = ["stand-in-decider"]
    private var _table: [String: [String: [String: Double]]] = [:]
    private var _probes: [[Double]] = DecisionServerStandIn.probesA
    private var _lookup: Lookup?
    private var _routing: (@Sendable (String) -> String?)?
    private var _wobble = false
    private var _overlay: [String: [String: Double]] = [:]
    private var _afterCard: (@Sendable () -> Void)?
    private var _asks: [String: Int] = [:]
    private var _requests: [Request] = []
    private var _listed = 0

    var port: UInt16 { lock.withLock { _port } }
    var address: String { "http://127.0.0.1:\(port)" }
    var requests: [Request] { lock.withLock { _requests } }
    var modelsRequests: Int { requests.filter { $0.path == JevAPI.modelsPath }.count }
    var probeRequests: Int { requests.filter(\.isProbe).count }
    var mode: Mode { get { lock.withLock { _mode } } set { lock.withLock { _mode = newValue } } }
    /// Every POST /v1/systemone waits this long before it answers.
    var slow: Duration { get { lock.withLock { _slow } } set { lock.withLock { _slow = newValue } } }
    /// /v1/models and the probes wait 5 seconds before they answer.
    var stallProbes: Bool { get { lock.withLock { _stallProbes } } set { lock.withLock { _stallProbes = newValue } } }
    var chunked: Bool { get { lock.withLock { _chunked } } set { lock.withLock { _chunked = newValue } } }
    /// How the probes are answered, one per warm-up question in option order.
    var probes: [[Double]] { get { lock.withLock { _probes } } set { lock.withLock { _probes = newValue } } }
    /// The bench's made-up cards, answered by their words (the measure).
    var lookup: Lookup? { get { lock.withLock { _lookup } } set { lock.withLock { _lookup = newValue } } }
    /// The model each answer names, by its state, as Laya's `routing.model`; nil names none.
    var routing: (@Sendable (String) -> String?)? { get { lock.withLock { _routing } } set { lock.withLock { _routing = newValue } } }
    /// On every second ask of each probe, 0.01 moves from its second option to its first.
    var wobble: Bool { get { lock.withLock { _wobble } } set { lock.withLock { _wobble = newValue } } }
    /// Added to the answers for a state, by key, after everything else.
    var overlay: [String: [String: Double]] { get { lock.withLock { _overlay } } set { lock.withLock { _overlay = newValue } } }
    /// Runs once a card's answer (not a probe's) has gone.
    var afterCard: (@Sendable () -> Void)? { get { lock.withLock { _afterCard } } set { lock.withLock { _afterCard = newValue } } }

    /// The answers for what was said or typed: the binders' and the agents' probabilities by key; the rest spread evenly.
    func set(_ state: String, binder: [String: Double]? = nil, agent: [String: Double]? = nil) {
        lock.withLock {
            if let binder { _table[state, default: [:]]["binder"] = binder }
            if let agent { _table[state, default: [:]]["agent"] = agent }
        }
    }

    /// Listening on 127.0.0.1, on `port` (a spare one when 0): the port, or nil.
    func start(port wanted: UInt16 = 0) async -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: wanted) ?? .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        lock.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let once = StandInOnce()
        let port: UInt16? = await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.first() { continuation.resume(returning: listener.port?.rawValue) }
                case .failed, .cancelled: if once.first() { continuation.resume(returning: nil) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        if let port { lock.withLock { _port = port } }
        return port
    }

    /// Nothing listens any more; `start(port:)` again on the same port brings it back.
    func stop() async {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
        try? await Task.sleep(for: .milliseconds(100))
    }

    // MARK: Answering

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var received = received
            if let data { received.append(data) }
            if let request = Self.request(in: received) {
                self.lock.withLock { self._requests.append(request) }
                return self.answer(request, on: connection)
            }
            if isComplete || error != nil { return connection.cancel() }
            self.read(connection, received)
        }
    }

    /// A whole request: its method, path, headers and body by its Content-Length; nil until all of it has come.
    static func request(in data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func answer(_ request: Request, on connection: NWConnection) {
        let (mode, slow, stall, chunked) = lock.withLock { (_mode, _slow, _stallProbes, _chunked) }
        let status: Int, body: String
        switch mode {
        case .wantsKey:
            (status, body) = (401, #"{"detail": "Not authenticated"}"#)
        case .notADecisionServer:
            (status, body) = (404, #"{"detail": "Not Found"}"#)
        case .answers, .badSums, .missingKey:
            if request.method == "GET", request.path == JevAPI.modelsPath {
                (status, body) = (200, models())
            } else if request.method == "POST", request.path == JevAPI.systemOnePath {
                (status, body) = (200, systemOne(request, mode: mode))
            } else {
                (status, body) = (404, #"{"detail": "Not Found"}"#)
            }
        }
        // A card's answer is made, then the switch it stands for happens, before the answer goes: as if another model
        // took the port right after the decision.
        if request.path == JevAPI.systemOnePath, !request.isProbe, let after = afterCard { after() }
        var delay = request.path == JevAPI.systemOnePath ? slow : .zero
        if stall, request.isProbe || request.path == JevAPI.modelsPath { delay = .seconds(5) }
        let data = Self.response(status: status, body: body, chunked: chunked)
        let send = {
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        }
        if delay > .zero {
            queue.asyncAfter(deadline: .now() + LoopbackHTTP.seconds(delay), execute: send)
        } else {
            send()
        }
    }

    /// Kev's /v1/models: its card's fixed fields, and counters that change on every call.
    private func models() -> String {
        let (names, listed) = lock.withLock { () -> ([String], Int) in
            _listed += 1
            return (_names, _listed)
        }
        let entries = names.map { name -> [String: Any] in
            ["name": name, "description": "A stand-in decision server for Binders' self-test", "release_date": "2026-10-01", "run": "runs/stand-in",
             "base": "stand-in/base", "lora": NSNull(), "device": "cpu", "backend": "stand-in", "dtype": "float32", "temperature": 1.0,
             "max_state_tokens": 4096, "truncate_states": false, "cuda_graphs": NSNull(),
             "prefix_cache": ["size": 4, "hits": listed, "misses": 1], "batches": ["count": listed, "requests": listed, "queued": 0]]
        }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: ["models": entries])) ?? Data(), as: UTF8.self)
    }

    /// The answer to POST /v1/systemone, built by hand so each answer's keys can come in the reverse of the order asked.
    private func systemOne(_ request: Request, mode: Mode) -> String {
        let object = request.json
        let state = object["state"] as? String ?? ""
        let questions = object["questions"] as? [String: Any] ?? [:]
        let raw = String(decoding: request.body, as: UTF8.self)
        var answers: [String] = []
        for name in questions.keys.sorted(by: { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }) {
            guard let question = questions[name] as? [String: Any] else { continue }
            let instructions = question["instructions"] as? String ?? ""
            let criteria = question["criteria"] as? [String: String] ?? [:]
            let asked = Self.order(Array(criteria.keys), in: raw, after: PythonText.jsonString(name) + ": ")
            var probs = probabilities(state: state, instructions: instructions, criteria: criteria, keys: asked)
            switch mode {
            case .badSums: probs = probs.mapValues { $0 * 0.9 }
            case .missingKey: if let last = asked.last { probs[last] = nil }
            case .answers, .wantsKey, .notADecisionServer: break
            }
            let written = asked.reversed().compactMap { key in probs[key].map { "\(PythonText.jsonString(key)): \($0)" } }.joined(separator: ", ")
            let top = asked.max { (probs[$0] ?? 0) < (probs[$1] ?? 0) } ?? ""
            answers.append("\(PythonText.jsonString(name)): {\"type\": \"choice\", \"choice\": \(PythonText.jsonString(top)), \"confidence\": 0.5, \"probabilities\": {\(written)}}")
        }
        // Kev echoes the model asked for, else its default name.
        let model = object["model"] as? String ?? lock.withLock { _names.first } ?? "stand-in-decider"
        var body = "{\"model\": \(PythonText.jsonString(model)), \"answers\": {\(answers.joined(separator: ", "))}, \"latency_ms\": 1.5"
        if let routed = routing?(state) { body += ", \"routing\": {\"model\": \(PythonText.jsonString(routed)), \"repo\": \"stand-in/\(routed)\"}" }
        return body + "}"
    }

    /// One question's probabilities by key: a probe from `probes`, a bench card from `lookup`, anything else from the table,
    /// the keys left out sharing the rest evenly; then the overlay.
    private func probabilities(state: String, instructions: String, criteria: [String: String], keys: [String]) -> [String: Double] {
        let (table, probes, lookup, wobble, overlay) = lock.withLock { (_table, _probes, _lookup, _wobble, _overlay) }
        var given: [String: Double] = [:]
        if let probe = Self.probe(state: state, instructions: instructions, keys: keys), probe < probes.count {
            var values = probes[probe]
            let ask = lock.withLock { () -> Int in
                _asks[state, default: 0] += 1
                return _asks[state] ?? 1
            }
            if wobble, ask % 2 == 0, values.count >= 2 {
                let order = values.indices.sorted { values[$0] > values[$1] }
                values[order[0]] += 0.01
                values[order[1]] -= 0.01
            }
            given = Dictionary(zip(RouterQuestions.warmUps[probe].options.map(\.key), values), uniquingKeysWith: { first, _ in first })
        } else if let found = lookup?(state, instructions, criteria) {
            given = found
        } else {
            given = table[state]?[instructions == RouterQuestions.binderQuestion ? "binder" : "agent"] ?? [:]
        }
        let listed = keys.filter { given[$0] != nil }
        let rest = max(0, 1 - listed.reduce(0) { $0 + (given[$1] ?? 0) })
        let others = keys.count - listed.count
        var probs = Dictionary(keys.map { ($0, given[$0] ?? (others > 0 ? rest / Double(others) : 0)) }, uniquingKeysWith: { first, _ in first })
        for (key, added) in overlay[state] ?? [:] { probs[key] = probs[key].map { $0 + added } }
        return probs
    }

    /// The keys in the order the request asked them: by where each first comes after the question's name.
    static func order(_ keys: [String], in raw: String, after marker: String) -> [String] {
        let start = raw.range(of: marker)?.upperBound ?? raw.startIndex
        func at(_ key: String) -> Int {
            guard let found = raw.range(of: PythonText.jsonString(key) + ": ", range: start..<raw.endIndex) else { return Int.max }
            return raw.distance(from: raw.startIndex, to: found.lowerBound)
        }
        return keys.sorted { at($0) < at($1) }
    }

    /// An HTTP answer, by its Content-Length, or chunked in three pieces.
    static func response(status: Int, body: String, chunked: Bool) -> Data {
        let reason = [200: "OK", 401: "Unauthorized", 404: "Not Found"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nConnection: close\r\n"
        let bytes = Data(body.utf8)
        guard chunked else { return Data((head + "Content-Length: \(bytes.count)\r\n\r\n").utf8) + bytes }
        var data = Data((head + "Transfer-Encoding: chunked\r\n\r\n").utf8)
        let size = max(1, (bytes.count + 2) / 3)
        var start = 0
        while start < bytes.count {
            let end = min(bytes.count, start + size)
            data += Data((String(end - start, radix: 16) + "\r\n").utf8) + bytes[start..<end] + Data("\r\n".utf8)
            start = end
        }
        return data + Data("0\r\n\r\n".utf8)
    }
}

/// True the first time it's asked, from any thread.
private final class StandInOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

/// Lane R1's answers to the bench: Tev1 0.8B bf16 in the app's runtime, as the kit's measure fixture keeps them
/// (Packages/BindersKit/Tests/BindersKitTests/Fixtures/router/measure-tev1-bf16.json, beside this build's source), for
/// stand-ins that answer the measure's questions as that model did.
struct MeasureFixture {
    struct Row {
        var binders: [Double]
        var agents: [Double]
    }

    /// The binder question's options and the agent question's, in the order the rows hold them.
    var binders: [String]
    var agents: [String]
    var devBoth: [String: Row]
    var devTitles: [String: Row]
    var test: [String: Row]

    static var url: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/BindersKit/Tests/BindersKitTests/Fixtures/router/measure-tev1-bf16.json")
    }

    static func load(_ url: URL = MeasureFixture.url) -> MeasureFixture? {
        guard let object = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              let binders = object["binders"] as? [String], let agents = object["agents"] as? [String] else { return nil }
        func rows(_ key: String) -> [String: Row] {
            Dictionary((object[key] as? [[String: Any]] ?? []).compactMap { row -> (String, Row)? in
                guard let id = row["id"] as? String, let b = row["binders"] as? [Double], let a = row["agents"] as? [Double] else { return nil }
                return (id, Row(binders: b, agents: a))
            }, uniquingKeysWith: { first, _ in first })
        }
        return MeasureFixture(binders: binders, agents: agents, devBoth: rows("dev_both"), devTitles: rows("dev_titles"), test: rows("test"))
    }

    /// A question by its words: its state, its instructions, and its options' keys and descriptions, in any order.
    static func key(_ state: String, _ instructions: String, _ criteria: [String: String]) -> String {
        state + "\u{1}" + instructions + "\u{1}" + criteria.sorted { $0.key < $1.key }.map { $0.key + "\u{2}" + $0.value }.joined(separator: "\u{3}")
    }

    static func key(_ question: DecisionQuestion) -> String {
        key(question.state, question.question, Dictionary(question.options.map { ($0.key, $0.description) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Every bench question's answer by its words: each card's binder question in both forms and its agent question.
    /// `wrongTestStart`: the first test card whose right agents don't include Grok Bot (which takes every binder's cards)
    /// gets Grok Bot at 0.99, a wrong start at any level the rules try.
    func answers(_ bench: RouterBench.Data, wrongTestStart: Bool = false) -> [String: [String: Double]] {
        var found: [String: [String: Double]] = [:]
        var wronged = !wrongTestStart
        func byKey(_ keys: [String], _ values: [Double]) -> [String: Double] {
            Dictionary(zip(keys, values).map { ($0, $1) }, uniquingKeysWith: { first, _ in first })
        }
        for item in bench.items {
            let dev = item.split == RouterBench.Split.dev.rawValue
            guard let both = bench.questions(item, form: .both), let row = dev ? devBoth[item.id] : test[item.id] else { continue }
            found[Self.key(both.binder.question)] = byKey(binders, row.binders)
            var agentValues = row.agents
            if !wronged, !dev, !item.acceptableAgents.contains("Grok Bot"), let grok = agents.firstIndex(of: "Grok Bot") {
                agentValues = agents.indices.map { $0 == grok ? 0.99 : 0.01 / Double(agents.count - 1) }
                wronged = true
            }
            found[Self.key(both.agent.question)] = byKey(agents, agentValues)
            if dev, let titles = bench.questions(item, form: .titles), let titlesRow = devTitles[item.id] {
                found[Self.key(titles.binder.question)] = byKey(binders, titlesRow.binders)
            }
        }
        return found
    }
}

/// A count kept from any thread, for the self-test's stand-ins.
final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// The last progress a measure reported, for the self-test.
@MainActor
final class ProgressSeen {
    var done = 0
}

extension SelfTest {
    /// The decision server, through the real JevDecisionBackend and LoopbackHTTP, against stand-in servers on 127.0.0.1
    /// (DecisionServerStandIn), chosen in the router's own DecisionModels: first contact and what it serves; a card's
    /// request as the Jev API wants it; the answer mapped back by key; a slow server, a hanging one and a stopped one; a key
    /// asked for, not a decision server, answers that don't map, a chunked answer; duplicate keys; a measure over it, found
    /// again across a rounding edge; a start, with its probes asked after the decision; probes that don't come back;
    /// another model behind the same address and names, found by the probes before a card and between its decision and its
    /// start; probes that answer differently on every second ask; a test verdict that holds; a server that routes by
    /// language; an address that isn't this Mac's, localhost and where it leads, a lookup that never returns; and the real
    /// factory's backend for a server, which never calls MLX.
    @MainActor
    static func decisionServerSelfTest(controller: DictationController, models: DecisionModels, standIns: RouterStandIns, website: BinderRecord,
                                       folder: URL, check: (Bool, String) -> Void) async {
        let router = controller.router, board = controller.board, log = RouterLogFile.shared
        let server = DecisionServerStandIn()
        guard let port = await server.start() else { return check(false, "the stand-in decision server listens on 127.0.0.1") }
        let display = "127.0.0.1:\(port)"
        standIns.serverBackend = { JevDecisionBackend(address: $0, skipFor: .milliseconds(500)) }
        let scribeID = AgentRegistry.shared.agent(named: "Scribe")?.id.uuidString
        /// A card typed on the Website board and sorted (the server's table gives its agent question `agent`), with its
        /// line in the tuning log.
        func card(_ title: String, into column: BoardColumn = .backlog, agent: [String: Double], on stand: DecisionServerStandIn) async -> (card: TaskCard, line: RouterLogEntry?) {
            stand.set(title, agent: agent)
            let made = board.create(title: title, binderID: website.id, column: column, by: .you)
            await router.routeCard(made.id, title: title, origin: column == .ready ? .typedReady : .typedBacklog)
            log.flush()
            return (made, log.entries().last { $0.card == made.id })
        }
        func started(_ card: TaskCard) -> Bool { board.timeline(card.id).contains { $0.kind == .woke } }
        func measured(_ resolved: ResolvedBands?) -> Bool {
            if case .measured = resolved?.source { return true }
            return false
        }

        // MARK: First contact
        let fresh = JevDecisionBackend(address: server.address)
        let freshState = await fresh.state()
        _ = await fresh.identity(by: .now + .seconds(5))
        let freshAfter = await fresh.state()
        check(freshState == .checking && JevDecisionBackend.askingLine(display) == "Asking \(display) what it serves…"
              && freshAfter == .answering(names: ["stand-in-decider"]),
              "a server's first contact is .checking (\"Asking … what it serves…\"), then answering: \(freshAfter)")
        let modelsBefore = server.modelsRequests, probesBefore = server.probeRequests
        models.choose(.server(server.address))
        let contact = await models.bands(by: .now + .seconds(5))
        guard let jev = models.backend as? JevDecisionBackend else {
            await server.stop()
            return check(false, "a server chosen gets the decision server's backend")
        }
        let contactState = await jev.state()
        check(contactState == .answering(names: ["stand-in-decider"]) && JevDecisionBackend.answersLine(jev.display, names: ["stand-in-decider"]) == "Answers at \(display) as stand-in-decider."
              && server.probeRequests - probesBefore == 3 && server.modelsRequests - modelsBefore == 1
              && contact?.identity.fingerprint.hasPrefix("jev1-") == true && contact?.identity.reader == "jev.1" && contact?.source == .unmeasured,
              "chosen: it answers as stand-in-decider, after one /v1/models and three probes; read as jev.1, its fingerprint \(contact?.identity.fingerprint ?? "none"), unmeasured")
        await jev.tryAgain()
        let probedAgain = await jev.knownIdentity
        check(server.modelsRequests - modelsBefore == 2 && probedAgain != nil && probedAgain?.key == contact?.identity.key,
              "Check Again probes it again: Kev's counters grew in /v1/models, and its identity is the same")

        // MARK: The request, and the answer mapped back
        let typedTitle = "Fix the typo on the press page"
        let beforeTyped = server.requests.count
        let typed = await card(typedTitle, agent: ["Scribe": 0.82], on: server)
        let sent = server.requests.dropFirst(beforeTyped).filter { $0.path == JevAPI.systemOnePath }
        let expectedAgent = RouterQuestions.agents(state: typedTitle, inputs: router.gather().inputs)?.question
        let expectedBody = expectedAgent.flatMap { try? JevAPI.request(state: typedTitle, questions: [$0], model: "stand-in-decider") }
        let q1 = (sent.first?.json["questions"] as? [String: Any])?["q1"] as? [String: Any]
        let headers = sent.first?.headers ?? [:]
        check(headers["host"] == display && headers["accept"] == "application/json" && headers["connection"] == "close" && headers["user-agent"] == "Binders"
              && headers["content-length"] == sent.first.map { String($0.body.count) } && headers.keys.allSatisfy { !["authorization", "cookie", "proxy-authorization"].contains($0) },
              "its headers: Host \(headers["host"] ?? "none"), Accept and Content-Type JSON, Content-Length, Connection: close, User-Agent Binders, and never a key or a cookie")
        check(sent.count == 1 && sent.first?.method == "POST" && sent.first?.headers["content-type"] == "application/json" && sent.first?.headers["authorization"] == nil
              && sent.first?.headers["cookie"] == nil && sent.first?.body == expectedBody && sent.first?.json["state"] as? String == typedTitle
              && sent.first?.json["model"] as? String == "stand-in-decider" && q1?["type"] as? String == "choice"
              && q1?["instructions"] as? String == RouterQuestions.agentQuestion && typed.card.meantFor == "Scribe" && typed.line?.backend == "jev.1",
              "a typed card is one POST /v1/systemone: JSON, no key and no cookie, its title as the state, the one model name, and q1 the agent question with the agents in Settings order, then nobody, each with its description")
        let beforeCommand = server.requests.count
        await controller.command(heard: "Add to-do order the new stand banners")
        controller.flowBar.hide()
        let commandSent = server.requests.dropFirst(beforeCommand).filter { $0.path == JevAPI.systemOnePath }
        let commandQuestions = commandSent.first?.json["questions"] as? [String: Any]
        check(commandSent.count == 1 && (commandQuestions?["q1"] as? [String: Any])?["instructions"] as? String == RouterQuestions.binderQuestion
              && (commandQuestions?["q2"] as? [String: Any])?["instructions"] as? String == RouterQuestions.agentQuestion,
              "a Command Mode to-do is one request: q1 the binder question, q2 the agent question")
        let ordered = await card("Fix the newsletter's broken unsubscribe link", agent: ["Looker": 0.15, "Scribe": 0.7, "Pennant": 0.05], on: server)
        let orderedTop = ordered.line?.agent?.top?.first
        check(ordered.card.meantFor == "Scribe" && orderedTop?.id == scribeID && abs((orderedTop?.p ?? 0) - 0.7) < 1e-12,
              "its answer's keys came in the reverse order and map back by key: the suggestion is the agent it gave the most")

        // Probes over 5 minutes old (cut to 0.1 s here) are asked again after the next card, not inside its time.
        let aging = JevDecisionBackend(address: server.address, probesLast: .milliseconds(100))
        let agingIdentity = await aging.identity(by: .now + .seconds(5))
        let roundsBefore = await aging.probeRoundsBegun
        try? await Task.sleep(for: .milliseconds(150))
        let agingBegan = ContinuousClock.now
        let agingAnswer = try? await aging.decide([RouterQuestions.warmUps[1]], expecting: agingIdentity, by: .now + .seconds(3))
        let agingTook = agingBegan.duration(to: .now)
        var roundsAfter = await aging.probeRoundsBegun
        for _ in 0..<100 where roundsAfter == roundsBefore {
            try? await Task.sleep(for: .milliseconds(10))
            roundsAfter = await aging.probeRoundsBegun
        }
        check(agingAnswer != nil && roundsAfter == roundsBefore + 1 && agingTook < .milliseconds(200),
              "probes past their age are asked again after a card, not inside its time (\(agingTook)): \(roundsAfter - roundsBefore) round")

        // LoopbackHTTP's reader: a redirect is never followed, a 100 is passed over, a body ends at the close, chunks
        // come across reads, and an answer over 1 MB is refused.
        func read(_ pieces: [String], ended: Bool = true) -> LoopbackHTTP.Reader.Step {
            var reader = LoopbackHTTP.Reader()
            var step = LoopbackHTTP.Reader.Step.more
            for (index, piece) in pieces.enumerated() { step = reader.read(Data(piece.utf8), ended: ended && index == pieces.count - 1) }
            return step
        }
        let ok = LoopbackHTTP.Response(status: 200, body: Data("{}".utf8))
        check(read(["HTTP/1.1 301 Moved Permanently\r\nLocation: http://10.0.0.5/\r\nContent-Length: 0\r\n\r\n"]) == .failed(.redirect(301))
              && read(["HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"]) == .done(ok)
              && read(["HTTP/1.0 200 OK\r\n\r\n{", "}"]) == .done(ok) && read(["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n{}"]) == .failed(.closed)
              && read(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r", "\n1;x=y\r\n}\r\n0\r\n\r\n"], ended: false) == .done(ok)
              && read(["HTTP/1.1 200 OK\r\nContent-Length: \(LoopbackHTTP.maxBody + 1)\r\n\r\n"], ended: false) == .failed(.tooLarge)
              && read(["not HTTP at all\r\n\r\n"]) == .failed(.malformed) && read([""]) == .failed(.closed),
              "LoopbackHTTP reads an answer by its length, chunked or until the close, passes over a 100, never follows a redirect, and refuses one over 1 MB")
        // A chunk size near Int.max once overflowed the reader's arithmetic, which ends the process; one over 1 MB is
        // refused too, before its bytes are waited for.
        check(read(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7ffffffffffffffe\r\nx"], ended: false) == .failed(.malformed)
              && read(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(String(LoopbackHTTP.maxBody + 1, radix: 16))\r\nx"], ended: false) == .failed(.malformed)
              && read(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(String(Int.max, radix: 16))\r\n"], ended: true) == .failed(.malformed),
              "LoopbackHTTP refuses a chunk size near Int.max, or over 1 MB, as malformed, and doesn't crash")

        // MARK: Slow, hanging, stopped
        router.budget = .milliseconds(500)
        server.slow = .seconds(5)
        let slowBegan = ContinuousClock.now
        let slowCard = await card("Fix the hero video on the home page", agent: ["Scribe": 0.9], on: server)
        let slowTook = slowBegan.duration(to: .now)
        server.slow = .zero
        let quickCard = await card("Fix the hero video's poster frame", agent: ["Scribe": 0.9], on: server)
        check(slowCard.card.meantFor == nil && slowTook >= .milliseconds(450) && slowTook < .milliseconds(1_000) && quickCard.card.meantFor == "Scribe",
              "a server slower than the card's time: the card goes on at its deadline with no agent (\(slowTook)), and the next, quick again, gets its answer")
        server.slow = .seconds(5)
        _ = await card("Fix the hero video's captions", agent: ["Scribe": 0.9], on: server)
        _ = await card("Fix the hero video's autoplay", agent: ["Scribe": 0.9], on: server)
        let requestsWhileSkipped = server.requests.count
        let skipBegan = ContinuousClock.now
        let skipped = await card("Fix the hero video's sound", agent: ["Scribe": 0.9], on: server)
        let skipTook = skipBegan.duration(to: .now)
        let skippedState = await jev.state()
        let hangingLine = JevDecisionBackend.Trouble.hanging.line(display)
        check(skipped.card.meantFor == nil && skipTook < .milliseconds(100) && server.requests.count == requestsWhileSkipped
              && skippedState == .unavailable(.unreachable(hangingLine))
              && hangingLine == "The server at \(display) took more than 4 seconds twice. Binders asks it again in a minute; meanwhile it sorts without it.",
              "two slow cards in a row: the next ones skip it at once (\(skipTook)), asking nothing, and row A says why")
        server.slow = .zero
        try? await Task.sleep(for: .milliseconds(600))
        let afterSkip = await card("Fix the hero video's subtitles", agent: ["Scribe": 0.9], on: server)
        check(afterSkip.card.meantFor == "Scribe", "once the skip is over (a minute, cut to half a second here), it's asked again")
        // One timeout doesn't put the model in doubt: the next card is asked at once, with no probes inside its time.
        // Probes there (three questions) and the card together pass its time on a server at 200 ms a question, here as
        // on one at about a second a question with 4 s, so no card would ever be answered again.
        server.slow = .milliseconds(800)
        let timedOut = await card("Fix the hero video's chapters", agent: ["Scribe": 0.9], on: server)
        server.slow = .milliseconds(200)
        let roundsBeforeNext = await jev.probeRoundsBegun
        let nextCard = await card("Fix the hero video's chapter titles", agent: ["Scribe": 0.9], on: server)
        let roundsAfterNext = await jev.probeRoundsBegun, nextState = await jev.state()
        server.slow = .zero
        check(timedOut.card.meantFor == nil && nextCard.card.meantFor == "Scribe" && roundsAfterNext == roundsBeforeNext
              && nextState == .answering(names: ["stand-in-decider"]),
              "after one timeout the next card is asked at once, with no probes in its time, and a server at 200 ms a question answers it: \(roundsAfterNext - roundsBeforeNext) rounds")
        router.budget = .seconds(3)
        await server.stop()
        let deadBegan = ContinuousClock.now
        let dead = await card("Fix the hero video's thumbnail", agent: ["Scribe": 0.9], on: server)
        let deadTook = deadBegan.duration(to: .now)
        let deadState = await jev.state()
        let nothingLine = "Nothing answers at \(display). Start your decision server there, then Check Again. Meanwhile Binders sorts without it."
        check(dead.card.meantFor == nil && deadTook < .milliseconds(100) && deadState == .unavailable(.unreachable(nothingLine))
              && JevDecisionBackend.Trouble.nothingAnswers.line(display) == nothingLine && !JevDecisionBackend.Trouble.nothingAnswers.isProblem,
              "a server that's stopped: a card costs \(deadTook) and gets no answer, and row A says nothing answers there")
        let restarted = await server.start(port: port)
        await jev.tryAgain()
        let backState = await jev.state()
        check(restarted == port && backState == .answering(names: ["stand-in-decider"]), "started again and Check Again: answering")

        // MARK: A key, not a decision server, answers that don't map
        let troubles: [(mode: DecisionServerStandIn.Mode, title: String, trouble: JevDecisionBackend.Trouble, words: String)] = [
            (.wantsKey, "Fix the members page", .wantsKey,
             "The server at \(display) wants a key. Binders sends none to a decision server: start it without one, listening on this Mac only."),
            (.notADecisionServer, "Fix the partners page", .notADecisionServer(status: 404, path: JevAPI.systemOnePath),
             "\(display) answered, but not as a decision server (HTTP 404 for /v1/systemone)."),
            (.badSums, "Fix the pricing table's totals", .noProbabilities, "The server at \(display) answered, but not with a probability for each option."),
            (.missingKey, "Fix the pricing table's footnotes", .noProbabilities, "The server at \(display) answered, but not with a probability for each option."),
        ]
        for (mode, title, trouble, words) in troubles {
            server.mode = mode
            await jev.tryAgain()
            let state = await jev.state(), found = await jev.troubleNow()
            let refusedCard = await card(title, agent: ["Scribe": 0.9], on: server)
            check(state == .unavailable(.unreachable(words)) && found == trouble && trouble.isProblem && refusedCard.card.meantFor == nil,
                  "\(mode): its card gets no answer, and row A says: \(words)")
        }
        server.mode = .answers
        server.chunked = true
        await jev.tryAgain()
        let chunkedState = await jev.state()
        let chunkedCard = await card("Fix the pricing table's currency", agent: ["Scribe": 0.9], on: server)
        server.chunked = false
        check(chunkedState == .answering(names: ["stand-in-decider"]) && chunkedCard.card.meantFor == "Scribe", "answers sent chunked map")
        let twoHomes = DecisionQuestion(state: "Water the balcony plants", question: RouterQuestions.binderQuestion,
                                        options: [DecisionOption(key: "Home", description: "The flat"), DecisionOption(key: "Home", description: "The garden")])
        let beforeDupes = server.requests.count
        var refusedKeys = false
        do {
            _ = try await jev.decide([twoHomes], expecting: nil, by: .now + .seconds(2))
        } catch DecisionError.refusedKeys {
            refusedKeys = true
        } catch {}
        check(refusedKeys && server.requests.count == beforeDupes, "a question with two options keyed Home is refused before anything is sent: no request")

        // MARK: Measured, and starting
        guard let fixture = MeasureFixture.load(), let bench = try? DecisionMeasureRun.bundledBench() else {
            await server.stop()
            return check(false, "lane R1's answers to the bench (\(MeasureFixture.url.path)) and the bench that comes with Binders read")
        }
        let r1 = fixture.answers(bench)
        let r1Lookup: DecisionServerStandIn.Lookup = { state, instructions, criteria in r1[MeasureFixture.key(state, instructions, criteria)] }
        server.lookup = r1Lookup
        let serverMeasure = await models.measure()?.value
        let measuredBands = await models.bands(by: .now + .seconds(5))
        let kept = serverMeasure.flatMap { models.measures.all.measure(for: $0.identity) }
        if let found = serverMeasure?.measure {
            print("INFO: the server's measure: bands \(found.bands.map { "\($0)" } ?? "none"), dev starts \(found.dev?.starts ?? -1), test starts \(found.test?.starts ?? -1) "
                  + "(\(found.test?.wrongStarts ?? -1) wrong), dev \(found.dev?.score ?? -1), test \(found.test?.score ?? -1), answeredBy \(found.answeredBy ?? []), "
                  + "golden as the probes \(found.golden == DecisionServerStandIn.probesA), kept \(kept?.key == serverMeasure?.identity.key), bands now \(measuredBands.map { "\($0.source) \($0.bands)" } ?? "none")")
        }
        check(serverMeasure?.measure.server?.address == server.address && serverMeasure?.measure.bands == .init(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33, auto: 0.60)
              && serverMeasure?.measure.test?.starts == 4 && serverMeasure?.measure.test?.wrongStarts == 0 && serverMeasure?.measure.dev?.starts == 3
              && serverMeasure?.measure.golden == DecisionServerStandIn.probesA && kept?.key == serverMeasure?.identity.key && measured(measuredBands)
              && measuredBands?.bands.start == 0.97 && serverMeasure?.measure.answeredBy == nil,
              "a server measured on lane R1's answers: start 0.97 (3 dev and 4 test starts, none wrong), suggest 0.50, General 0.45 and 0.33, Auto 0.60, kept with its server's parts and probes, and its bands resolve as measured: \(models.lastMeasureProblem ?? "no problem")")
        // 0.0004 across a rounding edge: nobody 0.2523 becomes 0.2527 (0.252 to 0.253), and the top 0.6539 becomes 0.6535.
        server.overlay = [RouterQuestions.warmUps[1].state: ["nobody": 0.0004, "Codex · pocketfold-site": -0.0004]]
        await jev.tryAgain()
        let wobbled = await models.bands(by: .now + .seconds(5))
        check(wobbled != nil && wobbled?.identity.key != serverMeasure?.identity.key && measured(wobbled) && wobbled?.bands.start == 0.97,
              "probed again with 0.0004 across a rounding edge: another strict key (\(wobbled?.identity.fingerprint ?? "none")), and its measure is still found by the match")
        server.overlay = [:]
        await jev.tryAgain()
        let beforeStart = server.requests.count
        let startCard = await card("Fix the broken image on the about page", into: .ready, agent: ["Scribe": 0.99], on: server)
        let afterStart = Array(server.requests.dropFirst(beforeStart))
        check(started(startCard.card) && startCard.line?.did == "started" && startCard.line?.bands == "measured" && startCard.line?.backend == "jev.1"
              && startCard.line?.model == serverMeasure?.identity.fingerprint && afterStart.count == 5 && afterStart.filter(\.isProbe).count == 3
              && afterStart.filter { $0.path == JevAPI.modelsPath }.count == 1,
              "measured, a card typed into Ready for Scribe at 0.99 starts, and right before the start its fields and three probes were asked again: \(afterStart.count) requests")
        controller.flowBar.hide()
        server.stallProbes = true
        let stallBegan = ContinuousClock.now
        let stalled = await card("Fix the broken image on the team page", into: .ready, agent: ["Scribe": 0.99], on: server)
        let stallTook = stallBegan.duration(to: .now)
        server.stallProbes = false
        check(!started(stalled.card) && stalled.card.meantFor == "Scribe" && stalled.line?.whyNotStarted == "the server didn't confirm its model"
              && stallTook < .milliseconds(2_600),
              "probes that don't come back at the start: suggested, not started, within the start's 2 s (\(stallTook)), and the log keeps that apart: the server didn't confirm its model")
        await jev.tryAgain()

        // MARK: Another model behind the same address and names
        var probesB = DecisionServerStandIn.probesA
        probesB[0][2] += 0.0015
        probesB[0][4] -= 0.0015
        // The 8-bit conversion's own answers to the two agent probes (scratch-R2/bench-s4-final-8bit-dev.jsonl): short-02 0.12
        // apart in log-odds, and fr-06's top option another.
        probesB[1] = [0.07173139402671913, 0.6604756403039523, 0.0014733422423715517, 0.012627602891981215, 0.0005228732203719576,
                      0.0009212785581302193, 6.783316262825116e-05, 7.772142721447737e-05, 0.25210231416663087]
        probesB[2] = [0.001367393781274827, 0.001506002024674855, 0.4144526686192584, 0.008051647897347823, 0.009470418263091767,
                      0.0013711101439355436, 0.3479758603726503, 0.0009540777533698215, 0.2148508211443967]
        let other = probesB
        server.probes = other
        await jev.tryAgain()
        let otherBands = await models.bands(by: .now + .seconds(5))
        let otherCard = await card("Fix the broken image on the jobs page", into: .ready, agent: ["Scribe": 0.99], on: server)
        check(otherBands != nil && otherBands?.identity.key != serverMeasure?.identity.key && otherBands?.source == .unmeasured && !started(otherCard.card)
              && otherCard.card.meantFor == "Scribe" && otherCard.line?.whyNotStarted == "backend has no start bar",
              "another model behind the same address and names, its binder probe within 0.002 of the measured one's: a new identity, unmeasured, and a card at 0.99 is suggested, not started")
        server.probes = DecisionServerStandIn.probesA
        await jev.tryAgain()
        server.afterCard = { [server] in server.probes = other }
        let switched = await card("Fix the broken image on the press page", into: .ready, agent: ["Scribe": 0.99], on: server)
        server.afterCard = nil
        check(!started(switched.card) && switched.card.meantFor == "Scribe" && switched.line?.whyNotStarted == "the decision model changed"
              && switched.line?.bands == "measured",
              "the same switch between a card's decision and its start: the probes asked after the decision find the other model, and the card is suggested")
        server.probes = DecisionServerStandIn.probesA
        await jev.tryAgain()

        // MARK: Servers that answer unlike one model
        let wobbly = DecisionServerStandIn()
        if await wobbly.start() != nil {
            wobbly.lookup = r1Lookup
            wobbly.wobble = true
            models.choose(.server(wobbly.address))
            _ = await models.bands(by: .now + .seconds(5))
            let unsteady = await models.measure()?.value
            check(unsteady == nil && models.lastMeasureProblem == DecisionMeasureRun.Stop.unsteady.words
                  && !models.measures.all.measures.contains { $0.server?.address == wobbly.address },
                  "a server whose probes answer 0.01 apart on every second ask is refused a measure, and nothing is kept: \(models.lastMeasureProblem ?? "no problem")")
            await wobbly.stop()
        } else {
            check(false, "a second stand-in decision server listens")
        }
        let strict = DecisionServerStandIn()
        if await strict.start() != nil {
            let wrong = fixture.answers(bench, wrongTestStart: true)
            strict.lookup = { state, instructions, criteria in wrong[MeasureFixture.key(state, instructions, criteria)] }
            models.choose(.server(strict.address))
            _ = await models.bands(by: .now + .seconds(5))
            let first = await models.measure()?.value
            strict.lookup = r1Lookup
            let second = await models.measure()?.value
            let held = await models.bands(by: .now + .seconds(5))
            check(first?.measure.noStart == .testWrong && first?.verdict?.noStart == .testWrong && first?.measure.test?.wrongStarts == 1
                  && second?.measure.noStart == .testBefore && second?.measure.bands?.start == nil && second?.measure.bands?.suggest == 0.50
                  && second?.measure.bands?.generalBelow == 0.45 && held?.bands.start == nil && held?.verdict?.noStart == .testWrong && held?.bands.suggest == 0.50,
                  "a test with a wrong start at 0.97 takes the start level away (testWrong), and that holds: fixed and measured again, it keeps its filing and naming bands and starts nothing (testBefore)")
            await strict.stop()
        } else {
            check(false, "a third stand-in decision server listens")
        }
        let routed = DecisionServerStandIn()
        if await routed.start() != nil {
            routed.lookup = r1Lookup
            routed.routing = { state in state.unicodeScalars.allSatisfy(\.isASCII) ? "english" : "multilingual" }
            models.choose(.server(routed.address))
            let bothModels = await models.bands(by: .now + .seconds(5))
            let several = await models.measure()?.value
            let suggested = await card("Fix the broken image on the blog index", agent: ["Scribe": 0.8], on: routed)
            check(bothModels?.identity.server?.answeredBy == ["english", "multilingual"] && several?.measure.noStart == .severalModels
                  && several?.measure.answeredBy == ["english", "multilingual"] && several?.measure.bands?.start == nil && several?.measure.bands?.suggest == 0.50
                  && suggested.card.meantFor == "Scribe",
                  "a server that routes by language: its probes reach both of its models, its measure keeps both and gets no start level (severalModels), and it still suggests")
            routed.routing = { _ in "english" }
            await (models.backend as? JevDecisionBackend)?.tryAgain()
            let one = await models.measure()?.value
            let routedTitle = "Fix the broken image on the careers page"
            routed.routing = { state in state == routedTitle ? "multilingual" : "english" }
            let listedBefore = routed.modelsRequests
            let routedCard = await card(routedTitle, into: .ready, agent: ["Scribe": 0.99], on: routed)
            for _ in 0..<50 where routed.modelsRequests == listedBefore { try? await Task.sleep(for: .milliseconds(10)) }
            check(one?.measure.noStart == nil && one?.measure.bands?.start == 0.97 && one?.measure.answeredBy == ["english"] && !started(routedCard.card)
                  && routedCard.card.meantFor == "Scribe" && routedCard.line?.whyNotStarted == "the decision model changed" && routed.modelsRequests > listedBefore,
                  "measured as one model, a card at 0.99 answered by another of its models is suggested, not started (the decision model changed), and it's probed again at once")
            await routed.stop()
        } else {
            check(false, "a fourth stand-in decision server listens")
        }

        // MARK: Only this Mac's own addresses
        let connectionsBefore = LoopbackHTTP.connections, requestsBefore = server.requests.count
        models.choose(.server("http://192.168.1.20:8008"))
        await models.settled()
        let lanState = await models.backend?.state()
        let lanCard = await card("Fix the broken image on the contact page", agent: ["Scribe": 0.9], on: server)
        let lanWords = "Binders uses a decision server only on this Mac, and 192.168.1.20 isn't one of its own addresses. Type 127.0.0.1, ::1 or localhost, with the server's port."
        try? await Task.sleep(for: .milliseconds(100))
        check(lanState == .unavailable(.address(lanWords)) && lanCard.card.meantFor == nil && LoopbackHTTP.connections == connectionsBefore
              && server.requests.count == requestsBefore,
              "a LAN address is refused with why, and nothing connects anywhere, the stand-in server included: \(lanState.map { "\($0)" } ?? "no backend")")
        let local = JevDecisionBackend(address: "http://localhost:\(port)")
        let localIdentity = await local.identity(by: .now + .seconds(5))
        let localState = await local.state()
        check(localIdentity != nil && localState == .answering(names: ["stand-in-decider"]) && local.display == "localhost:\(port)",
              "http://localhost:<port> works: localhost looked up, and every address it gave this Mac's loopback: \(localState)")
        let elsewhere = JevDecisionBackend(address: "http://localhost:\(port)", resolver: { _ in [.ipv4([192, 168, 1, 20]), .ipv4([127, 0, 0, 1])] })
        let connectionsElsewhere = LoopbackHTTP.connections, requestsElsewhere = server.requests.count
        let elsewhereIdentity = await elsewhere.identity(by: .now + .seconds(2))
        let elsewhereState = await elsewhere.state()
        check(elsewhereIdentity == nil && LoopbackHTTP.connections == connectionsElsewhere && server.requests.count == requestsElsewhere
              && elsewhereState == .unavailable(.address("On this Mac, localhost leads to 192.168.1.20, which isn't its own loopback address, so Binders won't send to it. Use 127.0.0.1 and the port.")),
              "localhost that leads to 192.168.1.20 and 127.0.0.1 is refused with why, and nothing connects: \(elsewhereState)")
        // A lookup that never comes back, until the test lets it.
        let release = DispatchSemaphore(value: 0)
        let lookups = CallCount()
        let stuck = JevDecisionBackend(address: "http://localhost:\(port)", resolver: { _ in
            lookups.add()
            release.wait()
            return [.ipv4([127, 0, 0, 1])]
        })
        router.override = stuck
        let connectionsStuck = LoopbackHTTP.connections
        let stuckBegan = ContinuousClock.now
        let meanwhile = Task { () -> Duration in
            try? await Task.sleep(for: .milliseconds(150))
            let asked = ContinuousClock.now
            _ = await stuck.state()
            return asked.duration(to: .now)
        }
        let firstStuck = await card("Fix the broken image on the events page", agent: ["Scribe": 0.9], on: server)
        let firstTook = stuckBegan.duration(to: .now)
        let stateTook = await meanwhile.value
        let secondBegan = ContinuousClock.now
        let secondStuck = await card("Fix the broken image on the venues page", agent: ["Scribe": 0.9], on: server)
        let secondTook = secondBegan.duration(to: .now)
        let stuckState = await stuck.state()
        router.override = nil
        check(firstStuck.card.meantFor == nil && firstTook >= .milliseconds(450) && firstTook < .milliseconds(1_000) && secondStuck.card.meantFor == nil
              && secondTook < .milliseconds(100) && lookups.value == 1 && LoopbackHTTP.connections == connectionsStuck && stateTook < .milliseconds(100)
              && stuckState == .unavailable(.unreachable(JevDecisionBackend.Trouble.lookupSlow.line("localhost:\(port)"))),
              "a lookup of localhost that never comes back: the card goes on at half a second (\(firstTook)), the next fails at once (\(secondTook)), one lookup in all, nothing connected, and the backend answered meanwhile (\(stateTook))")
        release.signal()

        // MARK: The real factory's backend for a server
        let realModels = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: folder.appendingPathComponent("router-test-server-measures.json")),
                                        fingerprints: FolderFingerprints(url: folder.appendingPathComponent("router-test-server-fingerprints.json")))
        let realTev1 = realModels.backend as? MLXDecisionBackend
        realModels.choose(.server(server.address))
        await realModels.settled()
        let realServer = realModels.backend as? JevDecisionBackend
        router.models = realModels
        let viaReal = await card("Fix the broken image on the sponsors page", agent: ["Scribe": 0.9], on: server)
        router.models = models
        let tev1Started = await realTev1?.startedMLX ?? false
        check(realServer != nil && viaReal.card.meantFor == "Scribe" && !tev1Started,
              "the real factory makes the decision server's backend for a server chosen, on any Mac, and with it nothing calls MLX")

        // The log names a server's model by its fingerprint alone.
        log.flush()
        let raw = (try? String(contentsOf: log.url, encoding: .utf8)) ?? ""
        check(raw.contains("jev1-") && !["stand-in-decider", "127.0.0.1", "localhost", "english", "multilingual"].contains { raw.contains($0) },
              "the tuning log holds the servers' fingerprints and reader, never an address, a model's name or the model an answer named")
        models.choose(.tev1)
        await models.settled()
        standIns.serverBackend = nil
        controller.flowBar.hide()
        await server.stop()
    }

    /// The measure through DecisionModels, the button's own path, over a stand-in that answers the bench's made-up cards
    /// with lane R1's answers: the bench that comes with Binders; R1's bands, scores and starts; kept under the stand-in's
    /// key, then resolved as measured; and stopped, keeping nothing, by Cancel after 50 calls, a call that throws, one
    /// whose model changed, one past a card's time, a switch, and a quit.
    @MainActor
    static func measureSelfTest(folder: URL, check: (Bool, String) -> Void) async {
        let bench: RouterBench.Data
        do {
            bench = try DecisionMeasureRun.bundledBench()
        } catch {
            return check(false, "the bench that comes with Binders reads: \(error.localizedDescription)")
        }
        check(bench.items.count == 278 && bench.items(.dev).count == 111 && bench.items(.test).count == 167,
              "the bench that comes with Binders is in its bundle, its two files as their names were checked (RouterBench.reviewedSHA256), and reads as 278 made-up cards: 111 dev, 167 test")
        guard let fixture = MeasureFixture.load() else { return check(false, "lane R1's answers to the bench read (\(MeasureFixture.url.path))") }
        let r1 = fixture.answers(bench)
        let standIn = RouterStandIn()
        standIn.identity = DecisionIdentity(fingerprint: "mlx1-feedfacefeedfacefeedface", reader: DecisionReader.chat.id)
        standIn.warmUpValues = DecisionServerStandIn.probesA
        standIn.answerer = { question in
            r1[MeasureFixture.key(question)].map { found in question.options.map { found[$0.key] ?? 0 } }
        }
        let path = folder.appendingPathComponent("models-measure/Measured Decider", isDirectory: true).path
        let measureModels = DecisionModels(choice: .folder(path), measures: DecisionMeasureStore(url: folder.appendingPathComponent("router-test-measure-store.json")),
                                           fingerprints: FolderFingerprints(url: folder.appendingPathComponent("router-test-measure-fingerprints.json")),
                                           makeBackend: { _ in standIn })
        func keptNothing() -> Bool { measureModels.measures.all.measure(for: standIn.identity) == nil && measureModels.measuring == nil }
        func waitFor(_ calls: Int) async {
            for _ in 0..<10_000 where (measureModels.measuring?.done ?? 0) < calls { try? await Task.sleep(for: .milliseconds(1)) }
        }
        let seen = ProgressSeen()
        let result = await measureModels.measure(onProgress: { seen.done = $0 })?.value
        let outcome = result?.outcome
        let resolved = await measureModels.bands(by: .now + .seconds(2))
        check(outcome?.bands == RouterBands(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33, auto: 0.60)
              && result?.auto.dev == DecisionBands.tev1?.auto?.dev && result?.auto.test == DecisionBands.tev1?.auto?.test
              && outcome?.dev.starts.map(\.id).sorted() == ["coding-13", "de-05", "fr-04"] && outcome?.test.starts.count == 4 && outcome?.test.starts.allSatisfy(\.right) == true
              && abs((outcome?.dev.score.score ?? 0) - 171.0 / 222) < 1e-12 && abs((outcome?.test.score.score ?? 0) - 265.0 / 334) < 1e-12
              && standIn.calls == DecisionMeasureRun.calls && seen.done == DecisionMeasureRun.calls,
              "the measure over lane R1's answers: General 0.45 and 0.33, suggest 0.50, Auto 0.60 with Tev1's built-in counts, start 0.97 with coding-13, fr-04 and de-05, and test's 4 starts, none wrong; dev 0.7703, test 0.7934, in \(standIn.calls) calls")
        let record = measureModels.measures.all.measure(for: standIn.identity)
        if case .measured = resolved?.source {
            check(record?.key == standIn.identity.key && record?.golden == standIn.warmUpValues && record?.test?.score.map { abs($0 - 265.0 / 334) < 1e-12 } == true
                  && resolved?.bands.start == 0.97 && standIn.goldenGiven == standIn.warmUpValues && measureModels.measuring == nil && measureModels.lastMeasureProblem == nil,
                  "kept under the model's key with its warm-ups as its goldens, and its bands then resolve as measured, the goldens given to it")
        } else {
            check(false, "the measure is kept, and its bands resolve as measured: \(resolved.map { "\($0.source)" } ?? "none")")
        }
        measureModels.measures.remove(fingerprint: standIn.identity.fingerprint)

        // Stopped, keeping nothing.
        standIn.delay = .milliseconds(2)
        let cancelled = measureModels.measure()
        await waitFor(50)
        measureModels.cancelMeasure()
        let cancelledResult = await cancelled?.value
        check(cancelledResult == nil && measureModels.lastMeasureProblem == DecisionMeasureRun.cancelled && keptNothing(),
              "Cancel after 50 calls keeps nothing: \(measureModels.lastMeasureProblem ?? "no words")")
        standIn.delay = .zero
        let stops: [(error: DecisionError, words: String)] = [
            (.mlx("the stand-in was told to fail"), "A made-up card got no answer (MLX: the stand-in was told to fail), so the measure stopped. Nothing was kept."),
            (.changed, DecisionMeasureRun.Stop.changed.words),
            (.timedOut, DecisionMeasureRun.Stop.tooSlow.words),
        ]
        for (error, words) in stops {
            standIn.failAt = (standIn.calls + 100, error)
            let stopped = await measureModels.measure()?.value
            check(stopped == nil && measureModels.lastMeasureProblem == words && keptNothing(), "a call that throws \(error) at call 100 stops it: \(words)")
        }
        standIn.failAt = nil
        standIn.delay = .milliseconds(2)
        let switchedAway = measureModels.measure()
        await waitFor(50)
        measureModels.choose(.off)
        let switchedResult = await switchedAway?.value
        check(switchedResult == nil && measureModels.lastMeasureProblem == DecisionMeasureRun.switched && keptNothing(),
              "choosing another model stops it, and nothing is kept: \(measureModels.lastMeasureProblem ?? "no words")")
        measureModels.choose(.folder(path))
        await measureModels.settled()
        let quitting = measureModels.measure()
        await waitFor(50)
        let quitAsked = ContinuousClock.now
        await measureModels.prepareForQuit(within: .seconds(3))
        let quitTook = quitAsked.duration(to: .now)
        let quitResult = await quitting?.value
        check(quitResult == nil && quitTook < .seconds(1) && keptNothing() && standIn.retired && measureModels.measure() == nil,
              "a quit during it returns within a second (\(quitTook)), the measure stopped and kept nothing, and no measure begins after")
        standIn.delay = .zero
    }
}
