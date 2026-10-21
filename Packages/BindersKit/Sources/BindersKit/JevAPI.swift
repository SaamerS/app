import Foundation

// A decision server on this Mac: the Jev API as Kev serves it (POST /v1/systemone, GET /v1/models), which Laya's
// laya-serve and OpenJev's helper also speak, and the rule for where Binders may send one a card: this Mac's own loopback
// addresses, nothing else. The Mac makes the connections (LoopbackHTTP, over the loopback interface only, with no key);
// the address check, the request and the mapping of the answer back to the options are here, as plain values.

// MARK: - The address

/// A decision server's address, as LoopbackRule allowed it: http, a loopback host and a port.
public struct LoopbackAddress: Equatable, Hashable, Sendable {
    public enum Host: String, Sendable {
        /// 127.0.0.1, used as it is.
        case ipv4 = "127.0.0.1"
        /// ::1, used as it is.
        case ipv6 = "::1"
        /// Looked up before every connection, and used only when every address it gives is this Mac's loopback.
        case localhost
    }

    public var host: Host
    public var port: Int

    public init(host: Host, port: Int) {
        self.host = host
        self.port = port
    }

    /// As Settings stores it: http://127.0.0.1:8008, http://[::1]:8008, http://localhost:8008.
    public var normalized: String { "http://\(display)" }

    /// As the rows show it, and as the Host header carries it: 127.0.0.1:8008, [::1]:8008, localhost:8008.
    public var display: String {
        switch host {
        case .ipv4: "127.0.0.1:\(port)"
        case .ipv6: "[::1]:\(port)"
        case .localhost: "localhost:\(port)"
        }
    }
}

/// Where Binders may send a card to a decision server: http, to 127.0.0.1, ::1 or localhost, with a port; never a LAN
/// address, another name or https. localhost is looked up before every connection, and every address it gives must be
/// this Mac's loopback (`pick`), so /etc/hosts can't send a card elsewhere.
public enum LoopbackRule {
    /// Why an address is refused, in words for the sheet and the row.
    public struct Refusal: Error, Equatable, Sendable {
        public var words: String

        public init(_ words: String) { self.words = words }
    }

    /// The paths that may follow the port, and are dropped: the server's root, or its API's.
    public static let pathsDropped: Set<String> = ["", "/", "/v1", "/v1/", "/v1/systemone"]

    static let portRange = "The port must be from 1 to 65535."

    /// The address as typed, checked; read with http:// in front when it has no scheme.
    public static func check(_ typed: String) -> Result<LoopbackAddress, Refusal> {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(Refusal("Type the server's address, such as http://127.0.0.1:8008.")) }
        let full = text.contains("://") ? text : "http://" + text
        guard let parts = URLComponents(string: full), let scheme = parts.scheme?.lowercased(), let host = parts.host, !host.isEmpty else {
            return .failure(Refusal("That isn't an address: type one such as http://127.0.0.1:8008."))
        }
        guard scheme != "https" else {
            return .failure(Refusal("Use http:// for a decision server on this Mac: the connection never leaves it, and Binders checks no certificate for one."))
        }
        guard scheme == "http" else { return .failure(Refusal("Type an http:// address, such as http://127.0.0.1:8008.")) }
        guard parts.user == nil, parts.password == nil else {
            return .failure(Refusal("Leave the name and password out of the address: Binders sends no key to a decision server."))
        }
        let kind: LoopbackAddress.Host
        switch host.lowercased() {
        case "127.0.0.1": kind = .ipv4
        case "::1", "[::1]": kind = .ipv6
        case "localhost": kind = .localhost
        default:
            return .failure(Refusal("Binders uses a decision server only on this Mac, and \(host) isn't one of its own addresses. Type 127.0.0.1, ::1 or localhost, with the server's port."))
        }
        guard let port = parts.port else {
            // URLComponents reads no port from one too long to be a number.
            return .failure(Refusal(endsInPortDigits(full) ? portRange : "Add the port the server listens on, such as http://127.0.0.1:8008."))
        }
        guard (1...65_535).contains(port) else { return .failure(Refusal(portRange)) }
        guard pathsDropped.contains(parts.percentEncodedPath), parts.query == nil, parts.fragment == nil else {
            return .failure(Refusal("Type only the address and the port, such as http://127.0.0.1:8008."))
        }
        return .success(LoopbackAddress(host: kind, port: port))
    }

    /// Whether the part after "://" and before any path ends in ":" and digits.
    static func endsInPortDigits(_ address: String) -> Bool {
        guard let start = address.range(of: "://")?.upperBound else { return false }
        let authority = address[start...].prefix { !"/?#".contains($0) }
        guard let colon = authority.lastIndex(of: ":") else { return false }
        let digits = authority[authority.index(after: colon)...]
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// An address the system gave for localhost.
    public enum Resolved: Equatable, Hashable, Sendable {
        /// Four bytes.
        case ipv4([UInt8])
        /// Sixteen bytes, and the interface its scope names (lo0, en0), if any.
        case ipv6([UInt8], interface: String?)

        /// As the refusal shows it: 10.0.0.5, fe80::1%en0.
        public var display: String {
            switch self {
            case .ipv4(let bytes):
                return bytes.map(String.init).joined(separator: ".")
            case .ipv6(let bytes, let interface):
                guard bytes.count == 16 else { return "an address that isn't one" }
                let groups = stride(from: 0, to: 16, by: 2).map { Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]) }
                // The longest run of two or more zero groups becomes "::".
                var best = (start: 0, length: 0), run = (start: 0, length: 0)
                for (index, group) in groups.enumerated() {
                    run = group == 0 ? (run.length == 0 ? (index, 1) : (run.start, run.length + 1)) : (0, 0)
                    if run.length > best.length { best = run }
                }
                let hex = groups.map { String($0, radix: 16) }
                let text = best.length >= 2
                    ? hex[0..<best.start].joined(separator: ":") + "::" + hex[(best.start + best.length)...].joined(separator: ":")
                    : hex.joined(separator: ":")
                return interface.map { text + "%" + $0 } ?? text
            }
        }
    }

    static let ipv6Loopback: [UInt8] = Array(repeating: 0, count: 15) + [1]

    /// This Mac's own loopback: IPv4 127.0.0.0/8, IPv6 ::1, or IPv6 link-local fe80::/10 scoped to lo0. Not
    /// ::ffff:127.0.0.1, not 0.0.0.0, not a LAN address.
    public static func isLoopback(_ address: Resolved) -> Bool {
        switch address {
        case .ipv4(let bytes):
            bytes.count == 4 && bytes[0] == 127
        case .ipv6(let bytes, let interface):
            bytes.count == 16 && (bytes == ipv6Loopback || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 && interface == "lo0"))
        }
    }

    /// Where Binders connects for localhost, by number, so nothing is looked up between the check and the connection:
    /// every address the lookup gave must be this Mac's loopback; then the first 127.x, else ::1, else the first other.
    public static func pick(_ addresses: [Resolved]) -> Result<Resolved, Refusal> {
        guard !addresses.isEmpty else {
            return .failure(Refusal("On this Mac, localhost leads to no address, so Binders didn't connect. Use 127.0.0.1 and the port."))
        }
        if let elsewhere = addresses.first(where: { !isLoopback($0) }) {
            return .failure(Refusal("On this Mac, localhost leads to \(elsewhere.display), which isn't its own loopback address, so Binders won't send to it. Use 127.0.0.1 and the port."))
        }
        if let ipv4 = addresses.first(where: { if case .ipv4 = $0 { true } else { false } }) { return .success(ipv4) }
        if let ipv6 = addresses.first(where: { if case .ipv6(let bytes, _) = $0 { bytes == ipv6Loopback } else { false } }) { return .success(ipv6) }
        return .success(addresses[0])
    }
}

// MARK: - The Jev API

/// The requests and answers of a decision server, as Kev serves them (kev/api.py, kev/serve.py). A card's questions go as
/// `choice` questions, each with its options as criteria keyed by the option's key and in the app's order (a JSON object
/// made from a Swift dictionary has none, and the order can change a server's answer); the answer's probabilities come
/// back by key and are put in that order again. `choice` and `confidence` are never read: Kev's and OpenJev's confidence
/// is (p_max − 1/K) / (1 − 1/K), not a probability.
public enum JevAPI {
    public static let systemOnePath = "/v1/systemone"
    public static let modelsPath = "/v1/models"
    public static let versionPath = "/v1/version"
    /// The most of an answer Binders reads.
    public static let maxAnswer = 1_000_000
    /// How far the asked options' probabilities may sum from 1: servers round each to 4 places, at most 0.0012 off for
    /// 24 options.
    public static let sumTolerance = 0.02

    /// What went wrong with a server, in words for the tuning log ("router model: …") and the row.
    public enum Problem: Error, Equatable, Sendable {
        /// Two options with one key, or an option with none: sent, a repeated name collapses into one on the server and the
        /// probabilities no longer line up with the options. Refused before anything is sent.
        case duplicateKeys
        /// HTTP 401 or 403.
        case wantsKey(status: Int)
        /// HTTP 404 or 405: something answered, but not as a decision server.
        case notADecisionServer(status: Int, path: String)
        /// HTTP 422: the first line of what it said.
        case refused(String)
        /// Anything else: what happened.
        case server(String)
        /// An answer without a probability from 0 to 1 for each option, or whose probabilities don't sum to 1.
        case noProbabilities

        public var words: String {
            switch self {
            case .duplicateKeys: "two options with one key"
            case .wantsKey: "wants a key"
            case .notADecisionServer(let status, let path): "HTTP \(status) for \(path)"
            case .refused(let detail): "it refused the question: \(detail)"
            case .server(let what): what
            case .noProbabilities: "no probability for each option"
            }
        }
    }

    /// One request: which of the questions it carries, in order, and its body.
    public struct Request: Equatable, Sendable {
        public var questions: [Int]
        public var body: Data
    }

    /// The requests for a card's questions: those that share a state go in one, so the server reads the state once (the
    /// router asks one state, so a card is one request); others go one request each, in the order they come.
    public static func requests(_ questions: [DecisionQuestion], model: String?) throws -> [Request] {
        var groups: [(state: [UInt8], indices: [Int])] = []
        for (index, question) in questions.enumerated() {
            let state = Array(question.state.utf8)
            if let at = groups.firstIndex(where: { $0.state == state }) {
                groups[at].indices.append(index)
            } else {
                groups.append((state, [index]))
            }
        }
        return try groups.map { group in
            let asked = group.indices.map { questions[$0] }
            return Request(questions: group.indices, body: try request(state: asked[0].state, questions: asked, model: model))
        }
    }

    /// One request's body, built by hand with Python's separators:
    /// {"model": M, "state": S, "questions": {"q1": {"type": "choice", "instructions": Q, "criteria": {K: D, …}}, …}},
    /// `model` only when given. Throws `duplicateKeys` when a question has two options whose keys are equal as Swift
    /// strings (equal bytes, or canonically equal like an NFC and an NFD "Café"), or a key that's blank.
    public static func request(state: String, questions: [DecisionQuestion], model: String?) throws -> Data {
        var asked: [String] = []
        for (index, question) in questions.enumerated() {
            var keys: [String] = []
            for option in question.options {
                guard !PythonText.strip(option.key).isEmpty, !keys.contains(option.key) else { throw Problem.duplicateKeys }
                keys.append(option.key)
            }
            let criteria = question.options.map { "\(PythonText.jsonString($0.key)): \(PythonText.jsonString($0.description))" }.joined(separator: ", ")
            asked.append("\"q\(index + 1)\": {\"type\": \"choice\", \"instructions\": \(PythonText.jsonString(question.question)), \"criteria\": {\(criteria)}}")
        }
        var body = "{"
        if let model { body += "\"model\": \(PythonText.jsonString(model)), " }
        body += "\"state\": \(PythonText.jsonString(state)), \"questions\": {\(asked.joined(separator: ", "))}}"
        return Data(body.utf8)
    }

    /// One request's answer: each question's probabilities in the order its options were asked, matched by key as Swift
    /// strings (a server may hand a key back in another normal form), and the model the answer says answered it. Keys it
    /// wasn't asked about are ignored, and the sum check catches any weight they took. Nothing is renormalised.
    /// `names` are those /v1/models gave, so an echo of one of them isn't taken for the model that answered.
    public static func answers(status: Int, body: Data, for questions: [DecisionQuestion], sent model: String?,
                               names: [String] = []) throws -> (probs: [[Double]], answeredBy: String?) {
        switch status {
        case 200: break
        case 401, 403: throw Problem.wantsKey(status: status)
        case 404, 405: throw Problem.notADecisionServer(status: status, path: systemOnePath)
        case 422: throw Problem.refused(detail(body) ?? "HTTP 422")
        default: throw Problem.server("HTTP \(status)")
        }
        guard body.count <= maxAnswer else { throw Problem.server("its answer was over 1 MB") }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw Problem.server("its answer wasn't JSON") }
        guard let answers = object["answers"] as? [String: Any] else { throw Problem.noProbabilities }
        var probs: [[Double]] = []
        for (index, question) in questions.enumerated() {
            guard let answer = answers["q\(index + 1)"] as? [String: Any], (answer["type"] as? String ?? "choice") == "choice",
                  let given = answer["probabilities"] as? [String: Any] else { throw Problem.noProbabilities }
            var row: [Double] = []
            for option in question.options {
                let found = given.filter { $0.key == option.key }
                guard found.count == 1, let value = found.first?.value, let p = probability(value) else { throw Problem.noProbabilities }
                row.append(p)
            }
            guard abs(row.reduce(0, +) - 1) <= sumTolerance else { throw Problem.noProbabilities }
            probs.append(row)
        }
        return (probs, answeredBy(object, sent: model, names: names))
    }

    /// A probability: a number, not a boolean, finite, from 0 to 1, the very one the server wrote. JSONSerialization reads
    /// a long decimal as an NSDecimalNumber, whose doubleValue can be a bit off the nearest double; its digits read as a
    /// Double aren't.
    static func probability(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let p = (number as? NSDecimalNumber).flatMap { Double($0.stringValue) } ?? number.doubleValue
        return p.isFinite && (0...1).contains(p) ? p : nil
    }

    /// The model an answer says answered it: Laya's routing.model (each answer of its router names the checkpoint);
    /// else the body's model when it's neither what Binders sent nor one of the names /v1/models gave (OpenJev's helper
    /// puts its model folder, calibration, flags and its own file's hash there); else nil (Kev echoes the model asked
    /// for, or its default name, which it lists).
    static func answeredBy(_ object: [String: Any], sent model: String?, names: [String]) -> String? {
        if let routing = object["routing"] as? [String: Any], let name = routing["model"] as? String, !name.isEmpty { return name }
        guard let named = object["model"] as? String, !named.isEmpty, named != model, !names.contains(named) else { return nil }
        return named
    }

    /// The first line of what a server said when it refused a request: FastAPI's `detail` (a string, or pydantic's list
    /// of errors), or OpenJev's `error.message`; at most 200 characters.
    static func detail(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let text: String?
        if let detail = object["detail"] as? String {
            text = detail
        } else if let errors = object["detail"] as? [[String: Any]] {
            text = errors.first?["msg"] as? String
        } else if let error = object["error"] as? [String: Any] {
            text = error["message"] as? String
        } else {
            text = object["error"] as? String
        }
        guard let line = text.flatMap({ PythonText.splitlines(PythonText.strip($0)).first }), !line.isEmpty else { return nil }
        return PythonText.prefix(line, codePoints: 200)
    }

    // MARK: What it says it serves

    /// What a server says it serves: its names, in order, and its fixed fields as key=value lines, sorted, without
    /// repeats. The fields are the entries' own strings, numbers and booleans named in `fixedFields`, which stay put while
    /// it serves; Kev's counters (prefix_cache, batches, cuda_graphs) are objects, and an OpenAI-style `created` is the
    /// time of each answer, so neither counts.
    public struct Served: Equatable, Sendable {
        public var names: [String]
        public var fields: [String]

        public init(names: [String], fields: [String]) {
            self.names = names
            self.fields = fields
        }
    }

    /// The fields of a /v1/models entry that make up a server's identity: Kev's card has twelve (all but id and the last
    /// four), an OpenAI-style list the rest.
    public static let fixedFields: Set<String> = ["name", "id", "description", "release_date", "run", "base", "lora", "device", "backend", "dtype",
                                                  "temperature", "max_state_tokens", "truncate_states", "root", "parent", "max_model_len", "owned_by"]
    /// OpenJev's /v1/version: its model folder, calibration and its own file's hash.
    public static let versionFields: Set<String> = ["model_dir", "T", "noul_t", "noul_bias", "shim_file", "shim_sha256"]

    /// GET /v1/models: Kev's {"models": [{"name": …}]} or an OpenAI-style {"data": [{"id": …}]}. Nil for a 404 or 405,
    /// a server that lists none (then GET /v1/version); a list it can't read counts as one with no names.
    public static func models(status: Int, body: Data) throws -> Served? {
        switch status {
        case 200: break
        case 401, 403: throw Problem.wantsKey(status: status)
        case 404, 405: return nil
        default: throw Problem.server("HTTP \(status) for \(modelsPath)")
        }
        guard body.count <= maxAnswer, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Served(names: [], fields: [])
        }
        let entries: [[String: Any]], nameKey: String
        if let models = object["models"] as? [[String: Any]] {
            (entries, nameKey) = (models, "name")
        } else if let data = object["data"] as? [[String: Any]] {
            (entries, nameKey) = (data, "id")
        } else {
            return Served(names: [], fields: [])
        }
        return Served(names: entries.compactMap { $0[nameKey] as? String }, fields: Set(entries.flatMap { fieldLines($0, named: fixedFields) }).sorted())
    }

    /// GET /v1/version, OpenJev's: its fixed fields, and no names (its answers name the model). Nil for a 404 or 405, or
    /// a body it can't read.
    public static func version(status: Int, body: Data) throws -> Served? {
        switch status {
        case 200: break
        case 401, 403: throw Problem.wantsKey(status: status)
        case 404, 405: return nil
        default: throw Problem.server("HTTP \(status) for \(versionPath)")
        }
        guard body.count <= maxAnswer, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return Served(names: [], fields: fieldLines(object, named: versionFields).sorted())
    }

    /// An entry's strings, numbers and booleans among `named`, as key=value.
    static func fieldLines(_ entry: [String: Any], named: Set<String>) -> [String] {
        entry.compactMap { key, value in
            guard named.contains(key), let text = scalar(value) else { return nil }
            return "\(key)=\(text)"
        }
    }

    /// A string, a number or a boolean as text; nil for anything else (an object, a list, null).
    static func scalar(_ value: Any) -> String? {
        if let string = value as? String { return string }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        if CFNumberIsFloatType(number) { return "\(number.doubleValue)" }
        return "\(number.int64Value)"
    }
}
