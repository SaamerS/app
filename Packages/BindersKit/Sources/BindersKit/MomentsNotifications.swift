import Foundation

/// How iOS shows notification previews (Settings → Notifications → Show Previews), as the iPhone reads it.
public enum NotificationPreviews: String, Sendable, CaseIterable {
    /// On the Lock Screen too: iOS's default on an iPhone with Touch ID.
    case always
    /// Once the iPhone is unlocked, iOS's default with Face ID. Locked, each notification shows its placeholder instead.
    case whenUnlocked
    /// Only the placeholder, always.
    case never
}

/// What a notification says.
public struct NotificationText: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String

    public init(title: String, subtitle: String = "", body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

/// The Lock Screen shows titles and counts by default, never what you said. With previews set to Always, a notification
/// about something you said, or something said in a conversation, says what was done ("To-do added in Personal") and
/// leaves the words for the app, unless you turned on "Show what you said on the Lock Screen". With previews hidden until
/// you unlock, or never shown, the words can be there: until then iOS shows the title and a placeholder with a count.
/// Titles never hold your words. Pure, so it's tested here; the iPhone reads the setting and posts.
public enum LockScreenText {
    /// Whether a notification may hold what you said: where iOS hides previews until you unlock, or where you asked for it.
    public static func showsWords(_ previews: NotificationPreviews, allowed: Bool) -> Bool {
        previews != .always || allowed
    }

    // MARK: Moments

    /// A moment's notification, from what the Mac made of it; nil for one with nothing to say (no title).
    public static func moment(_ outcome: CaptureOutcome, showsWords: Bool) -> NotificationText? {
        guard let title = outcome.title, !title.isEmpty else { return nil }
        if showsWords {
            // An answer without its sources' titles and marks; a line that only repeats the title isn't said twice.
            let body = outcome.state == "answered" ? outcome.spoken : outcome.line
            return NotificationText(title: title, body: body == title ? "" : body)
        }
        return NotificationText(title: title, body: withoutWords(outcome))
    }

    /// What was done, without what was said: "To-do added in Personal", "1 idea for the Ignite board", "Binders answered
    /// your question". The boards' digest stays, in counts and names, with each card's title taken out. Empty where the
    /// title says it all, and for a state this build doesn't know, whose line may hold your words.
    public static func withoutWords(_ outcome: CaptureOutcome) -> String {
        let kind = kind(of: outcome)
        let binder = outcome.binder.flatMap { $0.isEmpty ? nil : $0 }
        switch outcome.state {
        case "offered":
            if kind == .idea { return binder.map { "1 idea for the \($0) board" } ?? "1 idea for a board" }
            if kind == .note { return binder.map { "1 note for \($0)" } ?? "1 note" }
            return binder.map { "1 to-do for \($0)" } ?? "1 to-do"
        case "acted":
            switch kind {
            case .idea: return binder.map { "1 idea for the \($0) board" } ?? "1 idea for a board"
            case .note: return binder.map { "Note kept in \($0)" } ?? "Note kept"
            default:
                // Given to an agent since: its card is on the board.
                if outcome.card?.isEmpty == false { return binder.map { "On the \($0) board" } ?? "On a board" }
                return binder.map { "To-do added in \($0)" } ?? "To-do added"
            }
        case "answered":
            switch kind {
            case .question: return "Binders answered your question"
            // The boards' digest in counts and names: a card's title can be what you said.
            case .status: return WorkStreams.withoutTitles(outcome.line)
            // Not kept as a note: why, in the Mac's words, which hold none of yours.
            default: return outcome.line == outcome.title ? "" : outcome.line
            }
        default:
            // Nothing found, taken back, not added: the title says so, and the line may name what was asked.
            return ""
        }
    }

    /// What a moment was read as. A Mac says (`kind`); from one before that, it's worked out from what it made and its
    /// title, as such a Mac writes them.
    public static func kind(of outcome: CaptureOutcome) -> MomentKind? {
        if let said = outcome.kind.flatMap(MomentKind.init(rawValue:)) { return said }
        if outcome.todo?.isEmpty == false { return .todo }
        let title = outcome.title ?? ""
        if title == "Your work streams" { return .status }
        if title == "Not kept" || title.hasPrefix("Kept in ") || title.hasPrefix("Keep in ") { return .note }
        if outcome.card?.isEmpty == false || title.hasPrefix("An idea for ") || title.hasSuffix(" board?") { return .idea }
        switch outcome.state {
        case "answered", "nothing": return .question
        case "offered", "acted": return .todo
        default: return nil
        }
    }

    // MARK: Conversations

    /// A conversation's suggestion: a card to put on a board, an idea for a board's Backlog, or an answer to a question
    /// asked in it ("You asked: …" is your words). `heard` is when the conversation began, as the phone shows a time
    /// ("3:10 PM").
    public static func suggestion(_ suggestion: ConversationSuggestion, heard: String?, showsWords: Bool) -> NotificationText {
        let full = suggestion.notification
        if showsWords { return NotificationText(title: full.title, body: full.body) }
        let when = heard.map { " at \($0)" } ?? ""
        switch suggestion.kind {
        case .card: return NotificationText(title: full.title, body: "1 to-do from your conversation\(when)")
        case .idea: return NotificationText(title: full.title, body: "1 idea from your conversation\(when)")
        case .answer: return NotificationText(title: "Binders answered your question", body: "From your conversation\(when)")
        }
    }

    // MARK: Cards

    /// A card's title, where a notification about the card shows it: an agent's question on it, an agent picking it up or
    /// finishing it, a request for your approval, a hand-off that didn't go. A card can be made from what you said (a
    /// moment, a conversation), so its title is kept for the app as your words are, and as the widgets keep it. Without
    /// them, its binder says where it is ("On the Personal board"), or nothing does.
    public static func card(_ title: String, binder: String? = nil, showsWords: Bool) -> String {
        if showsWords { return title }
        guard let binder = binder?.trimmingCharacters(in: .whitespacesAndNewlines), !binder.isEmpty else { return "" }
        return "On the \(binder) board"
    }

    /// "Your answer on “Fix the login bug”" where the card's title may show, and "Your answer" where it may not: the start
    /// of the word that an answer typed into a notification waits on this iPhone.
    public static func yourAnswer(on title: String, showsWords: Bool) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return showsWords && !title.isEmpty ? "Your answer on “\(title)”" : "Your answer"
    }

    // MARK: Buttons and placeholders

    /// The Give to button, naming the agent: "Give to Claude Code · app". A long name is cut short, keeping the agent's
    /// own name whole where it can.
    public static func giveTo(_ agent: String, longest: Int = 32) -> String {
        let prefix = "Give to "
        return prefix + shortName(agent, longest: max(8, longest - prefix.count))
    }

    /// A name in at most `longest` characters: the part after " · " (the workspace) goes first, then the rest, each
    /// ending in "…".
    public static func shortName(_ name: String, longest: Int) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count > longest else { return name }
        let parts = name.components(separatedBy: " · ")
        let head = parts[0].trimmingCharacters(in: .whitespaces)
        // Room for " · ", a few characters of the rest and "…".
        if parts.count > 1, head.count + 3 + 3 + 1 <= longest {
            let rest = parts.dropFirst().joined(separator: " · ")
            return head + " · " + String(rest.prefix(longest - head.count - 3 - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return String(name.prefix(longest - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// In place of a notification's body while previews are hidden. iOS puts the count of them in for %u; each reads
    /// right whatever the count ("1 waiting for your answer", "3 waiting for your answer").
    /// Offers, cards a conversation suggests and agents' questions: they wait on you.
    public static let waitingPlaceholder = "%u waiting for your answer"
    /// Moments acted on: added, put on a board, kept.
    public static let keptPlaceholder = "%u kept from what you said"
    /// Moments whose card Binders handed to an agent without asking (in Auto, or a "Binders, …" by the start rule).
    public static let handedPlaceholder = "%u handed to agents from what you said"
    /// Answers, to moments and to questions asked in conversations.
    public static let answeredPlaceholder = "%u answered from your binders"
    /// What became of something you did: it couldn't be done, or it waits for your Mac.
    public static let aboutPlaceholder = "%u about what you said"
    /// Agents picking up cards and finishing them.
    public static let boardsPlaceholder = "%u from your boards"
    /// All-day capture itself: paused, still listening without its Live Activity, waiting to be turned on in the app.
    public static let capturePlaceholder = "%u about All-day capture"
    /// A capture's hand-overs, in one notification (lane Y2).
    public static let foundPlaceholder = "%u from what you said"

    // MARK: A capture's hand-overs (lane Y2)

    /// One thing read from a capture, or a moment that went with it, as the capture's notification counts it: handed to
    /// `agent`, added to `binder`, waiting on you, or offered.
    public struct FoundThing: Equatable, Sendable {
        public var title: String
        public var agent: String?
        public var binder: String?
        public var waits: Bool

        public init(title: String, agent: String? = nil, binder: String? = nil, waits: Bool = false) {
            self.title = title
            self.agent = agent
            self.binder = binder
            self.waits = waits
        }
    }

    /// The capture's one notification: nil when it made nothing, or exactly one thing (then that moment's own goes). The
    /// title never holds your words; the body does only with `showsWords`. `time` is when the capture began ("10:42").
    public static func captureFound(_ things: [FoundThing], offered: Int, time: String, showsWords: Bool) -> NotificationText? {
        guard things.count > 1 || (things.count == 1 && offered > 0) else { return nil }
        let handed = things.filter { $0.agent != nil && !$0.waits }
        let title: String
        if handed.count >= 2 {
            title = "Handed \(handed.count) things to agents"
        } else if let one = handed.first?.agent {
            title = "Handed 1 thing to \(one)"
        } else {
            title = "Added \(things.count) \(things.count == 1 ? "thing" : "things") from what you said"
        }
        let waiting = things.filter(\.waits).count
        var body: String
        if showsWords {
            body = things.map { thing in
                if let agent = thing.agent, !thing.waits { return "\(agent): \(AutoText.sentence(thing.title))" }
                return "Added to \(thing.binder ?? "your binders"): \(AutoText.sentence(thing.title))"
            }.joined(separator: " ")
            if waiting > 0 { body += " \(waiting) \(waiting == 1 ? "waits" : "wait") for you: Give to, or Wake Now on your Mac." }
        } else {
            var counts: [(String, Int)] = []
            for thing in things {
                let key = thing.agent.flatMap { thing.waits ? nil : $0 } ?? ("added to " + (thing.binder ?? "your binders"))
                if let index = counts.firstIndex(where: { $0.0 == key }) { counts[index].1 += 1 } else { counts.append((key, 1)) }
            }
            let parts = counts.map { $0.0.hasPrefix("added to ") ? "\($0.1) \($0.0)" : "\($0.1) to \($0.0)" }
            body = "From what you said at \(time): " + parts.joined(separator: ", ") + "."
            if waiting > 0 { body += " \(waiting) \(waiting == 1 ? "waits" : "wait") for you." }
        }
        if offered > 0 { body += " \(offered) more offered." }
        return NotificationText(title: title, body: body)
    }
}
