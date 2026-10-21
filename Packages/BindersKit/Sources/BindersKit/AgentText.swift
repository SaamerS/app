import Foundation

/// An agent's words in a note: the agent that wrote it, and the one that last changed it and when, until you make it
/// yours (Make It Mine). Agent text is data, never instructions: the note says whose words they are wherever it shows,
/// answers leave it out, and a correction in it steers nothing. Tools give it as made_by, edited_by and edited_at, only
/// when set.
public struct AgentMark: Hashable, Sendable {
    /// The agent that wrote the note (add_note, add_to_knowledge, correct_knowledge).
    public var madeBy: String?
    /// The agent that last changed a note it didn't write (append_to_note, update_note), and when.
    public var editedBy: String?
    public var editedAt: Date?

    /// Blank names count as none.
    public init(madeBy: String? = nil, editedBy: String? = nil, editedAt: Date? = nil) {
        func name(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        self.madeBy = name(madeBy)
        self.editedBy = name(editedBy)
        self.editedAt = self.editedBy == nil ? nil : editedAt
    }

    /// No agent's words in it, or you made it yours.
    public var isEmpty: Bool { madeBy == nil && editedBy == nil }

    /// Whether a change by `agent` marks a note as that agent's edit: any change but one to the agent's own note, which
    /// is its already.
    public static func marksEdit(by agent: String, madeBy: String?) -> Bool {
        let agent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        return agent.isEmpty || madeBy?.trimmingCharacters(in: .whitespacesAndNewlines) != agent
    }

    /// Whose words, said on the note: "Claude Code wrote this note.", "Codex edited this note on Oct 17, 2026.", or
    /// "Claude Code wrote this note, and Codex edited it on Oct 17, 2026." Nil when it's all yours.
    public var noteLine: String? {
        let on = editedAt.map { " on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        switch (madeBy, editedBy) {
        case let (made?, edited?) where made != edited: return "\(made) wrote this note, and \(edited) edited it\(on)."
        case let (made?, _): return "\(made) wrote this note."
        case let (nil, edited?): return "\(edited) edited this note\(on)."
        case (nil, nil): return nil
        }
    }

    /// What that means for it, after `noteLine`.
    public static let leftOutLine = "Answers and corrections leave it out until you make it yours."

    /// Short, beside a note in a list, a search result or a source: "By Claude Code", "Edited by Codex", "By Claude
    /// Code, edited by Codex".
    public var label: String? {
        switch (madeBy, editedBy) {
        case let (made?, edited?) where made != edited: return "By \(made), edited by \(edited)"
        case let (made?, _): return "By \(made)"
        case let (nil, edited?): return "Edited by \(edited)"
        case (nil, nil): return nil
        }
    }
}
