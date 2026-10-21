import CryptoKit
import dnssd
import Foundation
import Network

/// Reaching the Mac at every address the phone knows, together: Bonjour and the last good address at once, the rest a
/// stagger apart (at once when the one before fails). Every connection that opens asks for a challenge straight away;
/// the first whose challenge is answered says hello and subscribes, signing its own challenge, and every other try is
/// closed. One hello at a time, so a Mac sees one hello and one subscribe per connect. The phone connects with it, the
/// Mac's self-test plays the phone with it, and it's Your Mac's Test.
public enum LinkDial {
    /// What became of one address.
    public enum Outcome: String, Sendable {
        case answered, timedOut, refused, unreachable, notFound, keyRefused, notAllowed, noAnswer, closed, failed, cancelled

        /// As a list says it, after the address: "192.168.1.20 timed out".
        public var words: String {
            switch self {
            case .answered: "answered"
            case .timedOut: "timed out"
            case .refused: "refused"
            case .unreachable: "unreachable"
            case .notFound: "not found"
            case .keyRefused: "doesn't know this iPhone"
            case .notAllowed: "blocked by Local Network"
            case .noAnswer: "didn't answer"
            case .closed: "closed the connection"
            case .failed: "couldn't connect"
            case .cancelled: "stopped"
            }
        }

        /// Not answered, and not stopped because another one answered.
        public var isFailure: Bool { self != .answered && self != .cancelled }
    }

    /// One address tried.
    public struct Attempt: Equatable, Sendable {
        public var id: String
        public var name: String
        public var outcome: Outcome
        /// TLS finished: whatever is at this address holds this iPhone's key, so it's this Mac.
        public var opened: Bool
        /// From the candidate: Bonjour, an address the Mac listed, or the last good one.
        public var vouched: Bool

        public init(id: String, name: String, outcome: Outcome, opened: Bool = false, vouched: Bool = false) {
            self.id = id
            self.name = name
            self.outcome = outcome
            self.opened = opened
            self.vouched = vouched
        }
    }

    public struct Result: @unchecked Sendable {
        /// The winner, connected, its handshake done; nil if none.
        public var client: LinkClient?
        public var winner: LinkCandidate?
        /// What the winner's handshake returned (the hello reply).
        public var reply: [String: Any]
        /// One per candidate started, in candidate order.
        public var attempts: [Attempt]
        /// The Mac turned the hello down: its words.
        public var rejection: String?
    }

    /// Tries `candidates` as above. `connect` bounds each address's connection from its own start, `handshake` each
    /// try's challenge. `prove` is the rest of the handshake for the one try that goes, given that connection and its
    /// own challenge; nil, the first challenge answered wins (Test). The caller's cancellation is ignored: the phone's
    /// connect runs inside a task it may cancel itself.
    public static func dial(_ candidates: [LinkCandidate], bonjour: NWEndpoint?, identity: String, key: SymmetricKey,
                            connect: TimeInterval, stagger: TimeInterval, handshake: TimeInterval,
                            prove: (@Sendable (LinkClient, Data) async throws -> [String: Any])?) async -> Result {
        guard !candidates.isEmpty else { return Result(client: nil, winner: nil, reply: [:], attempts: [], rejection: nil) }
        let race = DialRace(candidates: candidates, bonjour: bonjour, identity: identity, key: key, connect: connect,
                            stagger: stagger, handshake: handshake, prove: prove)
        return await withCheckedContinuation { continuation in race.begin(continuation) }
    }

    /// What an error from one try means, in the words a list says: the Local Network setting first, then the link's
    /// own failures, then the network's.
    public static func outcome(of error: Error, networkError: NWError?, deniedByLocalNetwork: Bool, handshaking: Bool) -> Outcome {
        if deniedByLocalNetwork { return .notAllowed }
        if case .dns(let code)? = networkError ?? (error as? NWError), code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
            return .notAllowed
        }
        if let failure = error as? LinkClient.Failure {
            switch failure {
            case .timedOut: return handshaking ? .noAnswer : .timedOut
            case .closed: return .closed
            case .unreachable, .rejected: break
            }
        }
        guard let network = networkError ?? (error as? NWError) else { return .failed }
        switch network {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .refused
            case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN, .EADDRNOTAVAIL: return .unreachable
            case .ETIMEDOUT: return .timedOut
            case .ECONNRESET, .EPIPE, .ENOTCONN: return .closed
            default: return .failed
            }
        case .dns: return .notFound
        // The pre-shared key didn't match: whatever is there doesn't hold this iPhone's key.
        case .tls: return .keyRefused
        default: return .failed
        }
    }

    /// "Tried 3 addresses: 192.168.1.20 timed out, 100.64.0.2 refused, 100.96.0.8 timed out." With `again` (a new dial
    /// is on its way): "Trying again. Last time: 192.168.1.20 timed out, …". Either way, when any was blocked by Local
    /// Network, how to turn it on. Nil when there's nothing to say, or once one answered.
    public static func summary(_ attempts: [Attempt], again: Bool = false) -> String? {
        guard !attempts.contains(where: { $0.outcome == .answered }) else { return nil }
        let listed = attempts.filter { $0.outcome != .cancelled }
        guard !listed.isEmpty else { return nil }
        var parts = listed.prefix(4).map { "\($0.name) \($0.outcome.words)" }
        if listed.count > 4 { parts.append("and \(listed.count - 4) more") }
        var text = again ? "Trying again. Last time: " : "Tried \(listed.count) \(listed.count == 1 ? "address" : "addresses"): "
        text += parts.joined(separator: ", ") + "."
        if listed.contains(where: { $0.outcome == .notAllowed }) {
            text += " Turn on Local Network for Binders in Settings › Privacy & Security."
        }
        return text
    }

    /// No try got past TLS, and Bonjour, an address the Mac listed or the last good one failed the key: the Mac doesn't
    /// know this iPhone any more. A stale or typed address failing the key says nothing, as anything could be there now.
    public static func macForgotThisPhone(_ attempts: [Attempt]) -> Bool {
        !attempts.contains(where: \.opened) && attempts.contains { $0.vouched && $0.outcome == .keyRefused }
    }
}

/// One dial's state, behind a lock: which tries started, how each ended, the ones whose challenge was answered waiting
/// their turn to say hello, and the one saying it.
private final class DialRace: @unchecked Sendable {
    typealias Prove = @Sendable (LinkClient, Data) async throws -> [String: Any]

    private let lock = NSLock()
    private let candidates: [LinkCandidate]
    private let bonjour: NWEndpoint?
    private let identity: String
    private let key: SymmetricKey
    private let connectTimeout: TimeInterval
    private let stagger: TimeInterval
    private let handshake: TimeInterval
    private let prove: Prove?

    private var started: Set<Int> = []
    private var clients: [Int: LinkClient] = [:]
    private var outcomes: [Int: LinkDial.Outcome] = [:]
    private var opened: Set<Int> = []
    /// Tries connecting or waiting for their challenge.
    private var trying = 0
    /// Tries whose challenge was answered, in the order they were, waiting to say hello.
    private var answered: [(index: Int, nonce: Data)] = []
    private var proving: Int?
    private var done = false
    private var winner: Int?
    private var reply: [String: Any] = [:]
    private var rejection: String?
    private var timer: Task<Void, Never>?
    private var continuation: CheckedContinuation<LinkDial.Result, Never>?

    init(candidates: [LinkCandidate], bonjour: NWEndpoint?, identity: String, key: SymmetricKey, connect: TimeInterval,
         stagger: TimeInterval, handshake: TimeInterval, prove: Prove?) {
        self.candidates = candidates
        self.bonjour = bonjour
        self.identity = identity
        self.key = key
        connectTimeout = connect
        self.stagger = stagger
        self.handshake = handshake
        self.prove = prove
    }

    func begin(_ continuation: CheckedContinuation<LinkDial.Result, Never>) {
        var launches: [(Int, LinkClient)] = []
        var result: LinkDial.Result?
        lock.withLock {
            self.continuation = continuation
            let atOnce = candidates.indices.filter { candidates[$0].atOnce }
            for index in atOnce.isEmpty ? [0] : atOnce {
                if let client = register(index) { launches.append((index, client)) }
            }
            // Bonjour gone from the browser meanwhile: the next one goes now.
            if launches.isEmpty, let next = registerNext() { launches.append(next) }
            result = finishIfNothingLeft()
            if result == nil, started.count < candidates.count { startTimer() }
        }
        for (index, client) in launches { launch(index, client) }
        if let result { resume(result, closing: []) }
    }

    // MARK: Starting (under the lock)

    /// Makes the try for one candidate and counts it, unless the dial is over.
    private func register(_ index: Int) -> LinkClient? {
        guard !done, !started.contains(index) else { return nil }
        started.insert(index)
        let candidate = candidates[index]
        let client: LinkClient
        if let host = candidate.host {
            client = LinkClient(host: host, port: candidate.port, identity: identity, key: key)
        } else if let bonjour {
            client = LinkClient(endpoint: bonjour, identity: identity, key: key)
        } else {
            outcomes[index] = .notFound
            return nil
        }
        clients[index] = client
        trying += 1
        return client
    }

    /// The next candidate not started yet, started.
    private func registerNext() -> (Int, LinkClient)? {
        while !done, let index = candidates.indices.first(where: { !started.contains($0) }) {
            if let client = register(index) { return (index, client) }
        }
        return nil
    }

    /// One more every `stagger`. It checks the dial isn't over and starts its try in one locked step, so a try started
    /// just after the winner is always closed with the others.
    private func startTimer() {
        let stagger = max(stagger, 0.01)
        timer = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(stagger * 1_000_000_000))
                guard let self else { return }
                let next: (Int, LinkClient)?? = self.lock.withLock {
                    guard !self.done, self.started.count < self.candidates.count else { return .some(nil) }
                    return .some(self.registerNext())
                }
                guard let launch = next ?? nil else { return }
                self.launch(launch.0, launch.1)
            }
        }
    }

    private func launch(_ index: Int, _ client: LinkClient) {
        Task { await self.run(index, client) }
    }

    // MARK: A try

    private func run(_ index: Int, _ client: LinkClient) async {
        do {
            try await client.connect(timeout: connectTimeout)
        } catch {
            failed(index, client, error, handshaking: false)
            return
        }
        let goesOn: Bool = lock.withLock {
            guard !done else { return false }
            opened.insert(index)
            return true
        }
        guard goesOn else { return client.close() }
        do {
            let nonce = try await client.challenge(timeout: handshake)
            challengeAnswered(index, client, nonce)
        } catch {
            failed(index, client, error, handshaking: true)
        }
    }

    /// Connecting or the challenge failed: recorded, closed, and the next candidate starts at once.
    private func failed(_ index: Int, _ client: LinkClient, _ error: Error, handshaking: Bool) {
        let outcome = LinkDial.outcome(of: error, networkError: client.networkError, deniedByLocalNetwork: client.deniedByLocalNetwork,
                                       handshaking: handshaking)
        client.close()
        var launches: [(Int, LinkClient)] = []
        var result: LinkDial.Result?
        lock.withLock {
            // Late: closed by the dial, which has already said how it ended.
            guard !done else { return }
            outcomes[index] = outcome
            trying -= 1
            if let next = registerNext() { launches.append(next) }
            result = finishIfNothingLeft()
        }
        for (next, nextClient) in launches { launch(next, nextClient) }
        if let result { resume(result, closing: []) }
    }

    private func challengeAnswered(_ index: Int, _ client: LinkClient, _ nonce: Data) {
        var late = false
        var won: (closing: [LinkClient], result: LinkDial.Result)?
        var proveNow: (Int, LinkClient, Data)?
        lock.withLock {
            guard !done else {
                late = true
                return
            }
            trying -= 1
            guard prove != nil else {
                // Test: the first answered wins.
                won = win(index, reply: [:])
                return
            }
            answered.append((index, nonce))
            proveNow = nextToProve()
        }
        if late { return client.close() }
        if let won { return resume(won.result, closing: won.closing) }
        if let proveNow { runProve(proveNow.0, proveNow.1, proveNow.2) }
    }

    // MARK: Saying hello, one at a time

    /// The head of the queue, when nobody is saying hello (under the lock).
    private func nextToProve() -> (Int, LinkClient, Data)? {
        guard proving == nil, !answered.isEmpty else { return nil }
        let head = answered.removeFirst()
        guard let client = clients[head.index] else { return nil }
        proving = head.index
        return (head.index, client, head.nonce)
    }

    private func runProve(_ index: Int, _ client: LinkClient, _ nonce: Data) {
        guard let prove else { return }
        Task {
            do {
                let reply = try await prove(client, nonce)
                self.proved(index, reply)
            } catch LinkClient.Failure.rejected(let message) {
                self.rejected(index, message)
            } catch {
                self.proveFailed(index, client, error)
            }
        }
    }

    private func proved(_ index: Int, _ reply: [String: Any]) {
        var won: (closing: [LinkClient], result: LinkDial.Result)?
        lock.withLock {
            guard !done else { return }
            won = win(index, reply: reply)
        }
        if let won { resume(won.result, closing: won.closing) }
    }

    /// The Mac itself said no: every path leads to the same Mac, so the dial ends with its words.
    private func rejected(_ index: Int, _ message: String) {
        var closing: [LinkClient] = []
        var result: LinkDial.Result?
        lock.withLock {
            guard !done else { return }
            done = true
            rejection = message
            // It was reached, and said no.
            outcomes[index] = .answered
            for (other, client) in clients {
                if outcomes[other] == nil { outcomes[other] = .cancelled }
                closing.append(client)
            }
            answered.removeAll()
            timer?.cancel()
            result = makeResult()
        }
        if let result { resume(result, closing: closing) }
    }

    /// Its hello or subscribe failed on its own (timed out, closed): the next waiting says hello.
    private func proveFailed(_ index: Int, _ client: LinkClient, _ error: Error) {
        let outcome = LinkDial.outcome(of: error, networkError: client.networkError, deniedByLocalNetwork: client.deniedByLocalNetwork,
                                       handshaking: true)
        client.close()
        var launches: [(Int, LinkClient)] = []
        var proveNow: (Int, LinkClient, Data)?
        var result: LinkDial.Result?
        lock.withLock {
            guard !done else { return }
            outcomes[index] = outcome
            proving = nil
            proveNow = nextToProve()
            if let next = registerNext() { launches.append(next) }
            if proveNow == nil { result = finishIfNothingLeft() }
        }
        for (next, nextClient) in launches { launch(next, nextClient) }
        if let proveNow { runProve(proveNow.0, proveNow.1, proveNow.2) }
        if let result { resume(result, closing: []) }
    }

    // MARK: Ending (under the lock, then resume outside it)

    private func win(_ index: Int, reply: [String: Any]) -> (closing: [LinkClient], result: LinkDial.Result) {
        done = true
        winner = index
        self.reply = reply
        var closing: [LinkClient] = []
        for (other, client) in clients where other != index {
            if outcomes[other] == nil { outcomes[other] = .cancelled }
            closing.append(client)
        }
        answered.removeAll()
        timer?.cancel()
        return (closing, makeResult())
    }

    /// Every candidate started, none connecting or asking, none waiting or saying hello: no winner.
    private func finishIfNothingLeft() -> LinkDial.Result? {
        guard !done, started.count == candidates.count, trying == 0, answered.isEmpty, proving == nil else { return nil }
        done = true
        timer?.cancel()
        return makeResult()
    }

    private func makeResult() -> LinkDial.Result {
        let attempts = started.sorted().map { index in
            LinkDial.Attempt(id: candidates[index].id, name: candidates[index].name,
                             outcome: index == winner ? .answered : outcomes[index] ?? .cancelled,
                             opened: opened.contains(index), vouched: candidates[index].vouched)
        }
        return LinkDial.Result(client: winner.flatMap { clients[$0] }, winner: winner.map { candidates[$0] }, reply: reply,
                               attempts: attempts, rejection: rejection)
    }

    private func resume(_ result: LinkDial.Result, closing: [LinkClient]) {
        for client in closing { client.close() }
        let waiting: CheckedContinuation<LinkDial.Result, Never>? = lock.withLock {
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(returning: result)
    }
}
