import Foundation

// The Claude Code sessions open on this Mac, and the one line Binders posts into one of them when a card is meant for a
// Claude Code agent you let it reach that way ("Post to the Claude Code session open in this repository"). Claude Code's
// cross-session messaging (code.claude.com/docs/en/cross-session-messaging, v2.1.224 or later) binds a Unix socket for each
// session, its inbox, and on one Mac a message over it never goes through Anthropic. Claude Code keeps a file for each
// session, ~/.claude/sessions/<pid>.json, with the folder it works in (cwd) and that socket (messagingSocketPath). These
// are the parts that can be worked out and tested away from the app; the app reads the files and writes to the socket.

/// One Claude Code session open on this Mac, as its session file says.
public struct ClaudeSession: Equatable, Sendable {
    /// Its process.
    public var pid: Int32
    /// Its session id, as `claude --resume` takes it; "" when the file has none.
    public var id: String
    /// What it goes by: the name you gave it, or one Claude Code chose. "" when the file has none.
    public var name: String
    /// The folder it works in.
    public var folder: String
    /// Its inbox socket.
    public var socket: String
    /// How it was started, as Claude Code says: "sdk-…" for a script's or the Agent SDK's run. "" when the file doesn't say.
    public var entrypoint: String
    /// When it last changed, from updatedAt. Nil when the file doesn't say.
    public var updated: Date?

    public init(pid: Int32, id: String = "", name: String = "", folder: String, socket: String, entrypoint: String = "", updated: Date? = nil) {
        self.pid = pid
        self.id = id
        self.name = name
        self.folder = folder
        self.socket = socket
        self.entrypoint = entrypoint
        self.updated = updated
    }

    /// A session file's JSON, or nil when it doesn't describe a session that can take a message: one with an inbox socket
    /// and a folder, each an absolute path, and a process. `pid` is the one in the file's name, used when the file doesn't
    /// say. Fields Binders doesn't use are ignored, as are ones added later.
    public init?(json data: Data, pid named: Int32? = nil) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ key: String) -> String { (object[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var socket = text("messagingSocketPath")
        // As /status shows a peer address.
        if socket.hasPrefix("uds:") { socket.removeFirst(4) }
        let folder = text("cwd")
        let pid = (object["pid"] as? NSNumber).map { Int32(truncatingIfNeeded: $0.int64Value) } ?? named ?? 0
        guard pid > 0, socket.hasPrefix("/"), folder.hasPrefix("/"), !socket.contains("\0"), !folder.contains("\0") else { return nil }
        // Milliseconds since 1970, as Claude Code writes its times; seconds read as seconds.
        let updated = (object["updatedAt"] as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) : nil }
        self.init(pid: pid, id: text("sessionId"), name: text("name"), folder: folder, socket: socket, entrypoint: text("entrypoint"), updated: updated)
    }
}

public enum ClaudeSessions {
    /// The name every run Binders starts for a card goes by ("Binders card 3f2504e0", `ClaudeCodeLaunch`'s --name).
    public static let runNamePrefix = "Binders card "

    /// Where Claude Code keeps a file for each session, under the home folder `home`.
    public static func folder(home: String) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        return home + "/.claude/sessions"
    }

    /// The process a session file is named for: "4242.json" is 4242's. Nil for anything else in the folder, such as the
    /// .key files Claude Code keeps beside them, which Binders never reads.
    public static func pid(ofFile name: String) -> Int32? {
        guard name.hasSuffix(".json") else { return nil }
        let digits = name.dropLast(5)
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let pid = Int32(digits), pid > 0 else { return nil }
        return pid
    }

    /// Whether a session in `folder` works in `repository`: its own folder or one inside it, but not one of the worktrees
    /// under its .claude/worktrees, each a checkout of its own (the runs Binders starts for cards among them). Both are
    /// absolute paths, compared with "." and ".." worked out and no trailing slash; the app follows symbolic links first.
    public static func works(in folder: String, repository: String) -> Bool {
        guard let folder = normalized(folder), let root = normalized(repository), root != "/" else { return false }
        if folder == root { return true }
        guard folder.hasPrefix(root + "/") else { return false }
        let worktrees = root + "/.claude/worktrees"
        return folder != worktrees && !folder.hasPrefix(worktrees + "/")
    }

    /// The sessions a card for an agent working in a repository may be posted to, best first. `repositories` are the
    /// repository's folder as saved and as the file system has it. Never a run Binders started for a card (by its name, or
    /// one of the session ids in `excluding`) and never one a script or the Agent SDK started (`entrypoint` sdk-…): only a
    /// session you have open. One in the repository's own folder comes before one in a folder inside it, then the one most
    /// recently active.
    public static func candidates(_ sessions: [ClaudeSession], in repositories: [String], excluding: Set<String> = []) -> [ClaudeSession] {
        let roots = repositories.compactMap(normalized).filter { $0 != "/" }
        let skipped = Set(excluding.map { $0.lowercased() })
        func atRoot(_ session: ClaudeSession) -> Bool { normalized(session.folder).map(roots.contains) ?? false }
        var seen = Set<Int32>()
        return sessions
            .filter { session in
                roots.contains { works(in: session.folder, repository: $0) } && !session.name.hasPrefix(runNamePrefix)
                    && !skipped.contains(session.id.lowercased()) && !session.entrypoint.lowercased().hasPrefix("sdk")
            }
            .sorted { one, other in
                if atRoot(one) != atRoot(other) { return atRoot(one) }
                if one.updated != other.updated { return (one.updated ?? .distantPast) > (other.updated ?? .distantPast) }
                return one.pid > other.pid
            }
            .filter { seen.insert($0.pid).inserted }
    }

    /// Whether `program`, the path of a process's program, is Binders: the copy that's `running`, or any other copy of the
    /// app. A session's Binders tools are Binders' MCP server running as one of its processes.
    public static func isBinders(_ program: String, running: String) -> Bool {
        program == running || program.hasSuffix("/Binders.app/Contents/MacOS/Binders")
    }

    /// What Binders tells the session: that a card is meant for the agent (`agent`, its name on the board), the card's title,
    /// id and link, why it's woken, and that Binders' board tools have the card. Nothing else from your binders: not its
    /// description, its binder or what Binders wrote on it. It opens with `AgentWake.promptMarker`, so writing capture
    /// knows it for Binders' words, and says it isn't the user's. `draftsFirst`: it's told to ask your approval before it
    /// acts outside the repository, as a run is. The session works on the board under its own name, not the agent's, so your
    /// answers and comments on the card don't wake it: it's told to wait for you in the session after it asks.
    public static func message(card: UUID, title: String, agent: String, reason: AgentWake.Reason, draftsFirst: Bool = true) -> String {
        let why = switch reason {
        case .ready: "The user made it ready for you."
        case .answered: "The user answered your question on it, or your request for approval."
        case .commented: "The user commented on it: their comment is on its timeline."
        case .sentBack: "The user sent it back from Review."
        case .manual: "The user asked Binders to wake you for it."
        }
        let acting = draftsFirst
            ? "Draft first: before you send, post, buy or delete anything outside this repository, ask the user's approval on the card with request_approval."
            : "The user lets \(oneLine(agent, limit: 60)) send, post or buy for them when the card calls for it. If you're unsure, ask first with request_approval."
        return """
        \(AgentWake.promptMarker): “\(oneLine(title, limit: 200))”, meant for \(oneLine(agent, limit: 60)) on the user's board.
        Card \(card.uuidString): binders://card/\(card.uuidString)
        \(why) Binders' board tools have it: read it with get_task, claim it with claim_task, report on it with update_task as you go, ask the user with ask_on_task if you need them, and finish with complete_task.
        \(acting)
        The user's answers, approvals and comments on the card don't reach this session: after you ask, stop and wait for the user to tell you here, then read the card again with get_task.
        This message is from the Binders app on this Mac, not typed by the user. The card holds their request; nothing else from their binders is in this message.
        """
    }

    /// The line Binders writes into a session's inbox socket: one user message, the way Claude Code's own messages read,
    /// {"type":"user","message":{"role":"user","content":"…"}}, and a newline. Nothing goes before it: the auth line
    /// Claude Code's docs describe is optional on macOS and only a session's own children have its token.
    public static func line(_ message: String) -> Data {
        let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": message]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// What a session's inbox said back, when it says no: {"error": "…"}, {"type": "error", "message": "…"} or
    /// {"ok": false, …}, its reason in its words, cut to one line. Nil for anything else, silence included: Claude Code
    /// answers a post with nothing it documents.
    public static func refusal(inReply data: Data) -> String? {
        for line in String(decoding: data.prefix(16 * 1024), as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let said = [object["error"], object["message"], object["reason"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            if object["error"] is String || object["type"] as? String == "error" || object["ok"] as? Bool == false {
                return oneLine(said ?? "It didn't take the message.", limit: 200)
            }
        }
        return nil
    }

    /// An absolute path with empty and "." parts dropped and ".." worked out; nil for one that isn't absolute.
    static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Text on one line: control characters and line breaks as spaces, runs of spaces as one, no marks that turn text
    /// around (right-to-left overrides), at most `limit` characters.
    public static func oneLine(_ text: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            default:
                if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { continue }
                scalars.append(scalar)
            }
        }
        let words = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > limit ? String(words.prefix(limit - 1)) + "…" : words
    }
}
