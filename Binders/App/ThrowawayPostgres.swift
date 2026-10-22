import Darwin
import Foundation
import BindersKit

/// A Postgres of its own for a team database self-test: a new cluster in a folder of the self-test's throwaway data
/// folder, listening on a spare port of 127.0.0.1 only and on no Unix socket (the folder's path is too long for one),
/// taking only encrypted connections, on a certificate made for it, with logins checked by SCRAM-SHA-256. `stop()` stops
/// and removes it; a watcher process does the same within a second if the self-test ends any other way. Never the
/// Homebrew cluster, its service, or a fixed port.
@MainActor
final class ThrowawayPostgres {
    enum Problem: LocalizedError {
        case notInstalled(String)
        case notAThrowawayFolder
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let what): "\(what) The team database self-tests need it: brew install postgresql@17 pgvector."
            case .notAThrowawayFolder: "The team database self-tests run only with BINDERS_DATA_DIR set to an empty folder."
            case .failed(let what): what
            }
        }
    }

    /// Where Homebrew keeps Postgres 17; BINDERS_SELFTEST_POSTGRES names another folder, to check what a Mac without it
    /// is told.
    static let binaries = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BINDERS_SELFTEST_POSTGRES"] ?? "/opt/homebrew/opt/postgresql@17/bin",
                              isDirectory: true)

    let folder: URL
    let port: Int
    let superuser = "binders_selftest"
    let superuserPassword: String
    /// The test CA's certificate, as PEM: what a connection to this server trusts.
    let certificate: String
    private var watcher: Process?
    private var stopped = false

    private var data: URL { folder.appendingPathComponent("data", isDirectory: true) }
    private var logFile: URL { folder.appendingPathComponent("postgres.log") }

    private init(folder: URL, port: Int, password: String, certificate: String) {
        self.folder = folder
        self.port = port
        superuserPassword = password
        self.certificate = certificate
    }

    /// Makes and starts a cluster, or throws saying what's missing.
    static func start() async throws -> ThrowawayPostgres {
        guard AppPaths.isDemo else { throw Problem.notAThrowawayFolder }
        for tool in ["initdb", "pg_ctl", "postgres", "pg_config"] {
            guard FileManager.default.isExecutableFile(atPath: binaries.appendingPathComponent(tool).path) else {
                throw Problem.notInstalled("Postgres 17 isn't installed at \(binaries.path) (no \(tool)).")
            }
        }
        let share = try await run(binaries.appendingPathComponent("pg_config"), ["--sharedir"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.fileExists(atPath: share + "/extension/vector.control") else {
            throw Problem.notInstalled("pgvector isn't installed for Postgres 17 (no \(share)/extension/vector.control).")
        }
        let folder = AppPaths.support.appendingPathComponent("postgres-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let password = TeamPassword.generate()
            let passwordFile = folder.appendingPathComponent("password")
            try Data(password.utf8).write(to: passwordFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFile.path)
            let data = folder.appendingPathComponent("data", isDirectory: true)
            let made = try await run(binaries.appendingPathComponent("initdb"),
                                     ["-D", data.path, "-U", "binders_selftest", "--pwfile=\(passwordFile.path)", "--auth=scram-sha-256",
                                      "-E", "UTF8", "--locale=C", "--no-instructions"])
            try? FileManager.default.removeItem(at: passwordFile)
            guard made.status == 0 else { throw Problem.failed("initdb failed: \(made.output.suffix(600))") }
            let certificate = try await makeCertificates(in: folder, data: data)
            // Encrypted connections from this Mac only, logins checked with SCRAM-SHA-256; nothing else.
            try """
                # A Binders self-test's own cluster: encrypted connections from 127.0.0.1, checked with SCRAM-SHA-256.
                hostssl all all 127.0.0.1/32 scram-sha-256

                """.write(to: data.appendingPathComponent("pg_hba.conf"), atomically: true, encoding: .utf8)
            var lastFailure = ""
            for _ in 0..<3 {
                let port = try sparePort()
                let server = ThrowawayPostgres(folder: folder, port: port, password: password, certificate: certificate)
                server.watch()
                if try await server.launch() { return server }
                lastFailure = server.log
                server.stopWatching()
            }
            throw Problem.failed("Postgres didn't start: \(lastFailure.suffix(800))")
        } catch {
            _ = try? await run(binaries.appendingPathComponent("pg_ctl"), ["-D", folder.appendingPathComponent("data").path, "-m", "immediate", "stop"])
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func launch() async throws -> Bool {
        let options = [
            "-c listen_addresses=127.0.0.1", "-c port=\(port)", "-c unix_socket_directories=''",
            "-c ssl=on", "-c ssl_cert_file='\(data.path)/server.crt'", "-c ssl_key_file='\(data.path)/server.key'",
            "-c password_encryption=scram-sha-256", "-c fsync=off", "-c max_connections=60",
        ].joined(separator: " ")
        let started = try await Self.run(Self.binaries.appendingPathComponent("pg_ctl"),
                                         ["-D", data.path, "-l", logFile.path, "-w", "-t", "60", "-o", options, "start"])
        return started.status == 0
    }

    /// Stops the cluster and removes its folder.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        if frozen { await thaw() }
        _ = try? await Self.run(Self.binaries.appendingPathComponent("pg_ctl"), ["-D", data.path, "-m", "fast", "-w", "-t", "30", "stop"])
        try? FileManager.default.removeItem(at: folder)
        stopWatching()
    }

    var isRemoved: Bool { !FileManager.default.fileExists(atPath: folder.path) }

    // MARK: A server that goes away (lane DB8)

    /// Shuts the server down and keeps its folder, as a server that was stopped: its connections close. `resume` starts
    /// it again, on the same port.
    @discardableResult
    func pause() async -> Bool {
        let stoppedNow = try? await Self.run(Self.binaries.appendingPathComponent("pg_ctl"), ["-D", data.path, "-m", "fast", "-w", "-t", "30", "stop"])
        return stoppedNow?.status == 0
    }

    @discardableResult
    func resume() async -> Bool {
        (try? await launch()) ?? false
    }

    /// Whether its processes are frozen now.
    private(set) var frozen = false

    /// Freezes every process of the server (SIGSTOP): it keeps its connections open and answers nothing, as a server that
    /// hung, or a route that drops what it's sent without closing anything. `thaw` lets it go on.
    func freeze() async {
        await signal("-STOP")
        frozen = true
    }

    func thaw() async {
        await signal("-CONT")
        frozen = false
    }

    /// The server's own process and every process it started.
    private func processes() async -> [String] {
        guard let first = (try? String(contentsOf: data.appendingPathComponent("postmaster.pid"), encoding: .utf8))?
            .split(separator: "\n").first.map(String.init), Int(first) != nil else { return [] }
        let children = (try? await Self.run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-P", first]))?.output ?? ""
        return [first] + children.split(whereSeparator: \.isNewline).map(String.init).filter { Int($0) != nil }
    }

    private func signal(_ which: String) async {
        let pids = await processes()
        guard !pids.isEmpty else { return }
        _ = try? await Self.run(URL(fileURLWithPath: "/bin/kill"), [which] + pids)
    }

    /// What Postgres wrote, for a failure's report.
    var log: String { (try? String(contentsOf: logFile, encoding: .utf8)) ?? "" }

    /// A login on a database of this server, over its TLS, its name checked as "localhost".
    func server(database: String, login: String) -> TeamDatabaseServer {
        TeamDatabaseServer(host: "127.0.0.1", port: port, database: database, login: login, serverName: "localhost")
    }

    var trust: TeamDatabaseLink.Trust { .certificates([certificate]) }

    /// The cluster's superuser, on `database`.
    func superuserLink(database: String = "postgres") async throws -> TeamDatabaseLink {
        try await TeamDatabaseLink.connect(to: server(database: database, login: superuser), password: superuserPassword, trust: trust)
    }

    // MARK: The watcher

    /// A small shell that stops and removes the cluster once this process is gone, however it ends.
    private func watch() {
        let script = """
            while kill -0 \(getpid()) 2>/dev/null; do sleep 1; done
            pid=$(head -1 '\(data.path)/postmaster.pid' 2>/dev/null)
            [ -n "$pid" ] && { kill -CONT "$pid" 2>/dev/null; pkill -CONT -P "$pid" 2>/dev/null; }
            '\(Self.binaries.path)/pg_ctl' -D '\(data.path)' -m immediate stop >/dev/null 2>&1
            rm -rf '\(folder.path)'
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        watcher = process
    }

    private func stopWatching() {
        if let watcher, watcher.isRunning { watcher.terminate() }
        watcher = nil
    }

    // MARK: Helpers

    /// A port of 127.0.0.1 nothing listens on now, as the system hands one out.
    static func sparePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw Problem.failed("No socket for a spare port") }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 }
        }
        guard bound else { throw Problem.failed("No spare port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// A CA made for this cluster, and its server certificate for "localhost" (by name only: a certificate that also
    /// names the address would pass whatever name is checked), with the key Postgres reads. Returns the CA's certificate.
    private static func makeCertificates(in folder: URL, data: URL) async throws -> String {
        let openssl = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") ? "/usr/bin/openssl" : "/opt/homebrew/bin/openssl")
        let config = folder.appendingPathComponent("openssl.cnf")
        try """
            [req]
            distinguished_name = name
            [name]
            [ca]
            basicConstraints = critical, CA:TRUE
            keyUsage = critical, keyCertSign, cRLSign
            subjectKeyIdentifier = hash
            [server]
            basicConstraints = critical, CA:FALSE
            keyUsage = critical, digitalSignature, keyEncipherment
            extendedKeyUsage = serverAuth
            subjectAltName = DNS:localhost

            """.write(to: config, atomically: true, encoding: .utf8)
        let ca = folder.appendingPathComponent("ca.crt"), caKey = folder.appendingPathComponent("ca.key")
        let request = folder.appendingPathComponent("server.csr")
        let key = data.appendingPathComponent("server.key"), certificate = data.appendingPathComponent("server.crt")
        let steps: [[String]] = [
            ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", caKey.path, "-out", ca.path, "-days", "2", "-sha256",
             "-subj", "/CN=Binders self-test CA", "-config", config.path, "-extensions", "ca"],
            ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", request.path, "-sha256",
             "-subj", "/CN=localhost", "-config", config.path],
            // The serial file in the cluster's folder, removed with it: LibreSSL would otherwise write it where Binders runs.
            ["x509", "-req", "-in", request.path, "-CA", ca.path, "-CAkey", caKey.path, "-CAcreateserial",
             "-CAserial", folder.appendingPathComponent("ca.srl").path, "-out", certificate.path,
             "-days", "2", "-sha256", "-extfile", config.path, "-extensions", "server"],
        ]
        for step in steps {
            let made = try await run(openssl, step)
            guard made.status == 0 else { throw Problem.failed("openssl \(step[0]) failed: \(made.output.suffix(400))") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        try? FileManager.default.removeItem(at: caKey)
        return try String(contentsOf: ca, encoding: .utf8)
    }

    /// Runs a tool and waits for it off the main thread: its exit status and what it printed.
    static func run(_ tool: URL, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("binders-pg-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try? handle.close()
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: output)
        return (status, text)
    }
}
