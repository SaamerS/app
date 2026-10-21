import Foundation

/// Schedules calls to the one local model, so a call someone is waiting on never sits behind background work.
///
/// A now call (a dictation's cleanup, the answer to something just said) runs at once and never waits. A later call (a
/// capture's write-up, its suggestions, filing it) waits in line: later calls run one at a time, in the order they came,
/// and only while no now call is running. On a server that serves one request at a time, a now call can also interrupt
/// the later call in progress, which then goes back to the front of the line and runs again from the start.
public actor ModelLane {
    /// Whether someone is waiting on a call now, or it's background work that can wait its turn.
    public enum Priority: Sendable {
        case now, later
    }

    /// The lane every model call in the app goes through.
    public static let shared = ModelLane()

    /// The most times one later call is interrupted. After that it runs to the end, even alongside a now call.
    static let maxInterruptions = 2

    /// A later call, with its work wrapped so that each run reports back to the lane.
    private struct Call {
        let id: UUID
        let priority: TaskPriority
        /// Runs the work once, from the start.
        let attempt: @Sendable () async -> Void
        /// Ends the call with an error, without running it.
        let fail: @Sendable (any Error) -> Void
        var interruptions = 0
    }

    /// The later call that's running, and the task it runs in.
    private struct Turn {
        var call: Call
        let task: Task<Void, Never>
        /// The lane cancelled it for a now call: what it returns or throws is dropped, and it runs again.
        var interrupted = false
        /// Its caller cancelled it: what it returns or throws goes back to the caller as it is.
        var cancelled = false
    }

    private var nowCalls = 0
    /// Later calls waiting their turn, first come first served. An interrupted call goes back to the front.
    private var line: [Call] = []
    private var turn: Turn?

    /// A lane of its own, apart from `shared`. Each test makes one.
    public init() {}

    /// How many later calls are waiting their turn. Tests watch it to know a call is in line.
    var inLine: Int { line.count }

    /// Runs `work` in the lane and returns what it returns, or throws what it throws.
    ///
    /// A now call runs at once, in the caller's task. A later call waits in line until no now call and no other later call
    /// is running, then runs in a task of its own. Cancelling the caller takes the call out of the line before it runs, or
    /// cancels its work once it has started.
    ///
    /// With `interrupting`, a now call cancels the later call that's running, unless that call was interrupted twice
    /// already. What the interrupted work returns or throws is dropped. The call goes back to the front of the line and
    /// runs again from the start once no now call is running, so its caller sees only the extra time. A later call
    /// ignores `interrupting`.
    public nonisolated func run<T: Sendable>(_ priority: Priority, interrupting: Bool = false,
                                             _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        switch priority {
        case .now:
            await nowStarts(interrupting: interrupting)
            do {
                let value = try await work()
                await nowEnds()
                return value
            } catch {
                await nowEnds()
                throw error
            }
        case .later:
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await runLater(id, work)
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }
    }

    /// Counts a now call in, and interrupts the running later call when the now call asks to and that call may still be.
    private func nowStarts(interrupting: Bool) {
        nowCalls += 1
        guard interrupting, let running = turn, !running.interrupted, !running.cancelled,
              running.call.interruptions < Self.maxInterruptions else { return }
        turn?.call.interruptions += 1
        turn?.interrupted = true
        running.task.cancel()
    }

    /// Counts a now call out, and starts the next later call when it was the last one.
    private func nowEnds() {
        nowCalls -= 1
        startNext()
    }

    /// Puts a later call at the back of the line, and returns what its work returns once it has had its turn.
    private func runLater<T: Sendable>(_ id: UUID, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            line.append(Call(id: id, priority: Task.currentPriority, attempt: {
                let result: Result<T, any Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                if await self.ended(id) { continuation.resume(with: result) }
            }, fail: { continuation.resume(throwing: $0) }))
            startNext()
        }
    }

    /// Starts the first later call in line, when no now call and no other later call is running. The work runs in a
    /// detached task so it never runs on this actor: under Swift 6.2's approachable concurrency, a nonisolated closure
    /// awaited from here would.
    private func startNext() {
        guard nowCalls == 0, turn == nil, !line.isEmpty else { return }
        let call = line.removeFirst()
        let attempt = call.attempt
        turn = Turn(call: call, task: Task.detached(priority: call.priority) { await attempt() })
    }

    /// Called when a later call's work has returned or thrown. True when that is the call's outcome; false when the lane
    /// had interrupted it, and it's back at the front of the line to run again.
    private func ended(_ id: UUID) -> Bool {
        guard let finished = turn, finished.call.id == id else { return true }
        turn = nil
        let again = finished.interrupted && !finished.cancelled
        if again { line.insert(finished.call, at: 0) }
        startNext()
        return !again
    }

    /// The caller of a later call was cancelled. A call in line leaves it without running; a running call has its work
    /// cancelled, and what that work returns or throws goes back to the caller.
    private func cancel(_ id: UUID) {
        if let index = line.firstIndex(where: { $0.id == id }) {
            line.remove(at: index).fail(CancellationError())
        } else if turn?.call.id == id {
            turn?.cancelled = true
            turn?.task.cancel()
        }
    }
}
