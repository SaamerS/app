import Foundation
import BindersKit

/// Teammates' items that reach this Mac through a team database (lane DB5), kept from a tool that may not read them, as a
/// team folder's copies are (Settings → MCP, `Reads.team`). Notes, meetings, captures, to-dos and knowledge passages from
/// the database are team copies already (`isTeamCopy`, `teamAuthorID`, `KnowledgeHit.author`); these are the rest: the
/// binders a teammate made, and what teammates and their agents wrote on shared cards that aren't the agent's own work.
extension MCPServer {
    /// Who's who in the team as the app keeps it: the running app's, or what it last saved, for `Binders --mcp`. Nil without
    /// a team database, or while it's turned off.
    static var teamDirectory: TeamDirectory? { TeamBoard.current?.directory ?? TeamBoard.savedDirectory() }

    /// A teammate's binder: a team folder's copy, or one a teammate made and shares through a team database.
    static func isTeammates(_ binder: BinderRecord) -> Bool {
        binder.isTeamCopy || (binder.sharedThroughDatabase && !binder.teamMadeBy.isEmpty)
    }

    /// Whether a binder is shared with a team, as its pages say: through a team folder, yours or a teammate's, or a team
    /// database.
    static func isShared(_ binder: BinderRecord) -> Bool {
        binder.sharedWithTeam || binder.isTeamCopy || binder.shownSharedThroughDatabase
    }

    /// Whether a line on a card is a teammate's: a person's on another Mac, or a teammate's agent's. Only on a board shared
    /// through a team database, where this Mac names its own member "You", its own agents by their own names and Binders
    /// as Binders, and the team says whose every other agent is.
    static func isTeammates(_ event: TaskEvent, on card: TaskCard, directory: TeamDirectory?) -> Bool {
        guard Store.shared.binder(card.binderID)?.sharedThroughDatabase == true else { return false }
        let author = event.author.trimmingCharacters(in: .whitespaces)
        if BoardRules.isReserved(author) || author == BoardService.binders.name { return false }
        guard event.authorIsAgent else { return true }
        guard let directory, let owner = directory.owner(ofAgentNamed: author) else { return false }
        return owner != directory.me
    }

    /// The lines of a card's timeline a tool may read: every one for a tool that may read teammates' items, and on a card
    /// that's the agent's own work (it holds it, it's meant for it, or it asked on it), where teammates write to it.
    /// Elsewhere, teammates' lines are left out, as their notes are.
    static func readable(_ events: [TaskEvent], on card: TaskCard, by agent: BoardActor, reads: Reads) -> [TaskEvent] {
        guard !reads.team, agent.isAgent else { return events }
        func isAgent(_ name: String?) -> Bool {
            name.map { BoardRules.isNamed(agent.name, as: $0) || BoardRules.isNamed($0, as: agent.name) } ?? false
        }
        let own = isAgent(card.assignee) || (!card.meantForByAgent && isAgent(card.meantFor))
            || events.contains { ($0.kind == .question || $0.kind == .approval) && $0.authorIsAgent && isAgent($0.author) }
        guard !own else { return events }
        let directory = teamDirectory
        return events.filter { !isTeammates($0, on: card, directory: directory) }
    }

    /// The question a card in the work streams waits on, left out when a teammate's agent asked it and the tool may not
    /// read teammates' items: who asked stays.
    static func readable(_ cards: [WorkStreams.Card], reads: Reads) -> [WorkStreams.Card] {
        guard !reads.team, let directory = teamDirectory else { return cards }
        return cards.map { card in
            guard let asker = card.asker, let owner = directory.owner(ofAgentNamed: asker), owner != directory.me else { return card }
            var kept = card
            kept.question = nil
            return kept
        }
    }
}
