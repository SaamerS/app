import Foundation
import PostgresNIO
import BindersKit

/// Set up a team database (Settings → Team, by DB2): with an admin login, used once and never kept, it checks the server
/// (Postgres 15 or later, pgvector, the right to make roles), then in one transaction makes the team's two roles and its
/// schema, applies the migrations it lacks, and the first time records the team, pins its embedding model and admits the
/// first person, whose password this Mac makes and keeps in the Keychain. Run again on a database already set up, it
/// applies only migrations a newer Binders brought; a database newer than this Binders, or one whose migrations differ
/// from its own, is left alone. `update` is that second run on its own (Update the Team Database…, lane DB5): it never
/// makes a team. The statements are TeamSetupSQL's.
enum TeamDatabaseSetup {
    struct Request: Sendable {
        var host: String
        var port: Int = 5432
        var database: String
        var serverName: String?
        var adminLogin: String
        var adminPassword: String
        var teamName: String
        /// The first person: their login and name in the team.
        var firstLogin: String
        var firstName: String
        var embedding: TeamEmbeddingPin = .default
        var trust: TeamDatabaseLink.Trust = .system
    }

    /// Update the Team Database…: the database this Mac uses, and the server's admin login, used once and never kept.
    struct UpdateRequest: Sendable {
        var host: String
        var port: Int = 5432
        var database: String
        var serverName: String?
        var adminLogin: String
        var adminPassword: String
        var trust: TeamDatabaseLink.Trust = .system
    }

    struct Outcome: Sendable {
        /// The migrations applied now, in order: none when it was up to date.
        var applied: [Int]
        /// Whether this was the first setup: the team recorded, and the first person admitted.
        var madeTeam: Bool
        /// The first person's login on this database, its password kept in the Keychain: what TeamDatabase connects
        /// with. Nil when the team was already there.
        var member: TeamDatabaseServer?
    }

    enum Problem: LocalizedError, Equatable {
        case oldServer(String)
        case noVector
        case mayNotMakeRoles
        case invalid(String)
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .oldServer(let version): "This server runs Postgres \(version). The team database needs Postgres 15 or later."
            case .noVector: "pgvector isn't available on this server. Turn it on (on Azure, add vector to azure.extensions), then set up again."
            case .mayNotMakeRoles: "This login can't make roles. Use the server's admin login for the team database."
            case .invalid(let what): what
            case .refused(let why): why
            }
        }
    }

    /// `known`: the migrations this Binders applies, every one but for the self-tests (a database as an earlier Binders left it).
    static func run(_ request: Request, known: [TeamMigration] = TeamSchema.migrations) async throws -> Outcome {
        guard !request.teamName.trimmingCharacters(in: .whitespaces).isEmpty else { throw Problem.invalid("The team needs a name.") }
        guard TeamSchema.isValidRoleName(request.firstLogin) else {
            throw Problem.invalid("A login is 2 to 63 lower-case letters, digits or underscores, starting with a letter.")
        }
        let name = request.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !TeamSchema.isReservedName(name) else { throw Problem.invalid("Pick another name for yourself in the team.") }
        guard (1...2000).contains(request.embedding.dimension) else { throw Problem.invalid("An embedding model gives between 1 and 2,000 numbers.") }
        let roles = TeamSchema.roleNames(database: request.database)
        guard let becomeOwner = TeamSetupSQL.becomeOwner(roles.owner) else { throw Problem.invalid("That database's name can't name the team's roles.") }

        let admin = TeamDatabaseServer(host: request.host, port: request.port, database: request.database, login: request.adminLogin,
                                       serverName: request.serverName)
        let link = try await TeamDatabaseLink.connect(to: admin, password: request.adminPassword, trust: request.trust)
        do {
            let outcome = try await setUp(request, roles: roles, becomeOwner: becomeOwner, name: name, known: known, on: link)
            await link.close()
            return outcome
        } catch {
            await link.close()
            throw error
        }
    }

    /// Update the Team Database…: the migrations a database already set up lacks, applied in one transaction as Set Up
    /// applies them, with the server's admin login used for this call alone. Returns the migrations it applied (none when
    /// it was up to date). A database that isn't a team's yet is left alone, and so is one a newer Binders updated.
    static func update(_ request: UpdateRequest, known: [TeamMigration] = TeamSchema.migrations) async throws -> [Int] {
        let roles = TeamSchema.roleNames(database: request.database)
        guard let becomeOwner = TeamSetupSQL.becomeOwner(roles.owner) else { throw Problem.invalid("That database's name can't name the team's roles.") }
        let admin = TeamDatabaseServer(host: request.host, port: request.port, database: request.database, login: request.adminLogin,
                                       serverName: request.serverName)
        let link = try await TeamDatabaseLink.connect(to: admin, password: request.adminPassword, trust: request.trust)
        do {
            try await checkServer(on: link)
            let applied = try await transaction(on: link, roles: roles, becomeOwner: becomeOwner, known: known) {
                guard try await link.value(TeamSetupSQL.teamExists, as: Bool.self) == true else {
                    throw Problem.refused("That database isn't set up as a team database yet, so there's nothing to update.")
                }
                return false
            }.applied
            await link.close()
            return applied
        } catch {
            await link.close()
            throw error
        }
    }

    /// Before anything changes: Postgres 15 or later, pgvector, and an admin login that may make roles.
    private static func checkServer(on link: TeamDatabaseLink) async throws {
        let version = try await link.value(TeamSetupSQL.serverVersion, as: Int32.self) ?? 0
        guard version >= TeamSchema.oldestServer else {
            throw Problem.oldServer("\(version / 10000).\(version % 10000)")
        }
        guard try await link.value(TeamSetupSQL.vectorAvailable, as: Bool.self) == true else { throw Problem.noVector }
        guard try await link.value(TeamSetupSQL.mayMakeRoles, as: Bool.self) == true else { throw Problem.mayNotMakeRoles }
    }

    /// The one transaction Set Up and Update both run: the roles and the schema, the migrations the database lacks of
    /// `known`, then `team` (which records the team the first time, or checks there is one, and says whether it made it),
    /// then what the team role may do. All of it, or nothing.
    private static func transaction(on link: TeamDatabaseLink, roles: (owner: String, team: String), becomeOwner: String, known: [TeamMigration],
                                    team: () async throws -> Bool) async throws -> (applied: [Int], madeTeam: Bool) {
        var applied: [Int] = []
        let madeTeam: Bool
        try await link.execute(TeamSetupSQL.begin)
        do {
            try await link.execute(TeamSetupSQL.lock)
            do {
                try await link.execute(TeamSetupSQL.createExtension)
            } catch let error as PSQLError where error.code == .server {
                throw Problem.refused("pgvector couldn't be turned on in this database: \(error.plainMessage).")
            }
            guard let vectorSchema = try await link.value(TeamSetupSQL.vectorSchema, as: String.self) else { throw Problem.noVector }
            try await link.execute(TeamSetupSQL.names, [roles.owner, roles.team])
            try await link.execute(TeamSetupSQL.ownerRole)
            try await link.execute(becomeOwner)
            try await link.execute(TeamSetupSQL.teamRole)
            try await link.execute(TeamSetupSQL.migrationsTable)
            switch TeamSchema.plan(applied: try await link.appliedMigrations(), known: known) {
            case .upToDate: break
            case .apply(let versions): applied = versions
            case let other: throw Problem.refused(other.problem ?? "")
            }
            try await link.execute(TeamSetupSQL.searchPath(vectorSchema: vectorSchema))
            for migration in known where applied.contains(migration.version) {
                try await link.execute(TeamSetupSQL.loadMigration, [migration.sql])
                try await link.execute(TeamSetupSQL.runMigration)
                try await link.execute(TeamSetupSQL.recordMigration, [String(migration.version), migration.name, migration.checksum])
            }
            madeTeam = try await team()
            try await link.execute(TeamSetupSQL.grant)
            try await link.execute(TeamSetupSQL.commit)
        } catch {
            try? await link.execute(TeamSetupSQL.rollback)
            throw error
        }
        return (applied, madeTeam)
    }

    private static func setUp(_ request: Request, roles: (owner: String, team: String), becomeOwner: String, name: String,
                              known: [TeamMigration], on link: TeamDatabaseLink) async throws -> Outcome {
        try await checkServer(on: link)
        let firstID = UUID()
        let firstPassword = TeamPassword.generate()
        let (applied, madeTeam) = try await transaction(on: link, roles: roles, becomeOwner: becomeOwner, known: known) {
            guard try await link.value(TeamSetupSQL.teamExists, as: Bool.self) != true else { return false }
            try await link.execute(TeamSetupSQL.setupTeam, [request.teamName.trimmingCharacters(in: .whitespacesAndNewlines), roles.team,
                                                            roles.owner, request.embedding.model, String(request.embedding.dimension)])
            try await link.execute(TeamSetupSQL.pinEmbedding, [request.embedding.model, String(request.embedding.dimension)])
            try await link.execute(TeamSetupSQL.firstMember, [firstID.uuidString.lowercased(), request.firstLogin, name,
                                                              TeamPassword.verifier(for: firstPassword)])
            return true
        }
        var member: TeamDatabaseServer?
        if madeTeam {
            let first = TeamDatabaseServer(host: request.host, port: request.port, database: request.database, login: request.firstLogin,
                                           serverName: request.serverName)
            TeamDatabase.keep(password: firstPassword, for: first)
            member = first
        }
        return Outcome(applied: applied, madeTeam: madeTeam, member: member)
    }
}
