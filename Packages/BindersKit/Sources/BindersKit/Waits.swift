import Foundation

// Every wait names its reason and the next step. The iPhone finds the facts and shows the words; the words are here, so
// each wait is tested to say both.

/// Why a capture waits to be written down rather than being written down now, and when it will be: the first thing that
/// stands in its way, then the way on ("the iPhone is warm, so with Binders open or while charging"). Shown after
/// "waiting: " on its row and on its timeline.
public enum CaptureWait {
    /// What stands in a capture's way, as the iPhone finds it.
    public struct Facts: Equatable, Sendable {
        /// Binders is open on screen, writing down the capture before it.
        public var inFront: Bool
        /// iOS lets the speech models run with Binders in the background.
        public var mayInferInBackground: Bool
        /// It once stopped Binders in the background, so it waits for the app.
        public var appOnly: Bool
        /// "Write down while the iPhone is locked" is on.
        public var writesDownWhileLocked: Bool
        /// Something went wrong writing down in the background since Binders was last open.
        public var backgroundPaused: Bool
        /// The speech models were readied with Binders open, so they can run in the background.
        public var modelsReady: Bool
        /// Something keeps Binders running in the background: capture listening, or the keyboard's microphone.
        public var staysAlive: Bool
        public var warm: Bool
        public var lowPowerMode: Bool
        /// Under 20% and not charging.
        public var lowBattery: Bool
        /// Over 15 minutes of speech: more than the background takes on, on battery.
        public var long: Bool
        /// Why iOS wouldn't take the charging task, when it wouldn't ("Background App Refresh is off for Binders").
        public var chargingBlocked: String?

        public init(inFront: Bool = false, mayInferInBackground: Bool = true, appOnly: Bool = false, writesDownWhileLocked: Bool = true,
                    backgroundPaused: Bool = false, modelsReady: Bool = true, staysAlive: Bool = true, warm: Bool = false,
                    lowPowerMode: Bool = false, lowBattery: Bool = false, long: Bool = false, chargingBlocked: String? = nil) {
            self.inFront = inFront
            self.mayInferInBackground = mayInferInBackground
            self.appOnly = appOnly
            self.writesDownWhileLocked = writesDownWhileLocked
            self.backgroundPaused = backgroundPaused
            self.modelsReady = modelsReady
            self.staysAlive = staysAlive
            self.warm = warm
            self.lowPowerMode = lowPowerMode
            self.lowBattery = lowBattery
            self.long = long
            self.chargingBlocked = chargingBlocked
        }
    }

    /// The reason, then the way on: with Binders open, or while charging too where the charging task can write it down.
    /// When iOS wouldn't take that task, the way on is Binders, and it says why the charger can't help.
    public static func reason(_ facts: Facts) -> String {
        if facts.inFront { return "the one before it first" }
        if !facts.mayInferInBackground { return "only with Binders open on this iPhone" }
        if facts.appOnly { return "something went wrong in the background, so with Binders open" }
        let why: String
        if !facts.writesDownWhileLocked {
            why = "writing down while locked is off"
        } else if facts.backgroundPaused {
            why = "something went wrong in the background"
        } else if !facts.modelsReady {
            return "the speech models aren't ready yet: open Binders once"
        } else if !facts.staysAlive {
            why = "capture isn't listening"
        } else if facts.warm {
            why = "the iPhone is warm"
        } else if facts.lowPowerMode {
            why = "Low Power Mode is on"
        } else if facts.lowBattery {
            why = "the battery is under 20%"
        } else if facts.long {
            why = "over 15 minutes of speech"
        } else {
            why = "the iPhone is busy"
        }
        guard let blocked = facts.chargingBlocked?.trimmingCharacters(in: .whitespacesAndNewlines), !blocked.isEmpty else {
            return why + ", so with Binders open or while charging"
        }
        return why + ", so with Binders open (the charger can't help: \(blocked))"
    }
}

/// What something you said to yourself says while it waits on your Mac, with why and what comes next. `state` is this
/// iPhone's word on it (kept, while your Mac is out of reach; sent; refused), `outcome` the Mac's so far (nil, or
/// working while it decides). Nil once it doesn't wait: the Mac has said what it made of it, or couldn't read it.
public enum MomentWait {
    public static let kept = "Kept on this iPhone. It goes to your Mac when it's back."
    public static let sent = "Sent. Your Mac says what it made of it shortly."
    public static let working = "Your Mac is working on it, and says what it made of it shortly."

    public static func line(state: String?, outcome: String?) -> String? {
        switch outcome {
        case nil:
            switch state {
            case "refused": nil
            case "kept": kept
            default: sent
            }
        case "working": working
        default: nil
        }
    }

    /// Only what comes next, for a row whose word already says why it waits ("Waiting for your Mac", "Sent", "Your Mac
    /// is on it"). Nil where `line` is.
    public static func next(state: String?, outcome: String?) -> String? {
        guard line(state: state, outcome: outcome) != nil else { return nil }
        return outcome == nil && state == "kept" ? "It goes to your Mac when it's back." : "Your Mac says what it made of it shortly."
    }
}
