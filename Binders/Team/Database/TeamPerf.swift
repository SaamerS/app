import Foundation

/// How much work the team database's notes do on this Mac (lane DB10): the sweeps, and what's written to disk, counted for
/// the open-perf self-test and for looking into a slow binder. Counted from any thread.
final class TeamPerf: @unchecked Sendable {
    struct Counts: Equatable {
        /// Sweeps of the shared binders' notes: every note (`full`), or only the ones a save named.
        var sweeps = 0
        var fullSweeps = 0
        var notesSwept = 0
        /// The notes' states written (notes.json), and their size.
        var engineSaves = 0
        var engineBytes = 0
        /// Notes' documents written, and their size.
        var documentWrites = 0
        var documentBytes = 0
        /// The outbox written whole (outbox.json), and appended to (its journal).
        var outboxSaves = 0
        var outboxBytes = 0
        var outboxAppends = 0
        var outboxAppendBytes = 0
        /// Feed reads of notes' rows, and the documents read with them.
        var noteRowsRead = 0
        var documentsRead = 0
    }

    static let shared = TeamPerf()

    private let lock = NSLock()
    private var counts = Counts()

    /// What was counted since the last `reset`.
    var now: Counts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    func reset() {
        lock.lock()
        counts = Counts()
        lock.unlock()
    }

    func count(_ change: (inout Counts) -> Void) {
        lock.lock()
        change(&counts)
        lock.unlock()
    }
}
