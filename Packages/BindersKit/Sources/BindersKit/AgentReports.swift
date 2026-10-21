import Foundation

// How agents report back, the parts that can be worked out and tested away from the app: the MCP entry an agent adds to
// its own settings (on this Mac, or on another machine through ssh), what a status address answers, and what a Claude
// Code run's hooks put on its card.

/// The MCP entry an agent that reports with Binders' tools adds to its own MCP settings: Binders' server with the board's
/// tools alone (BINDERS_TOOLS=board), as that agent (BINDERS_AGENT), so it works on cards and never reads your binders.
public enum AgentMCPEntry {
    /// On this Mac. `binders` is the Binders program, the running build.
    public static func local(binders: String, agent: String) -> [String: Any] {
        ["command": binders, "args": ["--mcp"], "env": ["BINDERS_AGENT": agent, "BINDERS_TOOLS": "board"]]
    }

    /// On another machine: ssh to this Mac at `host`, which runs the same server with the same environment here. -T because
    /// MCP talks over plain standard input and output, and BatchMode because no one is there to type a password: it signs
    /// in with a key.
    public static func ssh(binders: String, agent: String, host: String) -> [String: Any] {
        ["command": "ssh", "args": ["-T", "-o", "BatchMode=yes", host.trimmingCharacters(in: .whitespaces), remoteCommand(binders: binders, agent: agent)]]
    }

    /// What ssh runs on this Mac, through the login shell here: the two variables, then Binders' server, each quoted.
    public static func remoteCommand(binders: String, agent: String) -> String {
        "env BINDERS_AGENT=\(quoted(agent)) BINDERS_TOOLS=board \(quoted(binders)) --mcp"
    }

    /// Whether `host` can go to ssh as the machine to reach: a name or an address, with a user and an @ before it if you
    /// like. Never one that starts like an option, or holds a space, a quote or anything a shell would read.
    public static func isHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, host.count <= 255, !host.hasPrefix("-"), !host.hasPrefix("@"), !host.hasSuffix("@"),
              host.filter({ $0 == "@" }).count <= 1 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-@:[]%"))
        return host.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// `text` in single quotes for zsh, bash or sh, with a quote inside it written as '\''.
    public static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An entry as JSON with sorted keys, for showing and copying.
    public static func json(_ entry: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What an agent's status address answers when Binders asks about a card: JSON with "state", a `TaskState` name, and
/// "note", the words for the card: what it did, its question, its summary, or why it failed.
public struct AgentStatusReply: Equatable, Sendable {
    public var state: TaskState
    public var note: String

    /// The most of a note that goes on a card, in characters.
    public static let noteLimit = 4_000

    public init(state: TaskState, note: String = "") {
        self.state = state
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note.count <= Self.noteLimit ? note : String(note.prefix(Self.noteLimit - 1)) + "…"
    }

    /// Reads a reply: {"state": "working", "note": "…"}. A2A's shape, {"status": {"state": "working"}}, and "message" for
    /// the note read too, and other keys are left alone. Nil when it isn't JSON with a state Binders knows.
    public init?(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data.prefix(256 * 1024))) as? [String: Any] else { return nil }
        let status = object["status"] as? [String: Any]
        guard let word = (object["state"] as? String) ?? (status?["state"] as? String), let state = TaskState(loose: word) else { return nil }
        self.init(state: state, note: (object["note"] as? String) ?? (object["message"] as? String) ?? (status?["message"] as? String) ?? "")
    }

    /// Asking about a card: a GET of `address` with the card's id added to its query as `card`, for JSON, with the token
    /// as Authorization: Bearer when there is one. Nil for an address that isn't http or https.
    public static func request(_ address: String, card: UUID, token: String?, timeout: TimeInterval = 20) -> URLRequest? {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme), components.host?.isEmpty == false else { return nil }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "card" } + [URLQueryItem(name: "card", value: card.uuidString)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Whether `address` is one Binders can ask: http or https, with a host.
    public static func isAddress(_ address: String) -> Bool {
        request(address, card: UUID(), token: nil) != nil
    }
}

/// What a Claude Code run Binders started says on its card when Claude stops and when its session ends (`Binders
/// --agent-hook`): what it said last, or that its session ended. The app keeps it to one report a run.
public enum AgentRunReport {
    /// The hooks, as `--agent-hook` names them.
    public enum Hook: String, CaseIterable, Sendable {
        case stop
        case sessionEnd = "session-end"
    }

    /// About this many characters of what it said last go on the card.
    public static let limit = 600

    /// The report for a hook, from the JSON Claude Code hands it on standard input: the run's session id ("" when there's
    /// none) and the words for the card. Stop takes the last assistant message, from the JSON when Claude Code includes it
    /// (last_assistant_message) and otherwise from the transcript at transcript_path, which `transcript` reads; nil when
    /// there's nothing to say. SessionEnd says "Session ended (<reason>)". Nil for input that isn't a hook's JSON.
    public static func make(_ hook: Hook, input: Data, transcript: (String) -> Data?) -> (session: String, text: String)? {
        guard let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return nil }
        let session = (object["session_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch hook {
        case .stop:
            var said = (object["last_assistant_message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if said.isEmpty, let path = object["transcript_path"] as? String, !path.isEmpty, let data = transcript(path) {
                said = lastAssistantText(in: data) ?? ""
            }
            return said.isEmpty ? nil : (session, trimmed(said))
        case .sessionEnd:
            let reason = (object["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (session, "Session ended (\(reason.isEmpty ? "other" : String(reason.prefix(40))))")
        }
    }

    /// The words of the last assistant message in a Claude Code transcript (one JSON object a line), its text blocks
    /// joined, or nil when there's none. A line that isn't whole, such as the first of a file read from the middle, is
    /// passed over, and so are subagents' lines (isSidechain) and blocks that aren't text (thinking, tool calls).
    public static func lastAssistantText(in transcript: Data) -> String? {
        var last: (id: String?, texts: [String])?
        for line in transcript.split(separator: 0x0A) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  entry["type"] as? String == "assistant", entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { continue }
            let blocks: [String]
            if let plain = message["content"] as? String {
                blocks = [plain]
            } else {
                blocks = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            }
            let texts = blocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !texts.isEmpty else { continue }
            // One message can be written over several lines, a block each.
            let id = message["id"] as? String
            if let current = last, id != nil, current.id == id {
                last?.texts += texts
            } else {
                last = (id, texts)
            }
        }
        return last.map { $0.texts.joined(separator: "\n\n") }
    }

    /// `text` cut to about `limit` characters, at the end of a word when one is close, with "…" when it was cut.
    public static func trimmed(_ text: String, limit: Int = limit) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        if let space = head.lastIndex(where: \.isWhitespace), head.distance(from: space, to: head.endIndex) <= max(12, limit / 5) {
            return head[..<space].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return String(head) + "…"
    }
}
