import Foundation
import BindersKit

enum LLMError: LocalizedError {
    case http(Int, String)
    case emptyResponse
    /// A thinking model used its whole reply on reasoning and never got to the answer.
    case onlyThinking
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): "HTTP \(code): \(body.prefix(200))"
        case .emptyResponse: "The model returned an empty response"
        case .onlyThinking:
            "The model spent its whole reply thinking and never answered. Turn thinking off for it on your server "
                + "(for llama.cpp, start it with --reasoning-budget 0), or choose a model without thinking."
        case .invalidResponse: "Unexpected response from the model server"
        }
    }
}

protocol LLMClient: Sendable {
    var model: String { get }
    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String
    /// Streams the reply and stops early, returning what arrived so far, once `stopWhen` says the model has gone off the
    /// rails. It is asked after every chunk that completes a line.
    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String
    /// The same, telling `onText` the reply so far each time it grows, for something shown as it's written (Ask). A client
    /// that can't stream tells it once, with the whole reply.
    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> String
    /// The same, the reply held to `schema` where the client can hold it (lane DS3): MLX token by token, Ollama with
    /// `format`, an OpenAI-compatible server with `response_format`. A client that can't, or a server that turns it down,
    /// answers as `stream` does, and says so in `SchemaReply.held` and `why`.
    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval, schema: ReplySchema,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> SchemaReply
    func listModels() async throws -> [String]
    /// Loads the model into memory so the first dictation isn't slow.
    func warmUp() async
    /// Frees the model's memory on the server, where the provider allows it.
    func unload() async
    /// Whether the model is in memory right now, and until when.
    func residency() async -> ModelResidency?
    /// How many tokens the model reads at once (its context: the prompt and the reply together), where Binders can tell:
    /// what Distill sizes the parts of a long note by (lane DS2). Nil when it can't.
    func contextTokens() async -> Int?
}

extension LLMClient {
    func unload() async {}
    func residency() async -> ModelResidency? { nil }
    func contextTokens() async -> Int? { nil }

    /// A client that can't hold a reply to a schema: the reply as it comes.
    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval, schema: ReplySchema,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> SchemaReply {
        let text = try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout,
                                    stopWhen: schema.stopWhenNotHeld ?? stopWhen, onText: onText)
        return SchemaReply(text: text, held: false, why: "this kind of model can't be held to a schema")
    }

    /// A client that can't stream: one reply, told once.
    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let text = try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout, stopWhen: stopWhen)
        onText(text)
        return text
    }
}

/// A model client whose replies wait their turn on the one model (ModelLane): what you're waiting for (dictation, Ask,
/// what you said to your iPhone) goes first; write-ups and other background work go one at a time behind it. On Ollama,
/// which answers one request per model at a time, what you're waiting for cuts in on a write-up, which starts again after.
struct LanedClient: LLMClient {
    let inner: LLMClient
    let lane: ModelLane.Priority
    let interrupts: Bool

    var model: String { inner.model }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        let inner = inner
        return try await ModelLane.shared.run(lane, interrupting: lane == .now && interrupts) {
            try await inner.complete(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout)
        }
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        let inner = inner
        return try await ModelLane.shared.run(lane, interrupting: lane == .now && interrupts) {
            try await inner.stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout, stopWhen: stopWhen)
        }
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let inner = inner
        return try await ModelLane.shared.run(lane, interrupting: lane == .now && interrupts) {
            try await inner.stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout,
                                   stopWhen: stopWhen, onText: onText)
        }
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval, schema: ReplySchema,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> SchemaReply {
        let inner = inner
        return try await ModelLane.shared.run(lane, interrupting: lane == .now && interrupts) {
            try await inner.stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout,
                                   schema: schema, stopWhen: stopWhen, onText: onText)
        }
    }

    func listModels() async throws -> [String] { try await inner.listModels() }
    func warmUp() async { await inner.warmUp() }
    func unload() async { await inner.unload() }
    func residency() async -> ModelResidency? { await inner.residency() }
    func contextTokens() async -> Int? { await inner.contextTokens() }
}

/// A JSON schema a reply is held to, where the model's client can hold it (lane DS3; Distill's is `DistillSchema`).
struct ReplySchema: Sendable {
    /// What an OpenAI-compatible server's `json_schema` is named.
    var name: String
    /// With lengths and counts: for MLX and Ollama, whose grammars hold to them.
    var bounded: String
    /// Without them: for an OpenAI-compatible server's strict mode, which may turn them down.
    var portable: String
    /// The answer's own limit in tokens: a reply MLX holds to the schema is brought to a close within it.
    var answerTokens: Int
    /// When to stop a reply that ends up not held to the schema (a client that can't, a server that turned it down), in
    /// place of the `stopWhen` given for a held one; nil for the same.
    var stopWhenNotHeld: (@Sendable (String) -> Bool)?
}

/// A reply asked for with a schema, and whether it was held to it.
struct SchemaReply: Sendable {
    var text: String
    var held: Bool
    /// Why it wasn't, for the log and the bench.
    var why: String?
}

/// Servers that turned a reply's schema down (`format`, `response_format`) once: asked without it from then on, until
/// Binders quits.
enum SchemaRefusals {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var refused: Set<String> = []

    static func refuses(_ server: String) -> Bool { lock.withLock { refused.contains(server) } }
    static func remember(_ server: String) { _ = lock.withLock { refused.insert(server) } }

    /// Whether a server's error turns down the schema it was sent: a 4xx that names it (`format`, `response_format`,
    /// `json_schema`, a schema or grammar it couldn't read), and isn't a prompt too long for its context.
    static func isRefusal(_ code: Int, _ message: String, field: String) -> Bool {
        guard (400..<500).contains(code), !DistillBudget.isTooLong(message) else { return false }
        let lower = message.lowercased()
        return [field, "json_schema", "schema", "grammar"].contains { lower.contains($0) }
    }
}

/// A value put in a request body as JSON text, as it is: a schema's properties keep their order, which a server's grammar
/// writes them in (JSONSerialization would reorder them).
private struct RawJSON {
    let text: String
    let marker = "binders-raw-json-" + UUID().uuidString
}

/// A model loaded on the server: how much memory it holds and when it will be freed.
struct ModelResidency: Sendable {
    var bytes: Int64
    var expiresAt: Date?
}

private func makeRequest(_ url: URL, body: [String: Any], headers: [String: String], timeout: TimeInterval) throws -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    request.httpBody = try serialize(body)
    return request
}

/// The body as JSON, a `RawJSON` anywhere in it put in as its text.
private func serialize(_ body: [String: Any]) throws -> Data {
    var raws: [RawJSON] = []
    func swap(_ value: Any) -> Any {
        if let raw = value as? RawJSON {
            raws.append(raw)
            return raw.marker
        }
        if let object = value as? [String: Any] { return object.mapValues(swap) }
        if let list = value as? [Any] { return list.map(swap) }
        return value
    }
    let swapped = body.mapValues(swap)
    var text = String(decoding: try JSONSerialization.data(withJSONObject: swapped), as: UTF8.self)
    for raw in raws { text = text.replacingOccurrences(of: "\"\(raw.marker)\"", with: raw.text) }
    return Data(text.utf8)
}

private func postJSON(_ url: URL, body: [String: Any], headers: [String: String] = [:], timeout: TimeInterval) async throws -> [String: Any] {
    let request = try makeRequest(url, body: body, headers: headers, timeout: timeout)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.invalidResponse }
    return json
}

private func getJSON(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 5) async throws -> [String: Any] {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "") }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.invalidResponse }
    return json
}

/// Opens a streaming POST; a non-2xx status is read to the end and thrown as `LLMError.http`.
private func openStream(_ url: URL, body: [String: Any], headers: [String: String] = [:], timeout: TimeInterval) async throws -> URLSession.AsyncBytes {
    let request = try makeRequest(url, body: body, headers: headers, timeout: timeout)
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "")
    }
    return bytes
}

/// Gathers streamed text line by line (NDJSON or SSE "data:" lines), telling `onText` the text so far each time it grows.
/// `content` pulls the new text out of one event, `thinking` any reasoning the server sends apart from it, and `isDone`
/// recognizes the last one. A server that answered with one plain reply instead of a stream is read with `whole`, and
/// `onText` is told once. Closing the connection early makes the server stop generating.
private func collect(_ bytes: URLSession.AsyncBytes, model: String, stopWhen: @escaping @Sendable (String) -> Bool,
                     onText: @Sendable (String) -> Void = { _ in },
                     content: ([String: Any]) -> String?, thinking: ([String: Any]) -> String? = { _ in nil },
                     whole: ([String: Any]) -> String? = { _ in nil },
                     isDone: ([String: Any]) -> Bool) async throws -> String {
    var text = ""
    var thought = false
    /// What came, as it came: a reply that wasn't a stream is read whole at the end.
    var body = ""
    defer { bytes.task.cancel() }
    for try await line in bytes.lines {
        if text.isEmpty { body += line + "\n" }
        var payload = line.trimmingCharacters(in: .whitespaces)
        if payload.hasPrefix("data:") { payload = String(payload.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        if payload.isEmpty { continue }
        if payload == "[DONE]" { break }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        if let error = json["error"] { throw LLMError.http(500, "\(error)") }
        if let chunk = content(json), !chunk.isEmpty {
            text += chunk
            onText(text)
            if chunk.contains("\n"), stopWhen(text) {
                Log.llm.warning("Stopped \(model) early: the output was repeating itself")
                break
            }
        }
        if let chunk = thinking(json), !chunk.isEmpty { thought = true }
        if isDone(json) { break }
    }
    if text.trimmed.isEmpty, let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] {
        if let error = json["error"] { throw LLMError.http(500, "\(error)") }
        if let reply = whole(json), !reply.trimmed.isEmpty {
            Log.llm.notice("\(model, privacy: .public) answered in one piece rather than streaming")
            text = reply
            onText(text)
        }
    }
    guard !text.trimmed.isEmpty else { throw thought ? LLMError.onlyThinking : LLMError.emptyResponse }
    return text
}

struct OllamaClient: LLMClient {
    let baseURL: URL
    let model: String
    /// How long Ollama keeps the model in memory after a request, in seconds; -1 keeps it loaded.
    var keepAliveSeconds: Int = 900

    private var keepAlive: Int { keepAliveSeconds < 0 ? -1 : keepAliveSeconds }

    private var chatURL: URL { baseURL.appendingPathComponent("api/chat") }

    private func chatBody(system: String, user: String, maxTokens: Int, temperature: Double, stream: Bool) -> [String: Any] {
        [
            "model": model,
            "stream": stream,
            "think": false,
            "keep_alive": keepAlive,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "options": ["temperature": temperature, "num_predict": maxTokens],
        ]
    }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        var body = chatBody(system: system, user: user, maxTokens: maxTokens, temperature: temperature, stream: false)
        let json: [String: Any]
        do {
            json = try await postJSON(chatURL, body: body, timeout: timeout)
        } catch LLMError.http(400, let message) where message.localizedCaseInsensitiveContains("think") {
            body.removeValue(forKey: "think")
            json = try await postJSON(chatURL, body: body, timeout: timeout)
        }
        guard let message = json["message"] as? [String: Any], let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }
        guard !content.trimmed.isEmpty else { throw LLMError.emptyResponse }
        return content
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout,
                         stopWhen: stopWhen, onText: { _ in })
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        var body = chatBody(system: system, user: user, maxTokens: maxTokens, temperature: temperature, stream: true)
        let bytes: URLSession.AsyncBytes
        do {
            bytes = try await openStream(chatURL, body: body, timeout: timeout)
        } catch LLMError.http(400, let message) where message.localizedCaseInsensitiveContains("think") {
            body.removeValue(forKey: "think")
            bytes = try await openStream(chatURL, body: body, timeout: timeout)
        }
        let message: ([String: Any]) -> String? = { ($0["message"] as? [String: Any])?["content"] as? String }
        return try await collect(bytes, model: model, stopWhen: stopWhen, onText: onText, content: message, whole: message,
                                 isDone: { $0["done"] as? Bool == true })
    }

    /// The schema goes as `format` (Ollama 0.5 and later hold the reply to it); an Ollama that turns it down is asked
    /// without it, then and from then on.
    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval, schema: ReplySchema,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> SchemaReply {
        let server = baseURL.absoluteString
        guard !SchemaRefusals.refuses(server) else {
            let text = try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout,
                                        stopWhen: schema.stopWhenNotHeld ?? stopWhen, onText: onText)
            return SchemaReply(text: text, held: false, why: "this Ollama turned the schema down before")
        }
        var body = chatBody(system: system, user: user, maxTokens: maxTokens, temperature: temperature, stream: true)
        body["format"] = RawJSON(text: schema.bounded)
        var why: String?
        var bytes: URLSession.AsyncBytes?
        for _ in 0..<3 where bytes == nil {
            do {
                bytes = try await openStream(chatURL, body: body, timeout: timeout)
            } catch LLMError.http(400, let message) where body["think"] != nil && message.localizedCaseInsensitiveContains("think") {
                body.removeValue(forKey: "think")
            } catch LLMError.http(let code, let message) where body["format"] != nil && SchemaRefusals.isRefusal(code, message, field: "format") {
                Log.llm.notice("\(model, privacy: .public) on Ollama turned the reply's schema down; asking without it: \(message.prefix(200), privacy: .public)")
                SchemaRefusals.remember(server)
                body.removeValue(forKey: "format")
                why = "Ollama turned the schema down: \(message.prefix(120))"
            }
        }
        guard let bytes else { throw LLMError.invalidResponse }
        let message: ([String: Any]) -> String? = { ($0["message"] as? [String: Any])?["content"] as? String }
        let held = body["format"] != nil
        let text = try await collect(bytes, model: model, stopWhen: held ? stopWhen : schema.stopWhenNotHeld ?? stopWhen, onText: onText,
                                     content: message, whole: message, isDone: { $0["done"] as? Bool == true })
        return SchemaReply(text: text, held: held, why: why)
    }

    func listModels() async throws -> [String] {
        let json = try await getJSON(baseURL.appendingPathComponent("api/tags"))
        let models = json["models"] as? [[String: Any]] ?? []
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    func warmUp() async {
        let body: [String: Any] = ["model": model, "messages": [] as [Any], "keep_alive": keepAlive]
        _ = try? await postJSON(chatURL, body: body, timeout: 120)
    }

    /// An empty request with keep_alive 0 makes Ollama drop the model at once.
    func unload() async {
        let body: [String: Any] = ["model": model, "messages": [] as [Any], "keep_alive": 0]
        _ = try? await postJSON(chatURL, body: body, timeout: 5)
    }

    func residency() async -> ModelResidency? {
        guard let json = try? await getJSON(baseURL.appendingPathComponent("api/ps")),
              let models = json["models"] as? [[String: Any]] else { return nil }
        let wanted = model.contains(":") ? model : model + ":latest"
        guard let entry = models.first(where: { ($0["name"] as? String) == wanted || ($0["model"] as? String) == wanted || ($0["name"] as? String) == model }) else { return nil }
        let bytes = (entry["size_vram"] as? Int64) ?? (entry["size"] as? Int64) ?? Int64((entry["size"] as? Int) ?? 0)
        var expires: Date?
        if let raw = entry["expires_at"] as? String {
            let trimmed = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            expires = formatter.date(from: trimmed)
            // Ollama reports a far-future date for models kept loaded.
            if let date = expires, date.timeIntervalSinceNow > 10 * 365 * 86_400 { expires = nil }
        }
        return ModelResidency(bytes: bytes, expiresAt: expires)
    }

    /// Ollama's default context when nothing sets it (`OLLAMA_CONTEXT_LENGTH`, the Ollama app's context setting, a
    /// model's own `num_ctx`). Binders sends no `num_ctx`, so a longer prompt is cut from the front, instructions first.
    static let defaultContext = 4_096

    /// The context the loaded model reads with, as Ollama reports it (`context_length` in /api/ps, from Ollama 0.12); the
    /// model is loaded first when it isn't. Ollama's default when it doesn't say.
    func contextTokens() async -> Int? {
        func loaded() async -> Int? {
            guard let json = try? await getJSON(baseURL.appendingPathComponent("api/ps")),
                  let models = json["models"] as? [[String: Any]] else { return nil }
            let wanted = model.contains(":") ? model : model + ":latest"
            let entry = models.first { ($0["name"] as? String) == wanted || ($0["model"] as? String) == wanted || ($0["name"] as? String) == model }
            return (entry?["context_length"] as? NSNumber)?.intValue
        }
        if let tokens = await loaded(), tokens > 0 { return tokens }
        await warmUp()
        if let tokens = await loaded(), tokens > 0 { return tokens }
        return Self.defaultContext
    }
}

struct OpenAICompatibleClient: LLMClient {
    let baseURL: URL
    let model: String
    let apiKey: String?

    private var headers: [String: String] {
        apiKey.map { ["Authorization": "Bearer \($0)"] } ?? [:]
    }

    private var chatURL: URL { baseURL.appendingPathComponent("chat/completions") }

    /// Thinking off, as llama.cpp, vLLM and SGLang take it: a thinking model would otherwise spend the reply's token
    /// budget on reasoning, which these servers send apart from the answer.
    private static let noThinking = "chat_template_kwargs"

    private func chatBody(system: String, user: String, maxTokens: Int, temperature: Double, stream: Bool) -> [String: Any] {
        [
            "model": model,
            "stream": stream,
            "temperature": temperature,
            "max_tokens": maxTokens,
            Self.noThinking: ["enable_thinking": false],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
    }

    /// Whether the server turned down the thinking switch, as OpenAI's own API does with any field it doesn't know.
    private static func rejectsNoThinking(_ code: Int, _ message: String) -> Bool {
        (400..<500).contains(code) && message.contains(noThinking)
    }

    /// The reasoning a server sent apart from the answer, under either of the names servers use for it.
    private static func reasoning(_ message: [String: Any]?) -> String? {
        (message?["reasoning_content"] as? String) ?? (message?["reasoning"] as? String)
    }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        var body = chatBody(system: system, user: user, maxTokens: maxTokens, temperature: temperature, stream: false)
        let json: [String: Any]
        do {
            json = try await postJSON(chatURL, body: body, headers: headers, timeout: timeout)
        } catch LLMError.http(let code, let message) where Self.rejectsNoThinking(code, message) {
            body.removeValue(forKey: Self.noThinking)
            json = try await postJSON(chatURL, body: body, headers: headers, timeout: timeout)
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { throw LLMError.invalidResponse }
        let content = message["content"] as? String ?? ""
        guard !content.trimmed.isEmpty else {
            throw Self.reasoning(message)?.isEmpty == false ? LLMError.onlyThinking : LLMError.emptyResponse
        }
        return content
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout,
                         stopWhen: stopWhen, onText: { _ in })
    }

    /// Whether the server turned streaming down: it then answers in one reply.
    private static func rejectsStreaming(_ code: Int, _ message: String) -> Bool {
        (400..<500).contains(code) && message.localizedCaseInsensitiveContains("stream") && !message.contains(noThinking)
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        var body = chatBody(system: system, user: user, maxTokens: maxTokens, temperature: temperature, stream: true)
        let bytes: URLSession.AsyncBytes
        do {
            do {
                bytes = try await openStream(chatURL, body: body, headers: headers, timeout: timeout)
            } catch LLMError.http(let code, let message) where Self.rejectsNoThinking(code, message) {
                body.removeValue(forKey: Self.noThinking)
                bytes = try await openStream(chatURL, body: body, headers: headers, timeout: timeout)
            }
        } catch LLMError.http(let code, let message) where Self.rejectsStreaming(code, message) {
            let text = try await complete(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout)
            onText(text)
            return text
        }
        func delta(_ json: [String: Any]) -> [String: Any]? {
            (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
        }
        return try await collect(bytes, model: model, stopWhen: stopWhen, onText: onText,
                                 content: { delta($0)?["content"] as? String },
                                 thinking: { Self.reasoning(delta($0)) },
                                 whole: { ((($0["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any])?["content"] as? String },
                                 isDone: { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] is String })
    }

    private static let format = "response_format"

    /// The schema goes as `response_format` (`json_schema`, strict), as llama.cpp, LM Studio, vLLM and OpenAI's own API
    /// take it, in its portable form; a server that turns it down is asked without it, then and from then on.
    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval, schema: ReplySchema,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> SchemaReply {
        let server = baseURL.absoluteString
        guard !SchemaRefusals.refuses(server) else {
            let text = try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout,
                                        stopWhen: schema.stopWhenNotHeld ?? stopWhen, onText: onText)
            return SchemaReply(text: text, held: false, why: "this server turned the schema down before")
        }
        var body = chatBody(system: system, user: user, maxTokens: maxTokens, temperature: temperature, stream: true)
        body[Self.format] = ["type": "json_schema",
                             "json_schema": ["name": schema.name, "strict": true, "schema": RawJSON(text: schema.portable)] as [String: Any]]
            as [String: Any]
        var why: String?
        var bytes: URLSession.AsyncBytes?
        var oneReply = false
        for _ in 0..<3 where bytes == nil && !oneReply {
            do {
                bytes = try await openStream(chatURL, body: body, headers: headers, timeout: timeout)
            } catch LLMError.http(let code, let message) where body[Self.noThinking] != nil && Self.rejectsNoThinking(code, message) {
                body.removeValue(forKey: Self.noThinking)
            } catch LLMError.http(let code, let message) where body[Self.format] != nil && SchemaRefusals.isRefusal(code, message, field: Self.format) {
                Log.llm.notice("\(model, privacy: .public) turned the reply's schema down; asking without it: \(message.prefix(200), privacy: .public)")
                SchemaRefusals.remember(server)
                body.removeValue(forKey: Self.format)
                why = "the server turned the schema down: \(message.prefix(120))"
            } catch LLMError.http(let code, let message) where Self.rejectsStreaming(code, message) {
                oneReply = true
            }
        }
        guard let bytes else {
            guard oneReply else { throw LLMError.invalidResponse }
            // A server that doesn't stream: one reply, without the schema (the plain question, as `stream` asks it).
            let text = try await complete(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout)
            onText(text)
            return SchemaReply(text: text, held: false, why: "the server answers in one piece, asked without the schema")
        }
        func delta(_ json: [String: Any]) -> [String: Any]? {
            (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
        }
        let held = body[Self.format] != nil
        let text = try await collect(bytes, model: model, stopWhen: held ? stopWhen : schema.stopWhenNotHeld ?? stopWhen, onText: onText,
                                     content: { delta($0)?["content"] as? String },
                                     thinking: { Self.reasoning(delta($0)) },
                                     whole: { ((($0["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any])?["content"] as? String },
                                     isDone: { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] is String })
        return SchemaReply(text: text, held: held, why: why)
    }

    func listModels() async throws -> [String] {
        let json = try await getJSON(baseURL.appendingPathComponent("models"), headers: headers)
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap { $0["id"] as? String }.sorted()
    }

    func warmUp() async {}

    /// The context the server reads with: llama.cpp's /props (`n_ctx`, per slot), else the model's entry in /models
    /// (vLLM's `max_model_len`, or `context_length`, `loaded_context_length`, `max_context_length`). Nil for a server that
    /// says neither, as hosted APIs don't.
    func contextTokens() async -> Int? {
        func number(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        let root = baseURL.lastPathComponent == "v1" ? baseURL.deletingLastPathComponent() : baseURL
        if let props = try? await getJSON(root.appendingPathComponent("props"), headers: headers) {
            let settings = props["default_generation_settings"] as? [String: Any]
            if let tokens = number(settings?["n_ctx"]) ?? number(props["n_ctx"]), tokens > 0 { return tokens }
        }
        guard let list = try? await getJSON(baseURL.appendingPathComponent("models"), headers: headers),
              let data = list["data"] as? [[String: Any]] else { return nil }
        guard let entry = data.first(where: { $0["id"] as? String == model }) ?? (data.count == 1 ? data.first : nil) else { return nil }
        for key in ["loaded_context_length", "max_model_len", "context_length", "max_context_length", "context_window"] {
            if let tokens = number(entry[key]), tokens > 0 { return tokens }
        }
        return nil
    }
}
