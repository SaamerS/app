import XCTest
@testable import BindersKit

/// The fast lane with fake model calls: a now call stands for a dictation's cleanup or an answer, a later call for a
/// capture's write-up. The fakes wait on each other's events rather than on the clock, so every run sees the same order.
final class ModelLaneTests: XCTestCase {
    func testALaterCallWaitsForARunningNowCall() async throws {
        let lane = ModelLane()
        let events = Events()
        let cleanup = Task {
            try await lane.run(.now) {
                await events.add("cleanup starts")
                await events.wait(for: "write-up is in line")
                await events.add("cleanup ends")
                return "Clean text"
            }
        }
        await events.wait(for: "cleanup starts")
        let writeUp = Task { try await lane.run(.later) { await events.add("write-up runs"); return "Summary" } }
        await eventually("the write-up is in line") { await lane.inLine == 1 }
        await events.add("write-up is in line")

        let text = try await finished(cleanup)
        let summary = try await finished(writeUp)
        XCTAssertEqual(text, "Clean text")
        XCTAssertEqual(summary, "Summary")
        let log = await events.all
        XCTAssertEqual(log, ["cleanup starts", "write-up is in line", "cleanup ends", "write-up runs"])
    }

    /// The second and third write-ups arrive while the first is running, with no now call in the way.
    func testLaterCallsRunOneAtATimeInTheOrderTheyCame() async throws {
        let lane = ModelLane()
        let events = Events()
        func writeUp(_ n: Int) -> Task<Int, Error> {
            Task {
                try await lane.run(.later) {
                    await events.add("write-up \(n) starts")
                    if n == 1 { await events.wait(for: "the others are in line") }
                    try await Task.sleep(for: .milliseconds(5))   // time for another to start, if the lane let it
                    await events.add("write-up \(n) ends")
                    return n
                }
            }
        }
        let first = writeUp(1)
        await events.wait(for: "write-up 1 starts")
        let second = writeUp(2)
        await eventually("write-up 2 is in line") { await lane.inLine == 1 }
        let third = writeUp(3)
        await eventually("write-up 3 is in line") { await lane.inLine == 2 }
        await events.add("the others are in line")

        let one = try await finished(first)
        let two = try await finished(second)
        let three = try await finished(third)
        XCTAssertEqual([one, two, three], [1, 2, 3])
        let log = await events.all
        XCTAssertEqual(log, ["write-up 1 starts", "the others are in line", "write-up 1 ends",
                             "write-up 2 starts", "write-up 2 ends", "write-up 3 starts", "write-up 3 ends"])
    }

    func testANowCallDoesntWaitForARunningLaterCall() async throws {
        let lane = ModelLane()
        let events = Events()
        let writeUp = Task {
            try await lane.run(.later) {
                await events.add("write-up starts")
                await events.wait(for: "cleanup ends")
                await events.add(Task.isCancelled ? "write-up was cancelled" : "write-up ends")
                return "Summary"
            }
        }
        await events.wait(for: "write-up starts")
        let cleanup = Task { try await lane.run(.now) { await events.add("cleanup ends"); return "Clean text" } }

        let text = try await finished(cleanup)
        let summary = try await finished(writeUp)
        XCTAssertEqual(text, "Clean text")
        XCTAssertEqual(summary, "Summary")
        let log = await events.all
        XCTAssertEqual(log, ["write-up starts", "cleanup ends", "write-up ends"], "a now call that doesn't interrupt leaves it be")
    }

    /// On a server that serves one request at a time, an answer can't wait out a whole write-up, so it cuts in. The
    /// write-up starts over once the answer is done, ahead of anything that was waiting behind it.
    func testAnInterruptedLaterCallRunsAgainAndItsCallerStillGetsTheValue() async throws {
        let lane = ModelLane()
        let events = Events()
        let attempts = Counter()
        let writeUp = Task {
            try await lane.run(.later) { () async -> String in
                let attempt = await attempts.next()
                await events.add("write-up \(attempt) starts")
                guard attempt == 1 else { return "Summary" }
                // Like a stream cut off early, it hands back what it has so far.
                do { try await Task.sleep(for: .seconds(5)) } catch { await events.add("write-up 1 sees cancellation") }
                return "Half a summary"
            }
        }
        await events.wait(for: "write-up 1 starts")
        let next = Task { try await lane.run(.later) { await events.add("next write-up runs"); return "Next" } }
        await eventually("the next write-up is in line") { await lane.inLine == 1 }
        let answer = Task {
            try await lane.run(.now, interrupting: true) {
                await events.wait(for: "write-up 1 sees cancellation")
                await eventually("the interrupted write-up is back in line") { await lane.inLine == 2 }
                await events.add("answer ends")
                return "Answer"
            }
        }

        let answerText = try await finished(answer)
        let summary = try await finished(writeUp)
        let nextSummary = try await finished(next)
        XCTAssertEqual(answerText, "Answer")
        XCTAssertEqual(summary, "Summary", "the caller gets what the full run returned, never the interrupted one")
        XCTAssertEqual(nextSummary, "Next")
        let log = await events.all
        XCTAssertEqual(log, ["write-up 1 starts", "write-up 1 sees cancellation", "answer ends",
                             "write-up 2 starts", "next write-up runs"])
    }

    func testAThirdInterruptionIsRefused() async throws {
        let lane = ModelLane()
        let events = Events()
        let attempts = Counter()
        let writeUp = Task {
            try await lane.run(.later) { () async throws -> String in
                let attempt = await attempts.next()
                await events.add("write-up \(attempt) starts")
                if attempt <= 2 {
                    do { try await Task.sleep(for: .seconds(5)) } catch {
                        await events.add("write-up \(attempt) sees cancellation")
                        throw error
                    }
                }
                // The third answer has started by now, so a cancellation from it would show here.
                await events.wait(for: "answer 3 starts")
                try Task.checkCancellation()
                await events.add("write-up \(attempt) ends")
                return "Summary"
            }
        }
        for n in 1...2 {
            await events.wait(for: "write-up \(n) starts")
            let answer = try await finished(Task {
                try await lane.run(.now, interrupting: true) {
                    await events.wait(for: "write-up \(n) sees cancellation")
                    await events.add("answer \(n) ends")
                    return n
                }
            })
            XCTAssertEqual(answer, n)
        }
        await events.wait(for: "write-up 3 starts")
        let third = try await finished(Task {
            try await lane.run(.now, interrupting: true) {
                await events.add("answer 3 starts")
                await events.wait(for: "write-up 3 ends")
                await events.add("answer 3 ends")
                return 3
            }
        })

        let summary = try await finished(writeUp)
        XCTAssertEqual(third, 3)
        XCTAssertEqual(summary, "Summary")
        let log = await events.all
        XCTAssertEqual(log, ["write-up 1 starts", "write-up 1 sees cancellation", "answer 1 ends",
                             "write-up 2 starts", "write-up 2 sees cancellation", "answer 2 ends",
                             "write-up 3 starts", "answer 3 starts", "write-up 3 ends", "answer 3 ends"])
    }

    func testALaterCallCancelledWhileInLineNeverRuns() async throws {
        let lane = ModelLane()
        let events = Events()
        let cleanup = Task {
            try await lane.run(.now) {
                await events.add("cleanup starts")
                await events.wait(for: "line is ready")
                return "Clean text"
            }
        }
        await events.wait(for: "cleanup starts")
        var writeUps: [Task<String, Error>] = []
        for name in ["first", "dropped", "last"] {
            writeUps.append(Task { try await lane.run(.later) { await events.add("\(name) runs"); return name } })
            let count = writeUps.count
            await eventually("\(name) is in line") { await lane.inLine == count }
        }
        writeUps[1].cancel()
        await eventually("the cancelled call has left the line") { await lane.inLine == 2 }
        do {
            _ = try await finished(writeUps[1])
            XCTFail("The cancelled call returned")
        } catch is CancellationError {}
        await events.add("line is ready")

        _ = try await finished(cleanup)
        let first = try await finished(writeUps[0])
        let last = try await finished(writeUps[2])
        XCTAssertEqual(first, "first")
        XCTAssertEqual(last, "last")
        let log = await events.all
        XCTAssertEqual(log, ["cleanup starts", "line is ready", "first runs", "last runs"])
    }

    func testALaterCallFromATaskAlreadyCancelledNeverRuns() async throws {
        let lane = ModelLane()
        let events = Events()
        let writeUp = Task {
            await events.wait(for: "caller cancelled")
            return try await lane.run(.later) { await events.add("write-up runs"); return "Summary" }
        }
        writeUp.cancel()
        await events.add("caller cancelled")
        do {
            _ = try await finished(writeUp)
            XCTFail("The cancelled call returned")
        } catch is CancellationError {}

        let next = try await finished(Task { try await lane.run(.later) { "Next" } })
        XCTAssertEqual(next, "Next")
        let log = await events.all
        XCTAssertEqual(log, ["caller cancelled"])
    }

    func testCancellingTheCallerCancelsARunningLaterCall() async throws {
        let lane = ModelLane()
        let events = Events()
        let writeUp = Task {
            try await lane.run(.later) { () async throws -> String in
                await events.add("write-up starts")
                do { try await Task.sleep(for: .seconds(5)) } catch {
                    await events.add("write-up sees cancellation")
                    throw error
                }
                return "Summary"
            }
        }
        await events.wait(for: "write-up starts")
        writeUp.cancel()
        do {
            _ = try await finished(writeUp)
            XCTFail("The cancelled call returned")
        } catch is CancellationError {}

        let next = try await finished(Task { try await lane.run(.later) { "Next" } })
        XCTAssertEqual(next, "Next", "the lane is free again, and the cancelled call didn't run again")
        let log = await events.all
        XCTAssertEqual(log, ["write-up starts", "write-up sees cancellation"])
    }

    func testNoDeadlockWhenACallThrows() async throws {
        let lane = ModelLane()
        let events = Events()
        let cleanup = Task {
            try await lane.run(.now) { () async throws -> String in
                await events.add("cleanup starts")
                await events.wait(for: "write-ups are in line")
                throw ModelDown()
            }
        }
        await events.wait(for: "cleanup starts")
        let failing = Task { try await lane.run(.later) { () async throws -> String in throw ModelDown() } }
        await eventually("the failing write-up is in line") { await lane.inLine == 1 }
        let writeUp = Task { try await lane.run(.later) { "Summary" } }
        await eventually("both write-ups are in line") { await lane.inLine == 2 }
        await events.add("write-ups are in line")

        do {
            _ = try await finished(cleanup)
            XCTFail("The cleanup didn't throw")
        } catch is ModelDown {}
        do {
            _ = try await finished(failing)
            XCTFail("The write-up didn't throw")
        } catch is ModelDown {}
        let summary = try await finished(writeUp)
        XCTAssertEqual(summary, "Summary")
    }
}

private struct ModelDown: Error {}
private struct NeverFinished: Error {}

/// What the fake calls did, in order, and a way to wait until something has happened.
private actor Events {
    private struct Waiter {
        let event: String
        let continuation: CheckedContinuation<Void, Never>
        let timer: Task<Void, Never>
    }

    private(set) var all: [String] = []
    private var waiters: [UUID: Waiter] = [:]

    func add(_ event: String) {
        all.append(event)
        for (id, waiter) in waiters where waiter.event == event {
            waiters[id] = nil
            waiter.timer.cancel()
            waiter.continuation.resume()
        }
    }

    /// Returns once `event` has happened. It gives up after two seconds, so a fake call waiting on a lane that got it
    /// wrong still ends, and the test fails on what it sees.
    func wait(for event: String) async {
        guard !all.contains(event) else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            let timer = Task.detached { [self] in
                try? await Task.sleep(for: .seconds(2))
                await giveUp(id)
            }
            waiters[id] = Waiter(event: event, continuation: continuation, timer: timer)
        }
    }

    private func giveUp(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }
}

/// Counts the times a fake call has started, so it can do something different each time.
private actor Counter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

/// Waits until `condition` holds, looking every millisecond, and fails the test if it doesn't within two seconds.
private func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                        _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while await !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("Never happened: \(what)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// A call's value, waiting at most two seconds for it, so a lane that never lets a call through fails the test instead
/// of hanging the run.
private func finished<T: Sendable>(_ task: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let done = XCTestExpectation(description: "the call finished")
    Task {
        _ = await task.result
        done.fulfill()
    }
    guard await XCTWaiter().fulfillment(of: [done], timeout: 2) == .completed else {
        XCTFail("The call never finished", file: file, line: line)
        throw NeverFinished()
    }
    return try await task.value
}
