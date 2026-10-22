import Foundation
import SwiftData
import BindersKit

/// The team's rows into this Mac's copy, and the answers to this Mac's own changes (lane DB2).
extension TeamBoard {
    // MARK: Updates from the feed

    /// One update from the feed: names first, then binders taken away, binders, cards, what they wait for and their
    /// timelines, cards gone; binders newly shared read whole; then the team's changes heard (the dispatcher, the bell).
    /// Acknowledged once applied, so after a restart catching up starts after it. Rows are current versions, so an update
    /// that comes again changes nothing.
    func apply(_ update: TeamUpdate, from database: TeamDatabase) async {
        guard database === self.database else { return }
        if let me = database.member?["id"]?.uuid, state.directory.me != me { state.directory.me = me }
        for row in update.rows[.members] ?? [] { state.directory.take(member: row) }
        for row in update.rows[.agents] ?? [] { state.directory.take(agent: row) }
        if !update.bindersAdded.isEmpty || state.directory.myName == nil { await readDirectory(database) }
        for id in update.bindersRemoved { binderGone(id) }
        let added = update.bindersAdded
        func inAdded(_ row: TeamRow) -> Bool { (row["binder_id"]?.uuid ?? row.rowID).map(added.contains) ?? false }
        for row in update.rows[.binders] ?? [] where !inAdded(row) { applyBinder(row) }
        for row in update.rows[.binderMembers] ?? [] { applyBinderMember(row) }
        for row in update.rows[.cards] ?? [] where !inAdded(row) { applyCard(row) }
        for row in update.rows[.cardDependencies] ?? [] where !inAdded(row) { applyDependency(row) }
        var heard: [(TaskEvent, TeamCardEvent)] = []
        let events = (update.rows[.cardEvents] ?? []).filter { !inAdded($0) }.sorted { ($0["number"]?.int64 ?? 0) < ($1["number"]?.int64 ?? 0) }
        for row in events { if let pair = applyEvent(row, hear: true) { heard.append(pair) } }
        let waiting = pendingCards
        for gone in update.gone where gone.table == .cards {
            if let card = controller?.board.card(gone.id), covers(card), !waiting.contains(gone.id) { controller?.board.removeHere(card) }
        }
        // Only when something changed: an empty save still tells everyone who listens (lane DB10).
        if store.context.hasChanges { store.save() }
        for binder in added {
            let read = await readWhole(binder, from: database)
            if !read, !state.readWhole.contains(binder) { state.readWhole.append(binder) }
        }
        for (event, team) in heard { hear(event, team) }
        await notes.apply(update)
        // After the notes, which apply folders first: a meeting or capture that names a folder finds it.
        await content.apply(update, from: database)
        database.acknowledge(update)
        saveState()
    }

    /// Binders that couldn't be read whole when they were shared with this Mac (the connection went), read now.
    func readWholeWhatsLeft(_ database: TeamDatabase) async {
        for binder in state.readWhole {
            if await readWhole(binder, from: database) { state.readWhole.removeAll { $0 == binder } }
        }
        saveState()
    }

    /// A binder read whole, at one moment: what the database has is what this Mac has, its cards' waits included; a card
    /// it no longer has goes from here too (one this Mac's own changes wait on, or one kept here, aside). Its timelines'
    /// lines this Mac hasn't got are added quietly: old news rings no bell and wakes no agent.
    func readWhole(_ binder: UUID, from database: TeamDatabase) async -> Bool {
        // What waits to go now, before the read: the outbox keeps going while it's read (lane DB10 reads the feed between its
        // items), and a card whose change went after the read began isn't in it, though its answer has come by the end.
        let waitedBefore = pendingCards
        guard let snapshot = try? await database.snapshot(binder: binder).rows, let board = controller?.board else { return false }
        for row in snapshot[.binders] ?? [] { applyBinder(row) }
        state.binderMembers[binder] = []
        for row in snapshot[.binderMembers] ?? [] { applyBinderMember(row) }
        guard covers(binder) else { return true }
        let waiting = pendingCards.union(waitedBefore)
        var have: Set<UUID> = []
        for row in snapshot[.cards] ?? [] {
            if let id = row.rowID, row.deletedAt == nil { have.insert(id) }
            applyCard(row, force: true)
        }
        for card in board.cards(in: binder) where !have.contains(card.id) && !waiting.contains(card.id) && TeamCardShadow(card.teamShadow) != nil {
            board.removeHere(card)
        }
        var waits: [UUID: [UUID]] = [:]
        for row in snapshot[.cardDependencies] ?? [] {
            guard let id = row.rowID, let card = row["card_id"]?.uuid, let other = row["waits_for_id"]?.uuid else { continue }
            dependencyTimes[id] = row["updated_at"]?.date
            if row.deletedAt == nil { waits[card, default: []].append(other) }
        }
        for card in board.cards(in: binder) where !waiting.contains(card.id) && TeamCardShadow(card.teamShadow) != nil {
            let wanted = (waits[card.id] ?? []).map(\.uuidString)
            if card.waitsFor != wanted { card.waitsFor = wanted }
        }
        let events = (snapshot[.cardEvents] ?? []).sorted { ($0["number"]?.int64 ?? 0) < ($1["number"]?.int64 ?? 0) }
        for row in events { _ = applyEvent(row, hear: false) }
        store.save()
        await notes.readWhole(binder, rows: snapshot)
        await content.readWhole(binder, rows: snapshot)
        return true
    }

    // MARK: Binders

    /// A binder's row: its name, colour and settings on this Mac's binder of the same id (made when it's new here), unless
    /// one was changed here since the database last said, which goes out as an edit.
    func applyBinder(_ row: TeamRow) {
        guard let id = row.rowID, let name = row["name"]?.string, let key = server?.key else { return }
        if row.deletedAt != nil { return binderGone(id) }
        let color = row["color"]?.string.flatMap { Int($0) }.map { max(0, min($0, BinderRecord.paletteSize - 1)) } ?? 0
        let me = state.directory.me
        let remote = TeamBoardState.Binder(name: name, color: color, agentsMayFinish: row["agents_may_finish"]?.bool ?? false,
                                           agentsMayPlace: row["agents_may_place"]?.bool ?? false, everyone: row["everyone"]?.bool ?? false,
                                           madeHere: me != nil && row["created_by"]?.uuid == me)
        let base = state.binders[id]
        let binder: BinderRecord
        if let existing = store.binder(id) {
            binder = existing
        } else {
            binder = BinderRecord(name: name, colorIndex: color)
            binder.id = id
            store.context.insert(binder)
        }
        if base == nil || binder.name.trimmingCharacters(in: .whitespaces) == base?.name { binder.name = name }
        if base == nil || binder.colorIndex == base?.color { binder.colorIndex = color }
        if base == nil || binder.agentsMayFinish == base?.agentsMayFinish { binder.agentsMayFinish = remote.agentsMayFinish }
        if base == nil || binder.agentsMayPlace == base?.agentsMayPlace { binder.agentsMayPlace = remote.agentsMayPlace }
        binder.teamDatabaseKey = key
        binder.teamMadeBy = remote.madeHere || (base?.madeHere ?? false) ? "" : (state.directory.memberName(row["created_by"]?.uuid) ?? "a teammate")
        var kept = remote
        kept.madeHere = remote.madeHere || (base?.madeHere ?? false)
        state.binders[id] = kept
        sharedChanged()
    }

    /// Who a binder is shared with: a `binder_members` row.
    func applyBinderMember(_ row: TeamRow) {
        guard let binder = row["binder_id"]?.uuid, let member = row["member_id"]?.uuid else { return }
        if row.deletedAt == nil { state.binderMembers[binder, default: []].insert(member) } else { state.binderMembers[binder]?.remove(member) }
    }

    /// The team lost a binder for this Mac (it was taken out of it, or it was deleted): one made here stays, a local binder
    /// again, with its board as it was; a teammate's goes, its cards with it (anything else in it moves to General).
    func binderGone(_ id: UUID) {
        guard let binder = store.binder(id), let key = server?.key, binder.teamDatabaseKey == key else { return }
        notes.binderGone(id)
        content.binderGone(id)
        let madeHere = state.binders[id]?.madeHere ?? binder.teamMadeBy.isEmpty
        let cards = controller?.board.cards(in: id) ?? []
        if madeHere {
            binder.teamDatabaseKey = ""
            for card in cards { card.teamShadow = "" }
        } else {
            for card in cards { controller?.board.removeHere(card) }
            store.deleteBinder(binder, movingItemsTo: store.defaultBinder())
        }
        state.binders[id] = nil
        sharedChanged()
        store.save()
        saveState()
    }

    // MARK: Cards

    /// The cards this Mac's own changes still wait on (in the outbox).
    var pendingCards: Set<UUID> {
        Set((database?.queued ?? []).flatMap { cards(of: $0.call) })
    }

    /// The cards a call is about: its card, or the cards a placing makes.
    func cards(of call: TeamCall) -> [UUID] {
        if let card = call.card { return [card] }
        if call.function == "place_work_items", let items = call.argument("p_items").flatMap({ TeamJSON(text: $0) })?.array {
            return items.compactMap { $0["card"]?.uuid }
        }
        return []
    }

    /// A card's row onto this Mac's card of the same id (made when it's new here). Held back, the newest kept, while this
    /// Mac's own changes to it wait for their answers; an older read than the one applied is let be (`force` applies it
    /// anyway, as a read of the whole binder does). Its title, details, due date, links and Distill's part stay as they are
    /// here when they were changed here since the database last said (they go out as an edit), unless `hard`: put back as
    /// the database has them after a refusal. Named as this Mac names everyone.
    @discardableResult
    func applyCard(_ row: TeamRow, force: Bool = false, hard: Bool = false) -> TaskCard? {
        guard let team = TeamCard(row: row), let board = controller?.board else { return nil }
        if pendingCards.contains(team.id) {
            if (latest[team.id]?["version"]?.int ?? 0) <= team.version { latest[team.id] = row }
            return board.card(team.id)
        }
        let existing = board.card(team.id)
        if team.deletedAt != nil {
            // Deleted on a board this Mac still shares; one moved off the team's board to a binder here stays.
            if let existing, covers(existing) { board.removeHere(existing) }
            latest[team.id] = nil
            return nil
        }
        // A card that lives in one of this Mac's own binders now (moved off the team's board) isn't the team's.
        if let existing, !covers(existing) { return existing }
        let base = existing.flatMap { TeamCardShadow($0.teamShadow) }
        if !force, let base, base.version > team.version { return existing }
        let card: TaskCard
        if let existing {
            card = existing
        } else {
            card = TaskCard(title: team.title, binderID: team.binderID, column: team.column)
            card.id = team.id
            store.context.insert(card)
        }
        let before = existing?.column
        let fresh = hard || base == nil
        card.binderID = team.binderID
        if fresh || card.title == base?.title { card.title = team.title }
        if fresh || card.details == base?.details { card.details = team.details }
        if fresh || Self.same(card.dueAt, base?.due) { card.dueAt = team.dueAt }
        if fresh || Self.teamLinks(card.links) == base?.links { card.links = team.links + Self.logLinks(card.links).filter { !team.links.contains($0) } }
        if fresh || Self.sameDistilled(card.distilledFrom?.teamJSON, base?.distilled) {
            let local = card.distilledFrom
            card.distilledFrom = DistilledFrom(team: team.distilled, keeping: local) ?? (team.distilled == nil && base == nil && !hard ? local : nil)
        }
        card.column = team.column
        card.position = team.position
        let holder = team.holderKind.map { state.directory.actor(kind: $0.rawValue, member: team.holderMemberID, agent: team.holderAgentID,
                                                                 stored: team.holderName) }
        card.assignee = holder?.name
        card.assigneeIsAgent = holder?.isAgent ?? false
        card.claimExpiresAt = team.leaseUntil
        card.meantFor = state.directory.localName(team.meantFor)
        card.meantForByAgent = team.meantForByAgent && card.meantFor != nil
        if team.sourceKind != nil || existing == nil {
            card.sourceKind = team.sourceKind
            card.sourceID = team.sourceID
            card.sourceTitle = team.sourceTitle
        }
        if card.sourceRef == nil, let todo = team.todoID { card.sourceRef = todo.uuidString }
        card.createdBy = state.directory.actor(kind: team.createdByAgent == nil ? "person" : "agent", member: team.createdByMember,
                                               agent: team.createdByAgent, stored: team.createdByName).name
        if let created = team.createdAt { card.createdAt = created }
        card.updatedAt = team.updatedAt ?? Date()
        card.externalKey = team.externalKey
        card.externalURL = team.externalURL
        card.teamShadow = TeamCardShadow(version: team.version, title: team.title, details: team.details, due: team.dueAt, links: team.links,
                                         distilled: team.distilled).text
        // Its to-do here follows it to Done, and back.
        if let before, (before == .done) != (card.column == .done), let todo = card.sourceRef {
            _ = Todos.setDone(todo, card.column == .done, commitments: controller?.commitments)
        }
        latest[team.id] = nil
        return card
    }

    /// One wait as the database has it now: the card waits for the other, or no longer does. An older read of the same
    /// wait than one applied is let be; a card this Mac's own changes wait on keeps its own.
    func applyDependency(_ row: TeamRow) {
        guard let id = row.rowID, let cardID = row["card_id"]?.uuid, let other = row["waits_for_id"]?.uuid,
              let card = controller?.board.card(cardID), !pendingCards.contains(cardID) else { return }
        let updated = row["updated_at"]?.date
        if let known = dependencyTimes[id], let updated, known > updated { return }
        dependencyTimes[id] = updated
        var waits = card.waitsFor
        if row.deletedAt == nil {
            if !waits.contains(other.uuidString) { waits.append(other.uuidString) }
        } else {
            waits.removeAll { $0 == other.uuidString }
        }
        if waits != card.waitsFor { card.waitsFor = waits }
    }

    /// A timeline line, added once by its id. One this Mac's own login wrote takes the place of the line it wrote while it
    /// waited; one from anyone else is handed back to be heard (`hear`) unless `hear` is off.
    func applyEvent(_ row: TeamRow, hear: Bool) -> (TaskEvent, TeamCardEvent)? {
        guard let team = TeamCardEvent(row: row), let card = controller?.board.card(team.cardID) else { return nil }
        let id = team.id
        if ((try? store.context.fetchCount(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.id == id }))) ?? 0) > 0 { return nil }
        let fromHere = team.writtenBy != nil && team.writtenBy == state.directory.me
        if fromHere, let old = dropWaitingLine(on: card.id, kind: team.kind, text: team.text) { replacements[old] = id }
        let actor = state.directory.actor(kind: team.author.kind.rawValue, member: team.authorMemberID, agent: team.authorAgentID,
                                          stored: team.author.name)
        let event = TaskEvent(taskID: card.id, kind: .comment, author: actor, text: team.text)
        event.id = id
        event.kindRaw = team.kind
        event.fromColumn = team.fromColumn
        event.toColumn = team.toColumn
        event.createdAt = team.createdAt ?? Date()
        store.context.insert(event)
        return hear && !fromHere ? (event, team) : nil
    }

    /// The line this Mac wrote while its change waited, now that the database's own has come: the first of that kind and
    /// words.
    @discardableResult
    private func dropWaitingLine(on card: UUID, kind: String, text: String) -> UUID? {
        let waiting = (try? store.context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.taskID == card && $0.teamOperation != nil }))) ?? []
        guard let line = waiting.first(where: { $0.kindRaw == kind && $0.text == text }) else { return nil }
        let id = line.id
        store.context.delete(line)
        return id
    }

    /// The lines a change wrote here while it waits for its answer.
    func lines(of operation: UUID) -> [TaskEvent] {
        let key: String? = operation.uuidString
        return (try? store.context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.teamOperation == key }))) ?? []
    }

    // MARK: Hearing the team

    /// A line from someone else, heard as the board's own changes are: an answer withdraws the question it answered; a
    /// question or a request for approval rings here when it's for this member (TeamDirectory.rings), a request for
    /// approval only for whoever decides on it (BoardRules.deciders); and the dispatcher hears it, as a teammate's change,
    /// or an agent's placing.
    private func hear(_ event: TaskEvent, _ team: TeamCardEvent) {
        guard let controller, let card = controller.board.card(event.taskID) else { return }
        let from = team.fromColumn.flatMap(BoardColumn.init(rawValue:)), to = team.toColumn.flatMap(BoardColumn.init(rawValue:))
        let actor = BoardActor(name: event.author, kind: event.authorIsAgent ? .agent : .person)
        if from == .blocked, card.column != .blocked { MacNotifications.shared.withdrawQuestion(card.id) }
        if event.kind == .question || event.kind == .approval, actor.isAgent, card.column == .blocked,
           state.directory.rings(askedBy: team.authorAgentID, meantFor: card.meantFor),
           event.kind != .approval || decides(card, askedBy: actor.name) != false {
            ring(event.kind, text: event.text, on: card, by: actor.name)
        }
        controller.agents.noticed(card, event.kind, by: actor, from: from, to: to, cause: cause(of: event, incoming: true))
    }

    /// Whose change a line is, for the dispatcher: yours (written on this Mac), a teammate's, or an agent's placing under
    /// Agents may place work items ("Meant for X: placed by Y, which this binder lets place work items."), by one of this
    /// member's agents or a teammate's. Binders' own other lines count as yours here (your Auto) and as a teammate's when
    /// they came from the team (`incoming`).
    func cause(of event: TaskEvent, incoming: Bool) -> TeamWakeCause {
        if event.authorIsAgent { return .teammate }
        if event.author == BoardActor.you.name { return .yours }
        guard event.author == BoardService.binders.name else { return .teammate }
        if event.kind == .assigned, let range = event.text.range(of: ": placed by ") {
            let placer = String(event.text[range.upperBound...].prefix { $0 != "," }).trimmingCharacters(in: .whitespaces)
            let mine = AgentRegistry.shared.agents.contains { AgentRegistry.isAgent($0, named: state.directory.localName(placer) ?? placer) }
            return .placedByAgent(fromTeammate: !mine)
        }
        return incoming ? .teammate : .yours
    }

    // MARK: Answers to this Mac's changes

    /// An outbox item's answer: applied, its waiting lines give way to the database's own, and the card is as the database
    /// left it; refused or failed, its lines go, the card is put back as the database has it now, and a line by Binders, on
    /// this Mac only, says what didn't go through and why. Whoever waits for it hears once this is done.
    func settle(_ outcome: TeamOutboxOutcome, from database: TeamDatabase) async {
        guard database === self.database else { return }
        await notes.settle(outcome)
        let operation = outcome.operation
        befores[operation] = nil
        let cards = cards(of: outcome.call)
        let waiting = lines(of: operation)
        switch outcome.outcome {
        case .applied(let result):
            // Each line written here gives way to the database's own of the same kind and words.
            var theirs = (result.body["events"]?.array ?? []).compactMap { $0.object.flatMap(TeamCardEvent.init(row:)) }
            for line in waiting {
                if let index = theirs.firstIndex(where: { $0.kind == line.kindRaw && $0.text == line.text && $0.cardID == line.taskID }) {
                    replacements[line.id] = theirs.remove(at: index).id
                }
                store.context.delete(line)
            }
            take(result)
        case .refused(let refusal) where refusal.code == "exists" && ["bring_card", "create_card"].contains(outcome.call.function):
            // Already on the team's board (shared before): as the database has it.
            for line in waiting { store.context.delete(line) }
            if let rows = try? await database.rows(.cards, ids: cards) { for row in rows { applyCard(row, force: true) } }
        case .refused(let refusal):
            await putBack(cards, call: outcome.call, lines: waiting, refusal: refusal, from: database)
            refusalWords[operation] = words(refusal, card: cards.first)
        case .failed(let message):
            await putBack(cards, call: outcome.call, lines: waiting, reason: message, from: database)
        }
        let still = pendingCards
        for id in cards where !still.contains(id) {
            if let row = latest.removeValue(forKey: id) { applyCard(row) }
        }
        if store.context.hasChanges { store.save() }
        content.settled(outcome)
        resume(operation, with: outcome.outcome)
        sendEditsSoon()
    }

    /// What an applied change's answer brings: the card(s) as it left them, its lines, a binder, an agent.
    private func take(_ result: TeamResult) {
        if let card = result.body["card"]?.object { applyCard(card) }
        for card in result.body["cards"]?.array ?? [] { if let row = card.object { applyCard(row) } }
        for event in result.body["events"]?.array ?? [] { if let row = event.object { _ = applyEvent(row, hear: false) } }
        if let binder = result.body["binder"]?.object { applyBinder(binder) }
        if let agent = result.body["agent"]?.object { state.directory.take(agent: agent) }
    }

    /// A refusal in this Mac's words, its holder named as this Mac names them: as the card here says (by id), once it's put
    /// back as the database has it, else by name.
    func words(_ refusal: TeamRefusal, card: UUID? = nil) -> String {
        var named = refusal
        if let holder = refusal.holder {
            if let card, let assignee = controller?.board.card(card)?.assignee {
                named.holder = assignee
            } else {
                named.holder = state.directory.localName(holder) ?? holder
            }
        }
        return named.errorDescription ?? named.message
    }

    /// The cards a refused change was about, put back as the database has them, each with a line saying why; a new card the
    /// database never took goes from here too. Read now; with the database gone meanwhile, their binders are read whole
    /// once it's back.
    private func putBack(_ cards: [UUID], call: TeamCall, lines: [TaskEvent], refusal: TeamRefusal? = nil, reason given: String = "",
                         from database: TeamDatabase) async {
        for line in lines { store.context.delete(line) }
        func reason(_ card: UUID?) -> String { refusal.map { words($0, card: card) } ?? given }
        guard !cards.isEmpty, let board = controller?.board else { return }
        let who: String = call.argument("p_agent").flatMap(UUID.init(uuidString:)).map { id in
            let directory = state.directory
            return directory.local[id] ?? directory.agents[id].map { directory.name(of: $0) } ?? "An agent"
        } ?? BoardActor.you.name
        guard let rows = try? await database.rows(.cards, ids: cards) else {
            for id in cards { if let binder = board.card(id)?.binderID, !state.readWhole.contains(binder) { state.readWhole.append(binder) } }
            for id in cards { if let card = board.card(id) { board.note(card, text: TeamRefusalLine.line(call, by: who, reason: reason(nil)), toTeam: false) } }
            saveState()
            return
        }
        let found = Dictionary(rows.compactMap { row in row.rowID.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        for id in cards {
            guard let card = board.card(id) else { continue }
            if let row = found[id] {
                applyCard(row, force: true, hard: true)
                if let binder = card.binderID, let deps = try? await database.rows(.cardDependencies, binder: binder) {
                    let wanted = deps.filter { $0["card_id"]?.uuid == id && $0.deletedAt == nil }.compactMap { $0["waits_for_id"]?.uuid?.uuidString }
                    if Set(card.waitsFor) != Set(wanted) { card.waitsFor = wanted }
                }
                board.note(card, text: TeamRefusalLine.line(call, by: who, reason: reason(id)), toTeam: false)
            } else if call.function == "bring_card" {
                // Not taken onto the team's board: it stays here, kept on this Mac, until you share it again.
                card.teamShadow = Self.held
                board.note(card, text: TeamRefusalLine.line(call, by: who, reason: reason(nil)), toTeam: false)
            } else {
                board.removeHere(card)
                controller?.flowBar.toast(TeamRefusalLine.line(call, by: who, reason: reason(nil)), symbol: "exclamationmark.circle", duration: 6)
            }
        }
    }

    // MARK: Helpers

    /// A card's links the team has: all but the files a run Binders started writes on this Mac.
    static func teamLinks(_ links: [String]) -> [String] { links.filter { !isLogLink($0) } }

    /// The links only this Mac has: its runs' log files.
    static func logLinks(_ links: [String]) -> [String] { links.filter(isLogLink) }

    static func isLogLink(_ link: String) -> Bool {
        guard let url = URL(string: link), url.isFileURL else { return false }
        return url.path.hasPrefix(AgentDispatcher.logs.path)
    }

    /// The same part of Distill's, as the database keeps it: its dates to the millisecond.
    static func sameDistilled(_ a: TeamJSON?, _ b: TeamJSON?) -> Bool {
        let first = DistilledFrom(team: a), second = DistilledFrom(team: b)
        guard let first, let second else { return first == nil && second == nil }
        return first.note == second.note && first.distill == second.distill && first.item == second.item && first.section == second.section
            && first.sectionHash == second.sectionHash && first.version == second.version && first.request == second.request
            && same(first.briefUpdated, second.briefUpdated) && same(first.closed, second.closed)
    }

    /// The same moment, as the database keeps it (microseconds).
    static func same(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) < 0.001
        default: false
        }
    }
}
