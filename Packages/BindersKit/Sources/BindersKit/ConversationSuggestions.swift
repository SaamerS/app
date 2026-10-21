import CryptoKit
import Foundation

/// Something Binders offers once a conversation is written up: a card for what you said you'd do, a card for an idea in
/// it, or an answer, from your binders, to a question you asked. Shown on the conversation and sent as a notification to
/// the device that heard it. A card or an idea can also be given to an agent, with Give to.
public struct ConversationSuggestion: Codable, Equatable, Identifiable, Sendable {
    /// A phone reads only the kinds it lists (`LinkFeatures.suggestion`): iPhone 2.0 knows card and answer alone.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Put a to-do from the conversation on its binder's board.
        case card
        /// A question you asked, answered from your notes, meetings and conversations.
        case answer
        /// An idea from the conversation's notes, for its binder's Backlog.
        case idea
    }

    public enum Status: String, Codable, Sendable {
        case offered, accepted, dismissed
    }

    /// Stable, so offering the same thing twice is recognised.
    public var id: String
    public var conversation: UUID
    public var kind: Kind
    /// For a card, the to-do; for an answer, the question.
    public var text: String
    /// The binder the card would go on, or the conversation is in.
    public var binder: String
    public var answer: String?
    /// The titles of what the answer came from.
    public var sources: [String]
    /// For a card, the to-do's id as list_todos gives it, which links the card to it.
    public var todo: String?
    public var status: Status

    public init(conversation: UUID, kind: Kind, text: String, binder: String, answer: String? = nil, sources: [String] = [],
                todo: String? = nil, status: Status = .offered) {
        self.id = Self.id(conversation: conversation, kind: kind, text: todo ?? text)
        self.conversation = conversation
        self.kind = kind
        self.text = text
        self.binder = binder
        self.answer = answer
        self.sources = sources
        self.todo = todo
        self.status = status
    }

    static func id(conversation: UUID, kind: Kind, text: String) -> String {
        let digest = SHA256.hash(data: Data("\(conversation.uuidString)|\(kind.rawValue)|\(TextNorm.normalizedWords(text).joined(separator: " "))".utf8))
        return kind.rawValue + "-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The notification: a short title and the body.
    public var notification: (title: String, body: String) {
        switch kind {
        case .card: ("Put this on the \(binder) board?", text)
        case .answer: ("You asked: \(text)", String((answer ?? "").prefix(240)))
        case .idea: ("An idea for the \(binder) board?", text)
        }
    }

    /// The card an idea becomes, the same every time it's said yes to or given to someone, so it's made once.
    public var cardID: UUID {
        var bytes = Array(SHA256.hash(data: Data("card|\(id)".utf8)).prefix(16))
        // A version 4 UUID, as UUID() makes.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The link methods: the iPhone asks for suggestions on its conversations, and says yes or no to one.
    public static let listMethod = "binders/suggestions"
    public static let actMethod = "binders/suggestion"
    public static let feature = "suggestions"

    /// Notification categories, the same on the Mac and the iPhone.
    public static let cardCategory = "conversation-card"
    public static let answerCategory = "conversation-answer"

    /// The suggestions kept on a conversation, as JSON.
    public static func decodeList(_ json: String) -> [ConversationSuggestion] {
        decodeEach(Data(json.utf8))
    }

    /// A list of suggestions, skipping any this build can't read (a kind from a newer Mac) rather than losing them all.
    public static func decodeEach(_ data: Data) -> [ConversationSuggestion] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return items.compactMap { item in
            (try? JSONSerialization.data(withJSONObject: item)).flatMap { try? JSONDecoder().decode(ConversationSuggestion.self, from: $0) }
        }
    }

    public static func encodeList(_ list: [ConversationSuggestion]) -> String {
        (try? String(data: JSONEncoder().encode(list), encoding: .utf8)) ?? "[]"
    }
}

public enum SuggestionPrompts {
    /// The to-dos in a conversation's notes worth a card: open, and yours. When it isn't known which voice is yours
    /// (`youKnown` false), anyone's: they may be yours. At most `limit`.
    public static func cardCandidates(summary: String, conversation: UUID, youKnown: Bool = true, limit: Int = 3) -> [(text: String, todo: String)] {
        var found: [(text: String, todo: String)] = []
        for line in summary.components(separatedBy: "\n") {
            guard let task = NotesEditing.task(from: line), !task.done, !task.text.isEmpty,
                  !youKnown || task.owner == nil || task.owner == TranscriptSegment.you else { continue }
            let todo = BoardTaskReference(place: .meeting, id: conversation, text: task.text).string
            if !found.contains(where: { $0.todo == todo }) { found.append((task.text, todo)) }
            if found.count == limit { break }
        }
        return found
    }

    /// The ideas in a conversation's notes worth a card: the lines of its Ideas section, at most `limit`. Nothing for a
    /// section that only says there were none.
    public static func ideaCandidates(summary: String, limit: Int = 2) -> [String] {
        var found: [String] = []
        var inIdeas = false
        for raw in summary.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inIdeas = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased() == "ideas"
                continue
            }
            guard inIdeas, NotesEditing.task(from: line) == nil else { continue }
            var idea = line
            for marker in ["- ", "* ", "• ", "+ "] where idea.hasPrefix(marker) {
                idea = String(idea.dropFirst(marker.count))
                break
            }
            if let range = idea.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) { idea.removeSubrange(range) }
            idea = idea.trimmingCharacters(in: .whitespaces)
            let plain = idea.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".()_* "))
            guard idea.count >= 4, !["none", "n/a", "no ideas", "none mentioned", "nothing", "no ideas mentioned"].contains(plain) else { continue }
            if !found.contains(where: { $0.caseInsensitiveCompare(idea) == .orderedSame }) { found.append(String(idea.prefix(200))) }
            if found.count == limit { break }
        }
        return found
    }

    /// Questions from a conversation worth looking up. `youKnown` says the transcript marks the user as "You".
    public static func questionsSystemPrompt(youKnown: Bool) -> String {
        let who = youKnown ? "the user, labelled \"You\"," : "the user (who may be any of the speakers)"
        return """
        You find questions \(who) asked, or wondered aloud, in a conversation, that weren't answered in it and that their own notes, meetings or earlier conversations might answer: facts, dates, decisions, numbers, names, what someone said or promised.
        Leave out small talk, rhetorical questions, and anything answered in the conversation itself.
        Rewrite each as a short question that stands on its own, with the names and subjects it needs.
        Reply with one line per question, "Q: <question>", at most 3. If there are none, reply with exactly: NONE
        """
    }

    public static func questionsUserPrompt(transcript: String) -> String {
        "Transcript:\n<transcript>\n\(transcript)\n</transcript>"
    }

    public static func parseQuestions(_ output: String, limit: Int = 3) -> [String] {
        var questions: [String] = []
        for line in OutputGuard.sanitize(output).components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*•0123456789.) ").union(.whitespaces))
            guard let range = trimmed.range(of: "Q:", options: [.caseInsensitive, .anchored]) else { continue }
            let question = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard question.count >= 8, !questions.contains(where: { $0.caseInsensitiveCompare(question) == .orderedSame }) else { continue }
            questions.append(String(question.prefix(200)))
            if questions.count == limit { break }
        }
        return questions
    }

    /// An answer only when the sources hold one: anything less is NO ANSWER, so a notification is never a guess.
    public static func answerSystemPrompt(today: String) -> String {
        """
        You answer a question the user asked out loud, from their own notes, meetings and conversations, given as numbered sources. Today is \(today).
        - Answer only if the sources clearly do. Otherwise reply with exactly: NO ANSWER
        - One or two short sentences, the answer first. Cite sources inline like [1].
        - Never invent details, and don't mention that you were given sources.
        """
    }

    /// The answer, or nil for NO ANSWER (or nothing usable).
    public static func parseAnswer(_ output: String) -> String? {
        let text = OutputGuard.sanitize(output).trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = text.trimmingCharacters(in: CharacterSet(charactersIn: "*_.`\"“” ").union(.whitespaces)).uppercased()
        guard !text.isEmpty, !plain.hasPrefix("NO ANSWER") else { return nil }
        return text
    }
}
