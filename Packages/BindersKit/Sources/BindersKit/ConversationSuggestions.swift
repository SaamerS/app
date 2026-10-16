import CryptoKit
import Foundation

/// Something Binders offers once a conversation is written up: a card for what you said you'd do, or an answer, from
/// your binders, to a question you asked. Shown on the conversation and sent as a notification to the device that heard it.
public struct ConversationSuggestion: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Put a to-do from the conversation on its binder's board.
        case card
        /// A question you asked, answered from your notes, meetings and conversations.
        case answer
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
        }
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
        (try? JSONDecoder().decode([ConversationSuggestion].self, from: Data(json.utf8))) ?? []
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
