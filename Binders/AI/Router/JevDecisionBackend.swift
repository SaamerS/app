import Darwin
import Foundation
import Network
import BindersKit

// A decision server on this Mac (Settings → AI → Decision model → Use a Decision Server on This Mac…): Laya, Kev and
// OpenJev come with servers that speak the Jev API. Binders reaches one only at this Mac's own loopback addresses, sends it
// no key, and never starts, stops or installs it. The address rule, the requests and the answers' mapping are BindersKit's
// (LoopbackRule, JevAPI); the connection and the backend are here.

/// Where a decision server is reached: a loopback number and the port, so nothing is looked up between the check of
/// where localhost leads and the connection.
struct LoopbackEndpoint: Equatable, Sendable {
    var address: LoopbackRule.Resolved
    var port: Int

    static let ipv4Loopback: LoopbackRule.Resolved = .ipv4([127, 0, 0, 1])
    static let ipv6Loopback: LoopbackRule.Resolved = .ipv6(Array(repeating: 0, count: 15) + [1], interface: nil)

    /// As Network.framework takes it; nil for a number that isn't one.
    var network: NWEndpoint? {
        guard (1...65_535).contains(port), let port = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        switch address {
        case .ipv4(let bytes):
            guard bytes.count == 4, let ip = IPv4Address(Data(bytes)) else { return nil }
            return .hostPort(host: .ipv4(ip), port: port)
        case .ipv6(let bytes, let interface):
            // A link-local address keeps its scope (fe80::1%lo0), which only its text carries.
            guard bytes.count == 16, let ip = interface == nil ? IPv6Address(Data(bytes)) : IPv6Address(address.display) else { return nil }
            return .hostPort(host: .ipv6(ip), port: port)
        }
    }
}

/// One HTTP/1.1 exchange with a decision server on this Mac, over Network.framework on the loopback interface only and
/// with no proxy, to the number LoopbackRule allowed: Connection: close, no cookie, no key, no redirect followed, at most
/// 1 MB. URLSession isn't used: it follows the system's proxy settings and redirects, and keeps cookies.
enum LoopbackHTTP {
    struct Response: Equatable, Sendable {
        var status: Int
        var body: Data
    }

    /// What went wrong before an answer could be read.
    enum Failure: Error, Equatable, Sendable {
        /// Nothing listens there: the connection was refused (NWConnection waiting, or failing before it was ready).
        case refused
        /// It wasn't accepted within the connect limit.
        case connectTimedOut
        /// No whole answer by the deadline.
        case timedOut
        /// Its deadline came while it waited in line behind another exchange: nothing was asked of the server.
        case busy
        /// localhost wasn't looked up in time, or an earlier lookup still hasn't come back.
        case lookupSlow
        /// localhost leads somewhere that isn't this Mac's loopback: the refusal's words.
        case elsewhere(String)
        /// The connection ended before a whole answer.
        case closed
        /// A redirect, never followed.
        case redirect(Int)
        /// An answer over 1 MB, or headers over 64 KB.
        case tooLarge
        /// Not an HTTP answer.
        case malformed
        /// The backend was switched away from, or Binders is quitting.
        case retired
    }

    /// The most of an answer's body read, and of its headers.
    static let maxBody = JevAPI.maxAnswer
    static let maxHead = 64 * 1024

    // MARK: Looking up localhost

    /// A lookup that blocks: the addresses a name gives, as getaddrinfo gives them (AF_UNSPEC, SOCK_STREAM).
    typealias Resolver = @Sendable (String) -> [LoopbackRule.Resolved]

    static let systemResolver: Resolver = { name in
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var found: [LoopbackRule.Resolved] = []
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let info = next {
            if let socket = info.pointee.ai_addr {
                switch Int32(socket.pointee.sa_family) {
                case AF_INET:
                    socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                        var number = address.pointee.sin_addr
                        found.append(.ipv4(withUnsafeBytes(of: &number) { Array($0) }))
                    }
                case AF_INET6:
                    socket.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { address in
                        var number = address.pointee.sin6_addr
                        var interface: String?
                        if address.pointee.sin6_scope_id != 0 {
                            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                            if if_indextoname(address.pointee.sin6_scope_id, &name) != nil { interface = String(cString: name) }
                        }
                        found.append(.ipv6(withUnsafeBytes(of: &number) { Array($0) }, interface: interface))
                    }
                default:
                    break
                }
            }
            next = info.pointee.ai_next
        }
        var unique: [LoopbackRule.Resolved] = []
        for address in found where !unique.contains(address) { unique.append(address) }
        return unique
    }

    /// A name looked up on a thread of its own, never the cooperative pool or an actor: getaddrinfo blocks and knows
    /// nothing of deadlines. Nil when it hasn't come back `within`; it's then left to finish on its own, and its answer is
    /// dropped. `ended` runs once the lookup itself has come back, in time or not.
    static func resolve(_ name: String, using resolver: @escaping Resolver, within: Duration,
                        ended: @escaping @Sendable () -> Void) async -> [LoopbackRule.Resolved]? {
        guard within > .zero else {
            ended()
            return nil
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            let thread = Thread {
                let found = resolver(name)
                ended()
                if once.first() { continuation.resume(returning: found) }
            }
            thread.name = "io.binders.decision-server.lookup"
            thread.start()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds(within)) {
                if once.first() { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: The exchange

    /// Connections made since launch, for the self-test: none may be made to an address the rule refused.
    static var connections: Int { made.value }
    private static let made = Counter()

    /// One request and its answer, by `deadline`: connected within `connectWithin` (a refused connection fails at once),
    /// the request written in one send, the answer read by its Content-Length, chunked, or until the connection closes.
    /// The caller's cancellation, and the deadline, end it and its connection; the server may go on working.
    static func exchange(_ method: String, path: String, body: Data?, to endpoint: LoopbackEndpoint, host: String,
                         connectWithin: Duration = .milliseconds(500), by deadline: ContinuousClock.Instant) async throws -> Response {
        let left = ContinuousClock.now.duration(to: deadline)
        guard left > .zero else { throw Failure.timedOut }
        guard let target = endpoint.network else { throw Failure.refused }
        let parameters = NWParameters.tcp
        // The system may open it on the loopback interface only, and no proxy, PAC file or VPN setting can route it.
        parameters.requiredInterfaceType = .loopback
        parameters.preferNoProxies = true
        let connection = NWConnection(to: target, using: parameters)
        made.add()
        let exchange = Exchange(connection: connection, request: request(method, path: path, host: host, body: body))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.start(continuation, connectWithin: min(connectWithin, left), within: left)
            }
        } onCancel: {
            exchange.finish(.failure(CancellationError()))
        }
    }

    /// The request's bytes: no Authorization, no Cookie, ever.
    static func request(_ method: String, path: String, host: String, body: Data?) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nAccept: application/json\r\n"
        if let body { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        head += "Connection: close\r\nUser-Agent: Binders\r\n\r\n"
        return Data(head.utf8) + (body ?? Data())
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

extension LoopbackHTTP {
    /// An answer read as it comes: the status line and headers, then the body by its Content-Length, chunked, or until
    /// the connection closes. A 1xx is passed over; a 3xx is a failure, never followed.
    struct Reader {
        enum Step: Equatable {
            case more
            case done(Response)
            case failed(Failure)
        }

        private struct Head {
            var status: Int
            var length: Int?
            var chunked: Bool
        }

        private var buffer = Data()
        private var head: Head?
        private static let lineEnd = Data("\r\n".utf8)
        private static let headEnd = Data("\r\n\r\n".utf8)

        /// More bytes, and whether the connection has ended.
        mutating func read(_ data: Data, ended: Bool) -> Step {
            buffer.append(data)
            while head == nil {
                guard let end = buffer.range(of: Self.headEnd) else {
                    if buffer.count > LoopbackHTTP.maxHead { return .failed(.tooLarge) }
                    return ended ? .failed(buffer.isEmpty ? .closed : .malformed) : .more
                }
                guard let parsed = Self.head(String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)) else { return .failed(.malformed) }
                buffer = Data(buffer[end.upperBound...])
                if (100..<200).contains(parsed.status) { continue }
                if (300..<400).contains(parsed.status) { return .failed(.redirect(parsed.status)) }
                head = parsed
            }
            guard let head else { return .more }
            if head.chunked {
                switch Self.dechunk(buffer) {
                case .none: return .failed(.malformed)
                case .some(let found):
                    if found.body.count > LoopbackHTTP.maxBody { return .failed(.tooLarge) }
                    if found.complete { return .done(Response(status: head.status, body: found.body)) }
                    return ended ? .failed(.closed) : .more
                }
            }
            if let length = head.length {
                guard length <= LoopbackHTTP.maxBody else { return .failed(.tooLarge) }
                if buffer.count >= length { return .done(Response(status: head.status, body: Data(buffer.prefix(length)))) }
                return ended ? .failed(.closed) : .more
            }
            if buffer.count > LoopbackHTTP.maxBody { return .failed(.tooLarge) }
            return ended ? .done(Response(status: head.status, body: buffer)) : .more
        }

        /// "HTTP/1.1 200 OK" and the headers that frame the body.
        private static func head(_ text: String) -> Head? {
            let lines = text.components(separatedBy: "\r\n")
            let status = lines.first?.split(separator: " ", omittingEmptySubsequences: true)
            guard let status, status.count >= 2, status[0].hasPrefix("HTTP/"), let code = Int(status[1]), (100...599).contains(code) else { return nil }
            var length: Int?, chunked = false
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased(), value = parts[1].trimmingCharacters(in: .whitespaces)
                if name == "content-length" {
                    guard let found = Int(value), found >= 0 else { return nil }
                    length = found
                } else if name == "transfer-encoding" {
                    chunked = value.lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "chunked" }
                }
            }
            return Head(status: code, length: chunked ? nil : length, chunked: chunked)
        }

        /// A chunked body as far as it has come: the bytes so far, and whether the last chunk has come. Nil when it isn't
        /// chunked properly. Trailers after the last chunk aren't read: the connection closes after the answer anyway.
        static func dechunk(_ data: Data) -> (body: Data, complete: Bool)? {
            let bytes = [UInt8](data)
            var index = 0
            var body = Data()
            while true {
                guard let end = find(lineEnd: bytes, from: index) else { return (body, false) }
                let size = String(decoding: bytes[index..<end], as: UTF8.self).split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                // A size over the most an answer may be is refused before any arithmetic: `start + count` would
                // otherwise overflow, which ends the process, for a size near Int.max.
                guard let count = Int(size, radix: 16), (0...LoopbackHTTP.maxBody).contains(count) else { return nil }
                let start = end + 2
                if count == 0 { return (body, true) }
                guard bytes.count >= start + count + 2 else { return (body, false) }
                body.append(contentsOf: bytes[start..<(start + count)])
                guard bytes[start + count] == 13, bytes[start + count + 1] == 10 else { return nil }
                index = start + count + 2
                if body.count > LoopbackHTTP.maxBody { return (body, false) }
            }
        }

        private static func find(lineEnd bytes: [UInt8], from start: Int) -> Int? {
            var index = start
            while index + 1 < bytes.count {
                if bytes[index] == 13, bytes[index + 1] == 10 { return index }
                index += 1
            }
            return nil
        }
    }
}

/// One connection's exchange, on its own serial queue: its continuation resumed once, by the answer, a failure, the
/// connect limit, the deadline or the caller's cancellation, whichever comes first, and the connection cancelled then.
private final class Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.binders.decision-server.exchange")
    private let request: Data
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LoopbackHTTP.Response, Error>?
    private var outcome: Result<LoopbackHTTP.Response, Error>?
    /// Touched on `queue` only.
    private var ready = false
    private var reader = LoopbackHTTP.Reader()

    init(connection: NWConnection, request: Data) {
        self.connection = connection
        self.request = request
    }

    func start(_ continuation: CheckedContinuation<LoopbackHTTP.Response, Error>, connectWithin: Duration, within: Duration) {
        lock.lock()
        if let outcome {
            // Cancelled before it began.
            lock.unlock()
            return continuation.resume(with: outcome)
        }
        self.continuation = continuation
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in self?.changed(state) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + LoopbackHTTP.seconds(connectWithin)) { [weak self] in
            guard let self, !self.ready else { return }
            self.finish(.failure(LoopbackHTTP.Failure.connectTimedOut))
        }
        queue.asyncAfter(deadline: .now() + LoopbackHTTP.seconds(within)) { [weak self] in
            self?.finish(.failure(LoopbackHTTP.Failure.timedOut))
        }
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { return self.finish(.failure(LoopbackHTTP.Failure.closed)) }
                self.receive()
            })
        case .waiting:
            // What a refused connection turns into: refused at once, never a wait.
            finish(.failure(LoopbackHTTP.Failure.refused))
        case .failed:
            finish(.failure(ready ? LoopbackHTTP.Failure.closed : LoopbackHTTP.Failure.refused))
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            switch self.reader.read(data ?? Data(), ended: isComplete || error != nil) {
            case .more: self.receive()
            case .done(let response): self.finish(.success(response))
            case .failed(let failure): self.finish(.failure(failure))
            }
        }
    }

    func finish(_ result: Result<LoopbackHTTP.Response, Error>) {
        lock.lock()
        guard outcome == nil else { return lock.unlock() }
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        connection.cancel()
        waiting?.resume(with: result)
    }
}

/// True the first time it's asked, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

/// A count kept from any thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// At most one lookup of localhost under way for a backend: while one hasn't come back, the next card doesn't start
/// another, so a resolver that never returns costs one card half a second, the rest nothing, and piles up no threads.
final class LookupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = false
    private var count = 0

    /// Lookups begun, for the self-test.
    var begun: Int { lock.withLock { count } }

    /// False while one is still out.
    func begin() -> Bool {
        lock.withLock {
            guard !outstanding else { return false }
            outstanding = true
            count += 1
            return true
        }
    }

    func end() { lock.withLock { outstanding = false } }
}

// MARK: - The backend

/// A decision server on this Mac, over the Jev API (JevAPI) as Kev serves it, which Laya's laya-serve and OpenJev's helper
/// also speak: a card's questions go to POST /v1/systemone, each option keyed by its key in the app's order, and the
/// probabilities come back mapped to the options in that order; duplicate keys are refused before anything is sent.
///
/// Only this Mac's own loopback addresses (LoopbackRule): 127.0.0.1 and ::1 are used as they are; localhost is looked up
/// before every connection, on a thread of its own and within half a second, one lookup at a time, and every address it
/// gives must be loopback. Then a connection on the loopback interface only, with no proxy (LoopbackHTTP): no key, no
/// cookie, no redirect. One exchange at a time, each by its card's deadline, so cards wait in line as they do for a model
/// inside Binders.
///
/// Which model it is, for its bands: everything it says about itself (the names and fixed fields of /v1/models, else
/// OpenJev's /v1/version) and its answers to three probes (the warm-up questions), with the models those answers named
/// (DecisionIdentity.Server, ServerMatch). Probed at the first need of a launch (Settings or the first card), after any
/// exchange that failed, on Check Again, after a card when the last probes are over 5 minutes old, after a card whose
/// answer named a model no probe reached, and right before every start (`stillSame`), never trusted from a cache there.
/// Binders never starts, stops or installs a server: refused, a card goes on without it in a millisecond; hanging, it
/// costs a card its time, and after two timeouts in a row cards skip it for a minute.
actor JevDecisionBackend: DecisionBackend {
    /// What went wrong the last time it was asked: row A's line for it, and the clause the tuning log keeps.
    enum Trouble: Error, Equatable, Sendable {
        /// Nothing listens at the address.
        case nothingAnswers
        /// One exchange took more than its time.
        case slow
        /// Two exchanges in a row took more than their time: cards skip it for a minute.
        case hanging
        /// localhost wasn't looked up in time.
        case lookupSlow
        /// localhost leads to an address that isn't this Mac's loopback: LoopbackRule's words.
        case elsewhere(String)
        /// HTTP 401 or 403.
        case wantsKey
        /// HTTP 404 or 405: something answered, but not as a decision server.
        case notADecisionServer(status: Int, path: String)
        /// An answer without a probability from 0 to 1 for each option, or whose probabilities don't sum to 1.
        case noProbabilities
        /// Anything else: what happened.
        case other(String)

        /// Row A's line for the server at `display` ("127.0.0.1:18708").
        func line(_ display: String) -> String {
            switch self {
            case .nothingAnswers: "Nothing answers at \(display). Start your decision server there, then Check Again. Meanwhile Binders sorts without it."
            case .slow: "The server at \(display) took more than its time to answer. Binders asks it again with the next card."
            case .hanging: "The server at \(display) took more than 4 seconds twice. Binders asks it again in a minute; meanwhile it sorts without it."
            case .lookupSlow: "This Mac didn't say where localhost is within half a second, so Binders didn't connect. Use 127.0.0.1 and the port, or Check Again."
            case .elsewhere(let words): words
            case .wantsKey: "The server at \(display) wants a key. Binders sends none to a decision server: start it without one, listening on this Mac only."
            case .notADecisionServer(let status, let path): "\(display) answered, but not as a decision server (HTTP \(status) for \(path))."
            case .noProbabilities: "The server at \(display) answered, but not with a probability for each option."
            case .other(let what): "The server at \(display) answered, but Binders couldn't use it: \(what). Check Again once that's put right; meanwhile Binders sorts without it."
            }
        }

        /// For the tuning log ("router model: …") and the measure ("got no answer (…)").
        var clause: String {
            switch self {
            case .nothingAnswers: "nothing answers at its address"
            case .slow: "it took more than its time"
            case .hanging: "it took more than its time twice, so Binders skips it for a minute"
            case .lookupSlow: "localhost wasn't looked up in time"
            case .elsewhere: "localhost doesn't lead to this Mac's own loopback address"
            case .wantsKey: "it wants a key"
            case .notADecisionServer(let status, let path): "HTTP \(status) for \(path)"
            case .noProbabilities: "no probability for each option"
            case .other(let what): what
            }
        }

        /// Row A shows it in the problem style; the others are a wait with its next step.
        var isProblem: Bool {
            switch self {
            case .nothingAnswers, .slow, .hanging, .lookupSlow: false
            case .elsewhere, .wantsKey, .notADecisionServer, .noProbabilities, .other: true
            }
        }

        /// What a card or the measure is told.
        var error: DecisionError {
            self == .slow ? .timedOut : .server(clause)
        }
    }

    /// Row A's line while the first probes are under way, and once they answered.
    static func askingLine(_ display: String) -> String { "Asking \(display) what it serves…" }
    static func answersLine(_ display: String, names: [String]) -> String {
        let named = switch names.count {
        case 0: "a decision server"
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
        return "Answers at \(display) as \(named)."
    }

    /// A probe exchange that no card waits for (Settings, Check Again, after a card): its own 4 s.
    static let probeWithin: Duration = .seconds(4)
    /// Connecting: on loopback a connection is accepted or refused at once, so this covers a server too busy to accept.
    static let connectWithin: Duration = .milliseconds(500)
    /// localhost's lookup, at most.
    static let lookupWithin: Duration = .milliseconds(500)

    /// The address as Settings stores it, and as LoopbackRule allowed it (nil when refused, with why).
    nonisolated let stored: String
    nonisolated let address: LoopbackAddress?
    nonisolated let refusal: String?
    /// "127.0.0.1:18708", "[::1]:18708", "localhost:18708": the rows' and the Host header's.
    nonisolated var display: String { address?.display ?? stored }

    private let resolver: LoopbackHTTP.Resolver
    private let lookups = LookupGate()
    /// After two timeouts in a row, cards skip it this long: a minute, cut in the self-test.
    private let skipFor: Duration
    /// Probes older than this are asked again after the next card.
    private let probesLast: Duration

    /// What the last probes found, and what /v1/models (or /v1/version) said then.
    private var known: DecisionIdentity?
    private var served: JevAPI.Served?
    private var probedAt: ContinuousClock.Instant?
    /// An exchange failed since (other than by one timeout, see `failed`): the next card probes before it's asked,
    /// inside its own time.
    private var needsProbe = true
    private var probing: Task<Result<DecisionIdentity, Trouble>, Never>?
    private var trouble: Trouble?
    private var timeoutsInARow = 0
    private var skipUntil: ContinuousClock.Instant?
    /// The probes recorded with the bands that apply (a measure's), held to this launch's.
    private var golden: [[Double]]?
    private var retired = false
    /// One exchange at a time: the one under way, and those waiting in line, each until its deadline.
    private var exchanging = false
    private var inLine: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextInLine = 0
    private var rounds = 0

    /// `resolver`: how localhost is looked up (the self-test gives stand-ins); `skipFor` and `probesLast`: a minute and
    /// 5 minutes, cut in the self-test.
    init(address typed: String, resolver: @escaping LoopbackHTTP.Resolver = LoopbackHTTP.systemResolver,
         skipFor: Duration = .seconds(60), probesLast: Duration = .seconds(300)) {
        stored = typed
        switch LoopbackRule.check(typed) {
        case .success(let allowed):
            address = allowed
            refusal = nil
        case .failure(let refused):
            address = nil
            refusal = refused.words
        }
        self.resolver = resolver
        self.skipFor = skipFor
        self.probesLast = probesLast
    }

    // MARK: DecisionBackend

    /// What Settings and the router see, without waiting. Before anything is known, the first probes start in the
    /// background (Settings' own 4 s each), and it's `.checking`.
    func state() -> DecisionBackendState {
        guard let address else { return .unavailable(.address(refusal ?? "")) }
        if case .elsewhere(let words)? = trouble { return .unavailable(.address(words)) }
        if skipping { return .unavailable(.unreachable(Trouble.hanging.line(address.display))) }
        if let trouble { return .unavailable(.unreachable(trouble.line(address.display))) }
        if let known { return .answering(names: known.server?.names ?? []) }
        if !retired { startProbe(by: nil) }
        return .checking
    }

    /// What went wrong the last time, for row A's style; nil when it answered.
    func troubleNow() -> Trouble? {
        skipping ? .hanging : trouble
    }

    /// The model behind the address: the last probes' identity while nothing failed since, else probed now, by
    /// `deadline` (a card waits for probes under way inside its own time). Nil while cards skip it, and when the probes
    /// don't answer in time.
    func identity(by deadline: ContinuousClock.Instant) async -> DecisionIdentity? {
        guard address != nil else { return nil }
        if let known, !needsProbe { return known }
        guard !skipping, !retired else { return nil }
        let task = probing ?? startProbe(by: deadline)
        let seconds = LoopbackHTTP.seconds(ContinuousClock.now.duration(to: deadline))
        guard seconds > 0, let result = try? await TimeLimit.run(within: seconds, { await task.value }), case .success(let found) = result else { return nil }
        return found
    }

    func setGolden(_ golden: [[Double]]?) {
        self.golden = golden
    }

    /// The probes recorded with its measure answered alike this launch (ServerMatch). Another model's numbers make another
    /// identity, so they never "differ": a server's numbers are its identity.
    func numbersMatch() -> Bool {
        guard let golden, let probes = known?.server?.probes else { return false }
        return ServerMatch.sameProbes(golden, probes)
    }

    func numbersDiffer() -> Bool { false }

    /// The last probes' answers, for the measure to record as its goldens.
    func warmUp() -> [[Double]]? {
        known?.server?.probes
    }

    /// A server's letters aren't Binders' to read.
    func warmUpShares() -> [Double]? { nil }

    /// A card's questions: those that share a state in one request (a card is one), the answers mapped back by key in the
    /// order asked, by `deadline`. `expected`: the model the bands are for, which the last probes must have found.
    func decide(_ questions: [DecisionQuestion], expecting expected: DecisionIdentity?,
                by deadline: ContinuousClock.Instant) async throws -> DecisionAnswers {
        guard address != nil else { throw DecisionError.unavailable(refusal ?? "") }
        guard !retired else { throw DecisionError.retired }
        guard !questions.isEmpty else { return DecisionAnswers(probs: [], answeredBy: nil) }
        guard questions.allSatisfy({ Tev1Prompt.options.contains($0.options.count) }) else { throw DecisionError.refused }
        if skipping { throw Trouble.hanging.error }
        if let expected {
            guard let known, known.sameModel(as: expected) else { throw DecisionError.changed }
        }
        let sent = sentModel
        let requests: [JevAPI.Request]
        do {
            requests = try JevAPI.requests(questions, model: sent)
        } catch {
            // Two options with one key would collapse into one on the server: nothing is sent.
            throw DecisionError.refusedKeys
        }
        var probs = [[Double]](repeating: [], count: questions.count)
        var named: [String?] = []
        do {
            for request in requests {
                let response = try await exchange("POST", JevAPI.systemOnePath, body: request.body, by: deadline)
                let asked = request.questions.map { questions[$0] }
                let answer = try JevAPI.answers(status: response.status, body: response.body, for: asked, sent: sent, names: served?.names ?? [])
                for (index, row) in zip(request.questions, answer.probs) { probs[index] = row }
                named.append(answer.answeredBy)
            }
        } catch LoopbackHTTP.Failure.retired {
            throw DecisionError.retired
        } catch {
            throw failed(error).error
        }
        succeeded()
        let models = Set(named.map { $0 ?? "" })
        let answeredBy = models.count == 1 ? named.first ?? nil : models.sorted().joined(separator: " + ")
        if let server = known?.server, !server.reached(answeredBy) {
            // Another model answered than the probes reached: probe again at once. Nothing starts on this answer
            // (DecisionModels.confirm), and the next card is held to what the probes find.
            needsProbe = true
            startProbe(by: nil)
        } else if let probedAt, probedAt.duration(to: .now) > probesLast {
            // After the card, not inside its time: it was asked as things stood, and the next one sees what these find.
            startProbe(by: nil)
        }
        return DecisionAnswers(probs: probs, answeredBy: answeredBy)
    }

    /// For the measure: its fields and probes read, then the probes asked again, by `deadline`. Two rounds that don't
    /// answer alike (ServerMatch) can't be measured: a measure needs the same answer to the same card.
    func prepare(by deadline: ContinuousClock.Instant) async throws {
        guard address != nil else { throw DecisionError.unavailable(refusal ?? "") }
        guard !retired else { throw DecisionError.retired }
        let first = await probeRound(by: deadline)
        let second = await probeRound(by: deadline)
        switch (first, second) {
        case (.success(let one), .success(let other)):
            guard let a = one.server, let b = other.server, ServerMatch.same(a, b) else { throw DecisionError.unsteady }
        case (.failure(let trouble), _), (_, .failure(let trouble)):
            throw trouble.error
        }
    }

    /// Right before a start, after the decision: its fields and three probes asked now, every time, and held to the
    /// identity the decision's bands were for. A probe that times out or fails says nothing about the model: not
    /// confirmed, which the log keeps apart from a model that changed.
    func stillSame(_ identity: DecisionIdentity, by deadline: ContinuousClock.Instant) async -> StillSame {
        guard address != nil, !retired else { return .changed }
        switch await probeRound(by: deadline) {
        case .success(let now): return now.sameModel(as: identity) ? .same : .changed
        case .failure: return .notConfirmed
        }
    }

    /// Binders doesn't manage a server's memory.
    func setIdle(minutes: Int) {}
    func unload() {}

    /// Switched away from or deleted: no new exchange until it's chosen again; one under way ends by its deadline.
    func retire() {
        retired = true
    }

    /// Chosen again: what the probes found before is asked again before the next card, as another model may answer there
    /// by now.
    func revive() {
        retired = false
        needsProbe = true
    }

    func prepareForQuit(within: Duration) {
        retired = true
    }

    /// Check Again: whatever went wrong is forgotten, and it's probed now, with Settings' own 4 s an exchange.
    func tryAgain() async {
        guard address != nil, !retired else { return }
        skipUntil = nil
        timeoutsInARow = 0
        needsProbe = true
        _ = await probeRound(by: nil)
    }

    // MARK: For the self-test

    /// Probe rounds begun, lookups of localhost begun, the last probes' identity, and whether it's retired.
    var probeRoundsBegun: Int { rounds }
    var lookupsBegun: Int { lookups.begun }
    var knownIdentity: DecisionIdentity? { known }
    var retiredNow: Bool { retired }

    // MARK: Probing

    /// Two timeouts in a row, less than `skipFor` ago: cards skip it without asking.
    private var skipping: Bool {
        guard let skipUntil else { return false }
        return ContinuousClock.now < skipUntil
    }

    /// The model name a request carries: only when /v1/models named exactly one. Kev lists two names for one model, and
    /// Laya's server routes between its models when none is named, so leaving it out lets each answer as it does.
    private var sentModel: String? {
        guard let names = served?.names, names.count == 1 else { return nil }
        return names[0]
    }

    /// Probes under way, or begun now: a card's by its deadline, else Settings' own 4 s an exchange.
    @discardableResult
    private func startProbe(by deadline: ContinuousClock.Instant?) -> Task<Result<DecisionIdentity, Trouble>, Never> {
        if let probing { return probing }
        let task = Task { () -> Result<DecisionIdentity, Trouble> in
            let found = await self.probeRound(by: deadline)
            self.probing = nil
            return found
        }
        probing = task
        return task
    }

    /// One round: what it says it serves, then the three warm-up questions, one request each, every exchange within 4 s
    /// and by `deadline` (a card's) when one is given. What it finds is kept, whatever it is: another model behind the
    /// address is another identity, and the bands are worked out again for it.
    private func probeRound(by deadline: ContinuousClock.Instant?) async -> Result<DecisionIdentity, Trouble> {
        guard let address else { return .failure(.other(refusal ?? "")) }
        rounds += 1
        func by() -> ContinuousClock.Instant { min(deadline ?? .now + Self.probeWithin, .now + Self.probeWithin) }
        do {
            let listed = try await exchange("GET", JevAPI.modelsPath, body: nil, by: by())
            var found = try JevAPI.models(status: listed.status, body: listed.body)
            if found == nil {
                // OpenJev's helper lists no models: its /v1/version has its fixed fields, and its answers name the model.
                let version = try await exchange("GET", JevAPI.versionPath, body: nil, by: by())
                found = try JevAPI.version(status: version.status, body: version.body)
            }
            let says = found ?? JevAPI.Served(names: [], fields: [])
            let sent = says.names.count == 1 ? says.names[0] : nil
            var probes: [[Double]] = []
            var named: [String] = []
            for question in RouterQuestions.warmUps {
                let body = try JevAPI.request(state: question.state, questions: [question], model: sent)
                let response = try await exchange("POST", JevAPI.systemOnePath, body: body, by: by())
                let answer = try JevAPI.answers(status: response.status, body: response.body, for: [question], sent: sent, names: says.names)
                probes.append(answer.probs[0])
                if let model = answer.answeredBy { named.append(model) }
            }
            let identity = DecisionIdentity(server: .init(address: address.normalized, names: says.names, fields: says.fields, answeredBy: named,
                                                          probes: probes))
            served = says
            known = identity
            probedAt = .now
            needsProbe = false
            succeeded()
            return .success(identity)
        } catch {
            return .failure(failed(error))
        }
    }

    // MARK: Exchanges

    /// One request and its answer, in line behind any under way, by `deadline`: localhost looked up first, then the
    /// connection, by number.
    private func exchange(_ method: String, _ path: String, body: Data?, by deadline: ContinuousClock.Instant) async throws -> LoopbackHTTP.Response {
        guard let address else { throw LoopbackHTTP.Failure.refused }
        guard !retired else { throw LoopbackHTTP.Failure.retired }
        guard await enter(by: deadline) else { throw LoopbackHTTP.Failure.busy }
        defer { leave() }
        guard !retired else { throw LoopbackHTTP.Failure.retired }
        let endpoint = try await endpoint(address, by: deadline)
        let left = ContinuousClock.now.duration(to: deadline)
        return try await LoopbackHTTP.exchange(method, path: path, body: body, to: endpoint, host: address.display,
                                               connectWithin: min(Self.connectWithin, left), by: deadline)
    }

    /// Where to connect: 127.0.0.1 and ::1 as they are; localhost looked up now, off the actor, within half a second (or
    /// what's left of the deadline), and only if every address it gives is this Mac's loopback; then by number.
    private func endpoint(_ address: LoopbackAddress, by deadline: ContinuousClock.Instant) async throws -> LoopbackEndpoint {
        switch address.host {
        case .ipv4:
            return LoopbackEndpoint(address: LoopbackEndpoint.ipv4Loopback, port: address.port)
        case .ipv6:
            return LoopbackEndpoint(address: LoopbackEndpoint.ipv6Loopback, port: address.port)
        case .localhost:
            // One lookup at a time: while one hasn't come back, this card fails at once.
            guard lookups.begin() else { throw LoopbackHTTP.Failure.lookupSlow }
            let gate = lookups
            let within = min(Self.lookupWithin, ContinuousClock.now.duration(to: deadline))
            guard let found = await LoopbackHTTP.resolve("localhost", using: resolver, within: within, ended: { gate.end() }) else {
                throw LoopbackHTTP.Failure.lookupSlow
            }
            switch LoopbackRule.pick(found) {
            case .success(let picked): return LoopbackEndpoint(address: picked, port: address.port)
            case .failure(let refused): throw LoopbackHTTP.Failure.elsewhere(refused.words)
            }
        }
    }

    /// In line for the one exchange at a time: true once it's this one's turn, false if its deadline came first.
    private func enter(by deadline: ContinuousClock.Instant) async -> Bool {
        guard exchanging else {
            exchanging = true
            return true
        }
        let id = nextInLine
        nextInLine += 1
        return await withCheckedContinuation { continuation in
            inLine.append((id, continuation))
            Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.giveUp(id)
            }
        }
    }

    private func giveUp(_ id: Int) {
        guard let at = inLine.firstIndex(where: { $0.id == id }) else { return }
        inLine.remove(at: at).continuation.resume(returning: false)
    }

    private func leave() {
        guard !inLine.isEmpty else {
            exchanging = false
            return
        }
        inLine.removeFirst().continuation.resume(returning: true)
    }

    // MARK: What happened

    /// An exchange went through and its answer mapped.
    private func succeeded() {
        trouble = nil
        timeoutsInARow = 0
        skipUntil = nil
    }

    /// What a failure means for the next card and for row A, and the trouble it was. A failed exchange means probing
    /// again before the next card is asked, except one timeout: that says nothing about the model, and the next card is
    /// asked at once with what the last probes found. Probing inside the next card's time instead cost a server at about
    /// a second a question every card after: the probes passed, the card then timed out, and the probes passing again
    /// meant it never had two timeouts in a row. A second timeout in a row: skipping it for a minute, and probing before
    /// the first card after. Waiting in line, a switch away and the caller's cancellation say nothing about the server.
    private func failed(_ error: Error) -> Trouble {
        let found: Trouble
        switch error {
        case let failure as LoopbackHTTP.Failure:
            switch failure {
            case .busy: return .slow
            case .retired: return .other(DecisionError.retired.localizedDescription)
            case .timedOut, .connectTimedOut:
                timeoutsInARow += 1
                guard timeoutsInARow >= 2 else { return .slow }
                timeoutsInARow = 0
                needsProbe = true
                skipUntil = .now + skipFor
                trouble = .hanging
                return .hanging
            case .refused: found = .nothingAnswers
            case .lookupSlow: found = .lookupSlow
            case .elsewhere(let words): found = .elsewhere(words)
            case .closed: found = .other("it closed the connection before it answered")
            case .redirect(let status): found = .other("it answered with a redirect (HTTP \(status)), which Binders doesn't follow")
            case .tooLarge: found = .other("its answer was over 1 MB")
            case .malformed: found = .other("its answer wasn't HTTP")
            }
        case let problem as JevAPI.Problem:
            switch problem {
            case .duplicateKeys: return .other(problem.words)
            case .wantsKey: found = .wantsKey
            case .notADecisionServer(let status, let path): found = .notADecisionServer(status: status, path: path)
            case .noProbabilities: found = .noProbabilities
            case .refused, .server: found = .other(problem.words)
            }
        case is CancellationError:
            return .slow
        default:
            found = .other(error.localizedDescription)
        }
        needsProbe = true
        timeoutsInARow = 0
        trouble = found
        return found
    }
}
