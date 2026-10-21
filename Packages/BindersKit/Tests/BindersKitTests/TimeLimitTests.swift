import Foundation
import XCTest
@testable import BindersKit

/// The time limits the iPhone puts on waiting: one budget shared by the steps of a dictation's cleanup, and work given
/// up on at its limit, even work that doesn't stop when asked. Timings are loose, as other work may share the machine.
final class TimeLimitTests: XCTestCase {
    /// Waits `seconds` without looking at cancellation, like a model that doesn't stop when asked.
    private static func stubborn(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> TimeInterval { start.duration(to: .now) / .seconds(1) }

    func testTheBudgetShrinksAndNeverGoesBelowZero() async throws {
        let budget = TimeBudget(seconds: 1)
        XCTAssertGreaterThan(budget.left, 0.5)
        XCTAssertLessThanOrEqual(budget.left, 1)
        XCTAssertEqual(budget.left(atMost: 0.1), 0.1, accuracy: 0.0001)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(budget.left, 0)
        XCTAssertEqual(budget.left(atMost: 2), 0)
        XCTAssertEqual(TimeBudget(seconds: -1).left, 0)
    }

    func testWorkInTimeGivesItsResult() async throws {
        let value = try await TimeLimit.run(within: 2) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testWorkThatFailsInTimeGivesItsError() async {
        struct Broke: Error {}
        do {
            _ = try await TimeLimit.run(within: 2) { () async throws -> Int in throw Broke() }
            XCTFail("It didn't fail")
        } catch {
            XCTAssertTrue(error is Broke, "\(error)")
        }
    }

    func testSlowWorkIsGivenUpAtTheLimitAndCancelled() async {
        let start = ContinuousClock.now
        let cancelled = expectation(description: "the work is told to stop")
        do {
            _ = try await TimeLimit.run(within: 0.3) { () async throws -> Int in
                do { try await Task.sleep(for: .seconds(10)) } catch { cancelled.fulfill() }
                return 1
            }
            XCTFail("It didn't give up")
        } catch {
            XCTAssertEqual(error as? TimeLimit.Exceeded, TimeLimit.Exceeded())
        }
        XCTAssertLessThan(Self.elapsed(since: start), 2, "It waited past the limit")
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testWorkThatIgnoresCancellationDoesntHoldTheCallerUp() async {
        let start = ContinuousClock.now
        let result = try? await TimeLimit.run(within: 0.3) { () async -> Int in
            await Self.stubborn(4)
            return 1
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Self.elapsed(since: start), 2.5, "It waited for work that wouldn't stop")
    }

    func testNoTimeMeansTheWorkNeverStarts() async {
        let started = Flag()
        let result = try? await TimeLimit.run(within: 0) { () async -> Int in
            started.set()
            return 1
        }
        XCTAssertNil(result)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(started.isSet)
    }

    func testCancellingTheCallerGivesUpAtOnce() async {
        let start = ContinuousClock.now
        let task = Task { try await TimeLimit.run(within: 10) { () async -> Int in
            await Self.stubborn(4)
            return 1
        } }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.result
        XCTAssertTrue((try? result.get()) == nil)
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(Self.elapsed(since: start), 2.5)
    }

    // MARK: A dictation's cleanup

    private let raw = "um so send the pricing deck to Sam by thursday"

    func testTheMacCleansUpWhenItAnswersInTime() async {
        let result = await DictationCleanup.run(raw, app: "Binders", budget: TimeBudget(seconds: 2),
                                                mac: { _ in ("So, send the pricing deck to Sam by Thursday.", "gemma4:26b") },
                                                device: { _, _ in "never asked" })
        XCTAssertEqual(result.cleaner, .mac(model: "gemma4:26b"))
        XCTAssertEqual(result.text, "So, send the pricing deck to Sam by Thursday.")
    }

    func testThisDevicesModelWhenTheMacIsOutOfReach() async {
        let result = await DictationCleanup.run(raw, app: "Binders", budget: TimeBudget(seconds: 2), mac: { _ in nil },
                                                device: { _, _ in "So send the pricing deck to Sam by Thursday." })
        XCTAssertEqual(result.cleaner, .device)
        XCTAssertEqual(result.text, "So send the pricing deck to Sam by Thursday.")
    }

    func testAnEmptyAnswerFromTheMacIsntUsed() async {
        let result = await DictationCleanup.run(raw, app: "Binders", budget: TimeBudget(seconds: 2), mac: { _ in ("", "") },
                                                device: { _, _ in "So send the pricing deck to Sam by Thursday." })
        XCTAssertEqual(result.cleaner, .device)
    }

    func testBindersRulesWithoutAModel() async {
        let result = await DictationCleanup.run(raw, app: "Binders", budget: TimeBudget(seconds: 2), mac: { _ in nil }, device: nil)
        XCTAssertEqual(result.cleaner, .rules)
        XCTAssertFalse(result.text.lowercased().hasPrefix("um"), result.text)
        XCTAssertTrue(result.text.contains("pricing deck"), result.text)
    }

    func testASlowMacUsesTheBudgetAndNothingElseWaits() async {
        let start = ContinuousClock.now
        let asked = Flag()
        let result = await DictationCleanup.run(raw, app: "Binders", budget: TimeBudget(seconds: 0.6),
                                                mac: { budget in
                                                    // The link's request times out with the budget.
                                                    try? await Task.sleep(for: .seconds(budget.left))
                                                    return nil
                                                },
                                                device: { _, _ in
                                                    asked.set()
                                                    return "So send the pricing deck to Sam by Thursday."
                                                })
        XCTAssertEqual(result.cleaner, .outOfTime(mac: true))
        XCTAssertFalse(asked.isSet, "The device's model was asked with no time left")
        XCTAssertFalse(result.text.lowercased().hasPrefix("um"), result.text)
        XCTAssertLessThan(Self.elapsed(since: start), 2)
    }

    func testASlowDeviceModelGetsOnlyWhatsLeft() async {
        let start = ContinuousClock.now
        let result = await DictationCleanup.run(raw, app: "Binders", budget: TimeBudget(seconds: 1.2),
                                                mac: { _ in
                                                    // Waiting for a link that doesn't come.
                                                    try? await Task.sleep(for: .milliseconds(400))
                                                    return nil
                                                },
                                                device: { _, _ in
                                                    await Self.stubborn(5)
                                                    return "So send the pricing deck to Sam by Thursday."
                                                })
        XCTAssertEqual(result.cleaner, .outOfTime(mac: false))
        XCTAssertTrue(result.text.contains("pricing deck"), result.text)
        let took = Self.elapsed(since: start)
        XCTAssertGreaterThan(took, 1.0, "It gave up before the budget was spent")
        XCTAssertLessThan(took, 3, "The whole cleanup went past its budget")
    }

    func testAQuickDeviceModelAfterAWaitForTheLink() async {
        let result = await DictationCleanup.run(raw, app: "Binders", budget: TimeBudget(seconds: 2),
                                                mac: { _ in
                                                    try? await Task.sleep(for: .milliseconds(300))
                                                    return nil
                                                },
                                                device: { _, _ in
                                                    try await Task.sleep(for: .milliseconds(100))
                                                    return "So send the pricing deck to Sam by Thursday."
                                                })
        XCTAssertEqual(result.cleaner, .device)
    }
}

/// Set once, read from anywhere.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
