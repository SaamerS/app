import Foundation
import SwiftData
import BindersKit

/// This Mac's changes to the team's boards (lane DB2): handed over from BoardService, edits made straight on a card or a
/// binder, sharing a binder and bringing its board in once, a card kept on this Mac until you share it, Distill's placing,
/// and a card moving between boards.
extension TeamBoard {
    /// The line a card made from what your iPhone or Mac heard gets when it lands on a shared board: it waits here.
    static let keptLine = "Kept on this Mac: it came from what your iPhone heard. Share It puts it on the team's board."

    // MARK: Handing a change over

    /// A change made here, to the outbox: the lines it wrote wait for its answer (`TaskEvent.teamOperation`). While the
    /// database can't be asked (lane DB8), it goes as it should arrive late (TeamBoardWrites.late: a report without
    /// keeping a claim alive, a check-in not at all), to the outbox kept for it while team databases are off. A change the
    /// database decides goes only while it's fresh (`sendBy`); `before`, the card as it was, puts it back if it's taken back
    /// unsent.
    func send(_ call: TeamCall, lines: [TaskEvent], before: TeamCardBefore? = nil) {
        guard let outbox = database ?? parked?.outbox else { return }
        var call = call
        if outboxReach != .reachable {
            guard let late = TeamBoardWrites.late(call) else { return }
            call = late
        }
        for line in lines { line.teamOperation = call.operation.uuidString }
        if !lines.isEmpty { store.save() }
        let decides = TeamBoardWrites.decides(call)
        // Kept until its answer comes (`settle`), or it's taken back (`withdraw`).
        if decides, let before { befores[call.operation] = (call, before) }
        outbox.send(call, sendBy: decides ? Date().addingTimeInterval(TeamBoardWrites.decideWithin) : nil)
        noteSent(call.operation)
    }

    // MARK: Edits made straight on a card or a binder

    /// A save that changed a card or a binder sends what differs from what the database last said, a moment later.
    func watchSaves() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            let changed = (note.userInfo?[ModelContext.NotificationKey.updatedIdentifiers.rawValue] as? [PersistentIdentifier]) ?? []
            guard changed.contains(where: { ["TaskCard", "BinderRecord"].contains($0.entityName) }) else { return }
            MainActor.assumeIsolated { self?.sendEditsSoon() }
        }
    }

    func sendEditsSoon() {
        editCheck?.cancel()
        let delay = editDelay
        editCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.sendEdits()
        }
    }

    /// What was changed here since the database last said, as edits: a card's title, details, due date and links (not a
    /// run's log file) and Distill's part; a binder's name, colour and settings. Not while the card's own changes still wait:
    /// once they're answered, what's left is looked at again.
    func sendEdits() {
        guard let database, let board = controller?.board else { return }
        let waiting = pendingCards
        let queued = database.queued
        for binderID in sharedBinders {
            for card in board.cards(in: binderID) where !waiting.contains(card.id) {
                guard let base = TeamCardShadow(card.teamShadow) else { continue }
                var fields: [String: TeamJSON] = [:]
                if card.title != base.title, !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["title"] = .string(card.title) }
                if card.details != base.details { fields["details"] = .string(card.details) }
                if !Self.same(card.dueAt, base.due) { fields["due_at"] = TeamJSON(card.dueAt) }
                let links = Self.teamLinks(card.links)
                if links != base.links { fields["links"] = TeamJSON(links) }
                if !fields.isEmpty { send(.editCard(card.id, fields: fields), lines: []) }
                let distilled = card.distilledFrom?.teamJSON
                if !Self.sameDistilled(distilled, base.distilled) { send(.setCardDistilled(card.id, distilled), lines: []) }
            }
            guard let binder = store.binder(binderID), let base = state.binders[binderID],
                  !queued.contains(where: { $0.call.function == "update_binder" && $0.call.argument("p_binder") == binderID.uuidString.lowercased() })
            else { continue }
            var fields: [String: TeamJSON] = [:]
            // The database keeps a name trimmed: compared as it keeps it, so a space at the end isn't an edit forever.
            let name = binder.name.trimmingCharacters(in: .whitespaces)
            if name != base.name, !name.isEmpty { fields["name"] = .string(name) }
            if binder.colorIndex != base.color { fields["color"] = .string(String(binder.colorIndex)) }
            if binder.agentsMayFinish != base.agentsMayFinish { fields["agents_may_finish"] = .bool(binder.agentsMayFinish) }
            if binder.agentsMayPlace != base.agentsMayPlace { fields["agents_may_place"] = .bool(binder.agentsMayPlace) }
            if !fields.isEmpty {
                database.send(.updateBinder(binderID, fields: fields))
                noteSent(database.queued.last?.id ?? UUID())
            }
        }
    }

    // MARK: Sharing a binder

    /// Shares one of this Mac's binders through the database, with everyone or with these members, and brings its board in
    /// once: every card as it is (one made from what your iPhone heard stays here, kept, until you share it), then what
    /// each waits for. Every step has an operation id made from the binder's and the card's, so doing it again makes
    /// nothing twice. Changes made meanwhile go after them.
    func share(_ binder: BinderRecord, everyone: Bool, with members: Set<UUID>) {
        guard let database, let key = server?.key, !binder.isTeamCopy, let board = controller?.board else { return }
        let id = binder.id
        if binder.teamDatabaseKey == key {
            return changeSharing(binder, everyone: everyone, with: members)
        }
        let fields: [String: TeamJSON] = ["color": .string(String(binder.colorIndex)), "agents_may_finish": .bool(binder.agentsMayFinish),
                                          "agents_may_place": .bool(binder.agentsMayPlace)]
        database.send(.createBinder(id, name: binder.name, everyone: everyone, fields: fields,
                                    operation: TeamOperationID.derived("share binder \(id.uuidString.lowercased())")))
        for member in members.sorted(by: { $0.uuidString < $1.uuidString }) where member != state.directory.me {
            database.send(.shareBinder(id, with: member,
                                       operation: TeamOperationID.derived("share binder \(id.uuidString.lowercased()) with \(member.uuidString.lowercased())")))
        }
        binder.teamDatabaseKey = key
        binder.teamMadeBy = ""
        state.binders[id] = .init(name: binder.name, color: binder.colorIndex, agentsMayFinish: binder.agentsMayFinish,
                                  agentsMayPlace: binder.agentsMayPlace, everyone: everyone, madeHere: true)
        state.binderMembers[id] = members.union(state.directory.me.map { [$0] } ?? [])
        sharedChanged()
        let cards = board.cards(in: id)
        for card in cards {
            if MCPServer.fromCapture(card) {
                card.teamShadow = Self.held
                board.note(card, text: Self.keptLine, toTeam: false)
                continue
            }
            card.teamShadow = ""
            database.send(bringCall(card))
        }
        let brought = Set(cards.filter { $0.teamShadow != Self.held }.map(\.id))
        for card in cards where brought.contains(card.id) {
            for wait in card.waitsFor.compactMap(UUID.init(uuidString:)) where brought.contains(wait) {
                database.send(.bringWait(card.id, waitsFor: wait))
            }
        }
        noteSent(database.queued.last?.id ?? UUID())
        store.save()
        saveState()
        publishSoon()
    }

    /// Who a shared binder is shared with, changed: everyone, or these members (you stay in it).
    func changeSharing(_ binder: BinderRecord, everyone: Bool, with members: Set<UUID>) {
        guard let database, covers(binder.id) else { return }
        let id = binder.id
        let now = state.binderMembers[id] ?? []
        if state.binders[id]?.everyone != everyone { database.send(.updateBinder(id, fields: ["everyone": .bool(everyone)])) }
        for member in members.subtracting(now).sorted(by: { $0.uuidString < $1.uuidString }) where member != state.directory.me {
            database.send(.shareBinder(id, with: member))
        }
        for member in now.subtracting(members).sorted(by: { $0.uuidString < $1.uuidString }) where member != state.directory.me {
            database.send(.unshareBinder(id, with: member))
        }
        state.binders[id]?.everyone = everyone
        state.binderMembers[id] = members.union(state.directory.me.map { [$0] } ?? [])
        saveState()
    }

    /// Stop Sharing, for a binder made here: everyone else is taken out of it, so teammates lose its board. It stays in
    /// the team database with only you in it, as it is, so sharing it again later brings everyone back to the same board.
    func stopSharing(_ binder: BinderRecord) {
        changeSharing(binder, everyone: false, with: [])
    }

    /// Leave a binder a teammate shared with you: you're taken out of it, and its board goes from this Mac.
    func leave(_ binder: BinderRecord) {
        guard let database, let me = state.directory.me, covers(binder.id) else { return }
        database.send(.unshareBinder(binder.id, with: me))
    }

    /// One of this Mac's cards, as `bring_card` takes it: its column, who has it (you, or one of your agents), what's left
    /// of an agent's lease, who it's meant for, when it's due, its links (not a run's log file), where it came from, its
    /// to-do, Distill's part, and who made it and when, as the team names them.
    func bringCall(_ card: TaskCard) -> TeamCall {
        var fields: [String: TeamJSON] = ["details": .string(card.details), "column": .string(card.column.rawValue), "position": .number(card.position),
                                          "created_at": TeamJSON(card.createdAt)]
        if let holder = card.assignee, BoardRules.isClaimed(card.state, at: Date()) || card.column == .done || card.column == .review {
            if card.assigneeIsAgent, let agent = AgentRegistry.shared.agents.first(where: { AgentRegistry.isAgent($0, named: holder) }) {
                _ = agentID(for: BoardActor(name: agent.name, kind: .agent))
                fields["holder"] = TeamJSON(agent.id)
            } else if !card.assigneeIsAgent, BoardRules.isReserved(holder) {
                fields["holder"] = "you"
            }
            if let lease = card.claimExpiresAt { fields["lease_until"] = TeamJSON(lease) }
        }
        if let meant = state.directory.teamName(card.meantFor) {
            fields["meant_for"] = .string(meant)
            fields["meant_for_by_agent"] = .bool(card.meantForByAgent)
        }
        if let due = card.dueAt { fields["due_at"] = TeamJSON(due) }
        let links = Self.teamLinks(card.links)
        if !links.isEmpty { fields["links"] = TeamJSON(links) }
        if let kind = card.sourceKind { fields["source_kind"] = .string(kind) }
        if let source = card.sourceID { fields["source_id"] = .string(source) }
        if let title = card.sourceTitle { fields["source_title"] = .string(title) }
        if let todo = card.sourceRef.flatMap(UUID.init(uuidString:)) { fields["todo_id"] = TeamJSON(todo) }
        if let key = card.externalKey { fields["external_key"] = .string(key) }
        if let url = card.externalURL { fields["external_url"] = .string(url) }
        if let distilled = card.distilledFrom { fields["distilled"] = distilled.teamJSON }
        if let maker = AgentRegistry.shared.agents.first(where: { AgentRegistry.isAgent($0, named: card.createdBy) }) {
            _ = agentID(for: BoardActor(name: maker.name, kind: .agent))
            fields["created_by_agent"] = TeamJSON(maker.id)
        } else {
            fields["created_by_name"] = .string(state.directory.teamName(card.createdBy) ?? card.createdBy)
        }
        return .bringCard(card.id, binder: card.binderID ?? UUID(), title: card.title, fields: fields)
    }

    /// Share It, on a card kept on this Mac: it goes onto the team's board as it is now.
    func shareKept(_ card: TaskCard) {
        guard card.teamShadow == Self.held, covers(card), let database else { return }
        card.teamShadow = ""
        let call = bringCall(card)
        database.send(call)
        noteSent(call.operation)
        store.save()
    }

    /// Whether a new card on a shared board waits here first: one made from what your iPhone or Mac heard.
    func keepsHere(_ card: TaskCard) -> Bool {
        MCPServer.fromCapture(card)
    }

    // MARK: Distill's placing

    /// Place on Board in a shared binder, as one call: the cards made here first (`lines`, their lines), in order, waiting
    /// as proposed, meant for whoever was picked; an agent's placing only where the binder lets agents place work items,
    /// which the database checks. Returns the operation, to wait for its answer.
    @discardableResult
    func place(binder: UUID, items: [TeamRow], column: BoardColumn, agent: UUID?, lines: [TaskEvent]) -> UUID {
        let call = TeamCall.placeWorkItems(binder: binder, items: items, column: column, agent: agent)
        send(call, lines: lines)
        return call.operation
    }

    // MARK: A card moving between boards

    /// A card moved to another binder here (BoardService.moveBinder): between two shared boards the database moves it;
    /// onto a shared board from one of this Mac's it's brought in (or kept here, made from what your iPhone heard); off a
    /// shared board to one of this Mac's, the team's board loses it and it stays here.
    func moved(_ card: TaskCard, from old: UUID?, keepSuggestion: Bool, by actor: BoardActor, lines: [TaskEvent]) {
        guard database != nil, let new = card.binderID else { return }
        switch (covers(old), covers(new)) {
        case (true, true):
            send(.moveCardToBinder(card.id, to: new, keepSuggestion: keepSuggestion, agent: agentID(for: actor)), lines: lines)
        case (false, true):
            if keepsHere(card) {
                card.teamShadow = Self.held
                controller?.board.note(card, text: Self.keptLine, toTeam: false)
            } else {
                card.teamShadow = ""
                let call = bringCall(card)
                database?.send(call)
                noteSent(call.operation)
            }
        case (true, false):
            card.teamShadow = ""
            latest[card.id] = nil
            // The database decides it, so it goes only while it's fresh (lane DB8).
            send(.deleteCard(card.id), lines: [])
        case (false, false):
            break
        }
    }
}
