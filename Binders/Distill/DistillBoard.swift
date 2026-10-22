import Foundation
import SwiftData
import BindersKit

/// What the board says about the work distilled from a note, read the same way by the app's Work bar and panel and by the
/// MCP tools in `Binders --mcp`: the cards placed from it, each as the progress reads it (`DistillProgress.Card`), the
/// note's progress and report, and a binder's Work list. From the board alone; nothing here writes.
@MainActor
enum DistillBoard {
    /// The cards placed from a note, in the order its distills placed them, then any others made from it by Distill. The
    /// cards that asked an agent to distill it aren't among them.
    static func cards(of note: UUID) -> [TaskCard] {
        let context = Store.shared.context
        // A card that came back from a team database names its note in lower case (lane DB3): either is the note.
        let id = note.uuidString, lower = note.uuidString.lowercased()
        let made = ((try? context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { ($0.sourceID == id || $0.sourceID == lower) && $0.distilledJSON != "" },
                                                                   sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
            .filter { $0.distilledFrom.map { $0.note == note && $0.request != true } ?? false }
        let order = DistillStore.shared.file(for: note).distills.flatMap { $0.items.compactMap(\.card) }
        let ranked = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return made.enumerated().sorted { a, b in
            (ranked[a.element.id] ?? order.count + a.offset) < (ranked[b.element.id] ?? order.count + b.offset)
        }.map(\.element)
    }

    /// The cards that asked an agent to distill the note ("Distill with…").
    static func requests(of note: UUID) -> [TaskCard] {
        let id = note.uuidString, lower = note.uuidString.lowercased()
        return ((try? Store.shared.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { ($0.sourceID == id || $0.sourceID == lower) && $0.distilledJSON != "" }))) ?? [])
            .filter { $0.distilledFrom?.request == true }
    }

    /// The timelines of these cards, oldest first, in one fetch.
    static func timelines(_ cards: [TaskCard]) -> [UUID: [TaskEvent]] {
        let context = Store.shared.context
        let ids = cards.map(\.id)
        guard !ids.isEmpty else { return [:] }
        let events = (try? context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { ids.contains($0.taskID) },
                                                                    sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return Dictionary(grouping: events, by: \.taskID)
    }

    /// One card as the progress reads it: its column and who has it, what it waits for, what waits on whom in Blocked or
    /// Review, its last report and when, when it was finished, and its section's change since it was made, with whether
    /// it caught up. `team`: who's who on a board shared through the team database, for whom a card there waits on.
    static func card(_ card: TaskCard, events: [TaskEvent], waits: [CardWaits.Wait], doing: String?,
                     team: TeamDirectory? = nil) -> DistillProgress.Card {
        var question: String?, asker: String?, askerIsAgent = false, approval = false, reason: String?, blockedBy: String?
        if card.column == .blocked {
            let shapes = events.map { (kind: $0.kindRaw, to: $0.toColumn ?? "") }
            if let index = BoardRules.waitingAsk(in: shapes) {
                let event = events[index]
                asker = event.author
                askerIsAgent = event.authorIsAgent
                if event.kind == .approval {
                    approval = true
                    question = AgentApproval(timeline: event.text)?.action ?? event.text
                } else {
                    question = event.text
                }
            } else {
                let moved = events.last { $0.toColumn == BoardColumn.blocked.rawValue }
                reason = moved?.text
                blockedBy = moved?.author
            }
        }
        // On a shared board, whom it waits on, as the board rings for it: a teammate, or you (nil).
        var waitsOn: String?
        if let team, card.column == .blocked || card.column == .review, !card.teamShadow.isEmpty, card.teamShadow != TeamBoard.held {
            waitsOn = team.waitsOn(asker: asker, askerIsAgent: askerIsAgent, meantFor: card.meantFor)
        }
        let report = events.last { $0.kind == .progress }
        let finished = card.column == .done ? events.last { $0.toColumn == BoardColumn.done.rawValue }?.createdAt ?? card.updatedAt : nil
        let from = card.distilledFrom
        let change = from?.change.map { notice -> DistillProgress.SectionChange in
            let caughtUp = (from?.briefUpdated.map { $0 >= notice.at } ?? false) || events.contains { event in
                event.createdAt > notice.at && event.author == card.assignee && [.progress, .claimed, .completed].contains(event.kind)
            }
            return DistillProgress.SectionChange(by: notice.by, at: notice.at, added: notice.added, removed: notice.removed, gone: notice.gone,
                                                 caughtUp: caughtUp, held: from?.held ?? false)
        }
        return DistillProgress.Card(id: card.id.uuidString, title: card.title, column: card.column, assignee: card.assignee,
                                    assigneeIsAgent: card.assigneeIsAgent, claimExpires: card.claimExpiresAt, meantFor: card.meantFor,
                                    meantForByAgent: card.meantForByAgent, waits: waits, question: question, asker: asker, approval: approval,
                                    blockedReason: reason, doing: doing, lastReport: report?.text, lastReportBy: report?.author,
                                    updated: card.updatedAt, finished: finished, section: from?.section, sectionChange: change,
                                    closed: from?.closed != nil, waitsOn: waitsOn, lastReportAt: report?.createdAt, blockedBy: blockedBy)
    }

    /// Who's who on the team, when any of these cards is on a board shared through the team database: the app's, or what
    /// it last kept for `Binders --mcp`. Nil otherwise.
    static func teamDirectory(for cards: [TaskCard]) -> TeamDirectory? {
        guard cards.contains(where: { !$0.teamShadow.isEmpty && $0.teamShadow != TeamBoard.held }) else { return nil }
        return TeamBoard.current?.directory ?? TeamBoard.savedDirectory()
    }

    /// Every card placed from the note, as the progress reads them. `doing`: what runs say they're doing, from the feed
    /// the app keeps while a page shows it (`lines`), or read now.
    static func progressCards(of note: UUID, doing lines: [UUID: String]? = nil, readDoing: Bool = false, now: Date = Date()) -> [DistillProgress.Card] {
        let cards = cards(of: note)
        let timelines = timelines(cards)
        // Only the cards waited for, in one fetch.
        let waited = Set(cards.flatMap(\.waitsFor)).compactMap(UUID.init(uuidString:))
        let found = waited.isEmpty ? [] : (try? Store.shared.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { waited.contains($0.id) }))) ?? []
        let byID = Dictionary(found.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let doing = lines ?? (readDoing ? AgentDoing.lines(for: cards, on: Store.shared.context, now: now) : [:])
        let team = teamDirectory(for: cards)
        return cards.map { card in
            let waits = card.waitsFor.compactMap { byID[$0] }.map { CardWaits.Wait(id: $0.id.uuidString, title: $0.title, column: $0.column) }
            return Self.card(card, events: timelines[card.id] ?? [], waits: waits, doing: doing[card.id], team: team)
        }
    }

    /// The note's progress: the Work bar, the Work panel's items and the report, since you last looked.
    static func progress(of note: NoteItem, doing lines: [UUID: String]? = nil, readDoing: Bool = false, since: Date?? = nil,
                         now: Date = Date()) -> DistillProgress.Progress {
        let cards = progressCards(of: note.id, doing: lines, readDoing: readDoing, now: now)
        let file = DistillStore.shared.file(for: note.id)
        let report = DistillProgress.report(note: note.title, cards: cards, since: since ?? file.lastLooked, now: now)
        let proposed = proposedCount(file)
        return DistillProgress.Progress(note: note.id.uuidString, title: note.title, binder: Store.shared.binder(note.binderID)?.name ?? "",
                                        counts: report.counts, line: report.line, items: DistillProgress.items(cards, at: now), report: report,
                                        proposed: proposed > 0 ? proposed : nil)
    }

    /// What its proposals still hold for a person to review: items to place, and Distill again's offers for cards on the
    /// board not yet taken or let be.
    static func proposedCount(_ file: DistillFile) -> Int {
        file.distills.filter { $0.status == .proposed }.map { $0.waiting.count + $0.openUpdates.count }.reduce(0, +)
    }

    /// A note's Work bar numbers alone.
    static func counts(of note: UUID, now: Date = Date()) -> DistillProgress.Counts {
        DistillProgress.counts(progressCards(of: note, now: now), at: now)
    }

    /// The notes with Distill on in a binder (every binder for nil), newest first.
    static func notes(in binder: UUID?) -> [NoteItem] {
        let notes = (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.distill },
                                                                               sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        return binder.map { id in notes.filter { $0.binderID == id } } ?? notes
    }

    /// A binder's Work list: each Distill note with its numbers.
    static func workList(in binder: UUID?, now: Date = Date()) -> [DistillProgress.WorkListEntry] {
        notes(in: binder).map { note in
            let counts = counts(of: note.id, now: now)
            let proposed = proposedCount(DistillStore.shared.file(for: note.id))
            return DistillProgress.WorkListEntry(note: note.id.uuidString, title: note.title, counts: counts, line: counts.line,
                                                 proposed: proposed > 0 ? proposed : nil)
        }
    }

    /// The card the agent holding it may read its spec through: its own card, when Distill made it or asked it to distill.
    static func note(forCard id: UUID) -> NoteItem? {
        guard let card = (try? Store.shared.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.id == id })))?.first,
              let from = card.distilledFrom else { return nil }
        return Store.shared.note(from.note)
    }
}

/// What a card still waits for, for its tile on the board: how many, and the line that names them.
@MainActor
enum CardWaitsBadge {
    static func open(_ card: TaskCard) -> [CardWaits.Wait] {
        let ids = card.waitsFor.compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty else { return [] }
        let found = (try? Store.shared.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        return CardWaits.open(found.map { CardWaits.Wait(id: $0.id.uuidString, title: $0.title, column: $0.column) })
    }

    static func count(_ card: TaskCard) -> Int? { open(card).count }
    static func line(_ card: TaskCard) -> String? { CardWaits.line(open(card)).map { $0 + ". An agent can't take it until they're done." } }
}
