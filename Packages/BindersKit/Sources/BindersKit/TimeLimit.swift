import Foundation

/// A few seconds shared by the steps of one job, such as cleaning up a dictation: each step gets what's left, so the
/// whole never takes longer.
public struct TimeBudget: Sendable {
    public let deadline: ContinuousClock.Instant

    public init(seconds: TimeInterval) {
        deadline = ContinuousClock.now.advanced(by: .seconds(max(0, seconds)))
    }

    /// Seconds left, never below zero.
    public var left: TimeInterval { max(0, ContinuousClock.now.duration(to: deadline) / .seconds(1)) }

    /// What's left, but no more than `cap`: for a step that mustn't take it all.
    public func left(atMost cap: TimeInterval) -> TimeInterval { min(max(0, cap), left) }
}

/// Runs work for at most a few seconds: its result when it's in time, `TimeLimit.Exceeded` when it isn't. At the limit
/// the work is cancelled and not waited for, so work that doesn't stop when cancelled can't hold anyone up. Cancelling
/// the caller gives up on it the same way.
public enum TimeLimit {
    public struct Exceeded: Error, LocalizedError, Equatable {
        public init() {}
        public var errorDescription: String? { "It took too long" }
    }

    public static func run<T: Sendable>(within seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds > 0 else { throw Exceeded() }
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                guard race.wait(continuation) else { return }
                race.hold(Task {
                    do { race.finish(.success(try await work())) } catch { race.finish(.failure(error)) }
                })
                race.hold(Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    race.finish(.failure(Exceeded()))
                })
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

/// The work, the clock and a cancel, racing: the first answers the caller, once, and the others are stopped.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var outcome: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    /// False when it's already over (cancelled before it began), and the caller has had its answer.
    func wait(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        guard let outcome else {
            self.continuation = continuation
            lock.unlock()
            return true
        }
        lock.unlock()
        continuation.resume(with: outcome)
        return false
    }

    /// A task to stop once it's over; stopped at once if it already is.
    func hold(_ task: Task<Void, Never>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return task.cancel()
        }
        tasks.append(task)
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard outcome == nil else { return lock.unlock() }
        outcome = result
        let waiting = continuation
        continuation = nil
        let running = tasks
        tasks = []
        lock.unlock()
        waiting?.resume(with: result)
        for task in running { task.cancel() }
    }
}
