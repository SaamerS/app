import Foundation

/// What's new in what waits on you, look after look, for the iPhone's warning by touch: something that joined since the
/// last look, even as something else left. The first look only learns what's there. Nil is no copy of the boards (none
/// yet, or gone with an unpairing): what was known is forgotten, so the next look only learns again, and a Mac paired
/// afterwards doesn't warn about everything already waiting on it.
public struct NewlyWaiting: Sendable {
    private var last: Set<String>?

    public init() {}

    /// Whether anything in `items` wasn't there at the last look. Every look counts, whether or not it may warn: one
    /// made in the background keeps up, so what came meanwhile doesn't warn later.
    public mutating func look(_ items: Set<String>?) -> Bool {
        defer { last = items }
        guard let items, let last else { return false }
        return !items.isSubset(of: last)
    }
}

/// Touches close together are one: a refresh that brings three outcomes at once, or a question that rings as its card
/// joins Needs you.
public struct TouchPacing: Sendable {
    /// How far apart two touches must be.
    public let apart: TimeInterval
    private var last: Date?

    public init(apart: TimeInterval) {
        self.apart = apart
    }

    /// Whether a touch at `now` plays; one that does counts from there.
    public mutating func allows(at now: Date) -> Bool {
        if let last, now.timeIntervalSince(last) < apart { return false }
        last = now
        return true
    }
}
