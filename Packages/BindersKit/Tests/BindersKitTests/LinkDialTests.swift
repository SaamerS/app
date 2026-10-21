import CryptoKit
import dnssd
import Network
import Security
import XCTest
@testable import BindersKit

/// The parts of the parallel dial that need no Mac: what each failure is called, what the phone says when none
/// answered, and when it may say the Mac forgot this iPhone. The Mac's self-test (--selftest-link) dials a real link.
final class LinkDialTests: XCTestCase {
    private func outcome(_ error: Error, _ network: NWError? = nil, denied: Bool = false, handshaking: Bool = false) -> LinkDial.Outcome {
        LinkDial.outcome(of: error, networkError: network, deniedByLocalNetwork: denied, handshaking: handshaking)
    }

    func testOutcomesFromErrors() {
        let unreachable = LinkClient.Failure.unreachable("The operation couldn't be completed.")
        // Local Network off says so first, whatever else went wrong.
        XCTAssertEqual(outcome(unreachable, .posix(.ECONNREFUSED), denied: true), .notAllowed)
        XCTAssertEqual(outcome(LinkClient.Failure.timedOut, denied: true), .notAllowed)
        XCTAssertEqual(outcome(unreachable, .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))), .notAllowed)
        // The link's own.
        XCTAssertEqual(outcome(LinkClient.Failure.timedOut), .timedOut)
        XCTAssertEqual(outcome(LinkClient.Failure.timedOut, handshaking: true), .noAnswer)
        XCTAssertEqual(outcome(LinkClient.Failure.closed), .closed)
        XCTAssertEqual(outcome(LinkClient.Failure.closed, .posix(.ECONNREFUSED)), .closed)
        // The network's.
        XCTAssertEqual(outcome(unreachable, .posix(.ECONNREFUSED)), .refused)
        for code: POSIXErrorCode in [.ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN, .EADDRNOTAVAIL] {
            XCTAssertEqual(outcome(unreachable, .posix(code)), .unreachable, "\(code)")
        }
        XCTAssertEqual(outcome(unreachable, .posix(.ETIMEDOUT)), .timedOut)
        for code: POSIXErrorCode in [.ECONNRESET, .EPIPE, .ENOTCONN] {
            XCTAssertEqual(outcome(unreachable, .posix(code)), .closed, "\(code)")
        }
        XCTAssertEqual(outcome(unreachable, .dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord))), .notFound)
        XCTAssertEqual(outcome(unreachable, .tls(errSSLHandshakeFail)), .keyRefused)
        XCTAssertEqual(outcome(unreachable, .tls(errSSLClosedAbort)), .keyRefused)
        XCTAssertEqual(outcome(NWError.posix(.ECONNREFUSED)), .refused, "an NWError thrown as it is")
        XCTAssertEqual(outcome(unreachable, .posix(.EPERM)), .failed)
        XCTAssertEqual(outcome(unreachable), .failed)
        XCTAssertEqual(outcome(LinkClient.Failure.rejected("The Mac sent no challenge"), handshaking: true), .failed)
        XCTAssertEqual(LinkDial.Outcome.keyRefused.words, "doesn't know this iPhone")
        XCTAssertTrue(LinkDial.Outcome.timedOut.isFailure)
        XCTAssertFalse(LinkDial.Outcome.answered.isFailure)
        XCTAssertFalse(LinkDial.Outcome.cancelled.isFailure)
    }

    private func attempt(_ name: String, _ outcome: LinkDial.Outcome, opened: Bool = false, vouched: Bool = false) -> LinkDial.Attempt {
        LinkDial.Attempt(id: name == "Bonjour" ? LinkCandidate.bonjourID : "\(name)|7447", name: name, outcome: outcome, opened: opened, vouched: vouched)
    }

    func testTheSummaryNamesAddressesAsTheListDoes() {
        XCTAssertEqual(LinkDial.summary([attempt("192.168.1.20", .timedOut)]), "Tried 1 address: 192.168.1.20 timed out.")
        let three = [attempt("192.168.1.20", .timedOut), attempt("100.64.0.2", .refused), attempt("100.96.0.8", .timedOut)]
        XCTAssertEqual(LinkDial.summary(three), "Tried 3 addresses: 192.168.1.20 timed out, 100.64.0.2 refused, 100.96.0.8 timed out.")
        XCTAssertEqual(LinkDial.summary(three, again: true),
                       "Trying again. Last time: 192.168.1.20 timed out, 100.64.0.2 refused, 100.96.0.8 timed out.")
        let six = [attempt("Bonjour", .notAllowed), attempt("100.64.0.2", .refused), attempt("[fd7a:115c:a1e0::2]:7450", .timedOut),
                   attempt("studio-mac.covee.example", .notFound), attempt("192.168.1.20", .unreachable), attempt("100.96.0.8", .noAnswer),
                   attempt("100.64.0.9", .cancelled)]
        XCTAssertEqual(LinkDial.summary(six),
                       "Tried 6 addresses: Bonjour blocked by Local Network, 100.64.0.2 refused, [fd7a:115c:a1e0::2]:7450 timed out, "
                       + "studio-mac.covee.example not found, and 2 more. Turn on Local Network for Binders in Settings › Privacy & Security.")
        XCTAssertEqual(LinkDial.summary([attempt("192.168.1.20", .notAllowed)], again: true),
                       "Trying again. Last time: 192.168.1.20 blocked by Local Network. Turn on Local Network for Binders in Settings › Privacy & Security.")
    }

    func testNoSummaryOnceOneAnswered() {
        XCTAssertNil(LinkDial.summary([]))
        XCTAssertNil(LinkDial.summary([attempt("192.168.1.20", .timedOut), attempt("100.64.0.2", .answered)]))
        XCTAssertNil(LinkDial.summary([attempt("192.168.1.20", .cancelled)]), "one that was only stopped says nothing")
    }

    func testTheMacForgotThisPhoneOnlyWhenAVouchedTryFailsTheKey() {
        XCTAssertTrue(LinkDial.macForgotThisPhone([attempt("Bonjour", .keyRefused, vouched: true), attempt("192.168.1.20", .timedOut)]))
        XCTAssertTrue(LinkDial.macForgotThisPhone([attempt("100.64.0.2", .keyRefused, vouched: true)]))
        // A stale address from the pairing code, or one typed, could be anything now.
        XCTAssertFalse(LinkDial.macForgotThisPhone([attempt("192.168.1.20", .keyRefused), attempt("100.64.0.2", .timedOut, vouched: true)]))
        // One try got past TLS: it holds this iPhone's key, so the Mac knows it.
        XCTAssertFalse(LinkDial.macForgotThisPhone([attempt("Bonjour", .keyRefused, vouched: true), attempt("100.64.0.2", .noAnswer, opened: true)]))
        XCTAssertFalse(LinkDial.macForgotThisPhone([]))
    }

    /// Two closed ports on this machine: both refused, no winner, each tried once, even when the task that dialled is
    /// cancelled (the phone's connect cancels its own retry task).
    func testADialOfClosedPortsEndsWithEachRefused() async throws {
        let first = try await closedPort(), second = try await closedPort()
        let candidates = [first, second].map { port in
            LinkCandidate(id: "127.0.0.1|\(port)", host: "127.0.0.1", port: port, name: "127.0.0.1:\(port)", label: "Added on this iPhone",
                          source: .added, addedHere: true)
        }
        let started = Date()
        let dialling = Task {
            await LinkDial.dial(candidates, bonjour: nil, identity: UUID().uuidString, key: SymmetricKey(size: .bits256), connect: 2,
                                stagger: 0.25, handshake: 2) { _, _ in [:] }
        }
        dialling.cancel()
        let result = await dialling.value
        XCTAssertNil(result.client)
        XCTAssertNil(result.winner)
        XCTAssertNil(result.rejection)
        XCTAssertEqual(result.attempts.map(\.outcome), [.refused, .refused])
        XCTAssertEqual(result.attempts.map(\.opened), [false, false])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "a refusal starts the next at once")
        XCTAssertEqual(LinkDial.summary(result.attempts), "Tried 2 addresses: 127.0.0.1:\(first) refused, 127.0.0.1:\(second) refused.")
        // Nothing to try is nothing tried.
        let none = await LinkDial.dial([], bonjour: nil, identity: "x", key: SymmetricKey(size: .bits256), connect: 1, stagger: 0.25,
                                       handshake: 1, prove: nil)
        XCTAssertEqual(none.attempts, [])
        // Bonjour without an endpoint isn't found, and the next goes.
        let bonjour = LinkCandidate(id: LinkCandidate.bonjourID, host: nil, port: 7447, name: "Bonjour", label: "On this network",
                                    source: .bonjour, vouched: true, atOnce: true)
        let missing = await LinkDial.dial([bonjour, candidates[0]], bonjour: nil, identity: "x", key: SymmetricKey(size: .bits256), connect: 2,
                                          stagger: 5, handshake: 2, prove: nil)
        XCTAssertEqual(missing.attempts.map(\.outcome), [.notFound, .refused])
    }

    /// A port nothing listens on: one a listener had a moment ago.
    private func closedPort() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let port: UInt16 = await withCheckedContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed, .cancelled: if once.claim() { continuation.resume(returning: 0) }
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "closed-port"))
        }
        listener.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        return try XCTUnwrap(port == 0 ? nil : port)
    }
}

/// True the first time only, from any queue.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
