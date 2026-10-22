import Foundation
import PostgresNIO
import BindersKit

/// One connection to the team database, made the way Binders makes them all: over a TCP channel with keepalives (so a
/// connection that died inside the mesh is noticed within about a minute, and the mesh keeps the route open), TLS
/// required with the server's certificate and name checked, and a login the server checks with SCRAM-SHA-256 (Binders
/// stores logins' passwords only as SCRAM verifiers). Every statement binds its values as text (TeamCall.statement).
final class TeamDatabaseLink: Sendable {
    /// Whose certificates the connection trusts.
    enum Trust: Sendable, Equatable {
        /// This Mac's own trust store: the team's server has a certificate from a public CA, as Azure's do.
        case system
        /// Only these certificates, as PEM: a team's own CA, or a throwaway test server's.
        case certificates([String])
    }

    /// Why a connection couldn't be made or used, in words for Settings → Team.
    enum Problem: LocalizedError, Equatable {
        case noPassword
        case notEncrypted
        /// The connection closed before the statement was answered: sending it again (with its operation id) is safe.
        case closed
        case unexpected(String)

        var errorDescription: String? {
            switch self {
            case .noPassword: "This Mac has no password for the team database. An admin can give you a new one-time password."
            case .notEncrypted: "The connection to the team database isn't encrypted, so Binders closed it."
            case .closed: "The connection to the team database closed."
            case .unexpected(let what): "The team database answered something Binders didn't expect (\(what))."
            }
        }
    }

    let connection: PostgresConnection
    private let logger: Logging.Logger
    /// One statement, or one call's transaction, at a time on this connection.
    private let turns = Turns()

    private init(connection: PostgresConnection, logger: Logging.Logger) {
        self.connection = connection
        self.logger = logger
    }

    /// TCP keepalives: probe after 30 seconds of quiet, every 10 seconds, and give up after 3 unanswered probes.
    static let keepAlive = (idle: Int32(30), interval: Int32(10), count: Int32(3))

    /// Connects and logs in, or throws. `timeout` covers reaching the server and logging in.
    static func connect(to server: TeamDatabaseServer, password: String, trust: Trust,
                        timeout: TimeAmount = .seconds(10)) async throws -> TeamDatabaseLink {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        tls.certificateVerification = .fullVerification
        switch trust {
        case .system:
            tls.trustRoots = .default
        case .certificates(let pems):
            tls.trustRoots = .certificates(try pems.flatMap { try NIOSSLCertificate.fromPEMBytes(Array($0.utf8)) })
        }
        let context = try NIOSSLContext(configuration: tls)

        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(timeout)
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelOption(.tcpOption(NIOBSDSocket.Option(rawValue: TCP_KEEPALIVE)), value: keepAlive.idle)
            .channelOption(.tcpOption(NIOBSDSocket.Option(rawValue: TCP_KEEPINTVL)), value: keepAlive.interval)
            .channelOption(.tcpOption(NIOBSDSocket.Option(rawValue: TCP_KEEPCNT)), value: keepAlive.count)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
        let channel = try await bootstrap.connect(host: server.host, port: server.port).get()

        var configuration = PostgresConnection.Configuration(establishedChannel: channel, tls: .require(context), username: server.login,
                                                             password: password, database: server.database)
        // The name the certificate must carry: the server's own, or the one given for an address.
        configuration.options.tlsServerName = server.serverName ?? (isAddress(server.host) ? nil : server.host)
        configuration.options.connectTimeout = timeout
        var logger = Logging.Logger(label: "io.binders.mac.team-database")
        logger.logLevel = .critical
        let connection: PostgresConnection
        do {
            connection = try await PostgresConnection.connect(on: channel.eventLoop, configuration: configuration,
                                                              id: Int.random(in: 1...Int(Int32.max)), logger: logger)
        } catch {
            try? await channel.close()
            throw error
        }
        let link = TeamDatabaseLink(connection: connection, logger: logger)
        do {
            try await link.execute(TeamQueries.sessionSetup)
            guard try await link.value(TeamQueries.usesTLS, as: Bool.self) == true else { throw Problem.notEncrypted }
        } catch {
            await link.close()
            throw error
        }
        return link
    }

    private static func isAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    var isClosed: Bool { connection.isClosed }

    func close() async {
        try? await connection.close()
    }

    // MARK: Statements

    private func query(_ sql: String, _ values: [String?]) -> PostgresQuery {
        var bindings = PostgresBindings(capacity: values.count)
        for value in values {
            if let value { bindings.append(value) } else { bindings.appendNull() }
        }
        return PostgresQuery(unsafeSQL: sql, binds: bindings)
    }

    /// Runs a statement and drops what it returns.
    func execute(_ sql: String, _ values: [String?] = []) async throws {
        await turns.take()
        do {
            try await executeInTurn(sql, values)
            await turns.give()
        } catch {
            await turns.give()
            throw error
        }
    }

    /// The first column of the first row, as `type`; nil when there's no row, or it's NULL.
    func value<Value: PostgresDecodable & Sendable>(_ sql: String, _ values: [String?] = [], as type: Value.Type) async throws -> Value?
    where Value._DecodableType == Value {
        await turns.take()
        do {
            let value = try await valueInTurn(sql, values, as: type)
            await turns.give()
            return value
        } catch {
            await turns.give()
            throw error
        }
    }

    /// Whether a statement or a call is running now: a ping then has nothing to add.
    var isBusy: Bool { get async { await turns.isBusy } }

    /// Since when the statement or call running now has held the connection (nil when nothing runs): one that's held it
    /// far longer than any answer takes means the database stopped answering without closing it (lane DB8).
    var busySince: Date? { get async { await turns.busySince } }

    /// For the self-tests (lane DB10): a distant server's round trip, before every statement on every connection.
    static let testLatency = TestLatency()

    final class TestLatency: @unchecked Sendable {
        private let lock = NSLock()
        private var latency: Duration?

        var value: Duration? {
            get { lock.lock(); defer { lock.unlock() }; return latency }
            set { lock.lock(); latency = newValue; lock.unlock() }
        }
    }

    private func roundTrip() async throws {
        if let latency = Self.testLatency.value { try await Task.sleep(for: latency) }
    }

    private func executeInTurn(_ sql: String, _ values: [String?] = []) async throws {
        try await roundTrip()
        let query = query(sql, values)
        try await whileOpen { [connection, logger] in
            let rows = try await connection.query(query, logger: logger)
            for try await _ in rows {}
        }
    }

    private func valueInTurn<Value: PostgresDecodable & Sendable>(_ sql: String, _ values: [String?] = [], as type: Value.Type) async throws
        -> Value? where Value._DecodableType == Value {
        try await roundTrip()
        let query = query(sql, values)
        return try await whileOpen { [connection, logger] in
            let rows = try await connection.query(query, logger: logger)
            var first: Value?
            var seen = false
            for try await row in rows where !seen {
                seen = true
                first = try row.decode(Value?.self)
            }
            return first
        }
    }

    /// Waits for a statement's answer, or stops waiting when the connection closes first, or the wait is cancelled. A
    /// statement sent on a connection that's already closing is never answered (PostgresNIO writes it without a promise),
    /// so nothing else would end the wait.
    private func whileOpen<Result: Sendable>(_ work: @escaping @Sendable () async throws -> Result) async throws -> Result {
        guard !connection.isClosed else { throw Problem.closed }
        let gate = Gate<Result>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                gate.arm(continuation)
                connection.closeFuture.whenComplete { _ in gate.finish(.failure(Problem.closed)) }
                Task {
                    do {
                        gate.finish(.success(try await work()))
                    } catch {
                        gate.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    /// A statement that answers with one JSON text.
    func json(_ sql: String, _ values: [String?] = []) async throws -> TeamJSON {
        guard let text = try await value(sql, values, as: String.self) else { return .null }
        guard let json = TeamJSON(text: text) else { throw Problem.unexpected("not JSON") }
        return json
    }

    /// One function call, with its operation id: its answer, applied or refused, once the database has committed it.
    /// Throws for an error, which the outbox sorts into worth sending again or not (TeamErrors). A function's answer can
    /// reach the Mac before its implicit transaction commits, and a connection lost in between would roll it back, so
    /// each call is its own transaction, and it's applied only when the COMMIT is answered; lost before that, it's sent
    /// again with the same operation id.
    func call(_ call: TeamCall) async throws -> TeamResult {
        guard let statement = call.statement else { throw Problem.unexpected("a call Binders can't make: \(call.function)") }
        await turns.take()
        do {
            try await executeInTurn("BEGIN")
            let text: String?
            do {
                text = try await valueInTurn(statement.sql, statement.values, as: String.self)
                try await executeInTurn("COMMIT")
            } catch {
                if !connection.isClosed { try? await executeInTurn("ROLLBACK") }
                throw error
            }
            await turns.give()
            guard let text, let result = TeamResult(json: text) else { throw Problem.unexpected("\(call.function) gave no answer") }
            return result
        } catch {
            await turns.give()
            throw error
        }
    }

    /// Several calls in one transaction (lane DB10): BEGIN, each call in order, COMMIT, so they cost two round trips more
    /// than their own rather than three each. As with one call, their answers count only once the COMMIT is answered. An
    /// error in any of them rolls them all back and throws; the caller then sends them one at a time.
    func calls(_ calls: [TeamCall]) async throws -> [TeamResult] {
        let statements = try calls.map { call in
            guard let statement = call.statement else { throw Problem.unexpected("a call Binders can't make: \(call.function)") }
            return statement
        }
        await turns.take()
        do {
            try await executeInTurn("BEGIN")
            var texts: [String?] = []
            do {
                for statement in statements { texts.append(try await valueInTurn(statement.sql, statement.values, as: String.self)) }
                try await executeInTurn("COMMIT")
            } catch {
                if !connection.isClosed { try? await executeInTurn("ROLLBACK") }
                throw error
            }
            await turns.give()
            return try zip(calls, texts).map { call, text in
                guard let text, let result = TeamResult(json: text) else { throw Problem.unexpected("\(call.function) gave no answer") }
                return result
            }
        } catch {
            await turns.give()
            throw error
        }
    }

    // MARK: Reads

    func changes(after seq: Int64, limit: Int) async throws -> [TeamChange] {
        let text = try await value(TeamQueries.changesAfter, [String(seq), String(limit)], as: String.self) ?? "[]"
        guard let changes = TeamChange.list(json: text) else { throw Problem.unexpected("the changes feed") }
        return changes
    }

    func lastSeq() async throws -> Int64 {
        try await value(TeamQueries.lastSeq, as: Int64.self) ?? 0
    }

    func visibleBinders() async throws -> Set<UUID> {
        Set(try await json(TeamQueries.visibleBinders).array?.compactMap(\.uuid) ?? [])
    }

    /// Rows by id; `leaving`: columns left out (lane DB10: a note's document and body).
    func rows(_ table: TeamTable, ids: [UUID], leaving: [String] = []) async throws -> [TeamRow] {
        guard !ids.isEmpty else { return [] }
        let list = TeamJSON(ids).text
        return try await json(TeamQueries.rows(byID: table, leaving: leaving), [list]).array?.compactMap(\.object) ?? []
    }

    /// Every row of `table` in `binder`, a page at a time.
    func rows(_ table: TeamTable, binder: UUID) async throws -> [TeamRow] {
        guard let sql = TeamQueries.rows(table) else {
            guard let all = TeamQueries.all(table) else { return [] }
            return try await json(all).array?.compactMap(\.object) ?? []
        }
        var rows: [TeamRow] = []
        var after: UUID?
        while true {
            let page = try await json(sql, [binder.uuidString.lowercased(), after?.uuidString.lowercased(), String(TeamQueries.pageSize)])
                .array?.compactMap(\.object) ?? []
            rows += page
            guard page.count == TeamQueries.pageSize, let last = page.last?.rowID else { break }
            after = last
        }
        return rows
    }

    /// The migrations the database applied.
    func appliedMigrations() async throws -> [TeamAppliedMigration] {
        let text = try await value(TeamSetupSQL.applied, as: String.self) ?? "[]"
        return try JSONDecoder().decode([TeamAppliedMigration].self, from: Data(text.utf8))
    }

    /// Listens on `channel` until the connection closes or the task is cancelled. `ready` runs once listening has begun,
    /// so whatever is read after it can't miss a change; `notified` gets each payload.
    func listen(_ channel: String, ready: @escaping @Sendable () async -> Void,
                notified: @escaping @Sendable (String) async -> Void) async throws {
        try await connection.listen(on: channel) { notifications in
            await ready()
            for try await notification in notifications {
                await notified(notification.payload)
            }
        }
    }
}

/// Turns at a connection: one statement, or one call's transaction, at a time, in the order they asked.
private actor Turns {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// When the turn going now began.
    private(set) var busySince: Date?

    var isBusy: Bool { busy }

    func take() async {
        guard busy else {
            busy = true
            busySince = Date()
            return
        }
        await withCheckedContinuation { waiting.append($0) }
        busySince = Date()
    }

    func give() {
        if waiting.isEmpty {
            busy = false
            busySince = nil
        } else {
            busySince = Date()
            waiting.removeFirst().resume()
        }
    }
}

/// Resumes a waiting continuation once, with whichever result comes first.
private final class Gate<Result: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Error>?
    private var early: Swift.Result<Result, Error>?
    private var done = false

    func arm(_ continuation: CheckedContinuation<Result, Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Swift.Result<Result, Error>) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        guard let continuation else {
            early = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

extension PSQLError {
    /// The server's SQLSTATE, for an error the server sent.
    var sqlState: String? { code == .server ? serverInfo?[.sqlState] : nil }

    /// The server's words, or what happened to the connection.
    var plainMessage: String {
        if code == .server, let message = serverInfo?[.message] { return message }
        switch code {
        case .connectionError, .serverClosedConnection, .clientClosedConnection, .uncleanShutdown:
            return "The connection to the team database closed"
        case .sslUnsupported: return "The team database doesn't offer an encrypted connection"
        case .saslError, .unsupportedAuthMechanism, .authMechanismRequiresPassword:
            return "The team database and Binders couldn't agree how to check this Mac's login"
        default: return "The team database stopped answering (\(code))"
        }
    }
}
