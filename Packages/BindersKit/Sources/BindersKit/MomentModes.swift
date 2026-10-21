import Foundation

// What Binders does with what it hears you say on your own near the iPhone: offer it (Suggest, the default), add it at
// once (Add at Once), or add it and hand a to-do or an idea straight to the agent the decision model picks (Auto). Chosen
// on the iPhone; the Mac reads the mode from each moment (MomentPayload.mode). Pure, so `swift test` holds the rules both
// ends share.

// MARK: - The modes

/// The iPhone's mode for what you say on your own, kept in its UserDefaults as `momentMode` (a string). Missing or unknown
/// reads as Suggest, so a step back to an older build, or a newer build's mode, never hands anything over.
public enum MomentMode: String, Codable, Sendable, CaseIterable {
    /// Offered with Add and Not Now; a kind you nearly always add graduates to Added with Undo (MomentGraduation).
    case suggest
    /// To-dos, ideas and notes added at once with Undo; work for an agent offered with Give to.
    case add
    /// Added at once, and a to-do or an idea handed to the agent Binders picks, without asking (RouterRules.mayHandOver).
    case auto

    /// As kept: "suggest", "add" or "auto"; anything else, or nothing, is Suggest.
    public init(stored: String?) {
        self = stored.flatMap(MomentMode.init(rawValue:)) ?? .suggest
    }

    /// Its name in the Mode menu.
    public var name: String {
        switch self {
        case .suggest: "Suggest"
        case .add: "Add at Once"
        case .auto: "Auto"
        }
    }

    /// The line under the Mode menu.
    public var summary: String {
        switch self {
        case .suggest:
            "Offers each thing you say on your own, with Add and Not Now. A kind you add nearly every time is then added at once with Undo."
        case .add:
            "Adds to-dos, ideas and notes at once, with Undo. Work for an agent is offered, with Give to."
        case .auto:
            "Adds them at once, and hands a to-do or an idea to the agent Binders picks, without asking first. "
                + "Binders skips only its own question: each agent keeps its own permission checks, and is told to ask your approval "
                + "before it sends, posts or buys."
        }
    }

    /// Lower modes hand less over: Suggest, then Add at Once, then Auto.
    public var rank: Int {
        switch self {
        case .suggest: 0
        case .add: 1
        case .auto: 2
        }
    }
}

// MARK: - Auto's limits

/// Auto's limits, in one place.
public enum AutoRules {
    /// Words that reach the Mac longer than this after they were heard are late: handed over, with when they were heard,
    /// at most `lateAtOnce` in any `lateWindow`. The start rule of a "Binders, …" keeps its own 15 minutes
    /// (RouterRules.freshFor).
    public static let lateAfter: TimeInterval = RouterRules.freshFor
    /// A heard time this far in the Mac's future (the iPhone's clock ahead) counts as late too.
    public static let clockSlack: TimeInterval = 2 * 60
    /// Further than this from the Mac's now, either way, nothing is handed over: it's added at once, with Give to.
    public static let horizon: TimeInterval = 12 * 3_600
    /// At most this many late ones are handed over in any `lateWindow`; the rest wait for your Give to.
    public static let lateAtOnce = 5
    public static let lateWindow: TimeInterval = 10 * 60
    /// The same thing handed the same agent again within this is a repeat (`alreadyHanded`).
    public static let repeatWithin: TimeInterval = 30 * 60
    /// …and so is one heard within this of the hand-over's own words, however long ago it was decided (lane Y2: a capture
    /// is read minutes or hours after a moment said the same thing).
    public static let repeatHeardWithin: TimeInterval = 30 * 60

    /// Whether an earlier hand-over of the same thing counts as this one again: decided within `repeatWithin` of now, or
    /// heard within `repeatHeardWithin` of when this was heard.
    public static func isRepeat(decided: Date, heard: Date?, now: Date, heardNow: Date) -> Bool {
        if now.timeIntervalSince(decided) <= repeatWithin { return true }
        guard let heard else { return false }
        return abs(heardNow.timeIntervalSince(heard)) <= repeatHeardWithin
    }
    /// Not me's among Auto's last `notMeWindow` hand-overs that turn Auto off on the iPhone (AutoWatch).
    public static let notMeToTurnOff = 2
    public static let notMeWindow = 10
    /// A hand-over's notification this soon after the last one comes quietly.
    public static let quietWithin: TimeInterval = 30
    /// Two titles at least this alike are the same thing (`sameThing`).
    public static let sameShare = 0.85

    /// Late, by its age on the Mac's clock (now − heard): more than `lateAfter` old, or more than `clockSlack` ahead.
    public static func isLate(_ age: TimeInterval) -> Bool { age > lateAfter || age < -clockSlack }

    /// The same thing, for `alreadyHanded`: two titles whose normalized words (TextNorm.normalizedWords, joined by
    /// spaces) are the same, or at least `sameShare` alike (TextNorm.similarity). Two empty titles are never the same.
    public static func sameThing(_ a: String, _ b: String) -> Bool {
        let one = TextNorm.normalizedWords(a).joined(separator: " "), other = TextNorm.normalizedWords(b).joined(separator: " ")
        guard !one.isEmpty, !other.isEmpty else { return false }
        return one == other || TextNorm.similarity(one, other) >= sameShare
    }
}

// MARK: - Sending a moment kept for the Mac

public enum MomentModes {
    /// The kinds Add at Once and Auto add at once, as `adds` carries them.
    public static let everyKind: [String] = MomentGraduation.kinds.map(\.rawValue)

    /// A moment kept while the Mac was out of reach, as it's sent now. One heard in Auto goes as the mode you have now, if
    /// you've left Auto since, or as Add at Once if the sheet hasn't listed the agents (`listed` false): without the yes it
    /// carried for what was heard on its own, and with the `adds` that mode sends. To a Mac that doesn't list
    /// `MomentPayload.autoFeature`, without `mode`, `autoHold` and `alone`, as Add at Once there. Never up: one heard in
    /// Suggest isn't handed over, nor added at once, because Auto is on when it goes. A "Binders, …" keeps its yes, for
    /// the start rule, whatever the mode. One with no mode (an older build's, or one built for a Mac without the feature)
    /// goes as it was kept.
    ///
    /// `addsNow` is what Suggest sends now for something heard on its own: the kinds that have graduated (nil when none, or
    /// when that's not known: then it's offered, which only ever asks more). `conversation` is sent as kept, for every Mac.
    ///
    /// Lane Y2: to a Mac that doesn't list `ConversationPayload.soloFeature`, without `fromTranscript` and `uncued`; and
    /// `agreed` cut to the yeses still given in `consents` (nil keeps it as kept), so a yes taken back on the iPhone while
    /// the Mac was away is taken back for what was waiting too.
    public static func asSent(_ payload: MomentPayload, modeNow: MomentMode, listed: Bool, addsNow: [String]?,
                              macFeatures: Set<String>, consents: [String: String]? = nil) -> MomentPayload {
        var payload = payload
        // To a Mac that doesn't read them, what only Y2 sends goes as before Y2: a "Binders, …" found in a capture's
        // transcript with no mode (offered), and a sentence kept without a cue only offered, never added or handed over.
        let older = !macFeatures.contains(ConversationPayload.soloFeature)
        let olderTranscript = older && payload.fromTranscript == true
        let olderUncued = older && payload.uncued != nil
        if older {
            payload.fromTranscript = nil
            payload.uncued = nil
        }
        if olderTranscript || olderUncued {
            payload.mode = olderUncued && payload.mode != nil && macFeatures.contains(MomentPayload.autoFeature) ? MomentMode.suggest.rawValue : nil
            payload.adds = nil
            payload.agreed = nil
            payload.autoHold = nil
            if payload.mode == nil { payload.alone = nil }
            return payload
        }
        if let consents, let agreed = payload.agreed {
            let still = agreed.filter { consents[$0.key] == $0.value && !$0.value.isEmpty }
            payload.agreed = still.isEmpty ? nil : still
        }
        guard let stored = payload.mode else { return payload }
        let heard = MomentMode(stored: stored)
        let now = modeNow == .auto && !listed ? MomentMode.add : modeNow
        let autoMac = macFeatures.contains(MomentPayload.autoFeature)
        // As heard, or lower; and Auto only where the Mac hands over in Auto.
        var mode = now.rank < heard.rank ? now : heard
        if mode == .auto, !autoMac { mode = .add }
        var sent = payload
        if mode != heard {
            // Lower than heard: what it carried for the mode it was heard in goes, and it takes what this mode sends.
            let onItsOwn = payload.wake != true
            if mode != .auto {
                sent.autoHold = nil
                if onItsOwn { sent.agreed = nil }
            }
            if onItsOwn {
                let mayAdd = macFeatures.contains(MomentPayload.addsFeature)
                switch mode {
                case .suggest: sent.adds = mayAdd ? addsNow.flatMap { $0.isEmpty ? nil : $0 } : nil
                case .add, .auto: sent.adds = mayAdd ? everyKind : nil
                }
            }
        }
        if autoMac {
            sent.mode = mode.rawValue
        } else {
            sent.mode = nil
            sent.autoHold = nil
            sent.alone = nil
        }
        return sent
    }
}

// MARK: - Auto turning itself off

/// Auto's own drop-back: `AutoRules.notMeToTurnOff` Not me's among its last `AutoRules.notMeWindow` hand-overs turn it
/// off on the iPhone, as two Undos in its last ten send a graduated kind back to offering. A "Binders, …" handed over in
/// Auto counts too. Moments' ids and verdicts only, never words. Kept on the iPhone in UserDefaults as `autoWatch`.
public struct AutoWatch: Codable, Equatable, Sendable {
    /// Newest last, at most `AutoRules.notMeWindow`.
    public private(set) var recent: [Entry] = []

    public struct Entry: Codable, Equatable, Sendable {
        public var moment: UUID
        public var notMe: Bool

        public init(moment: UUID, notMe: Bool = false) {
            self.moment = moment
            self.notMe = notMe
        }
    }

    public init() {}

    /// Auto handed this one over. Once only: a moment already in the window keeps its place.
    public mutating func handedOver(_ moment: UUID) {
        guard !recent.contains(where: { $0.moment == moment }) else { return }
        recent.append(Entry(moment: moment))
        if recent.count > AutoRules.notMeWindow { recent.removeFirst(recent.count - AutoRules.notMeWindow) }
    }

    /// Not me on one Auto handed over: true when that makes `AutoRules.notMeToTurnOff` in the window, and Auto goes off.
    /// One outside the window, or said already, changes nothing.
    public mutating func notMe(_ moment: UUID) -> Bool {
        guard let index = recent.firstIndex(where: { $0.moment == moment }), !recent[index].notMe else { return false }
        recent[index].notMe = true
        return recent.filter(\.notMe).count >= AutoRules.notMeToTurnOff
    }

    /// Auto chosen again: it counts afresh.
    public mutating func reset() {
        recent = []
    }
}

// MARK: - Where a moment opens

/// Where a moment's Open, or a tap on its notification, goes (MomentCenter.place).
public enum MomentPlace: Equatable, Sendable {
    /// The card it made: an idea, or a to-do given to an agent.
    case card(String)
    /// The to-dos of the binder its to-do went into.
    case todos(binder: String)
    /// Its own page: an answer, an offer, a note, one taken back or still on its way, and one whose card Binders handed
    /// over without asking, where Stop, Undo, Not Me and Turn Off Auto are (the page has Open Card).
    case moment(UUID)

    /// From what the Mac made of it (its id is the moment's).
    public static func of(outcome: CaptureOutcome) -> MomentPlace {
        guard outcome.state == "acted", outcome.handedOver == nil else { return .moment(outcome.id) }
        if let card = outcome.card, !card.isEmpty { return .card(card) }
        if outcome.todo?.isEmpty == false, let binder = outcome.binder, !binder.isEmpty { return .todos(binder: binder) }
        return .moment(outcome.id)
    }
}
