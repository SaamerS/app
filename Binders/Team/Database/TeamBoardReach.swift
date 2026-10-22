import Foundation
import SwiftData
import BindersKit

/// A board shared through the team database while the database is turned off on this Mac, or out of reach (lane DB8).
/// What the database decides (who holds a card, where it is, whether it's done, an approval) is refused at once, before
/// anything changes here; the rest is kept in the outbox and goes once it's back (TeamBoardWrites says which, and why).
/// So every change over MCP and from the iPhone answers within a few seconds whatever the database's state: one the
/// database decides first asks whether it answers (a ping, two seconds at most), and one whose answer then doesn't come
/// within the wait is taken back unsent, its card put back as it was.
extension TeamBoard {
    // MARK: Which boards, and how they stand

    /// Whether this card's changes go to a team database that's turned off on this Mac: on a board shared through it, and
    /// not one kept on this Mac.
    func parks(_ card: TaskCard) -> Bool {
        guard let parked, parked.knowsItself, card.teamShadow != Self.held, let binder = card.binderID else { return false }
        return parked.binders.contains(binder)
    }

    /// Whether a binder's board is shared through the team database set up here, running or turned off.
    func isShared(binder: UUID?) -> Bool {
        if covers(binder) { return true }
        guard let parked, parked.knowsItself, let binder else { return false }
        return parked.binders.contains(binder)
    }

    func isShared(_ card: TaskCard) -> Bool { isShared(binder: card.binderID) }

    /// How this Mac stands with the database its changes go to: off while team databases are turned off (from the moment
    /// they are), unreachable while it isn't connected or doesn't answer.
    var outboxReach: TeamReach {
        if parked != nil || turningOff { return .off }
        guard let database, database.isAnswering else { return .unreachable }
        return .reachable
    }

    /// How a binder's board stands with the database it's shared through: nil for one that isn't.
    func reach(binder: UUID?) -> TeamReach? {
        isShared(binder: binder) ? outboxReach : nil
    }

    /// How a card stands with it: nil for one whose changes don't go to the team (kept on this Mac, or not shared).
    func reach(_ card: TaskCard) -> TeamReach? {
        sends(card) ? outboxReach : nil
    }

    /// Why `write` can't happen on `card` now, in words for whoever asked (`agent`: an agent over MCP); nil when it can. A
    /// database that stopped answering is asked again in the background, so the next try finds it if it's back.
    func refusal(_ write: TeamBoardWrite, on card: TaskCard, agent: Bool) -> String? {
        guard let reach = reach(card), reach != .reachable else { return nil }
        if reach == .unreachable, let database, database.stalledSince != nil { Task { _ = await database.probe() } }
        return TeamBoardWrites.refusal(write, reach, agent: agent)
    }

    /// The same for a binder's board: a card moving onto it while team databases are off (nothing could take it there).
    func refusal(_ write: TeamBoardWrite, binder: UUID?, agent: Bool) -> String? {
        guard reach(binder: binder) == .off else { return nil }
        return TeamBoardWrites.refusal(write, .off, agent: agent)
    }

    /// Before a change the database decides, from MCP or the iPhone, which can wait two seconds: whether it answers now.
    /// Binders' own windows go by what's known (`refusal`).
    func checkReach(_ card: TaskCard) async {
        guard let database, reach(card) == .reachable else { return }
        _ = await database.probe()
    }

    // MARK: Taking a change back

    /// The changes the database decides among `operations`, when their answers didn't come within the wait: one still
    /// waiting in the outbox is taken back unsent, its card put back as it was with a line on this Mac saying why
    /// (`withdrawn`); one already on its way may yet go through (`sending`), and past its time it goes again only if the
    /// database has it. `agent`: whose words the reasons are in.
    func withdraw(_ operations: [UUID], agent: Bool) -> (withdrawn: [TeamCall], sending: [TeamCall]) {
        guard let database else { return ([], []) }
        var withdrawn: [TeamCall] = [], sending: [TeamCall] = []
        for operation in operations {
            guard let (call, before) = befores[operation] else { continue }
            switch database.withdraw(operation) {
            case .withdrawn:
                befores[operation] = nil
                restore(before, call: call, operation: operation, reason: TeamBoardWrites.withdrawn(call, agent: agent))
                withdrawn.append(call)
            case .sending:
                sending.append(call)
            case .answered:
                befores[operation] = nil
            }
        }
        return (withdrawn, sending)
    }

    /// A card as it was before a change taken back unsent: its lines from the change go, and a line by Binders, on this
    /// Mac only, says what didn't go through and why.
    private func restore(_ before: TeamCardBefore, call: TeamCall, operation: UUID, reason: String) {
        guard let board = controller?.board, let card = board.card(before.card) else { return resume(operation, with: .failed(reason)) }
        for line in lines(of: operation) { store.context.delete(line) }
        let wasDone = card.column == .done
        card.state = before.state
        card.position = before.position
        if wasDone != (card.column == .done), let todo = card.sourceRef {
            _ = Todos.setDone(todo, card.column == .done, commitments: controller?.commitments)
        }
        board.note(card, text: TeamRefusalLine.line(call, by: actorName(of: call), reason: reason), toTeam: false)
        // What the database sent of the card meanwhile, held back while this change waited.
        if let row = latest.removeValue(forKey: card.id) { applyCard(row) }
        store.save()
        resume(operation, with: .failed(reason))
    }

    /// Who made a change, as this Mac names them: its agent, or you.
    private func actorName(of call: TeamCall) -> String {
        guard let id = call.argument("p_agent").flatMap(UUID.init(uuidString:)) else { return BoardActor.you.name }
        let directory = writingDirectory
        return directory.local[id] ?? directory.agents[id].map { directory.name(of: $0) } ?? "An agent"
    }

    // MARK: Turned off on this Mac

    /// Team databases are off and one is set up here: its boards' changes that can wait are kept for it from now on, and
    /// what it decides is refused. Nothing connects.
    func park() {
        guard parked == nil, database == nil, !TeamDatabaseFeature.isOn, let server = Self.setUpServer() else { return }
        parked = TeamParking(server: server, folder: folderOverride ?? TeamDatabaseFiles.folder(for: server), trust: trust)
    }

    /// Turned on again: what was kept goes from the outbox on disk, which the database read from now on takes.
    func unpark() {
        parked = nil
    }

    /// The team database set up on this Mac, whether team databases are turned on or off.
    static func setUpServer() -> TeamDatabaseServer? {
        guard let text = AppSettings.shared.teamDatabase, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TeamDatabaseServer.self, from: data)
    }

    /// Waits for `work`, at most `timeout`: true when it ended in time. It isn't stopped then: it ends on its own.
    static func waiting(_ timeout: Duration, for work: @escaping @MainActor () async -> Void) async -> Bool {
        let first = FirstAnswer()
        return await withCheckedContinuation { continuation in
            first.arm(continuation)
            Task { @MainActor in
                await work()
                first.finish(true)
            }
            Task {
                try? await Task.sleep(for: timeout)
                first.finish(false)
            }
        }
    }
}

/// While team databases are turned off on this Mac, the one set up here (lane DB8): its outbox (a TeamDatabase that's
/// never started, so nothing connects and changes only wait in its file), who's who as it was last kept (board.json), and
/// the binders shared through it.
@MainActor
final class TeamParking {
    let server: TeamDatabaseServer
    let outbox: TeamDatabase
    private(set) var state: TeamBoardState
    let binders: Set<UUID>
    private let stateURL: URL

    init(server: TeamDatabaseServer, folder: URL, trust: TeamDatabaseLink.Trust) {
        self.server = server
        outbox = TeamDatabase(server: server, trust: trust, folder: folder)
        stateURL = folder.appendingPathComponent("board.json")
        state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(TeamBoardState.self, from: $0) } ?? TeamBoardState()
        let key = server.key
        binders = Set(((try? Store.shared.context.fetch(FetchDescriptor<BinderRecord>(predicate: #Predicate { $0.teamDatabaseKey == key }))) ?? []).map(\.id))
    }

    /// Whether this Mac knows who it is in the team: it had connected before. A Mac that never did keeps its boards as
    /// ordinary boards while team databases are off, as before.
    var knowsItself: Bool { state.directory.me != nil && state.directory.myName != nil }

    /// The team's id for an agent acting through this Mac: its own, for one set up in Settings → Agents, else a
    /// session's; the team's row for it goes to the outbox first when the team hasn't had it.
    func agentID(for actor: BoardActor, board: TeamBoard) -> UUID? {
        guard actor.isAgent, let me = state.directory.me, let owner = state.directory.myName else { return nil }
        if let agent = AgentRegistry.shared.agents.first(where: { AgentRegistry.isAgent($0, named: actor.name) }) {
            if state.published[agent.id] == nil {
                let fields = TeamAgentRow.fields(for: agent, owner: owner,
                                                 binders: binders.filter { agent.takesCards(from: $0) }.sorted { $0.uuidString < $1.uuidString },
                                                 startsOnTeammatesCards: board.startsOnTeammatesCards(agent), status: agent.isEnabled ? "ready" : "off",
                                                 runningCard: nil, online: nil)
                state.published[agent.id] = TeamJSON.object(fields).text
                outbox.send(.putAgent(agent.id, fields: fields))
                save()
            }
            return agent.id
        }
        let id = TeamNames.sessionAgentID(member: me, name: actor.name)
        if state.published[id] == nil {
            let fields = TeamAgentRow.session(name: actor.name, owner: owner)
            state.published[id] = TeamJSON.object(fields).text
            outbox.send(.putAgent(id, fields: fields))
            state.directory.agents[id] = TeamDirectory.Agent(id: id, owner: me, name: TeamNames.published(actor.name, owner: owner), kind: "session")
            save()
        }
        return id
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }
}

/// A card as it was before a change the database decides, to put it back if the change is taken back unsent (lane DB8).
struct TeamCardBefore {
    var card: UUID
    var state: CardState
    var position: Double

    @MainActor
    init(_ card: TaskCard) {
        self.card = card.id
        state = card.state
        position = card.position
    }
}

/// A change refused because the team database it waits for is turned off on this Mac, or out of reach.
struct TeamWaitRefusal: LocalizedError {
    let words: String
    var errorDescription: String? { words }
}
