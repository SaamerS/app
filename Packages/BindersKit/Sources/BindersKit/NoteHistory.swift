import Foundation

/// When a note's earlier text is kept, which kept versions go, and how two versions differ, for version history.
public enum NoteVersions {
    /// How long after one kept version the next can be: an editing session keeps a version every few minutes.
    public static let interval: TimeInterval = 5 * 60
    /// Versions older than this go, except the latest few.
    public static let keepDays = 30
    public static let keepLatest = 20

    /// Whether the text a note had before a change should be kept: when the last kept version is old enough, and the
    /// text isn't empty or the same as it.
    public static func shouldKeep(_ previous: String, lastKept: (date: Date, text: String)?, now: Date) -> Bool {
        guard !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let lastKept else { return true }
        return now.timeIntervalSince(lastKept.date) >= interval && lastKept.text != previous
    }

    /// Of these kept versions' dates, the ones to delete: older than `keepDays`, beyond the latest `keepLatest`.
    public static func expired(_ dates: [Date], now: Date, calendar: Calendar = .current) -> [Date] {
        let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: now) ?? now
        return dates.sorted(by: >).dropFirst(keepLatest).filter { $0 < cutoff }
    }

    /// Lines added and removed going from `old` to `new`.
    public static func change(from old: String, to new: String) -> (added: Int, removed: Int) {
        let difference = new.components(separatedBy: "\n").difference(from: old.components(separatedBy: "\n"))
        return (difference.insertions.count, difference.removals.count)
    }

    /// One line of what changed: kept as it was, added, or taken out.
    public enum Line: Equatable, Sendable {
        case same(String), added(String), removed(String)
    }

    /// What changed going from `old` to `new`, line by line in reading order: every line of both, with what was taken
    /// out just before what took its place.
    public static func lines(from old: String, to new: String) -> [Line] {
        let before = old.components(separatedBy: "\n"), after = new.components(separatedBy: "\n")
        var removed = Set<Int>(), added = Set<Int>()
        for step in after.difference(from: before) {
            switch step {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var lines: [Line] = []
        var old = 0, new = 0
        while old < before.count || new < after.count {
            if old < before.count, removed.contains(old) {
                lines.append(.removed(before[old]))
                old += 1
            } else if new < after.count, added.contains(new) {
                lines.append(.added(after[new]))
                new += 1
            } else if old < before.count, new < after.count {
                // Lines neither taken out nor added are the same lines, in the same order.
                lines.append(.same(after[new]))
                old += 1
                new += 1
            } else {
                break
            }
        }
        return lines
    }
}
