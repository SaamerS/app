import Foundation

/// How far an answer being written has got: the passages found by their words (at once, before the slower search by
/// meaning), then the passages the answer draws on, then the answer as it's written.
public enum AskStage: String, Sendable, CaseIterable {
    case keywordHits = "keyword"
    case sources
    case writing

    /// What Ask is doing while there's no answer to show yet, with `found` passages so far; nil `stage` is before anything
    /// is found. Nil once the answer is being written.
    public static func waiting(_ stage: AskStage?, found: Int) -> String? {
        let passages = found == 1 ? "1 passage" : "\(found) passages"
        switch stage {
        case nil: return "Searching your meetings, notes and dictations…"
        case .keywordHits?: return found == 0 ? "Nothing matches those words. Searching by meaning…" : "Found \(passages) with those words. Searching by meaning…"
        case .sources?: return "Writing the answer from \(passages)…"
        case .writing?: return nil
        }
    }

    /// What the iPhone says while its Mac answers, before any of the answer shows: until the Mac first says how it's going
    /// (`stage` nil), a line that's true whether or not it ever will, as Binders 0.8.0 lists `LinkFeatures.askProgress`
    /// and sends no updates; then what `waiting` says.
    public static func waitingForMac(_ stage: AskStage?, found: Int) -> String? {
        guard let stage else { return "Your Mac is looking this up and writing the answer…" }
        return waiting(stage, found: found)
    }
}

/// Ask over the phone link, as it goes: `LinkFeatures.askProgressMethod`, from a Mac that lists `LinkFeatures.askProgress`.
///
/// A phone that reads it adds a token to ask_knowledge's arguments (`tokenKey`). The Mac then sends that phone, and no
/// other, `binders/ask-progress` notifications for it before the usual reply: the stage, the sources whenever they change
/// (in ask_knowledge's reply shape), and the answer so far. Each update is numbered and says all of what it says (every
/// source, the whole text so far), so one handled late can't take anything back. The reply is the answer, as before; a
/// Mac that doesn't stream ignores the token and sends only that.
public enum LinkAskProgress {
    /// In ask_knowledge's arguments: the token the phone's updates come with. MCP hosts never send it.
    public static let tokenKey = "progress_token"

    /// The token in a tool call's arguments, if any.
    public static func token(in arguments: [String: Any]) -> String? {
        if let text = arguments[tokenKey] as? String, !text.isEmpty, text.count <= 100 { return text }
        return nil
    }

    /// One notification's params. `sources` with the stages that change them, `text` with the writing stage.
    public static func params(token: String, seq: Int, stage: AskStage, sources: [[String: Any]]? = nil, text: String? = nil) -> [String: Any] {
        var params: [String: Any] = ["token": token, "seq": seq, "stage": stage.rawValue]
        if let sources { params["sources"] = sources }
        if let text { params["text"] = text }
        return params
    }

    /// One notification, read leniently: a stage this build doesn't know is left out, and so is any key it doesn't read.
    public struct Update: Sendable {
        public let token: String
        public let seq: Int
        public let stage: AskStage?
        /// The sources, as JSON in ask_knowledge's reply shape, when this update changes them.
        public let sources: Data?
        /// The answer so far, with the writing stage.
        public let text: String?

        /// Nil when it isn't one: no token or no number.
        public init?(params: [String: Any]) {
            guard let token = params["token"] as? String, !token.isEmpty,
                  let seq = (params["seq"] as? Int) ?? (params["seq"] as? Double).map(Int.init) else { return nil }
            self.token = token
            self.seq = seq
            stage = (params["stage"] as? String).flatMap(AskStage.init(rawValue:))
            sources = (params["sources"] as? [Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            text = params["text"] as? String
        }
    }

    /// What's shown of an answer being written, from its updates in whatever order they're handled: the stage, the
    /// sources and the text each come from the newest update that carried them.
    public struct Shown<Source: Sendable>: Sendable {
        public private(set) var stage: AskStage?
        public private(set) var sources: [Source] = []
        public private(set) var text = ""
        private var stageSeq = Int.min, sourcesSeq = Int.min, textSeq = Int.min

        public init() {}

        /// True when it changed what's shown.
        @discardableResult
        public mutating func apply(seq: Int, stage: AskStage?, sources: [Source]?, text: String?) -> Bool {
            var changed = false
            if let stage, seq > stageSeq {
                stageSeq = seq
                changed = changed || self.stage != stage
                self.stage = stage
            }
            if let sources, seq > sourcesSeq {
                sourcesSeq = seq
                self.sources = sources
                changed = true
            }
            if let text, seq > textSeq {
                textSeq = seq
                changed = changed || self.text != text
                self.text = text
            }
            return changed
        }
    }
}

extension OutputGuard {
    /// Reasoning blocks as models mark them: opening and closing tags.
    private static let reasoningTags = [("<think>", "</think>"), ("<|channel>thought", "<channel|>")]

    /// What to show of a reply still being written, cleaned up as `sanitize` cleans the finished one: reasoning that's
    /// still open, and the start of a tag that may be one, stay hidden until they're closed or turn out to be text.
    public static func streaming(_ partial: String) -> String {
        var text = partial
        for (open, close) in reasoningTags {
            guard let start = text.range(of: open, options: .backwards) else { continue }
            if text.range(of: close, range: start.upperBound..<text.endIndex) == nil { text = String(text[..<start.lowerBound]) }
        }
        // "<thi" at the very end may be the start of a reasoning block: wait for the next piece.
        if let last = text.lastIndex(of: "<") {
            let tail = text[last...]
            if ["<think>", "</think>", "<|channel>thought", "<channel|>"].contains(where: { $0.hasPrefix(tail) && $0 != tail }) {
                text = String(text[..<last])
            }
        }
        return sanitize(text)
    }

    /// The same, for a model whose replies start inside its reasoning (`opensInReasoning`): nothing shows until the
    /// reasoning closes, as there's no opening tag to tell it from the answer.
    public static func streaming(_ partial: String, opensInReasoning: Bool) -> String {
        guard opensInReasoning, !reasoningTags.contains(where: { partial.contains($0.1) }) else { return streaming(partial) }
        return ""
    }

    /// Whether a reply, or as much of it as has come, started inside reasoning because the chat template opened it: it
    /// closes reasoning it never opened ("Okay, the user asks…</think>The launch is on Thursday."). `sanitize` drops what
    /// comes before the close.
    public static func opensInReasoning(_ partial: String) -> Bool {
        reasoningTags.contains { open, close in
            guard let end = partial.range(of: close) else { return false }
            return partial.range(of: open, range: partial.startIndex..<end.lowerBound) == nil
        }
    }
}
