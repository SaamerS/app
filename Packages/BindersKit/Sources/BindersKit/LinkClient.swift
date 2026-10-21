import CryptoKit
import Foundation
import Network

/// A connection to Binders on a Mac: JSON-RPC requests with their replies, and the Mac's notifications as they arrive.
/// The iPhone app talks to the Mac through this, and the Mac's own self-test uses it to play the phone.
public final class LinkClient: @unchecked Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        case unreachable(String)
        case closed
        case rejected(String)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .unreachable(let reason): "Couldn't reach the Mac: \(reason)"
            case .closed: "The connection to the Mac closed"
            case .rejected(let message): message
            case .timedOut: "The Mac didn't answer in time"
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.binders.link.client")
    private var buffer = LineBuffer()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<Any, Error>] = [:]
    private var ready: CheckedContinuation<Void, Error>?
    private var notificationHandler: (@Sendable ([String: Any]) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var timeoutHandler: (@Sendable () -> Void)?
    private var closed = false
    /// When the Mac last said anything.
    private var heard = Date()
    /// Why the connection failed or waited, as Network.framework said it.
    private var lastNetworkError: NWError?
    /// The path was refused because Local Network is off for the app.
    private var localNetworkDenied = false
    /// What the connection last said about its path being usable.
    private var viable = true

    /// Seconds since the Mac last said anything; none while a request waits, as its own timeout covers the link then.
    public var quietFor: TimeInterval { queue.sync { waiting.isEmpty ? Date().timeIntervalSince(heard) : 0 } }

    /// What Network.framework said when the connection failed or waited, for saying what happened to an address.
    public var networkError: NWError? { queue.sync { lastNetworkError } }
    /// The connection couldn't go because Local Network is off for the app.
    public var deniedByLocalNetwork: Bool { queue.sync { localNetworkDenied } }
    public var isClosed: Bool { queue.sync { closed } }
    /// A request is waiting for its answer, which has its own timeout.
    public var isWaitingForReply: Bool { queue.sync { !waiting.isEmpty } }
    /// The connection's path still works: true until the connection says otherwise, false once its path isn't satisfied.
    public var isViable: Bool { queue.sync { viable && (connection.currentPath.map { $0.status == .satisfied } ?? true) } }
    /// The interface the connection runs over: "en0", "utun3".
    public var interfaceName: String? { queue.sync { connection.currentPath?.availableInterfaces.first?.name } }
    /// The address it reached, as LinkAddresses writes it: what Bonjour found, say.
    public var remoteHost: String? {
        queue.sync {
            guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint else { return nil }
            return LinkAddresses.hostText(host)
        }
    }

    public init(host: String, port: UInt16, identity: String, key: SymmetricKey) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: Link.parameters(keys: [(identity, key)]))
    }

    /// Connects to an endpoint found by Bonjour.
    public init(endpoint: NWEndpoint, identity: String, key: SymmetricKey) {
        connection = NWConnection(to: endpoint, using: Link.parameters(keys: [(identity, key)]))
    }

    /// Opens the connection; fails if the Mac can't be reached or refuses the key. Closed before it opens, it ends at
    /// once with `.closed`.
    public func connect(timeout: TimeInterval = 8) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed else { return continuation.resume(throwing: Failure.closed) }
                ready = continuation
                connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                connection.viabilityUpdateHandler = { [weak self] viable in self?.viable = viable }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let pending = ready else { return }
                    ready = nil
                    pending.resume(throwing: Failure.timedOut)
                    connection.cancel()
                }
            }
        }
        receive()
    }

    /// Called once when the connection ends, for whatever reason, on a background queue.
    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        queue.async {
            if self.closed { handler() } else { self.closeHandler = handler }
        }
    }

    /// Called for each notification the Mac sends, on a background queue.
    public func onNotification(_ handler: @escaping @Sendable ([String: Any]) -> Void) {
        queue.async { self.notificationHandler = handler }
    }

    /// Called when a request goes unanswered for its timeout, on a background queue: a sign the Mac may be gone.
    public func onTimeout(_ handler: @escaping @Sendable () -> Void) {
        queue.async { self.timeoutHandler = handler }
    }

    /// Sends a request and returns its result, or throws the Mac's error.
    public func request(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 60) async throws -> Any {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            queue.async { [self] in
                guard !closed else { return continuation.resume(throwing: Failure.closed) }
                let id = nextID
                nextID += 1
                waiting[id] = continuation
                send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let continuation = waiting.removeValue(forKey: id) else { return }
                    continuation.resume(throwing: Failure.timedOut)
                    timeoutHandler?()
                }
            }
        }
    }

    public func close() {
        queue.async { [self] in
            connection.cancel()
            finish()
        }
    }

    // MARK: The Binders conversation

    /// Proves which paired device this is: the Mac sends a challenge, the client signs it with its device key. `features`
    /// says what this client reads (LinkFeatures), so the Mac sends it nothing it can't. Each of its two requests waits
    /// `timeout` seconds at most.
    @discardableResult
    public func hello(device: UUID, key: SymmetricKey, name: String, features: [String] = [], timeout: TimeInterval = 60) async throws -> [String: Any] {
        let nonce = try await challenge(timeout: timeout)
        return try await prove(nonce, device: device, key: key, name: name, features: features, timeout: timeout)
    }

    /// The first half of hello: the Mac's challenge. It counts no connection on the Mac, and every Mac with the link
    /// answers it, so it also says Binders is there.
    public func challenge(timeout: TimeInterval = 60) async throws -> Data {
        let reply = try await request("binders/challenge", timeout: timeout) as? [String: Any]
        guard let nonce = (reply?["challenge"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw Failure.rejected("The Mac sent no challenge")
        }
        return nonce
    }

    /// The second half: `binders/hello`, signing this connection's own challenge. Returns the Mac's reply.
    public func prove(_ nonce: Data, device: UUID, key: SymmetricKey, name: String, features: [String] = [],
                      timeout: TimeInterval = 60) async throws -> [String: Any] {
        let proof = Link.proof(challenge: nonce, key: key).base64EncodedString()
        var params: [String: Any] = ["device": device.uuidString, "proof": proof, "name": name, "protocol": Link.protocolVersion]
        if !features.isEmpty { params["features"] = features }
        let reply = try await request("binders/hello", params, timeout: timeout)
        return reply as? [String: Any] ?? [:]
    }

    /// Calls one of the tools the MCP server offers and returns its text, or throws the tool's error.
    public func callTool(_ name: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 60) async throws -> String {
        let reply = try await request("tools/call", ["name": name, "arguments": arguments], timeout: timeout) as? [String: Any] ?? [:]
        let text = ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        if reply["isError"] as? Bool == true { throw Failure.rejected(text) }
        return text
    }

    /// Pairs with the Mac in a QR code: tries each of its addresses, then asks for a device key.
    public static func pair(_ pairing: LinkPairing, deviceName: String) async throws -> (device: UUID, key: SymmetricKey, host: String, port: UInt16) {
        guard !pairing.isExpired() else { throw Failure.rejected("This pairing code has expired. Show a new one on the Mac.") }
        var lastError: Error = Failure.unreachable("no address")
        for address in pairing.addresses {
            guard let (host, port) = split(address) else { continue }
            let client = LinkClient(host: host, port: port, identity: "pair", key: Link.pairingKey(secret: pairing.secret))
            do {
                try await client.connect(timeout: 4)
                defer { client.close() }
                let reply = try await client.request("binders/pair", ["name": deviceName, "protocol": Link.protocolVersion]) as? [String: Any]
                guard let id = (reply?["device"] as? String).flatMap(UUID.init(uuidString:)),
                      let key = (reply?["key"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                    throw Failure.rejected("The Mac's answer was incomplete")
                }
                // The main port, where every later connection goes.
                let mainPort = (reply?["port"] as? Int).flatMap(UInt16.init(exactly:)) ?? Link.port
                return (id, SymmetricKey(data: key), host, mainPort)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// "host:port" → parts. IPv6 hosts come in brackets: "[fd7a::1]:7447"; one without them can't say where its port
    /// starts, so it's nil, as is port 0. A name is kept as it is, for the connection to look up.
    public static func split(_ address: String) -> (host: String, port: UInt16)? {
        guard let colon = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: colon)...]), port != 0 else { return nil }
        var host = String(address[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        } else if host.contains(":") {
            return nil
        }
        return host.isEmpty ? nil : (host, port)
    }

    // MARK: Plumbing (on `queue`)

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready?.resume()
            ready = nil
        case .failed(let error), .waiting(let error):
            lastNetworkError = error
            if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { localNetworkDenied = true }
            if let pending = ready {
                ready = nil
                pending.resume(throwing: Failure.unreachable(error.localizedDescription))
            }
            connection.cancel()
            finish()
        case .cancelled:
            finish()
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                for line in buffer.append(data) { handle(line) }
            }
            if isComplete || error != nil || buffer.overflowed {
                connection.cancel()
                finish()
            } else {
                receive()
            }
        }
    }

    private func handle(_ line: Data) {
        heard = Date()
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let id = message["id"] as? Int, let continuation = waiting.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: Failure.rejected(error["message"] as? String ?? "The Mac refused the request"))
            } else {
                continuation.resume(returning: message["result"] ?? [String: Any]())
            }
        } else if message["method"] != nil, message["id"] == nil {
            notificationHandler?(message)
        }
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        // Closed while it was still opening: its connect() ends now, rather than at its timeout.
        if let pending = ready {
            ready = nil
            pending.resume(throwing: Failure.closed)
        }
        for continuation in waiting.values { continuation.resume(throwing: Failure.closed) }
        waiting.removeAll()
        closeHandler?()
        closeHandler = nil
    }
}
