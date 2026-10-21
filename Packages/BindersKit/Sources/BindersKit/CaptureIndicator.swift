import Foundation

/// All-day capture's sign on the Lock Screen and in the Dynamic Island, its Live Activity, kept up for as long as capture is
/// on (App Store 2.5.14). iOS ends a Live Activity after eight hours or when it's swiped away, and lets Binders start one
/// only while it's in front or one of capture's own buttons runs. So one that ends while capture is on is asked for again
/// at once and at every chance after, and while it can't be shown and capture listens, one quiet notification says so.
public struct CaptureIndicator: Equatable, Sendable {
    /// It ended while capture was on, and none has shown since.
    public private(set) var lost = false
    /// The one notification about it went.
    public private(set) var told = false

    public init() {}

    /// iOS ended the Live Activity. Only an end while capture is on is a loss.
    public mutating func ended(captureOn: Bool) {
        if captureOn { lost = true }
    }

    /// One shows again, or capture turned off: nothing to say any more.
    public mutating func settled() {
        lost = false
        told = false
    }

    /// Asking for a new one failed: whether to post the notification now. Only after a loss, only while capture listens
    /// (muted, the microphone is off), only with Live Activities allowed (otherwise the capture screen says the microphone
    /// indicator is the only sign), and once.
    public mutating func couldNotShow(listening: Bool, allowed: Bool) -> Bool {
        guard lost, listening, allowed, !told else { return false }
        told = true
        return true
    }
}
