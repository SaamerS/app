import Foundation

/// A rule the user wrote: when a phrase is spoken in Command Mode, or something happens in Binders, run something.
public struct AutomationRule: Codable, Equatable, Identifiable, Sendable {
    public enum Trigger: Codable, Equatable, Sendable {
        /// Spoken in Command Mode; whatever follows the phrase is the payload's text.
        case phrase(text: String)
        case event(name: AutomationEvent)
    }

    public enum Action: Codable, Equatable, Sendable {
        /// The Shortcut receives the rendered `input` template as text.
        case shortcut(name: String, input: String)
        /// Placeholders go only in the query, percent-encoded (`AutomationTemplate.urlProblem`), so what they say can't
        /// change what opens.
        case openURL(template: String)
        /// Run with zsh; the payload arrives as BINDERS_* environment variables, and the text on standard input.
        case script(command: String)
        /// POST as JSON: the rendered `body` template, or the whole payload when `body` is empty. A token, when the rule
        /// has one, is kept in the Keychain and goes as Authorization: Bearer.
        case webhook(url: String, body: String)
    }

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var trigger: Trigger
    public var action: Action
    /// "Also for to-dos said to yourself, from agents and from links": a to-do rule runs for those too, not only for the
    /// ones you made. Off unless you turn it on (nil in rules from before it was there). A web hook's token isn't here: it
    /// stays in the Keychain.
    public var anyOrigin: Bool?

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, trigger: Trigger, action: Action, anyOrigin: Bool? = nil) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.action = action
        self.anyOrigin = anyOrigin
    }

    /// Whether it runs for something from `origin`: always for what you made, and for events that aren't to-dos (they
    /// have no origin); for a to-do said to yourself, an agent's or a link's only when the rule says so.
    public func runs(for origin: TodoOrigin?) -> Bool {
        guard let origin, !origin.madeByYou else { return true }
        return anyOrigin == true
    }
}

/// Where a to-do came from, kept with it and given to automations as BINDERS_TODO_ORIGIN. Automations run for the ones
/// you made; the others only for a rule that also takes them, so nothing you said to yourself, and nothing an agent or a
/// link added, leaves the Mac through a rule without your tap.
public enum TodoOrigin: String, Codable, CaseIterable, Sendable {
    /// Said in Command Mode on the Mac ("Add to-do …").
    case voice
    /// Added in Binders on your iPhone, typed or dictated there.
    case phone
    /// Something you said to yourself that Binders offered, and you tapped Add.
    case suggestion
    /// Something you said to yourself and Binders did at once: "Binders, …", or Tell Binders, which works locked.
    case moment
    /// An agent or a tool, over MCP or the inbox. The to-do names it.
    case agent
    /// A binders://todo link, from whatever opened it.
    case link

    /// Made by you (typed, dictated at the Mac, or a suggestion you tapped Add on): automations run for it.
    public var madeByYou: Bool {
        switch self {
        case .voice, .phone, .suggestion: true
        case .moment, .agent, .link: false
        }
    }

    /// Said to yourself, done at once or added with your tap: its text is your own words, which Binders quotes in New
    /// York italic wherever it lists them ("Said to yourself").
    public var isSaidToYourself: Bool { self == .moment || self == .suggestion }

    /// The source list_todos gives a to-do said to yourself, from every Mac since moments.
    public static let saidToYourselfSource = "Said to yourself"

    /// Whether a to-do, as list_todos gives it, is said to yourself: by its origin when it's one this build knows; else
    /// (a Mac from before `origin`, a cached reply without it, or an origin from a newer Mac) by its source.
    public static func isSaidToYourself(origin: String?, source: String?) -> Bool {
        if let origin, let known = TodoOrigin(rawValue: origin) { return known.isSaidToYourself }
        return source == saidToYourselfSource
    }
}

public enum AutomationEvent: String, Codable, CaseIterable, Identifiable, Sendable {
    case dictationInserted, todoAdded, promiseNoted, meetingReady, writingCaptured

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dictationInserted: "Dictation inserted"
        case .todoAdded: "To-do added"
        case .promiseNoted: "Promise noted"
        case .meetingReady: "Meeting notes ready"
        case .writingCaptured: "Writing captured"
        }
    }
}

/// What a trigger hands to its action. Every field is a placeholder: `{text}`, `{title}` and so on.
public struct AutomationPayload: Codable, Equatable, Sendable {
    public var event: String
    public var text: String
    public var title: String
    public var when: String
    public var date: String
    public var app: String
    public var binder: String
    public var summary: String
    public var link: String
    /// A to-do's origin (TodoOrigin): BINDERS_TODO_ORIGIN for a script, `todo_origin` in a web hook's payload. Nil for
    /// everything else, which then reads as it always did.
    public var todoOrigin: String?

    public init(event: String = "phrase", text: String = "", title: String = "", when: String = "", date: String = "",
                app: String = "", binder: String = "", summary: String = "", link: String = "", todoOrigin: TodoOrigin? = nil) {
        self.event = event
        self.text = text
        self.title = title
        self.when = when
        self.date = date
        self.app = app
        self.binder = binder
        self.summary = summary
        self.link = link
        self.todoOrigin = todoOrigin?.rawValue
    }

    /// "call Sam tomorrow at 3 pm": the text as said, title "call Sam", when "tomorrow at 3 pm", date in ISO 8601.
    public static func spoken(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> AutomationPayload {
        let split = CommitmentDetection.splitDue(text, relativeTo: now, calendar: calendar)
        return AutomationPayload(text: text, title: split.task, when: split.due ?? "", date: split.dueAt.map(iso) ?? "")
    }

    public var fields: [String: String] {
        var fields = ["event": event, "text": text, "title": title, "when": when, "date": date, "app": app, "binder": binder,
                      "summary": summary, "link": link]
        if let todoOrigin { fields["todo_origin"] = todoOrigin }
        return fields
    }

    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// A time in ISO 8601 as a tool sends it, with or without fractions of a second. Nil when it isn't one.
    public static func date(fromISO text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

public enum AutomationTemplate {
    public static let placeholders = ["text", "title", "when", "date", "app", "binder", "summary", "link", "event", "todo_origin"]

    /// Fills `{text}`, `{title}`… from the payload, passing each value through `encode` first. One pass over the
    /// template: a value that has braces in it stays as it is, never filled in turn.
    public static func render(_ template: String, payload: AutomationPayload, encode: (String) -> String = { $0 }) -> String {
        let fields = payload.fields
        var result = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let value = fields[String(after[..<close])] {
                result += encode(value)
                rest = after[after.index(after: close)...]
            } else {
                result += "{"
                rest = after
            }
        }
        return result + rest
    }

    /// Safe as a value in a URL's query: everything but ASCII letters, digits, "-", "_" and "~" is percent-encoded,
    /// "." and "/" too, so a value can't end its parameter, add another or reach the path.
    public static func percentEncoded(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Why a link template can't be used, or nil when it can. Card and binder words go only into query values (`?q={title}`):
    /// never into the scheme, the address, the path, a parameter's name or the part after `#`, where they could change
    /// what the link opens.
    public static func urlProblem(_ template: String) -> String? {
        let link = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return "Give the link to open." }
        func placeholder(in part: Substring) -> String? { placeholders.first { part.contains("{\($0)}") } }
        let parts = link.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let beforeQuery = parts[0].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        if let name = placeholder(in: beforeQuery[0]) {
            return "{\(name)} is in the link's address or path. Placeholders go only in its query, after ? as in ?title={title}, so what a to-do or binder says can't change what the link opens."
        }
        if parts.count > 1, let name = placeholder(in: parts[1]) {
            return "{\(name)} is after #. Placeholders go only in the link's query, after ? as in ?title={title}."
        }
        if beforeQuery.count > 1 {
            for parameter in beforeQuery[1].split(separator: "&") {
                let name = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
                if let placeholder = placeholder(in: name) {
                    return "{\(placeholder)} names a parameter. Placeholders go only after a parameter's =, as in ?title={title}."
                }
            }
        }
        guard link.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil else {
            return "Start the link with what opens it, such as https:// or things:///."
        }
        return nil
    }

    /// Safe inside a JSON string literal (the quotes are the template's).
    public static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let quoted = String(data: data, encoding: .utf8), quoted.count >= 2 else { return value }
        return String(quoted.dropFirst().dropLast())
    }

    /// What follows the phrase when the instruction starts with it: "send to Things buy milk" → "buy milk", and "" when
    /// the phrase is the whole instruction. Nil when the instruction is about something else.
    public static func remainder(of instruction: String, afterPhrase phrase: String) -> String? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        let words = phrase.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let pattern = "(?i)^(?:hey\\s+)?" + words.joined(separator: "\\s+") + "\\b[,:]?\\s*(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
