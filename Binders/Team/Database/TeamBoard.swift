import Foundation
import Observation
import SwiftData
import BindersKit

/// Boards and agents on the team database (lane DB2). Owns this Mac's `TeamDatabase` (from Settings → Team) and is the
/// only code that turns the team's rows into this Mac's copy (`TaskCard`, `TaskEvent`, `BinderRecord`) and this Mac's
/// board changes into the database's calls:
/// - going: `BoardService` makes a change here at once, then hands it over (`send`); its lines wait for the answer,
///   which puts the database's own lines in their place, or puts the card back as the database has it, with why;
/// - coming: `TeamDatabase.updates`, applied idempotently, named by id ("You", teammates by name, this Mac's agents by
///   their own names, a teammate's agent with its owner), and heard as the board's own changes are (the dispatcher,
///   questions that ring here);
/// - agents: this Mac's agents' public rows, kept current; who's who in the team (`TeamDirectory`);
/// - Settings → Team's setup, invites, members and sharing (TeamBoardAdmin.swift).
@MainActor
@Observable
final class TeamBoard {
    @ObservationIgnored weak var controller: DictationController?
    private(set) var database: TeamDatabase?
    var server: TeamDatabaseServer?
    /// Who's who, the shared binders as the database last had them, and what was published: kept beside the outbox.
    var state = TeamBoardState()
    /// What went wrong outside a connection (a setup, a join, an invite), for Settings → Team.
    var problem: String?
    /// An invite opened on this Mac, waiting for Join in Settings → Team.
    var pendingInvite: TeamInvite?
    /// Moving this Mac's team folder over (lane DB3): setting up or joining a database is allowed while it's in one.
    @ObservationIgnored var movingFolderTeam = false

    /// For the self-tests: whose certificates to trust, where the files go, how often this Mac says it's around, how long
    /// edits gather before they go.
    @ObservationIgnored var trust: TeamDatabaseLink.Trust = .system
    @ObservationIgnored var folderOverride: URL?
    @ObservationIgnored var heartbeat: TimeInterval = 300
    @ObservationIgnored var editDelay: Duration = .seconds(1)
    /// For the self-tests: set up the database client before it starts (quicker reconnects).
    @ObservationIgnored var prepare: ((TeamDatabase) -> Void)?
    /// Every question or request for approval that rang here because of the team (card, kind), for the self-tests.
    @ObservationIgnored private(set) var rang: [(card: UUID, kind: String)] = []
    /// The operation of the last change handed over, for whoever made it and waits for its answer (InboxCommands).
    @ObservationIgnored private(set) var lastSent: UUID?
    /// Every change handed over, newest last (the last 200), and how many in all: what one write sent is what came after.
    @ObservationIgnored private(set) var sentLog: [UUID] = []
    @ObservationIgnored private(set) var sentTotal = 0

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// Meetings, captures, to-dos and knowledge on the database (lane DB4).
    @ObservationIgnored private(set) lazy var content = TeamContent(team: self)
    @ObservationIgnored var saveObserver: NSObjectProtocol?
    @ObservationIgnored var editCheck: Task<Void, Never>?
    @ObservationIgnored private var publishing: Task<Void, Never>?
    /// Card rows held back while this Mac's own changes to the card wait for their answers: the newest of each.
    @ObservationIgnored var latest: [UUID: TeamRow] = [:]
    /// When each `card_dependencies` row last changed, as read: an older read of it doesn't win.
    @ObservationIgnored var dependencyTimes: [UUID: Date] = [:]
    /// Lines written here that the database's own replaced, by their ids here: a decision from your iPhone names the request
    /// it saw.
    @ObservationIgnored var replacements: [UUID: UUID] = [:]
    /// Each refused change's reason in this Mac's words, as it said it once the card was put back.
    @ObservationIgnored var refusalWords: [UUID: String] = [:]
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<TeamOutcome?, Never>]] = [:]
    @ObservationIgnored private var answered: [UUID: TeamOutcome] = [:]
    /// The shared binders' ids on this Mac, read again when one changes.
    @ObservationIgnored private var sharedCache: Set<UUID>?
    /// The team folder this Mac synced when `sharedCache` was worked out (lane DB9).
    @ObservationIgnored private var sharedCacheFolder: String?
    @ObservationIgnored private var connected = false
    /// Notes, folders, Distill's records and who's in a note, on the same database (lane DB3).
    @ObservationIgnored private(set) lazy var notes = TeamNotes(board: self)
    /// The team database's default, heard while Binders runs (lane DB5): off disconnects at once, on connects again.
    @ObservationIgnored private var featureWatcher: TeamDatabaseFeature.Watcher?
    /// While team databases are turned off on this Mac and one is set up here (lane DB8): its outbox on disk, who's who
    /// as it was last kept, and the binders shared through it, so their boards' changes that can wait are kept for it and
    /// what it decides is refused (TeamBoardReach.swift). Nil while it runs, and on a Mac without one.
    var parked: TeamParking?
    /// Turning off: from the moment the default goes off until the connection has closed, the shared boards read as off.
    private(set) var turningOff = false
    /// Changes the database decides, still waiting for their answers: the call and the card as it was before, to put it
    /// back if the change is taken back unsent (lane DB8).
    @ObservationIgnored var befores: [UUID: (call: TeamCall, before: TeamCardBefore)] = [:]

    /// A card kept on this Mac (made from what your iPhone heard) until you share it: its `teamShadow`.
    nonisolated static let held = "held"
    /// The app's own, while one runs: MCP tools answered in the app read who's who from it.
    static weak var current: TeamBoard?

    var directory: TeamDirectory { state.directory }
    var status: TeamDatabaseStatus { database?.status ?? .off }
    var isConnected: Bool { database?.status == .connected }
    var store: Store { Store.shared }

    // MARK: Starting

    /// The team database Settings → Team saved, if any; none while the team database is off (`TeamDatabaseFeature`), when a
    /// Mac with one set up keeps it as it is and leaves it alone.
    static func savedServer() -> TeamDatabaseServer? {
        guard TeamDatabaseFeature.isOn, let text = AppSettings.shared.teamDatabase, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TeamDatabaseServer.self, from: data)
    }

    static func save(_ server: TeamDatabaseServer?) {
        AppSettings.shared.teamDatabase = server.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Who's who in the team, as the app last kept it beside the outbox: for `Binders --mcp`, which runs no team database of
    /// its own. Nil without a team database.
    static func savedDirectory() -> TeamDirectory? {
        guard let server = savedServer() else { return nil }
        let url = TeamDatabaseFiles.folder(for: server).appendingPathComponent("board.json")
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(TeamBoardState.self, from: data) else { return nil }
        return state.directory
    }

    /// Starts with the database Settings → Team saved, if there is one, and from then on follows the team database's
    /// default as it's turned off and on.
    func start() {
        watchFeature()
        guard database == nil, let server = Self.savedServer() else { return park() }
        run(server)
    }

    /// Hears the team database's default from now on (TeamDatabaseFeature.Watcher): turned off while Binders runs, this Mac
    /// disconnects at once and shows nothing of it, as at a launch with it off; on again, it connects to the database
    /// saved here.
    func watchFeature() {
        guard featureWatcher == nil else { return }
        featureWatcher = TeamDatabaseFeature.Watcher { [weak self] on in
            guard let self else { return }
            if on {
                self.start()
            } else {
                Task { @MainActor in await self.turnOff() }
            }
        }
    }

    /// The default went off: disconnect now and forget, on this Mac's screens, who's who and which binders go through the
    /// database, as a launch with it off would. What's kept on disk (the saved database, who's who, the outbox and this
    /// Mac's copies of the shared binders) stays as it is, for when it's on again.
    func turnOff() async {
        guard database != nil || server != nil else { return park() }
        // Its boards read as off at once, while the connection closes (lane DB8): nothing waits on it meanwhile.
        turningOff = true
        if database != nil { saveState() }
        await stop()
        server = nil
        state = TeamBoardState()
        pendingInvite = nil
        problem = nil
        sharedChanged()
        if Self.current === self { Self.current = nil }
        turningOff = false
        park()
    }

    /// Connects to `server` and keeps this Mac's copy of its shared boards current until `stop`.
    func run(_ server: TeamDatabaseServer) {
        guard database == nil else { return }
        // What was kept for it while it was off goes now, from its outbox on disk (lane DB8).
        unpark()
        Self.current = self
        self.server = server
        sharedCache = nil
        loadState()
        state.directory.local = localAgents()
        let database = TeamDatabase(server: server, trust: trust, folder: folder)
        self.database = database
        prepare?(database)
        database.start()
        notes.start(database)
        tasks = [
            Task { [weak self] in
                for await update in database.updates {
                    guard let self else { return }
                    await self.apply(update, from: database)
                }
            },
            Task { [weak self] in
                for await outcome in database.outcomes {
                    guard let self else { return }
                    await self.settle(outcome, from: database)
                }
            },
            Task { [weak self] in await self?.watch(database) },
        ]
        watchSaves()
        observeChanges({ [weak self] in self?.agentsView() ?? AgentsView() }) { [weak self] _ in self?.publishSoon() }
        content.start()
    }

    /// Disconnects. What waits in the outbox stays for the next start.
    func stop() async {
        content.stop()
        for task in tasks { task.cancel() }
        tasks = []
        editCheck?.cancel()
        publishing?.cancel()
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        saveObserver = nil
        // Notes say this Mac left them when the database answers in a moment; one that doesn't answer doesn't hold up
        // stopping (lane DB8): closing the connection ends the wait, and the notes finish stopping then.
        let notesStopped = Task { @MainActor [notes] in await notes.stop() }
        _ = await Self.waiting(.seconds(3)) { await notesStopped.value }
        await database?.stop()
        await notesStopped.value
        database = nil
        connected = false
        for (operation, list) in waiters {
            for waiter in list { waiter.resume(returning: nil) }
            waiters[operation] = nil
        }
    }

    /// Everything kept for the team written to disk now (quitting, lane DB10): the outbox whole, in the file an earlier
    /// Binders reads too, and the notes' states and documents.
    func flushToDisk() {
        notes.engine?.flush()
        database?.flushFiles()
    }

    /// Where its files go: the outbox's folder, unless a self-test gave one.
    var folder: URL? {
        guard let server else { return folderOverride }
        return folderOverride ?? TeamDatabaseFiles.folder(for: server)
    }

    // MARK: The connection

    /// While connected: who's who read again, this Mac's agents published, binders still to read whole read, and every
    /// few minutes a word that it's around (with how far it read, which pruning keeps), and a prune once a day.
    private func watch(_ database: TeamDatabase) async {
        var lastBeat = Date.distantPast
        while !Task.isCancelled {
            if database.status == .connected {
                if !connected {
                    connected = true
                    await came(online: database)
                    lastBeat = Date()
                }
                if Date().timeIntervalSince(lastBeat) >= heartbeat {
                    lastBeat = Date()
                    await beat(database)
                }
            } else {
                connected = false
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func came(online database: TeamDatabase) async {
        await readDirectory(database)
        publishAgents()
        await readWholeWhatsLeft(database)
        await beat(database)
        sendEdits()
        await content.cameOnline()
    }

    private func beat(_ database: TeamDatabase) async {
        let mine = state.directory.agents.values.filter { state.directory.isMine($0) && $0.login == nil && !$0.removed }.map(\.id)
        _ = try? await database.call(.seen(seq: database.acknowledgedSeq, agents: mine))
        await readDirectory(database)
        if state.lastPrune.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true {
            state.lastPrune = Date()
            saveState()
            _ = try? await database.call(.prune())
        }
    }

    /// Members and agents, read whole (they're small): names for everything this Mac writes.
    func readDirectory(_ database: TeamDatabase) async {
        guard let members = try? await database.rows(.members, binder: UUID()),
              let agents = try? await database.rows(.agents, binder: UUID()) else { return }
        var directory = state.directory
        directory.me = database.member?["id"]?.uuid ?? directory.me
        directory.members = [:]
        for row in members { directory.take(member: row) }
        // Session agents this Mac made known before their rows came back stay known.
        let sessions = directory.agents.filter { $0.value.kind == "session" }
        directory.agents = [:]
        for row in agents { directory.take(agent: row) }
        for (id, agent) in sessions where directory.agents[id] == nil { directory.agents[id] = agent }
        directory.local = localAgents()
        if directory != state.directory {
            state.directory = directory
            saveState()
        }
    }

    // MARK: The shared binders

    /// Whether a binder's board goes through the team database.
    func covers(_ binderID: UUID?) -> Bool {
        guard let binderID, server != nil else { return false }
        return sharedBinders.contains(binderID)
    }

    func covers(_ card: TaskCard) -> Bool { covers(card.binderID) }

    /// Whether this card's changes go to the team database: on a shared board, and not one kept on this Mac.
    func sends(_ card: TaskCard) -> Bool {
        (database != nil && covers(card) && card.teamShadow != Self.held) || parks(card)
    }

    /// The binders shared through this database, by id. A binder the team folder this Mac still syncs shares isn't one
    /// (lane DB9): a Mac never syncs one binder both ways at once. Joining from Move This Team to a Database… and cancelling,
    /// or opening Binders with both set up, leaves it the folder's, as it was; the move brings it over, then it's read whole.
    var sharedBinders: Set<UUID> {
        let folder = AppSettings.shared.teamFolderPath
        if let sharedCache, sharedCacheFolder == folder { return sharedCache }
        guard let key = server?.key else { return [] }
        let found = Set(((try? store.context.fetch(FetchDescriptor<BinderRecord>(predicate: #Predicate { $0.teamDatabaseKey == key }))) ?? [])
            .filter { folder == nil || !($0.sharedWithTeam || $0.isTeamCopy) }.map(\.id))
        sharedCache = found
        sharedCacheFolder = folder
        return found
    }

    /// Whether a binder is one of this database's that the team folder this Mac still syncs keeps for now (`sharedBinders`
    /// leaves it out): the database leaves it alone on this Mac until the move, deleting nothing of it for the team.
    func keptByFolder(_ binderID: UUID?) -> Bool {
        guard AppSettings.shared.teamFolderPath != nil, let key = server?.key, let binder = store.binder(binderID) else { return false }
        return binder.teamDatabaseKey == key && (binder.sharedWithTeam || binder.isTeamCopy)
    }

    /// The shared binders changed: worked out again when next asked. Agents' rows this Mac has published say again which
    /// they take cards from (lane DB9: a binder that arrived after they were first published was missing from them until
    /// something else changed).
    func sharedChanged() {
        sharedCache = nil
        if database != nil, !state.published.isEmpty { publishSoon() }
    }

    // MARK: Approvals

    /// Whether this Mac's member decides on the approval a card waits on, asked by `agent` (as this Mac names it): on a
    /// board that isn't shared, always; on a shared one, when it's their agent asking or the card is meant for them
    /// (BoardRules.deciders, TeamDirectory). Nil when this Mac can't tell: the team database decides then.
    func decides(_ card: TaskCard, askedBy agent: String) -> Bool? {
        guard covers(card), card.teamShadow != Self.held else { return true }
        return state.directory.decides(askedBy: agent, meantFor: card.meantFor, suggested: card.meantForByAgent)
    }

    /// Who decides, in words, for someone who doesn't.
    func onlyDeciders(_ card: TaskCard, askedBy agent: String) -> String {
        state.directory.onlyDeciders(askedBy: agent, meantFor: card.meantFor, suggested: card.meantForByAgent)
    }

    // MARK: Waiting for an answer

    /// The answer to a change handed over, once this Mac has applied it (its lines, the card as the database left it, or
    /// the card put back): nil when none came within `timeout`.
    func settled(_ operation: UUID, within timeout: Duration = .seconds(10)) async -> TeamOutcome? {
        if let done = answered[operation] { return done }
        return await withCheckedContinuation { continuation in
            waiters[operation, default: []].append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(operation, with: nil)
            }
        }
    }

    func resume(_ operation: UUID, with outcome: TeamOutcome?) {
        if let outcome {
            answered[operation] = outcome
            if answered.count > 400 { answered.removeAll() }
        }
        for waiter in waiters.removeValue(forKey: operation) ?? [] { waiter.resume(returning: outcome) }
    }

    func noteSent(_ operation: UUID) {
        lastSent = operation
        sentLog.append(operation)
        sentTotal += 1
        if sentLog.count > 200 { sentLog.removeFirst(sentLog.count - 200) }
    }

    /// The changes handed over since `total` changes had been: what one write sent.
    func sent(since total: Int) -> [UUID] {
        Array(sentLog.suffix(max(0, min(sentTotal - total, sentLog.count))))
    }

    /// Waits for the answers to these changes: the first refusal, in this Mac's words; nil when all went through. `timedOut`
    /// when the database didn't answer them all within `timeout`, which is one wait for all of them, of 5 seconds at most
    /// (lane DB8): the database then counts as stalled until it answers again, so what comes next doesn't wait for it too.
    func answers(to operations: [UUID], within timeout: Duration) async -> (refused: String?, timedOut: Bool) {
        let deadline = ContinuousClock.now + min(timeout, .seconds(TeamBoardWrites.agentWait))
        for operation in operations {
            let left = deadline - ContinuousClock.now
            var outcome = answered[operation]
            if outcome == nil, left > .zero { outcome = await settled(operation, within: left) }
            guard let outcome else {
                database?.stalled()
                return (nil, true)
            }
            switch outcome {
            case .applied: continue
            case .refused(let refusal): return (refusalWords[operation] ?? words(refusal), false)
            case .failed(let message): return (message, false)
            }
        }
        return (nil, false)
    }

    /// The database's id for a line written here that its own line replaced.
    func replaced(_ id: UUID) -> UUID? { replacements[id] }

    // MARK: Rings

    /// A question or a request for approval from the team that rings here (TeamDirectory.rings).
    func ring(_ kind: TaskEvent.Kind, text: String, on card: TaskCard, by agent: String) {
        rang.append((card.id, kind.rawValue))
        if rang.count > 100 { rang.removeFirst(rang.count - 100) }
        switch kind {
        case .question: MacNotifications.shared.post(question: text, on: card, by: agent)
        case .approval: if let approval = AgentApproval(timeline: text) { MacNotifications.shared.post(approval: approval, on: card, by: agent) }
        default: break
        }
    }

    // MARK: This Mac's agents

    /// This Mac's agents by their id in the team (their own ids), with the names they go by here.
    func localAgents() -> [UUID: String] {
        Dictionary(AgentRegistry.shared.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// What publishing depends on, so a change to any of it publishes again.
    struct AgentsView: Equatable {
        var agents: [AgentProfile] = []
        var paused = false
        var working: Set<UUID> = []
        var shared: Set<UUID> = []
    }

    private func agentsView() -> AgentsView {
        AgentsView(agents: AgentRegistry.shared.agents, paused: AgentRegistry.shared.paused, working: controller?.agents.working ?? [],
                   shared: sharedBinders)
    }

    /// Publishes again a moment after something it depends on changed.
    func publishSoon() {
        publishing?.cancel()
        publishing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.state.directory.local = self?.localAgents() ?? [:]
            self?.publishAgents()
        }
    }

    /// This Mac's agents' public rows, sent when they changed since they were last sent (TeamAgentRow: never how an agent
    /// runs), and an agent taken off this Mac taken off the team's list.
    func publishAgents() {
        guard let database, let me = state.directory.me, let owner = state.directory.myName else { return }
        let registry = AgentRegistry.shared
        let shared = sharedBinders
        var changed = false
        for agent in registry.agents {
            let fields = TeamAgentRow.fields(for: agent, owner: owner, binders: shared.filter { agent.takesCards(from: $0) }.sorted { $0.uuidString < $1.uuidString },
                                             startsOnTeammatesCards: startsOnTeammatesCards(agent), status: status(of: agent),
                                             runningCard: runningCard(of: agent), online: nil)
            let print = TeamJSON.object(fields).text
            guard state.published[agent.id] != print else { continue }
            state.published[agent.id] = print
            database.send(.putAgent(agent.id, fields: fields))
            changed = true
        }
        let listed = Set(registry.agents.map(\.id))
        for agent in state.directory.agents.values where agent.owner == me && agent.login == nil && agent.kind != "session" && !agent.removed
            && !listed.contains(agent.id) && state.published[agent.id] != "removed" {
            database.send(.removeAgent(agent.id))
            state.published[agent.id] = "removed"
            changed = true
        }
        if changed { saveState() }
    }

    /// Whether it starts on teammates' cards on its own: its Take cards from teammates and its start switch, with its
    /// Keychain yes, both on, and Binders may wake it.
    func startsOnTeammatesCards(_ agent: AgentProfile) -> Bool {
        let registry = AgentRegistry.shared
        return agent.takesTeammatesCards && registry.startsOnItsOwn(agent) && registry.wakeable(agent)
    }

    private func status(of agent: AgentProfile) -> String {
        if !agent.isEnabled { return "off" }
        if AgentRegistry.shared.paused { return "paused" }
        if runningCard(of: agent) != nil { return "working" }
        return "ready"
    }

    /// The card in a shared binder its run is on, if one is going.
    private func runningCard(of agent: AgentProfile) -> UUID? {
        guard let controller else { return nil }
        for id in controller.agents.working.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let card = controller.board.card(id), covers(card) else { continue }
            if card.assignee.map({ AgentRegistry.isAgent(agent, named: $0) }) == true || card.meantFor.map({ AgentRegistry.isAgent(agent, named: $0) }) == true {
                return id
            }
        }
        return nil
    }

    /// The team's id for whoever acts: nil for a person (this Mac's member acts), an agent's own id for one set up in
    /// Settings → Agents (its row published first), else a session's (its row made the first time).
    func agentID(for actor: BoardActor) -> UUID? {
        guard actor.isAgent else { return nil }
        if let parked { return parked.agentID(for: actor, board: self) }
        if let agent = AgentRegistry.shared.agents.first(where: { AgentRegistry.isAgent($0, named: actor.name) }) {
            if state.published[agent.id] == nil { publishAgents() }
            return agent.id
        }
        guard let me = state.directory.me, let owner = state.directory.myName else { return nil }
        let id = TeamNames.sessionAgentID(member: me, name: actor.name)
        if state.published[id] == nil, let database {
            let fields = TeamAgentRow.session(name: actor.name, owner: owner)
            state.published[id] = TeamJSON.object(fields).text
            database.send(.putAgent(id, fields: fields))
            state.directory.agents[id] = TeamDirectory.Agent(id: id, owner: me, name: TeamNames.published(actor.name, owner: owner), kind: "session")
            saveState()
        }
        return id
    }

    /// Whether an agent acting through this Mac can be named to the team now: this Mac knows who it is there.
    var knowsItself: Bool { writingDirectory.me != nil && writingDirectory.myName != nil }

    /// Who's who for what this Mac writes to the team: as it was last kept, while team databases are off (lane DB8).
    var writingDirectory: TeamDirectory { parked?.state.directory ?? state.directory }

    // MARK: A teammate's agent: the yes

    /// A teammate's agent by the name it goes by here ("Claude Code (Dana)"), when it's one.
    func teammatesAgent(named name: String?) -> TeamDirectory.Agent? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let directory = state.directory
        return directory.teammatesAgents.first { directory.name(of: $0).localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// Teammates' agents that take a binder's cards, as they publish it.
    func teammatesAgents(taking binder: UUID?) -> [TeamDirectory.Agent] {
        guard covers(binder) else { return [] }
        return state.directory.teammatesAgents.filter { $0.takes(binder: binder) }
    }

    /// What Binders asks before the first card goes to a teammate's agent.
    func consent(for agent: TeamDirectory.Agent) -> TeamConsent {
        TeamConsent(agent: agent, name: state.directory.name(of: agent), owner: state.directory.ownerName(of: agent))
    }

    private static func consentKey(_ agent: UUID) -> String { AgentRegistry.keychainKey("team-agent-yes-\(agent.uuidString)") }

    /// Whether you said yes to giving this teammate's agent cards, as it is now: its name, owner and who it sends cards to.
    func agreed(to agent: TeamDirectory.Agent) -> Bool {
        let consent = consent(for: agent)
        return Keychain.read(Self.consentKey(agent.id)) == TeamAgentConsent.fingerprint(name: consent.name, owner: consent.owner, sendsTo: agent.sendsTo)
    }

    func agree(to agent: TeamDirectory.Agent) {
        let consent = consent(for: agent)
        Keychain.write(TeamAgentConsent.fingerprint(name: consent.name, owner: consent.owner, sendsTo: agent.sendsTo), for: Self.consentKey(agent.id))
    }

    // MARK: On disk

    private var stateURL: URL? { folder?.appendingPathComponent("board.json") }

    private func loadState() {
        guard let url = stateURL, let data = try? Data(contentsOf: url), let read = try? JSONDecoder().decode(TeamBoardState.self, from: data) else {
            state = TeamBoardState()
            return
        }
        state = read
    }

    func saveState() {
        guard let url = stateURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
    }

    func updateState(_ change: (inout TeamBoardState) -> Void) {
        change(&state)
        saveState()
    }
}

/// What TeamBoard keeps beside the outbox (`board.json`): who's who, each shared binder as the database last had it, what
/// of each agent was last published, binders still to read whole, and when it last pruned.
struct TeamBoardState: Codable, Equatable {
    struct Binder: Codable, Equatable {
        var name: String
        var color: Int
        var agentsMayFinish: Bool
        var agentsMayPlace: Bool
        var everyone: Bool
        /// Made on this Mac (by its member): it stays here, as a local binder, if the team loses it.
        var madeHere: Bool
    }

    var directory = TeamDirectory()
    var binders: [UUID: Binder] = [:]
    /// Who each shared binder is shared with, by member (besides everyone, when it's shared with everyone).
    var binderMembers: [UUID: Set<UUID>] = [:]
    /// Each agent's fields as last sent (JSON text), "removed" once taken off the list.
    var published: [UUID: String] = [:]
    var readWhole: [UUID] = []
    var lastPrune: Date?
}

/// What the database last said of a card on this Mac (`TaskCard.teamShadow`): its version, and the parts an edit here is
/// told apart by.
struct TeamCardShadow: Codable, Equatable {
    var version: Int
    var title: String
    var details: String
    var due: Date?
    var links: [String]
    var distilled: TeamJSON?

    init(version: Int, title: String, details: String, due: Date?, links: [String], distilled: TeamJSON?) {
        self.version = version
        self.title = title
        self.details = details
        self.due = due
        self.links = links
        self.distilled = distilled
    }

    init?(_ text: String) {
        guard !text.isEmpty, text != TeamBoard.held, let read = try? JSONDecoder().decode(TeamCardShadow.self, from: Data(text.utf8)) else { return nil }
        self = read
    }

    var text: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}

/// Giving a card to a teammate's agent, waiting for your yes: asked once, naming its owner and who it sends cards to
/// (TeamAgentConsent), and again when that changes.
struct TeamConsent: Identifiable, Equatable {
    let agent: TeamDirectory.Agent
    let name: String
    let owner: String
    var id: UUID { agent.id }

    var question: String { TeamAgentConsent.question(name) }
    var message: String { TeamAgentConsent.message(owner: owner, sendsTo: agent.sendsTo, headless: agent.login != nil) }
}
