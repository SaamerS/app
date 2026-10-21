import Foundation

/// What became of something the iPhone sent: a capture written up and filed, or not kept; later, a moment acted on,
/// offered or left alone. The Mac writes the words. `state` and `actions` are open sets of words, so a newer Mac's states
/// still read on an older phone.
///
/// Asked for over the link only (`binders/outcomes`, with the ids), never through MCP, so no agent reads it.
public struct CaptureOutcome: Codable, Equatable, Sendable, Identifiable {
    /// The capture's or the moment's id.
    public var id: UUID
    /// One of `States`, or one a newer Mac has.
    public var state: String
    /// "Filed in Events: Ignite booth plan · 2 to-dos". It can hold what was said, so it isn't for the Lock Screen.
    public var line: String
    /// The same without anything that was said, for the Lock Screen: "Filed in Events", "Not kept".
    public var title: String?
    /// Nothing more will change, so the phone stops asking.
    public var settled: Bool?
    public var binder: String?
    /// Open checklist items in its notes.
    public var todos: Int?
    /// What `binders/outcome` takes for it now (add, not-now, undo, assign; and, for a moment from an iPhone that sends a
    /// mode, stop and not-me while its card is handed over).
    public var actions: [String]?
    /// Who Assign would give it to.
    public var agent: String?
    /// What it made, for Open: a card's id, or a to-do's as list_todos gives it.
    public var card: String?
    public var todo: String?
    /// For an answer, the titles of what it came from, which `line` also holds after the answer, on a line of their own;
    /// empty for an answer from nowhere in particular. Nil from a Mac before it.
    public var sources: [String]?
    /// For a moment: how long it took (MomentTimings), the Mac's part filled in.
    public var timings: MomentTimings?
    /// For a moment: what it was read as (MomentKind: todo, idea, note, question, status, none), so the iPhone can say what
    /// was done without the words (LockScreenText). Nil from a Mac before it, and for captures.
    public var kind: String?
    /// For a moment that came with a mode (MomentPayload.mode): "auto" when Binders handed its card over in Auto, "start"
    /// when it did by the start rule a "Binders, …" has (RouterRules.mayStart); nil otherwise, and from a Mac before it.
    public var handedOver: String?
    /// It waits on you: "wake" for a card made ready for its agent and not woken (the hourly cap), "give" for one Auto
    /// held back with Give to (too many late ones at once). The iPhone shows it in amber, in Needs you.
    public var waiting: String?
    /// It reached the Mac late (AutoRules.isLate), so the iPhone adds when it was said, in its own time zone: the Mac's
    /// lines hold no time for an iPhone that sends a mode.
    public var late: Bool?
    /// For a capture read for what you said (lane Y2): each item and each moment that went with it, in the order heard.
    public var found: [Found]?
    /// For a capture from a phone in Auto or Add at Once that wasn't read: why, in AutoText.soloWhy's words.
    public var soloLine: String?
    /// For a moment heard during a capture in Auto: the capture it waits for. Cleared once it's decided.
    public var joins: UUID?

    /// One thing read from a capture, or a moment said in it that went with it: its own outcome comes with
    /// binders/outcomes, as a moment's, under `id`.
    public struct Found: Codable, Equatable, Sendable {
        public var id: UUID
        public var heard: Date
        /// Your sentences.
        public var said: String
        /// todo or idea (a fix is a to-do).
        public var kind: String
        /// A moment said during the capture that went with it.
        public var joined: Bool?

        public init(id: UUID, heard: Date, said: String, kind: String, joined: Bool? = nil) {
            self.id = id
            self.heard = heard
            self.said = said
            self.kind = kind
            self.joined = joined
        }
    }

    public init(id: UUID, state: String, line: String, title: String? = nil, settled: Bool? = nil, binder: String? = nil,
                todos: Int? = nil, actions: [String]? = nil, agent: String? = nil, card: String? = nil, todo: String? = nil,
                sources: [String]? = nil, timings: MomentTimings? = nil, kind: String? = nil, handedOver: String? = nil,
                waiting: String? = nil, late: Bool? = nil, found: [Found]? = nil, soloLine: String? = nil, joins: UUID? = nil) {
        self.id = id
        self.state = state
        self.line = line
        self.title = title
        self.settled = settled
        self.binder = binder
        self.todos = todos
        self.actions = actions
        self.agent = agent
        self.card = card
        self.todo = todo
        self.sources = sources
        self.timings = timings
        self.kind = kind
        self.handedOver = handedOver
        self.waiting = waiting
        self.late = late
        self.found = found
        self.soloLine = soloLine
        self.joins = joins
    }

    /// The line as Siri says it: an answer without the titles of its sources after it, nor its [1]-style marks.
    public var spoken: String {
        var text = line
        if let sources {
            let after = "\n" + sources.joined(separator: " · ")
            if !sources.isEmpty, text.hasSuffix(after) { text = String(text.dropLast(after.count)) }
        } else if state == "answered", let last = text.range(of: "\n", options: .backwards) {
            // A Mac from before `sources` puts them on the answer's last line.
            text = String(text[..<last.lowerBound])
        }
        return Self.speakable(text)
    }

    /// Text to be said aloud: without "[1]" or "[2][3]" marks citing sources, and the space before them.
    public static func speakable(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*(?:\[\d+(?:\s*[,–-]\s*\d+)*\])+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The words a Mac uses today.
    public enum States {
        /// A capture being written up.
        public static let writing = "writing"
        public static let filed = "filed"
        public static let notKept = "not-kept"
        public static let failed = "failed"
    }

    /// The words of `handedOver` and `waiting`.
    public enum Handed {
        public static let auto = "auto"
        public static let start = "start"
    }

    public enum Waiting {
        /// Made ready for its agent and not woken: Wake Now on the card on your Mac.
        public static let wake = "wake"
        /// Held back with Give to.
        public static let give = "give"
    }

    /// The link methods: ask after some ids; act on one. And the feature a Mac lists in hello when it has them.
    public static let listMethod = "binders/outcomes"
    public static let actMethod = "binders/outcome"
    public static let feature = "outcomes"

    /// A list of outcomes, skipping any this build can't read rather than losing them all.
    public static func decodeEach(_ items: [Any]) -> [CaptureOutcome] {
        items.compactMap { item in
            (try? JSONSerialization.data(withJSONObject: item)).flatMap { try? JSONDecoder().decode(CaptureOutcome.self, from: $0) }
        }
    }

    public var jsonObject: [String: Any] {
        (try? JSONEncoder().encode(self)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}
