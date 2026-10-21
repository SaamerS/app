import Darwin
import Foundation
import BindersKit

/// The Claude Code sessions open on this Mac and their inboxes: Claude Code's own cross-session messaging binds a Unix
/// socket for each session, and on one Mac a message over it never goes through Anthropic. Binders reads which sessions
/// are open where from the files Claude Code keeps for them (`ClaudeSessions`), whether a session has Binders' tools from
/// the programs its own processes run, and posts one line into a session's socket. Only `AgentDispatcher` posts, to wake a
/// Claude Code agent you let it reach in the session you have open. Nothing else of Claude Code's is read: not the .key
/// files beside the session files, a transcript, a setting or its configuration (~/.claude.json).
enum ClaudeSessionInbox {
    /// Why a post didn't go through, in words for the card.
    enum Failure: LocalizedError, Equatable {
        /// Nothing listens there any more: the session closed after its file was written.
        case closed
        /// Its inbox isn't one Binders posts to.
        case unsafe(String)
        /// The session said no, in its own words.
        case refused(String)
        /// The post itself failed.
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .closed: "it had closed"
            case .unsafe(let why), .failed(let why): why
            case .refused(let why): "it said “\(why)”"
            }
        }
    }

    /// How long Binders listens, once it has posted, for the session to say no.
    static let replyWait: TimeInterval = 1

    /// The home folder whose .claude Binders reads: BINDERS_AGENT_HOME when it's set, else yours. In a throwaway folder
    /// (the self-tests) only BINDERS_AGENT_HOME, so a self-test never reads or posts to a session of yours.
    static var home: String? {
        let given = ProcessInfo.processInfo.environment["BINDERS_AGENT_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        return AppPaths.isDemo ? given : given ?? NSHomeDirectory()
    }

    /// The sessions open now: each <pid>.json in the sessions folder that names an inbox, for a process still running. In
    /// a throwaway folder, only those whose inbox is in it or in BINDERS_AGENT_HOME.
    static func open() -> [ClaudeSession] {
        guard let home else { return [] }
        let folder = ClaudeSessions.folder(home: home)
        let manager = FileManager.default
        var found: [ClaudeSession] = []
        for file in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] {
            guard let pid = ClaudeSessions.pid(ofFile: file) else { continue }
            let path = (folder as NSString).appendingPathComponent(file)
            // A small file of its own: never a link to something else.
            guard let attributes = try? manager.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1024,
                  let data = manager.contents(atPath: path), let session = ClaudeSession(json: data, pid: pid), isRunning(session.pid) else { continue }
            if AppPaths.isDemo, ![AppPaths.support.path, home].contains(where: { inside(session.socket, $0) }) { continue }
            found.append(session)
        }
        return found
    }

    /// The sessions open in `repository` that a card may be posted to now, best first (`ClaudeSessions.candidates`), and
    /// those open there that don't have Binders' tools, which couldn't read it. `excluding`: the runs Binders started.
    static func sessions(in repository: String, excluding: Set<String> = []) -> (ready: [ClaudeSession], withoutTools: [ClaudeSession]) {
        let open = ClaudeSessions.candidates(Self.open(), in: [repository, resolved(repository)], excluding: excluding)
        var ready: [ClaudeSession] = [], withoutTools: [ClaudeSession] = []
        for session in open {
            if hasBindersTools(session) { ready.append(session) } else { withoutTools.append(session) }
        }
        return (ready, withoutTools)
    }

    /// Whether the session has Binders' tools: Binders' MCP server runs as one of its processes (its child, or its child's,
    /// for a server started through a wrapper), as Claude Code keeps each stdio server it's set up with running for the
    /// life of the session. However it was added (Settings → MCP, a project's .mcp.json), a session started before it, or
    /// one whose server didn't start, has none. Only process ids and the programs' paths are looked at: never a process's
    /// arguments, environment or files.
    static func hasBindersTools(_ session: ClaudeSession) -> Bool {
        var level = children(of: session.pid)
        for depth in 0..<2 {
            if level.contains(where: { program(of: $0).map { ClaudeSessions.isBinders($0, running: MCPHost.executable) } ?? false }) { return true }
            guard depth == 0 else { break }
            level = level.prefix(64).flatMap(children(of:))
        }
        return false
    }

    /// The processes `pid` started that are still running.
    private static func children(of pid: Int32) -> [Int32] {
        guard pid > 0 else { return [] }
        var buffer = [Int32](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        return count > 0 ? buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 } : []
    }

    /// The path of the program a process runs, or nil when it can't be read (gone, or another user's).
    private static func program(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    /// A folder as the file system has it, as a session's own folder reads: its symbolic links followed and its letters
    /// in the case it was made with. The path as given when the folder can't be opened.
    static func resolved(_ path: String) -> String {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return path }
        defer { close(descriptor) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return path }
        return String(cString: buffer)
    }

    /// A Unix socket address for `path`, as its bytes. macOS takes a path longer than sockaddr_un's 104 bytes when the
    /// address's length says so, up to 252; nil for a longer one.
    static func address(_ path: String) -> [UInt8]? {
        let bytes = Array(path.utf8)
        let length = 2 + bytes.count + 1
        guard !bytes.isEmpty, !bytes.contains(0), length <= 255 else { return nil }
        return [UInt8(length), UInt8(AF_UNIX)] + bytes + [0]
    }

    /// Posts `line` into the inbox socket at `path`, then listens a moment for the session to say no. Off the main thread.
    /// Throws a `Failure`.
    static func post(_ line: Data, to path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try postNow(line, to: path, wait: replyWait)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func postNow(_ line: Data, to path: String, wait: TimeInterval) throws {
        func why() -> String { String(cString: strerror(errno)) }
        // Only a socket of yours: never a link to something else, or another user's.
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw Failure.closed }
            throw Failure.failed("its inbox couldn't be read (\(why()))")
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw Failure.unsafe("its inbox isn't a socket, so Binders left it alone") }
        guard info.st_uid == getuid() else { throw Failure.unsafe("its inbox belongs to another user, so Binders left it alone") }
        guard let address = address(path) else { throw Failure.unsafe("its inbox's path is too long") }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw Failure.failed("Binders couldn't open a socket (\(why()))") }
        defer { close(socket) }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var sending = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &sending, socklen_t(MemoryLayout<timeval>.size))
        var listening = timeval(tv_sec: Int(wait), tv_usec: Int32((wait - wait.rounded(.down)) * 1_000_000))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &listening, socklen_t(MemoryLayout<timeval>.size))
        let connected = address.withUnsafeBytes { raw in
            connect(socket, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
        }
        guard connected == 0 else {
            if errno == ECONNREFUSED || errno == ENOENT { throw Failure.closed }
            throw Failure.failed("Binders couldn't reach its inbox (\(why()))")
        }
        // The whole line, then the end of what Binders sends.
        let sent = line.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = write(socket, raw.baseAddress! + offset, raw.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard sent else {
            if errno == EAGAIN { throw Failure.failed("it didn't take the message in time") }
            if errno == EPIPE || errno == ECONNRESET { throw Failure.failed("it closed the connection before the message was in") }
            throw Failure.failed("the message didn't go (\(why()))")
        }
        shutdown(socket, SHUT_WR)
        // What it says back, if anything, until it closes or the wait is over.
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let capacity = buffer.count
        let end = Date().addingTimeInterval(wait)
        while reply.count < 16 * 1024, Date() < end {
            let count = read(socket, &buffer, capacity)
            if count > 0 {
                reply.append(contentsOf: buffer[0..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        // Claude Code documents no answer to a post: anything it says goes in the log, for checking on a device.
        if !reply.isEmpty {
            Log.app.notice("A Claude Code session's inbox answered a post (\(reply.count) bytes): \(String(decoding: reply.prefix(200), as: UTF8.self), privacy: .public)")
        }
        if let refusal = ClaudeSessions.refusal(inReply: reply) { throw Failure.refused(refusal) }
    }

    /// Whether the process is still running. Signal 0 only checks: nothing is sent to it.
    private static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func inside(_ path: String, _ folder: String) -> Bool {
        var folder = folder
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        return path.hasPrefix(folder + "/")
    }
}
