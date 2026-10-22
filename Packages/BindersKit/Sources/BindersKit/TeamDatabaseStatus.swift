import Foundation

/// Where this Mac stands with the team database, for the status line in Settings → Team.
public enum TeamDatabaseStatus: Equatable, Sendable {
    /// No team database is set up on this Mac, or it was stopped.
    case off
    case connecting
    /// Connected, and reading what changed while it was away.
    case catchingUp
    /// Connected and up to date: changes arrive as they're made.
    case connected
    /// Not connected since `since`, for `reason`. It tries again on its own unless `retrying` is false (the database
    /// is newer than this Binders, or the login was turned down), when someone has to do something first.
    case offline(since: Date, reason: String, retrying: Bool)

    public var isConnected: Bool {
        switch self {
        case .connected, .catchingUp: true
        default: false
        }
    }

    /// The status line: "Connected", "Catching up", "Offline since 10:42. <reason> Binders tries again on its own."
    public func summary(now: Date = Date()) -> String {
        switch self {
        case .off: return "Not set up on this Mac."
        case .connecting: return "Connecting to the team database."
        case .catchingUp: return "Catching up with the team's changes."
        case .connected: return "Connected. Changes arrive as they're made."
        case .offline(let since, let reason, let retrying):
            let when = Calendar.current.isDate(since, inSameDayAs: now)
                ? since.formatted(date: .omitted, time: .shortened)
                : since.formatted(date: .abbreviated, time: .shortened)
            let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let sentence = reason.isEmpty ? "" : " " + (reason.hasSuffix(".") ? reason : reason + ".")
            return "Offline since \(when).\(sentence)" + (retrying ? " Binders tries again on its own, and your changes wait on this Mac." : "")
        }
    }
}

/// How long to wait before connecting again: 1 second, doubling each time, at most a minute, and a little either side
/// (`jitter`, from -1 to 1) so three Macs that lost the database together don't come back in step.
public enum TeamBackoff {
    public static let first: TimeInterval = 1
    public static let longest: TimeInterval = 60

    public static func delay(attempt: Int, jitter: Double = 0) -> TimeInterval {
        let base = min(longest, first * pow(2, Double(max(0, min(attempt, 16)))))
        return max(first / 2, base * (1 + 0.2 * max(-1, min(1, jitter))))
    }
}

/// The team database a Mac uses, and who it is there: what Settings → Team keeps (no password: that's in the Keychain).
public struct TeamDatabaseServer: Codable, Equatable, Hashable, Sendable {
    /// The server's name as its certificate gives it (inside the mesh, its private endpoint's name), or an address.
    public var host: String
    public var port: Int
    public var database: String
    public var login: String
    /// The name TLS checks the certificate against, when it isn't `host` (an address).
    public var serverName: String?

    public init(host: String, port: Int = 5432, database: String, login: String, serverName: String? = nil) {
        self.host = host
        self.port = port
        self.database = database
        self.login = login
        self.serverName = serverName
    }

    /// A short id for this login on this database: names its Keychain item and its folder on this Mac.
    public var key: String {
        let text = "\(login)@\(host.lowercased()):\(port)/\(database)"
        return TeamOperationID.derived(text).uuidString.lowercased().prefix(13).replacingOccurrences(of: "-", with: "")
    }
}

/// What an admin gives a new member: where the database is, their login, and a one-time password (changed by their
/// Mac the first time it connects, and kept in its Keychain).
public struct TeamInvite: Codable, Equatable, Sendable {
    public var server: TeamDatabaseServer
    public var oneTimePassword: String
    public var teamName: String
    /// Who made it, by their name in the team, so the Mac that opens it can say who invited (lane DB7). Nil in an invite an
    /// earlier Binders made; an earlier Binders ignores it.
    public var invitedBy: String?

    public init(server: TeamDatabaseServer, oneTimePassword: String, teamName: String, invitedBy: String? = nil) {
        self.server = server
        self.oneTimePassword = oneTimePassword
        self.teamName = teamName
        self.invitedBy = invitedBy
    }
}
