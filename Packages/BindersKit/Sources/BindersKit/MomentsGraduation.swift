import Foundation

// MARK: - Graduating

/// What became of something heard on its own (no "Binders, …"), for its kind's graduation (MomentGraduation).
public enum MomentVerdict: String, Codable, Sendable, CaseIterable {
    /// Offered, and you tapped Add.
    case added
    /// Offered, and you tapped Not Now or swiped it away.
    case notNow
    /// "Not me": it wasn't you, or it wasn't said to Binders. A hard no, which also counts against the voice print.
    case notMe
    /// Added at once with Undo, its kind having graduated, and left there.
    case kept
    /// Added, at once or after Add, and taken back with Undo.
    case undone
}

/// Per kind (to-do, idea, note), whether what you say to yourself is offered, with Add and Not Now, or added at once with
/// Undo: a kind graduates once you've said yes to it often enough, and drops back when you take too much of it back.
/// Questions and status requests never graduate, as they're answered rather than added, and nothing that gives work to
/// an agent is added without your tap (the Mac's part). Counted on the iPhone, where you tap, from verdicts alone, never
/// words. Pure and Codable, so the tests decide as the iPhone does.
///
/// - A kind graduates with at least 40 offers resolved since it last went back to offering, a 95% Wilson lower bound of
///   at least 0.85 on the share you added, and no Not me among the last 40 of them.
/// - It drops back after 2 Undos (a Not me counts as one) in its last 10 since it graduated, or when you switch it back.
///   Either way it counts afresh from there.
public struct MomentGraduation: Codable, Equatable, Sendable {
    /// One moment's verdict, the latest standing: Add, then Undo, is undone.
    public struct Event: Codable, Equatable, Sendable {
        public var moment: UUID
        /// For this kind, in the order first resolved, from 0.
        public var serial: Int
        /// It was offered; otherwise it was added at once.
        public var offered: Bool
        public var verdict: MomentVerdict
    }

    /// One kind's mode and what counts towards it.
    public struct Track: Codable, Equatable, Sendable {
        /// Added at once with Undo, rather than offered.
        public var adding = false
        /// The serial of the first event that counts: those before it came before the last change.
        public var from = 0
        /// The next event's serial.
        public var next = 0
        /// Newest last, the last `remembered` of them.
        public var events: [Event] = []
    }

    public enum Change: Equatable, Sendable {
        /// Now added at once with Undo.
        case graduated(MomentKind)
        /// Offered again.
        case droppedBack(MomentKind)
    }

    /// A kind's mode, and how far it has come towards graduating.
    public struct Progress: Equatable, Sendable {
        public var adding: Bool
        /// Offers resolved since it last went back to offering, and how many of them you added.
        public var resolved: Int
        public var added: Int
        /// The 95% Wilson lower bound of the share added.
        public var lowerBound: Double
        /// A Not me among the last 40 of them.
        public var notMe: Bool
    }

    /// The kinds that graduate.
    public static let kinds: [MomentKind] = [.todo, .idea, .note]
    public static let leastOffers = 40
    public static let leastShare = 0.85
    public static let notMeWindow = 40
    public static let undoWindow = 10
    public static let undosToDropBack = 2
    /// Events remembered per kind: room for the windows and for counting since the last change.
    public static let remembered = 200

    /// By MomentKind.rawValue.
    public private(set) var tracks: [String: Track]

    public init() {
        tracks = [:]
    }

    public func isAdding(_ kind: MomentKind) -> Bool { tracks[kind.rawValue]?.adding ?? false }

    /// The kinds added at once now, in `kinds`' order: what the iPhone tells the Mac (MomentPayload.adds).
    public var adding: [MomentKind] { Self.kinds.filter(isAdding) }

    public func progress(_ kind: MomentKind) -> Progress { Self.progress(of: tracks[kind.rawValue] ?? Track()) }

    /// What became of a moment of `kind`, and the change it made, if any. A moment already counted takes its new verdict
    /// in its place (Add, then Undo), except `kept`, which is only ever a moment's first, and over Not me, which stands.
    /// `mayAdd`: the Mac can add at once (MomentPayload.addsFeature); without that, a kind keeps offering, however well
    /// it's going.
    @discardableResult
    public mutating func record(_ verdict: MomentVerdict, moment: UUID, kind: MomentKind, offered: Bool, mayAdd: Bool = true) -> Change? {
        guard Self.kinds.contains(kind) else { return nil }
        var track = tracks[kind.rawValue] ?? Track()
        defer { tracks[kind.rawValue] = track }
        if let index = track.events.firstIndex(where: { $0.moment == moment }) {
            let was = track.events[index].verdict
            guard verdict != .kept, was != verdict, was != .notMe else { return nil }
            track.events[index].verdict = verdict
        } else {
            track.events.append(Event(moment: moment, serial: track.next, offered: offered, verdict: verdict))
            track.next += 1
            if track.events.count > Self.remembered { track.events.removeFirst(track.events.count - Self.remembered) }
        }
        if track.adding {
            let recent = track.events.filter { $0.serial >= track.from }.suffix(Self.undoWindow)
            guard recent.filter({ $0.verdict == .undone || $0.verdict == .notMe }).count >= Self.undosToDropBack else { return nil }
            track.adding = false
            track.from = track.next
            return .droppedBack(kind)
        }
        let progress = Self.progress(of: track)
        guard mayAdd, progress.resolved >= Self.leastOffers, progress.lowerBound >= Self.leastShare, !progress.notMe else { return nil }
        track.adding = true
        track.from = track.next
        return .graduated(kind)
    }

    /// You switched a kind back to offering: it counts afresh.
    public mutating func suggest(_ kind: MomentKind) {
        guard var track = tracks[kind.rawValue], track.adding else { return }
        track.adding = false
        track.from = track.next
        tracks[kind.rawValue] = track
    }

    private static func progress(of track: Track) -> Progress {
        let offers = track.events.filter { $0.offered && $0.serial >= track.from }
        let added = offers.filter { $0.verdict == .added }.count
        return Progress(adding: track.adding, resolved: offers.count, added: added, lowerBound: wilsonLowerBound(added, of: offers.count),
                        notMe: offers.suffix(notMeWindow).contains { $0.verdict == .notMe })
    }

    /// The 95% Wilson score lower bound of `successes` out of `total`: the least share of yeses that many out of that many
    /// still leaves likely. 0 with none.
    public static func wilsonLowerBound(_ successes: Int, of total: Int, z: Double = 1.959964) -> Double {
        guard total > 0 else { return 0 }
        let n = Double(total), share = Double(min(max(successes, 0), total)) / n, z2 = z * z
        let centre = share + z2 / (2 * n)
        let margin = z * ((share * (1 - share) + z2 / (4 * n)) / n).squareRoot()
        return max(0, (centre - margin) / (1 + z2 / n))
    }

    // MARK: Words

    /// "To-dos", "Ideas", "Notes".
    public static func plural(_ kind: MomentKind) -> String {
        switch kind {
        case .todo: "To-dos"
        case .idea: "Ideas"
        case .note: "Notes"
        case .question: "Questions"
        case .status: "Status requests"
        case .none: "Others"
        }
    }

    /// A kind's state as the capture screen shows it: "Suggesting, 12 of 40", "Added with Undo".
    public static func summary(_ progress: Progress) -> String {
        if progress.adding { return "Added with Undo" }
        if progress.resolved < leastOffers { return "Suggesting, \(progress.resolved) of \(leastOffers)" }
        if progress.notMe { return "Suggesting, a Not me in the last \(notMeWindow)" }
        let share = Int((Double(progress.added) / Double(progress.resolved) * 100).rounded(.down))
        return "Suggesting, \(progress.resolved) so far, \(share)% added"
    }

    /// The one notification when a kind graduates, and the quiet one when it drops back. None of your words.
    public static func notification(_ change: Change) -> NotificationText {
        switch change {
        case .graduated(let kind):
            NotificationText(title: "Added with Undo from now on",
                             body: "\(plural(kind)) you say to yourself are now added with Undo. You can switch back in Capture.")
        case .droppedBack(let kind):
            NotificationText(title: "Suggesting \(plural(kind).lowercased()) again",
                             body: "You took back \(undosToDropBack) of the last \(undoWindow) added with Undo, so Binders asks first again.")
        }
    }
}
