import Foundation

/// The iPhone's Dictate bar, touch by touch: a tap dictates; a hold listens for a question, and letting go asks it. iOS
/// can take a touch away from the bar while it's held (the tab bar's own gestures cancel the bar's), which looked just
/// like letting go: listening stopped after a second or so. Taken away, it carries on listening, and the next tap asks.
/// However it goes, listening ends: let go, tapped, or at `longest`. Pure, so it's tested here; the bar runs it.
public struct TalkTouch: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Nothing in hand.
        case idle
        /// A finger down, not yet held long enough to listen.
        case pressed
        /// Held: listening, the finger still down.
        case holding
        /// Listening, but iOS took the touch away: the next tap asks.
        case loose
        /// That tap, its finger down.
        case looseTapping
        /// Let go, or tapped: what was heard is being written down, then asked. Another touch waits for it.
        case finishing
    }

    /// What the bar does next.
    public enum Outcome: Equatable, Sendable {
        case none
        /// A tap: dictation opens.
        case dictate
        /// Held long enough: the microphone starts.
        case listen
        /// Done listening: what was heard is written down and asked.
        case ask
    }

    public private(set) var phase: Phase = .idle

    /// A touch that moved further than this, in points, was a swipe across the bar, not a tap.
    public static let tapTravel: Double = 30
    /// The longest it listens for one question, in seconds: past it, it asks what it heard.
    public static let longest: TimeInterval = 60

    public init() {}

    /// Listening for a question, whether or not the finger is still down.
    public var isListening: Bool { phase == .holding || phase == .loose || phase == .looseTapping }

    /// The bar shows the question's states (listening, writing it down), not "Tap to dictate".
    public var isAsking: Bool { isListening || phase == .finishing }

    public mutating func down() {
        switch phase {
        case .idle: phase = .pressed
        case .loose: phase = .looseTapping
        default: break
        }
    }

    /// The touch has lasted long enough to be a hold.
    public mutating func held() -> Outcome {
        guard phase == .pressed else { return .none }
        phase = .holding
        return .listen
    }

    /// The finger lifted, `travelled` points from where it came down.
    public mutating func up(travelled: Double) -> Outcome {
        switch phase {
        case .pressed:
            phase = .idle
            return travelled < Self.tapTravel ? .dictate : .none
        case .holding, .looseTapping:
            phase = .finishing
            return .ask
        default:
            return .none
        }
    }

    /// iOS took the touch away. Held, it keeps listening for a tap to ask. A touch not yet held is taken as lifted, as
    /// before, since iOS may also end a plain tap on the bar this way.
    public mutating func cancelled(travelled: Double) -> Outcome {
        switch phase {
        case .pressed: return up(travelled: travelled)
        case .holding, .looseTapping:
            phase = .loose
            return .none
        default:
            return .none
        }
    }

    /// Listening went on for `longest`: it asks what it heard.
    public mutating func timedOut() -> Outcome {
        guard isListening else { return .none }
        phase = .finishing
        return .ask
    }

    /// Asked, or let go of (the bar went away, the microphone couldn't start): ready for the next touch.
    public mutating func reset() {
        phase = .idle
    }
}
