import Foundation

/// Cards that wait for others: a card distilled from a spec waits for the cards it needs first (`card_dependencies` in the
/// team database), and an agent can't take it until they're all Done (`BoardRules.claim`'s `waitingOn`). These are the
/// parts every surface shares: what a card still waits for, and that no card ever waits for itself, directly or through
/// others.
public enum CardWaits {
    /// A card it waits for, as the board has it now.
    public struct Wait: Equatable, Sendable {
        public var id: String
        public var title: String
        public var column: BoardColumn

        public init(id: String, title: String, column: BoardColumn) {
            self.id = id
            self.title = title
            self.column = column
        }

        public var done: Bool { column == .done }
    }

    /// What a card still waits for: the waits that aren't Done, in their order. A card that's gone (deleted) is waited for
    /// no longer.
    public static func open(_ waits: [Wait]) -> [Wait] {
        waits.filter { !$0.done }
    }

    /// Whether `card` waiting for `waitsFor` would make some card wait for itself, directly or through others. `graph` is
    /// what every other card waits for, by id; the card's own entry in it is replaced by `waitsFor`.
    public static func makesCycle(card: String, waitsFor: [String], graph: [String: [String]]) -> Bool {
        if waitsFor.contains(card) { return true }
        var graph = graph
        graph[card] = waitsFor
        // From what it would wait for, can the card itself be reached?
        var seen: Set<String> = []
        var stack = waitsFor
        while let next = stack.popLast() {
            if next == card { return true }
            guard seen.insert(next).inserted else { continue }
            stack += graph[next] ?? []
        }
        return false
    }

    /// The waits of a set of items (by index: each item's list of the items it waits for), with any wait that would close a
    /// circle left out, earliest first: an item's own number, one out of range, and a wait that would make an item wait for
    /// itself through others. What was left out comes back too, as (item, the one it would have waited for).
    public static func acyclic(_ waits: [[Int]]) -> (waits: [[Int]], dropped: [(item: Int, on: Int)]) {
        var kept = Array(repeating: [Int](), count: waits.count)
        var dropped: [(item: Int, on: Int)] = []
        func reaches(_ from: Int, _ target: Int) -> Bool {
            var seen: Set<Int> = []
            var stack = [from]
            while let next = stack.popLast() {
                if next == target { return true }
                guard seen.insert(next).inserted else { continue }
                stack += kept[next]
            }
            return false
        }
        for (item, list) in waits.enumerated() {
            for on in list {
                guard on != item, waits.indices.contains(on), !kept[item].contains(on) else {
                    if on == item || !waits.indices.contains(on) { dropped.append((item, on)) }
                    continue
                }
                // Waiting for `on` closes a circle when `on` already reaches `item`.
                if reaches(on, item) {
                    dropped.append((item, on))
                } else {
                    kept[item].append(on)
                }
            }
        }
        return (kept, dropped)
    }

    /// The items in an order where each comes after everything it waits for, keeping their own order otherwise. Nil when
    /// they wait in a circle.
    public static func order(_ waits: [[Int]]) -> [Int]? {
        var placed: [Int] = []
        var done: Set<Int> = []
        while placed.count < waits.count {
            guard let next = waits.indices.first(where: { !done.contains($0) && waits[$0].allSatisfy { done.contains($0) || !waits.indices.contains($0) } }) else {
                return nil
            }
            placed.append(next)
            done.insert(next)
        }
        return placed
    }

    /// "Waits for “A” and “B”": what a card still waits for, said on the card, the board and the phone. Nil when nothing.
    public static func line(_ open: [Wait]) -> String? {
        guard !open.isEmpty else { return nil }
        let titles = open.prefix(3).map { "“\($0.title)”" }
        let list = titles.count > 1 ? titles.dropLast().joined(separator: ", ") + " and " + titles.last! : titles[0]
        return "Waits for " + list + (open.count > 3 ? " and \(open.count - 3) more" : "")
    }
}
