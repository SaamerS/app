import Foundation
import Observation
import PostgresNIO
import BindersKit

/// The team's shared database, for this Mac's member (docs/plans/team-database.md). It connects over the team's mesh,
/// reads what changed since this Mac last looked (the changes feed, after the last number it applied), then listens, so
/// catching up and live updates are the same code; it reconnects on its own, with backoff, when the connection drops.
/// This Mac's own changes go through the outbox: saved on disk, sent in order with their operation ids, applied once
/// however often they're sent, each answered (applied, or refused with its reason) to whoever made it.
///
/// What DB2 and DB3 build on:
/// - `status`, for the status line in Settings → Team;
/// - `send(_:)` and `outcomes` / `outcome(of:)`: the outbox, for changes made here (TeamCall's typed board calls, row
///   writes, binders and agents);
/// - `call(_:)`: one call now, for admin work and passwords, which never wait in the outbox;
/// - `updates` and `acknowledge(_:)`: the stream of changes, with the rows they touched as they are now;
/// - `rows(_:binder:)`, `rows(_:ids:)`, `snapshot(binder:)`, `visibleBinders()`: reads, by table and binder.
@MainActor
@Observable
final class TeamDatabase {
    /// Why a connection or a call didn't go through, in words for Settings → Team.
    enum Problem: LocalizedError {
        case offline
        case closed
        case stoppedAnswering
        case notSetUp
        case needsUpdate
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .offline: "This Mac isn't connected to the team database now."
            case .closed: "The connection to the team database closed."
            case .stoppedAnswering: "The team database stopped answering."
            case .notSetUp: "That database isn't set up as a team database yet. An admin sets it up from Settings → Team."
            case .needsUpdate: "The team's database needs an update that this version of Binders brings. An admin of the team runs it once, from Settings → Team."
            case .refused(let reason): reason
            }
        }

        /// Whether trying again on its own can help, or someone has to do something first.
        var retrying: Bool {
            switch self {
            case .offline, .closed, .stoppedAnswering: true
            case .notSetUp, .needsUpdate, .refused: false
            }
        }
    }

    /// For the self-tests: drop the connection after the database answered an outbox item and before its answer is
    /// kept, as a connection lost on the way back would; and make reconnecting quicker.
    struct TestHooks {
        var dropAfterAnswer: (@MainActor (TeamOutboxItem) -> Bool)?
        var reconnectDelay: TimeInterval?
        var pingInterval: TimeInterval = 30
        /// A distant server's round trip, before each outbox item goes and each page of the feed is read.
        var latency: Duration?
        /// Holds an outbox item back before it's sent, while this says so: a database slow to take this Mac's changes
        /// (lane DB8).
        var holdBeforeSending: (@MainActor (TeamOutboxItem) -> Bool)?
    }

    let server: TeamDatabaseServer
    @ObservationIgnored let trust: TeamDatabaseLink.Trust

    private(set) var status: TeamDatabaseStatus = .off
    /// Who this login is in the team (`binders.members`), as of connecting.
    private(set) var member: TeamRow?
    /// The team's own row (`team_settings`, without its role names), as of connecting.
    private(set) var team: TeamRow?
    /// The binders this member sees, as of the last catch-up.
    private(set) var binders: Set<UUID> = []
    /// How many of this Mac's changes wait in the outbox.
    private(set) var waiting = 0
    /// The team's database needs an update this Binders brings (lane DB5): what it lacks, and who can run it, as of the
    /// last time this Mac reached it. Nil once it's up to date, and when it never said so.
    private(set) var update: UpdateNeeded?
    /// Since when the database hasn't answered in time while this Mac is connected to it (a probe, or the answer to a
    /// change that didn't come within its wait): a frozen server, or a route that drops what it's sent without closing the
    /// connection. Nil once it answers again (lane DB8). What the database decides is refused meanwhile.
    private(set) var stalledSince: Date?

    /// An update the team's database needs before this Mac connects: Update the Team Database…, by an admin, once.
    struct UpdateNeeded: Equatable {
        /// The migrations it lacks, in order.
        var missing: [Int]
        /// Whether this Mac's member is an admin, who can run it.
        var youAreAdmin: Bool
        /// The team's other admins, by name.
        var otherAdmins: [String]
    }

    /// What changed, in order, with the rows it touched as they are now. Read it from one place (DB2 / DB3 apply it to
    /// the local copy), and `acknowledge` each update once applied.
    @ObservationIgnored let updates: AsyncStream<TeamUpdate>
    /// What became of each change sent through the outbox, in the order they went, those from before a restart
    /// included.
    @ObservationIgnored let outcomes: AsyncStream<TeamOutboxOutcome>
    @ObservationIgnored var testHooks = TestHooks()
    /// The feed's note rows come without their documents and words (lane DB10); whoever reads `updates` reads a row whole
    /// when it needs one (`TeamNoteRow.isWhole`). Off for a client that applies note rows as they come.
    @ObservationIgnored var lightNoteRows = false

    @ObservationIgnored private let updatesContinuation: AsyncStream<TeamUpdate>.Continuation
    @ObservationIgnored private let outcomesContinuation: AsyncStream<TeamOutboxOutcome>.Continuation
    @ObservationIgnored private let files: TeamDatabaseFiles
    @ObservationIgnored private var link: TeamDatabaseLink?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var nudge: AsyncStream<Void>.Continuation?
    /// The feed's number this Mac has read up to: ahead of what was acknowledged while updates wait to be applied.
    @ObservationIgnored private var delivered: Int64 = 0
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<TeamOutcome, Never>]] = [:]
    @ObservationIgnored private var recent: [(operation: UUID, outcome: TeamOutcome)] = []
    /// The feed was pruned past what this Mac had read (migration 5): its binders are read whole again at the next catch-up.
    @ObservationIgnored private var readAllAgain = false
    /// When this Mac last asked whether the database answers (lane DB8).
    @ObservationIgnored private var lastProbe: Date?
    /// The outbox item on its way now, if one is: it can't be taken back.
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// The database said something changed while the outbox was going: the feed is read between its batches (lane DB10),
    /// so a teammate's change doesn't wait for every change of this Mac's to go first.
    @ObservationIgnored private var feedChanged = false
    /// Items to send one at a time, after a batch one of them was turned down in.
    @ObservationIgnored private var alone = 0

    /// How many changes one read of the feed takes.
    static let pageSize = 1000
    /// An outbox item older than this isn't sent: the database keeps operation ids 30 days (migration 5's prune), so one
    /// sent later could be applied twice.
    static let oldestSent: TimeInterval = 29 * 86_400

    init(server: TeamDatabaseServer, trust: TeamDatabaseLink.Trust = .system, folder: URL? = nil) {
        self.server = server
        self.trust = trust
        files = TeamDatabaseFiles(folder: folder ?? TeamDatabaseFiles.folder(for: server))
        (updates, updatesContinuation) = AsyncStream<TeamUpdate>.makeStream()
        (outcomes, outcomesContinuation) = AsyncStream<TeamOutboxOutcome>.makeStream()
        waiting = files.outbox.count
    }

    // MARK: Passwords, in the Keychain

    /// The Keychain item holding this login's password, named as AgentRegistry names Binders' items (apart for the
    /// self-tests).
    nonisolated static func passwordKey(_ server: TeamDatabaseServer) -> String {
        AgentRegistry.keychainKey("team-database-password-\(server.key)")
    }

    /// The new password while it's being changed, so a Mac that stops between the change and keeping it still knows it.
    nonisolated static func nextPasswordKey(_ server: TeamDatabaseServer) -> String {
        AgentRegistry.keychainKey("team-database-password-next-\(server.key)")
    }

    /// Keeps a login's password: an invite's one-time password, or the first person's at setup.
    nonisolated static func keep(password: String, for server: TeamDatabaseServer) {
        Keychain.write(password, for: passwordKey(server))
    }

    /// Forgets a login's passwords on this Mac.
    nonisolated static func forget(_ server: TeamDatabaseServer) {
        Keychain.write("", for: passwordKey(server))
        Keychain.write("", for: nextPasswordKey(server))
    }

    /// Joining with an invite: its one-time password goes in the Keychain, and the first connection changes it for one
    /// only this Mac knows.
    static func join(_ invite: TeamInvite, trust: TeamDatabaseLink.Trust = .system) -> TeamDatabase {
        keep(password: invite.oneTimePassword, for: invite.server)
        return TeamDatabase(server: invite.server, trust: trust)
    }

    // MARK: Running

    /// Connects, and keeps connecting when the connection drops, until `stop`.
    func start() {
        guard runner == nil else { return }
        delivered = files.state.acknowledgedSeq
        binders = Set(files.state.binders)
        status = .connecting
        runner = Task { [weak self] in await self?.run() }
    }

    /// Disconnects. What waits in the outbox stays on disk for the next start.
    func stop() async {
        runner?.cancel()
        runner = nil
        nudge?.finish()
        await link?.close()
        link = nil
        status = .off
        stalledSince = nil
        files.flush()
    }

    /// The outbox written whole on disk, for quitting (lane DB10): what its journal holds goes into outbox.json.
    func flushFiles() {
        files.flush()
    }

    // MARK: Whether it answers (lane DB8)

    /// Connected, and answering: what the database decides can be asked of it now.
    var isAnswering: Bool { status.isConnected && link?.isClosed == false && stalledSince == nil }

    /// The database answered something.
    func heard() {
        if stalledSince != nil { stalledSince = nil }
    }

    /// It didn't answer in time while connected.
    func stalled() {
        guard status.isConnected, stalledSince == nil else { return }
        stalledSince = Date()
    }

    /// Whether the database answers now: a ping that must come back within `timeout`, behind whatever runs on the
    /// connection now. Asked every time, as a route can drop the moment after the last answer. One that doesn't come
    /// back marks it stalled until it answers again, and it's asked again at most every five seconds meanwhile. The
    /// connection stays open, as a slow answer may still come: the ping every half a minute closes one that's really gone.
    func probe(within timeout: Duration = .seconds(2)) async -> Bool {
        guard status.isConnected, let link, !link.isClosed else { return false }
        if stalledSince != nil, let lastProbe, Date().timeIntervalSince(lastProbe) < 5 { return false }
        lastProbe = Date()
        let answered = await Self.answers(link, within: timeout)
        if answered { heard() } else { stalled() }
        return answered
    }

    /// A ping raced against `timeout`, no longer waited for once the time is up: it may wait its turn behind a call that's
    /// never answered.
    nonisolated private static func answers(_ link: TeamDatabaseLink, within timeout: Duration) async -> Bool {
        let first = FirstAnswer()
        return await withCheckedContinuation { continuation in
            first.arm(continuation)
            Task { first.finish((try? await link.execute(TeamQueries.ping)) != nil) }
            Task {
                try? await Task.sleep(for: timeout)
                first.finish(false)
            }
        }
    }

    /// The feed's number this Mac applied up to: what it catches up from after a restart.
    var acknowledgedSeq: Int64 { files.state.acknowledgedSeq }

    /// An update was applied to the local copy: after a restart, catching up starts after it.
    func acknowledge(_ update: TeamUpdate) {
        files.acknowledge(through: update.lastSeq, binders: update.binders)
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            var retrying = true
            do {
                let link = try await connect()
                attempt = 0
                try await session(link)
            } catch {
                if Task.isCancelled { break }
                let (reason, again) = Self.describe(error)
                retrying = again
                if case .offline(let since, _, _) = status {
                    status = .offline(since: since, reason: reason, retrying: again)
                } else {
                    status = .offline(since: Date(), reason: reason, retrying: again)
                }
            }
            await link?.close()
            link = nil
            if Task.isCancelled { break }
            let delay = retrying ? (testHooks.reconnectDelay ?? TeamBackoff.delay(attempt: attempt, jitter: .random(in: -1...1))) : 300
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// The words for why the connection failed, and whether trying again on its own can help.
    static func describe(_ error: Error) -> (reason: String, retrying: Bool) {
        if let problem = error as? Problem { return (problem.errorDescription ?? "", problem.retrying) }
        if let problem = error as? TeamDatabaseLink.Problem { return (problem.errorDescription ?? "", problem == .closed) }
        if let error = error as? PSQLError {
            switch error.sqlState {
            case "28P01", "28000":
                return ("The team database didn't accept this Mac's login. An admin can give you a new one-time password", false)
            case "3D000":
                return ("There's no database of that name on the server", false)
            default:
                // The TLS or socket error underneath says more than "the connection closed".
                if error.sqlState == nil, let underlying = error.underlying, !(underlying is PSQLError) { return describe(underlying) }
                return (error.plainMessage, true)
            }
        }
        // A certificate that doesn't check out stays that way until someone changes it, but trying again now and then
        // costs nothing, and a handshake cut short by the network is worth retrying at once.
        if let error = error as? NIOSSLError {
            if case .handshakeFailed = error { return ("The team database's certificate couldn't be checked, so Binders didn't connect", true) }
            return ("The encrypted connection to the team database broke off", true)
        }
        if error is NIOSSLExtraError {
            return ("The team database's certificate is for another name, so Binders didn't connect", true)
        }
        return ("Binders can't reach the team database", true)
    }

    // MARK: Connecting

    private func connect() async throws -> TeamDatabaseLink {
        let password = Keychain.read(Self.passwordKey(server)).flatMap { $0.isEmpty ? nil : $0 }
        let next = Keychain.read(Self.nextPasswordKey(server)).flatMap { $0.isEmpty ? nil : $0 }
        guard let password = password ?? next else { throw TeamDatabaseLink.Problem.noPassword }
        let link: TeamDatabaseLink
        do {
            link = try await TeamDatabaseLink.connect(to: server, password: password, trust: trust)
        } catch let error as PSQLError where error.sqlState == "28P01" && next != nil && next != password {
            // A password change that went through without this Mac keeping its result: the new one works.
            link = try await TeamDatabaseLink.connect(to: server, password: next!, trust: trust)
            Keychain.write(next!, for: Self.passwordKey(server))
            Keychain.write("", for: Self.nextPasswordKey(server))
        }
        do {
            // A database other than the one this Binders knows: refused, both ways.
            let applied: [TeamAppliedMigration]
            do {
                applied = try await link.appliedMigrations()
            } catch let error as PSQLError where ["42P01", "3F000"].contains(error.sqlState ?? "") {
                throw Problem.notSetUp
            }
            switch TeamSchema.plan(applied: applied) {
            case .upToDate: update = nil
            case .apply(let missing):
                if applied.isEmpty { throw Problem.notSetUp }
                // An update this Binders brings: who can run it, read first, so Settings → Team can say.
                update = try await updateNeeded(missing, on: link)
                throw Problem.needsUpdate
            case let other:
                update = nil
                throw Problem.refused(other.problem ?? "")
            }
            var me = try await link.json(TeamQueries.whoami)
            if me["member"]?["temporary_password"]?.bool == true {
                try await changePassword(on: link)
                me = try await link.json(TeamQueries.whoami)
            }
            guard me["member"]?.object != nil else {
                throw Problem.refused("This login isn't a member of the team. An admin adds members in Settings → Team")
            }
            member = me["member"]?.object
            team = me["team"]?.object
            // A Mac that never caught up reads its binders in full instead (bindersAdded), and the feed from now on.
            if files.state.acknowledgedSeq == 0, files.state.binders.isEmpty, delivered == 0 {
                delivered = try await link.lastSeq()
            } else if let pruned = team?["changes_pruned_through"]?.int64, pruned > delivered {
                // Changes it hadn't read were pruned (one of them may be a deletion): it reads its binders whole again.
                readAllAgain = true
            }
        } catch {
            await link.close()
            throw error
        }
        self.link = link
        return link
    }

    /// Who can update a database that needs it: this member (an admin?) and the team's other admins. Only migration 1's
    /// reads, which every database Binders set up has. A one-time password is changed first, as connecting changes it,
    /// so an invite doesn't run out while the team waits for its update.
    private func updateNeeded(_ missing: [Int], on link: TeamDatabaseLink) async throws -> UpdateNeeded {
        var me = try await link.json(TeamQueries.whoami)
        if me["member"]?["temporary_password"]?.bool == true {
            try await changePassword(on: link)
            me = try await link.json(TeamQueries.whoami)
        }
        let admins = (try await link.json(TeamQueries.otherAdmins).array ?? []).compactMap(\.string)
        return UpdateNeeded(missing: missing, youAreAdmin: me["member"]?["is_admin"]?.bool == true && me["member"]?["kind"]?.string != "agent",
                            otherAdmins: admins)
    }

    /// The one-time password goes, for one this Mac makes and keeps: kept as the next password first, so a Mac that
    /// stops halfway still knows it.
    private func changePassword(on link: TeamDatabaseLink) async throws {
        let password = TeamPassword.generate()
        Keychain.write(password, for: Self.nextPasswordKey(server))
        let result = try await link.call(.changePassword(verifier: TeamPassword.verifier(for: password)))
        guard result.ok else { throw Problem.refused(result.refusal?.errorDescription ?? "The team database didn't take the new password") }
        Keychain.write(password, for: Self.passwordKey(server))
        Keychain.write("", for: Self.nextPasswordKey(server))
    }
}

// MARK: The session

extension TeamDatabase {
    /// One connection's life: listen first, so nothing committed after the catch-up is missed; catch up; send what waits;
    /// then do both again whenever the database says something changed or a change of this Mac's is queued. A ping
    /// every half a minute notices a connection that died without saying so. Ends (throws) when the connection does.
    private func session(_ link: TeamDatabaseLink) async throws {
        let (nudges, nudge) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (listening, ready) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.nudge = nudge
        defer {
            nudge.finish()
            ready.finish()
            self.nudge = nil
        }
        let interval = testHooks.pingInterval
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await link.listen(TeamSchema.channel, ready: { ready.yield() }, notified: { payload in
                    // Only a number: something changed somewhere. Reading the feed says what, and RLS says where.
                    guard TeamChange.notified(payload) != nil else { return }
                    nudge.yield()
                    await self.heardOfChange()
                })
                throw Problem.closed
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(interval))
                    if try await TeamDatabase.ping(link) { await self.heard() }
                }
            }
            group.addTask { @MainActor in
                for await _ in listening { break }
                try Task.checkCancellation()
                try await self.work(link, nudges: nudges)
            }
            // The first to end ends them all: closing the connection first stops the listener and any query still
            // waiting, which cancelling alone might not.
            do {
                try await group.next()
            } catch {
                await link.close()
                group.cancelAll()
                throw error
            }
            await link.close()
            group.cancelAll()
        }
    }

    /// The connection answers within `timeout`, or it's closed: a ping that hangs means the route died. True when the ping
    /// was answered, false when it wasn't sent because a statement runs now.
    @discardableResult
    nonisolated static func ping(_ link: TeamDatabaseLink, timeout: TimeInterval = 15) async throws -> Bool {
        // A statement running now says the connection works, or fails when it doesn't (TCP keepalives see to a dead route),
        // unless it has run far longer than any answer takes (lane DB8): then the database stopped answering without
        // closing the connection (a frozen server, a route that drops what it's sent), which keepalives don't notice while
        // a statement waits for its answer.
        if await link.isBusy {
            guard let since = await link.busySince, Date().timeIntervalSince(since) > 2 * timeout else { return false }
            await link.close()
            throw Problem.stoppedAnswering
        }
        let answered = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await link.execute(TeamQueries.ping)
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return false
            }
            let first = try await group.next() ?? false
            if !first { await link.close() }
            group.cancelAll()
            return first
        }
        if !answered { throw Problem.stoppedAnswering }
        return true
    }

    private func heardOfChange() {
        feedChanged = true
    }

    /// How many outbox items go in one transaction at most (lane DB10): few enough that a call made meanwhile (a probe, a
    /// note's presence) waits well under a second behind them, even far away.
    static let sentTogether = 8

    private func work(_ link: TeamDatabaseLink, nudges: AsyncStream<Void>) async throws {
        status = .catchingUp
        stalledSince = nil
        try await catchUp(link)
        status = .connected
        heard()
        try await drain(link)
        for await _ in nudges {
            try Task.checkCancellation()
            try await catchUp(link)
            try await drain(link)
        }
        throw Problem.closed
    }

    /// Reads the feed after the last number this Mac read, a page at a time, with the rows each page touched as they are
    /// now, and which binders this member started or stopped seeing (their own changes are invisible once they're gone).
    private func catchUp(_ link: TeamDatabaseLink) async throws {
        let visible = try await link.visibleBinders()
        if readAllAgain {
            // Every binder counts as newly shared, read whole; the feed from now on.
            binders = []
            delivered = try await link.lastSeq()
            readAllAgain = false
        }
        var added = visible.subtracting(binders)
        var removed = binders.subtracting(visible)
        binders = visible
        while true {
            if let latency = testHooks.latency { try await Task.sleep(for: latency) }
            let changes = try await link.changes(after: delivered, limit: Self.pageSize)
            if changes.isEmpty, added.isEmpty, removed.isEmpty { return }
            let batch = TeamChangeBatch(changes)
            var rows: [TeamTable: [TeamRow]] = [:]
            for (table, ids) in batch.rowsToRead {
                // A note's document and words only when the app asks for them (TeamNotes.apply reads a row whole for a note
                // it makes the document of): what most rows carry is a note this Mac already has (lane DB10).
                let leaving = table == .notes && lightNoteRows ? TeamQueries.noteRowHeavyColumns : []
                rows[table] = try await link.rows(table, ids: ids, leaving: leaving)
            }
            if let read = rows[.notes] {
                TeamPerf.shared.count { $0.noteRowsRead += read.count; $0.documentsRead += read.filter { $0["document"]?.bytes != nil }.count }
            }
            delivered = max(delivered, batch.lastSeq ?? delivered)
            updatesContinuation.yield(TeamUpdate(changes: batch.changes, rows: rows, gone: batch.gone(read: rows), bindersAdded: added,
                                                 bindersRemoved: removed, binders: visible, lastSeq: delivered))
            added = []
            removed = []
            if changes.count < Self.pageSize { return }
        }
    }

    /// Sends what waits, oldest first, one at a time. An item leaves with a definite answer: applied, refused, or an
    /// error a retry wouldn't change. Anything else (the connection, a rollback, the server shutting down) ends the
    /// session with the item still first, to go again, with the same operation id, once connected.
    private func drain(_ link: TeamDatabaseLink) async throws {
        while let item = files.outbox.next {
            if item.added < Date().addingTimeInterval(-Self.oldestSent) {
                settle(item, .failed("This change waited on this Mac for more than 29 days, longer than the team database keeps its record of changes, so Binders didn't send it."))
                continue
            }
            // A change the database decides goes only while it's fresh (lane DB8). Left here past its time (its answer lost
            // with the connection, or stuck behind changes the database was slow to take), it goes again only when the
            // database has it already, which gives back its first answer; otherwise it's taken back and whoever made it
            // hears it didn't go through, rather than have it land long after they were told it hadn't.
            if let sendBy = item.sendBy, sendBy < Date() {
                let known: Bool
                do {
                    known = try await link.value(TeamQueries.operationKnown, [item.id.uuidString.lowercased()], as: Bool.self) ?? false
                } catch let error as PSQLError where error.code == .server {
                    known = false
                }
                heard()
                if !known {
                    settle(item, .failed(TeamBoardWrites.notSentLate))
                    continue
                }
            }
            while let hold = testHooks.holdBeforeSending, hold(item) { try await Task.sleep(for: .milliseconds(50)) }
            if let latency = testHooks.latency { try await Task.sleep(for: latency) }
            // Taken back meanwhile (`withdraw`): it never goes.
            guard files.outbox.items.contains(where: { $0.id == item.id }) else { continue }
            // The items after it that can go with it, in one transaction (lane DB10): not one the database decides, nor one
            // held back.
            let batch = alone > 0 ? [item] : together(from: item)
            if batch.count > 1 {
                try await send(batch, on: link)
            } else {
                if alone > 0 { alone -= 1 }
                try await send(item, on: link)
            }
            // What changed for the team meanwhile, read before the rest goes.
            if feedChanged {
                feedChanged = false
                try await catchUp(link)
            }
        }
    }

    /// `first`, and the items waiting after it that can go in the same transaction: new notes, each another note (sharing a
    /// binder of hundreds). Only those: a transaction gives every call in it the same time, which a note's versions and a
    /// card's timeline go by, so changes to what's there already go one at a time, as before.
    private func together(from first: TeamOutboxItem) -> [TeamOutboxItem] {
        func joins(_ item: TeamOutboxItem) -> Bool {
            item.call.function == "create_note" && item.call.note != nil && item.sendBy == nil && item.call.statement != nil
                && item.added >= Date().addingTimeInterval(-Self.oldestSent) && !(testHooks.holdBeforeSending?(item) ?? false)
        }
        guard joins(first) else { return [first] }
        var batch = [first]
        var notes: Set<UUID> = [first.call.note!]
        for item in files.outbox.items.drop(while: { $0.id != first.id }).dropFirst() {
            guard batch.count < Self.sentTogether, joins(item), let note = item.call.note, notes.insert(note).inserted else { break }
            batch.append(item)
        }
        return batch
    }

    /// One item: its answer kept, or the session ended with it still first, to go again.
    private func send(_ item: TeamOutboxItem, on link: TeamDatabaseLink) async throws {
        let result: TeamResult
        inFlight = [item.id]
        do {
            result = try await link.call(item.call)
            inFlight = []
            heard()
        } catch let error as PSQLError where error.code == .server && !TeamErrors.isRetryable(sqlState: error.sqlState) {
            inFlight = []
            settle(item, .failed(TeamErrors.describe(sqlState: error.sqlState, message: error.plainMessage)))
            return
        } catch let error as TeamDatabaseLink.Problem where error != .closed {
            inFlight = []
            settle(item, .failed(error.localizedDescription))
            return
        } catch {
            inFlight = []
            files.attempted(item.id, error: Self.describe(error).reason)
            throw error
        }
        if let drop = testHooks.dropAfterAnswer, drop(item) {
            files.attempted(item.id, error: "The connection closed before the answer arrived")
            await link.close()
            throw Problem.closed
        }
        settle(item, result.refusal.map { .refused($0) } ?? .applied(result))
    }

    /// Several items in one transaction (lane DB10), each answered as if it had gone alone. One the database turns down with
    /// an error rolls them all back: they go again one at a time, so only that one is answered with it.
    private func send(_ batch: [TeamOutboxItem], on link: TeamDatabaseLink) async throws {
        let results: [TeamResult]
        inFlight = Set(batch.map(\.id))
        do {
            results = try await link.calls(batch.map(\.call))
            inFlight = []
            heard()
        } catch let error as PSQLError where error.code == .server && !TeamErrors.isRetryable(sqlState: error.sqlState) {
            inFlight = []
            alone = batch.count
            return
        } catch let error as TeamDatabaseLink.Problem where error != .closed {
            inFlight = []
            alone = batch.count
            return
        } catch {
            inFlight = []
            for item in batch { files.attempted(item.id, error: Self.describe(error).reason) }
            throw error
        }
        for (index, (item, result)) in zip(batch, results).enumerated() {
            if let drop = testHooks.dropAfterAnswer, drop(item) {
                for rest in batch[index...] { files.attempted(rest.id, error: "The connection closed before the answer arrived") }
                await link.close()
                throw Problem.closed
            }
            settle(item, result.refusal.map { .refused($0) } ?? .applied(result))
        }
    }

    private func settle(_ item: TeamOutboxItem, _ outcome: TeamOutcome) {
        files.settle(item.id)
        waiting = files.outbox.count
        recent.append((item.id, outcome))
        if recent.count > 500 { recent.removeFirst(recent.count - 500) }
        outcomesContinuation.yield(TeamOutboxOutcome(operation: item.id, call: item.call, outcome: outcome))
        for waiter in waiters.removeValue(forKey: item.id) ?? [] { waiter.resume(returning: outcome) }
    }
}

// MARK: Changes and reads

extension TeamDatabase {
    /// Queues a change: saved on disk at once, sent in its turn, now or once connected. Returns its operation id;
    /// `outcome(of:)` waits for its answer. Calls that carry a password are never queued (they go with `call`): one is
    /// answered failed at once.
    /// `sendBy`: for a change the database decides, when it stops being worth sending (TeamOutboxItem.sendBy).
    @discardableResult
    func send(_ call: TeamCall, sendBy: Date? = nil) -> UUID {
        if files.add(call, sendBy: sendBy) {
            waiting = files.outbox.count
            nudge?.yield()
        } else {
            let item = TeamOutboxItem(call: call, added: Date())
            settle(item, .failed("A change that carries a password is sent at once, never kept waiting on this Mac."))
        }
        return call.operation
    }

    /// The answer to a change sent through the outbox, once it comes: at once for one answered lately.
    func outcome(of operation: UUID) async -> TeamOutcome {
        if let done = recent.last(where: { $0.operation == operation }) { return done.outcome }
        guard files.outbox.items.contains(where: { $0.id == operation }) else {
            return .failed("This Mac has no change with that id waiting.")
        }
        return await withCheckedContinuation { waiters[operation, default: []].append($0) }
    }

    /// What waits in the outbox, oldest first.
    var queued: [TeamOutboxItem] { files.outbox.items }

    /// What taking a change back from the outbox did (lane DB8).
    enum Withdrawal: Equatable {
        /// It was still waiting: it's gone, and never sent.
        case withdrawn
        /// It's on its way now, so it may yet go through; past its `sendBy` it's sent again only if the database has it.
        case sending
        /// It had its answer already.
        case answered
    }

    /// Takes a change back before it's sent: a change the database decides whose answer didn't come in time.
    func withdraw(_ operation: UUID) -> Withdrawal {
        if inFlight.contains(operation) { return .sending }
        guard files.outbox.items.contains(where: { $0.id == operation }) else { return .answered }
        files.settle(operation)
        waiting = files.outbox.count
        let outcome = TeamOutcome.failed("Taken back before it was sent.")
        recent.append((operation, outcome))
        if recent.count > 500 { recent.removeFirst(recent.count - 500) }
        for waiter in waiters.removeValue(forKey: operation) ?? [] { waiter.resume(returning: outcome) }
        return .withdrawn
    }

    private func connected() throws -> TeamDatabaseLink {
        guard let link, !link.isClosed, status.isConnected else { throw Problem.offline }
        // Connected but not answering (lane DB8): a call now would wait as long as the connection stays open.
        guard stalledSince == nil else { throw Problem.stoppedAnswering }
        return link
    }

    /// One call now, past the outbox: for admin work and passwords, or a caller that must know at once. Throws when
    /// this Mac isn't connected, or the database turned it down with an error; a refusal is an answer.
    func call(_ call: TeamCall) async throws -> TeamResult {
        try await connected().call(call)
    }

    /// Every row of `table` in `binder` this member sees (a team table: every row).
    func rows(_ table: TeamTable, binder: UUID) async throws -> [TeamRow] {
        try await connected().rows(table, binder: binder)
    }

    /// Rows of `table` by id; the ones this member can't see aren't there.
    func rows(_ table: TeamTable, ids: [UUID]) async throws -> [TeamRow] {
        try await connected().rows(table, ids: ids)
    }

    /// The binders this member sees now.
    func visibleBinders() async throws -> Set<UUID> {
        try await connected().visibleBinders()
    }

    /// One read now, answered as JSON (lane DB3: one note's changes, when this Mac's copy of it is gone).
    func json(_ sql: String, _ values: [String?] = []) async throws -> TeamJSON {
        try await connected().json(sql, values)
    }

    /// Everything in a binder at one moment, every table, and the feed's number then: what a Mac reads for a binder
    /// newly shared with it (or when it first joins), before applying the feed after that number. On a connection of its
    /// own, so the outbox never runs inside its read-only transaction.
    func snapshot(binder: UUID) async throws -> (seq: Int64, rows: [TeamTable: [TeamRow]]) {
        _ = try connected()
        guard let password = Keychain.read(Self.passwordKey(server)).flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw TeamDatabaseLink.Problem.noPassword
        }
        let reader = try await TeamDatabaseLink.connect(to: server, password: password, trust: trust)
        do {
            try await reader.execute(TeamQueries.beginSnapshot)
            let seq = try await reader.lastSeq()
            var rows: [TeamTable: [TeamRow]] = [:]
            for table in TeamTable.binderTables {
                rows[table] = try await reader.rows(table, binder: binder)
            }
            try await reader.execute(TeamQueries.endSnapshot)
            await reader.close()
            return (seq, rows)
        } catch {
            await reader.close()
            throw error
        }
    }

    // MARK: Admin

    /// An admin adds a person, or a headless agent with its own login (`agent`: the agent's id and name): their login,
    /// with a one-time password that goes in the invite, shown once. Refused (a login that's taken, say) with its reason.
    func addMember(login: String, name: String, agent: (id: UUID, name: String)? = nil) async throws -> TeamInvite {
        let password = TeamPassword.generate()
        let result = try await call(.addMember(UUID(), login: login, name: name, verifier: TeamPassword.verifier(for: password),
                                               agent: agent))
        if let refusal = result.refusal { throw refusal }
        return invite(login: login, password: password)
    }

    /// An admin gives a member a new one-time password, for an invite again.
    func resetPassword(member: UUID, login: String) async throws -> TeamInvite {
        let password = TeamPassword.generate()
        let result = try await call(.resetPassword(member, verifier: TeamPassword.verifier(for: password)))
        if let refusal = result.refusal { throw refusal }
        return invite(login: login, password: password)
    }

    private func invite(login: String, password: String) -> TeamInvite {
        TeamInvite(server: TeamDatabaseServer(host: server.host, port: server.port, database: server.database, login: login,
                                              serverName: server.serverName),
                   oneTimePassword: password, teamName: team?["name"]?.string ?? "")
    }
}

/// The first of two answers to a probe, the ping's or the clock's, given once.
final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var early: Bool?
    private var done = false

    func arm(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(returning: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ answered: Bool) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        guard let continuation else {
            early = answered
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: answered)
    }
}
