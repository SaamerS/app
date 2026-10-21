import Foundation
import SwiftData
import BindersKit

/// What Binders writes on a card the first time it goes to an agent: up to three passages from the notes and meetings in
/// the card's binder that match it (`AgentContext`), as a comment by Binders, "From your binders". Only what that agent may
/// read, as Settings → MCP allows its tool: a capture, or a note or meeting a teammate shared, only when it may read those;
/// never a transcript, and never a note an agent wrote or changed, until you make it yours. Written once a card, for the
/// agent it first goes to; you can edit or delete it on the card.
@MainActor
enum AgentBriefing {
    /// What the agent named `name` may read besides your notes and meetings: what Settings → MCP allows its tool.
    static func reads(for name: String) -> AgentReads {
        let reads = MCPServer.reads(for: name)
        return AgentReads(captures: reads.captures, transcripts: reads.transcripts, team: reads.team)
    }

    /// The card goes to `agent`. The first time, what its binder knows is written on it, unless the agent's "Add context
    /// from the binder" is off. Written already, for an agent it went to before, it loses what this one may not read.
    static func brief(_ card: TaskCard, for agent: AgentProfile, board: BoardService) {
        let reads = reads(for: agent.name)
        if let written = board.contextNote(on: card) {
            let kept = AgentContext.keeping(written.text, readableBy: reads)
            if kept != written.text { board.editContext(written, text: kept) }
            return
        }
        guard agent.addsContext else { return }
        // Never the capture the card came from (lane Y2): its words reach the agent only as the card quotes them.
        // A to-do's card links its moment by `sourceRef`; an idea's card has the moment's own id, and names it as its source.
        let leavingOut = [card.sourceRef, card.sourceKind == "moment" ? card.sourceID : nil, card.id.uuidString]
            .compactMap { $0 }.lazy.compactMap { MomentService.capture(ofMoment: $0) }.first
        let snippets = AgentContext.snippets(title: card.title, details: card.details, from: sources(in: card.binderID, reads: reads, leavingOut: leavingOut),
                                             reads: reads)
        board.addContext(card, text: AgentContext.comment(snippets))
    }

    /// What the card says it found, for the agent woken for it: as you left it, and only for an agent that adds it.
    static func text(on card: TaskCard, for agent: AgentProfile, board: BoardService) -> String {
        guard agent.addsContext, let written = board.contextNote(on: card) else { return "" }
        return AgentContext.keeping(written.text, readableBy: reads(for: agent.name))
    }

    /// The notes and meetings in the binder, newest first, that may go with a card to an agent that may read `reads`: a
    /// capture only when it may read captures, a teammate's only when it may read theirs, never a note an agent wrote or
    /// changed (its agent mark, as Ask leaves it out). Meetings and captures by their notes, never their transcripts.
    /// `leavingOut`: a capture the card came from, whose notes never go with it (lane Y2).
    static func sources(in binderID: UUID?, reads: AgentReads, leavingOut: UUID? = nil) -> [AgentContext.Source] {
        guard let binderID else { return [] }
        let context = Store.shared.context
        var notes = FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        notes.fetchLimit = 300
        var meetings = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID && $0.status == "ready" },
                                                      sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        meetings.fetchLimit = 150
        var sources: [AgentContext.Source] = []
        for note in (try? context.fetch(notes)) ?? [] where note.agentMark.isEmpty && (reads.team || !note.isTeamCopy) {
            sources.append(AgentContext.Source(kind: .note, title: note.title, text: note.text, teammate: note.isTeamCopy, date: note.updatedAt))
        }
        for meeting in (try? context.fetch(meetings)) ?? [] where (reads.team || !meeting.isTeamCopy) && (reads.captures || !meeting.isConversation)
            && meeting.id != leavingOut {
            let notes = meeting.isTeamCopy ? TeamSyncService.shown(meeting.summary, by: meeting.teamAuthorName) : meeting.summary
            sources.append(AgentContext.Source(kind: meeting.isConversation ? .capture : .meeting, title: meeting.title, text: notes,
                                               teammate: meeting.isTeamCopy, date: meeting.createdAt))
        }
        return sources
    }
}
