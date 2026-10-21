import Foundation
import SwiftData
import BindersKit

/// A card on a binder's board: a piece of work someone, or some agent, can pick up.
@Model
final class TaskCard {
    @Attribute(.unique) var id: UUID
    var binderID: UUID?
    var title: String
    /// Markdown.
    var details: String = ""
    var columnRaw: String = BoardColumn.backlog.rawValue
    /// Order within its column; lower is higher up.
    var position: Double = 0
    var assignee: String?
    var assigneeIsAgent: Bool = false
    var claimExpiresAt: Date?
    var dueAt: Date?
    /// Pull requests, files, pages: whatever the work produced or points at.
    var links: [String] = []
    /// Where it came from: "meeting", "note", "commitment"…, with the item's id and title.
    var sourceKind: String?
    var sourceID: String?
    var sourceTitle: String?
    /// The to-do this card was made from, as list_todos names it; it's ticked off when the card is done.
    var sourceRef: String?
    var createdBy: String = "You"
    var createdAt: Date
    var updatedAt: Date
    /// The same card in Jira, Linear or GitHub, once one is connected.
    var externalKey: String?
    var externalURL: String?
    /// Who the card is meant for before anyone takes it: an agent such as "Claude Code" or "Pennant", or a person. Kept
    /// apart from the claim, so "meant for Pennant, not started" survives a lapse.
    var meantFor: String?
    /// Meant for someone by an agent rather than by you: a suggestion. Binders wakes no one for it until you assign it.
    var meantForByAgent: Bool = false

    init(title: String, binderID: UUID?, column: BoardColumn = .backlog) {
        self.id = UUID()
        self.title = title
        self.binderID = binderID
        self.columnRaw = column.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.position = Date().timeIntervalSinceReferenceDate
    }

    var column: BoardColumn {
        get { BoardColumn(rawValue: columnRaw) ?? .backlog }
        set { columnRaw = newValue.rawValue }
    }

    var state: CardState {
        get { CardState(column: column, assignee: assignee, assigneeIsAgent: assigneeIsAgent, claimExpires: claimExpiresAt) }
        set {
            column = newValue.column
            assignee = newValue.assignee
            assigneeIsAgent = newValue.assigneeIsAgent
            claimExpiresAt = newValue.claimExpires
        }
    }

    /// Its state in the words A2A and MCP Tasks use: its column, and in Blocked whether a question waits on you
    /// (input_required) or it's blocked with a reason (failed). `events`, its timeline oldest first, when it's at hand;
    /// only a Blocked card reads it.
    @MainActor
    func taskState(events: [TaskEvent]? = nil) -> TaskState {
        guard column == .blocked else { return TaskState(column: column, questionWaiting: false) }
        let id = self.id
        let timeline = events ?? (try? Store.shared.context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.taskID == id },
                                                                                             sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return TaskState(column: .blocked, timeline: timeline.map { (kind: $0.kindRaw, to: $0.toColumn ?? "") })
    }

    /// The request for your approval it waits on in Blocked, and what it asks, or nil. `events`, its timeline oldest first,
    /// when it's at hand.
    @MainActor
    func waitingApproval(events: [TaskEvent]? = nil) -> (event: TaskEvent, approval: AgentApproval)? {
        guard column == .blocked else { return nil }
        let id = self.id
        let timeline = events ?? (try? Store.shared.context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.taskID == id },
                                                                                             sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        guard let index = BoardRules.waitingApproval(in: timeline.map { (kind: $0.kindRaw, to: $0.toColumn ?? "") }),
              let approval = AgentApproval(timeline: timeline[index].text) else { return nil }
        return (timeline[index], approval)
    }

    /// Whether a save (ModelContext.didSave's userInfo) changed only cards and their timelines. The knowledge index and
    /// team sharing hold neither, so they let such a save, an agent's progress report among them, go by.
    nonisolated static func onlyBoards(_ userInfo: [AnyHashable: Any]?) -> Bool {
        let changed = [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
            .flatMap { userInfo?[$0.rawValue] as? [PersistentIdentifier] ?? [] }
        return !changed.isEmpty && changed.allSatisfy { ["TaskCard", "TaskEvent"].contains($0.entityName) }
    }
}

/// One line of a card's timeline: a move, a claim, a progress report, a question, an answer, a comment.
@Model
final class TaskEvent {
    @Attribute(.unique) var id: UUID
    var taskID: UUID
    var kindRaw: String
    var author: String
    var authorIsAgent: Bool
    var text: String
    var fromColumn: String?
    var toColumn: String?
    var createdAt: Date

    enum Kind: String {
        case created, moved, claimed, released, lapsed, progress, question, answer, comment, completed, edited, assigned, woke
        /// What Binders found in the card's binder when the card first went to an agent ("From your binders"), by Binders.
        /// Only Binders writes one; emptied, it was deleted, and it isn't written again.
        case context
        /// An agent asks your approval before it sends, posts, buys or deletes something outside Binders (request_approval):
        /// `AgentApproval.timelineText`, by the agent. The card waits in Blocked until you decide.
        case approval
        /// The receipt for your decision on one: who decided, where, when and exactly what (`AgentApproval.receipt`), by
        /// Binders. Your answer follows it, as an answer.
        case decision
    }

    init(taskID: UUID, kind: Kind, author: BoardActor, text: String = "", from: BoardColumn? = nil, to: BoardColumn? = nil) {
        self.id = UUID()
        self.taskID = taskID
        self.kindRaw = kind.rawValue
        self.author = author.name
        self.authorIsAgent = author.isAgent
        self.text = text
        self.fromColumn = from?.rawValue
        self.toColumn = to?.rawValue
        self.createdAt = Date()
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .comment }
}

extension TaskEvent {
    /// The event as a card's conversation reads it (`CardConversation`).
    var conversation: CardConversation.Event {
        CardConversation.Event(kind: kindRaw, author: author, byAgent: authorIsAgent, text: text, from: fromColumn, to: toColumn, at: createdAt)
    }
}
