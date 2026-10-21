import Foundation

/// The hover highlight on the knowledge graph's nodes: it eases in on the node under the pointer and out on the one it
/// left, and lands on its end exactly, so the graph can stop drawing once it gets there.
public struct GraphHighlight: Equatable, Sendable {
    /// How lit each node is, 0 to 1; nodes at 0 aren't kept.
    public private(set) var amounts: [String: Double] = [:]

    public init() {}

    public subscript(id: String) -> Double { amounts[id] ?? 0 }

    /// Whether a step would change anything: the hovered node isn't fully lit yet, or another one is still fading.
    public func isEasing(toward hovered: String?) -> Bool {
        if let hovered, amounts[hovered] != 1 { return true }
        return amounts.keys.contains { $0 != hovered }
    }

    /// One frame's worth: `rate` of the way to the end, and the rest at once when it's nearly there.
    public mutating func step(toward hovered: String?, rate: Double = 0.22) {
        for id in Set(amounts.keys).union(hovered.map { [$0] } ?? []) {
            let target: Double = id == hovered ? 1 : 0
            let now = amounts[id] ?? 0
            let next = now + (target - now) * rate
            amounts[id] = abs(target - next) < 0.01 ? (target == 0 ? nil : target) : next
        }
    }

    /// Straight to the end, for Reduce Motion.
    public mutating func snap(to hovered: String?) {
        amounts = hovered.map { [$0: 1] } ?? [:]
    }
}
