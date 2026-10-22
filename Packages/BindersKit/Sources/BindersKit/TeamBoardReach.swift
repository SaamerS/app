import Foundation

// A board shared through a team database while the database is turned off on this Mac, or out of reach (lane DB8). The
// database decides who holds a card, where it is on the board, whether it's done, and approvals: those changes are
// refused at once while it can't be asked, so nothing is queued that would surprise anyone when it's back. Everything
// else (a comment, a report, links, a new card, who a card is meant for, what it waits for, an edit) is kept on this Mac
// in the outbox and goes once the database is back, because the database takes it as well then as now.
//
// Checked against how each is applied when it arrives late (migrations 2, 5 and 8):
// - claim_card: a person takes a card over from anyone, so a late claim would take it from a teammate who took it since.
// - move_card: a person moves anything, and a move back to Backlog or Ready lets go of whoever holds it; into In progress
//   it's a claim; into Review or Done it finishes. All of it is the database's to decide.
// - finish, decide, release: finishing, an approval, letting go of a card (a person releases anyone's).
// - delete_card: a late delete would take away a card a teammate has picked up since.
// - move_card_to_binder: a card leaving the team's board, or moving between its boards.
// - answer from a person who decides on the approval the card waits on: the database takes it as the decision.
// - report: sent late, it would keep an agent's claim alive from when it arrives, so it goes without renewing the claim.
// - keep_alive: changes nothing but the lease, so it isn't sent late at all.
// - answer (a comment), ask, request_approval, create_card, assign_card, add_dependency, remove_dependency, edit_card,
//   log_card, bring_card, set_card_distilled, place_work_items: taken as they are, or refused then with the reason (an
//   agent asking about a card a teammate has since taken), and put back with a line that says why.

/// How this Mac stands with the team database a board is shared through.
public enum TeamReach: String, Equatable, Sendable {
    /// Connected, and answering.
    case reachable
    /// Set up and turned on, but not connected, or connected and not answering.
    case unreachable
    /// Team databases are turned off on this Mac (TeamDatabaseFeature).
    case off
}

/// A change to a card that the team database decides, so it waits for the database.
public enum TeamBoardWrite: Equatable, Sendable {
    case claim
    case move(BoardColumn)
    case finish
    case release
    case decide
    /// A person's comment on a card that waits for an approval they decide on: the database takes it as the decision.
    case answerApproval
    case delete
    /// To another binder's board, from a board shared through the database.
    case moveToBoard

    /// What can't happen yet, in words: "the card can't be taken".
    public var phrase: String {
        switch self {
        case .claim: "the card can't be taken"
        case .move(let column): "the card can't move to \(column.title)"
        case .finish: "the card can't be finished"
        case .release: "the card can't be let go"
        case .decide: "this approval can't be decided"
        case .answerApproval: "this approval can't be answered"
        case .delete: "the card can't be deleted"
        case .moveToBoard: "the card can't move to another board"
        }
    }
}

public enum TeamBoardWrites {
    /// The database's functions that decide (TeamBoardWrite): never queued while it's off or out of reach.
    public static let deciding: Set<String> = ["claim_card", "move_card", "finish", "release", "decide", "delete_card", "move_card_to_binder"]

    public static func decides(_ call: TeamCall) -> Bool { deciding.contains(call.function) }

    /// How long a change the database decides may wait in the outbox before it goes. Later than that, it goes only when the
    /// database already has it (its answer was lost on the way back); otherwise it's taken back, so it can't land minutes
    /// after whoever made it was told it didn't.
    public static let decideWithin: TimeInterval = 8

    /// How long an agent over MCP waits for the database's answer before it hears what this Mac knows; a person's change
    /// from the iPhone waits a little less.
    public static let agentWait: TimeInterval = 5
    public static let personWait: TimeInterval = 4

    /// How a change made while the database can't be asked goes when it's sent later: a report without keeping an agent's
    /// claim alive from then, a check-in not at all (nil). Anything else as it is.
    public static func late(_ call: TeamCall) -> TeamCall? {
        switch call.function {
        case "keep_alive":
            return nil
        case "report":
            var late = call
            late.arguments = call.arguments.map { $0.name == "p_renewing" ? .boolean("p_renewing", false) : $0 }
            return late
        default:
            return call
        }
    }

    // MARK: Words

    /// Why a change the database decides is refused now. `agent`: for an agent over MCP, which can try again later; a
    /// person hears what to do.
    public static func refusal(_ write: TeamBoardWrite, _ reach: TeamReach, agent: Bool) -> String {
        switch reach {
        case .reachable:
            return ""
        case .unreachable:
            return "This board is shared through your team's database, which this Mac can't reach right now, so \(write.phrase) yet."
                + (agent ? " Try again later." : " Check that your VPN (such as Covee) is connected, then try again.")
        case .off:
            return "This board is shared through your team's database, which is turned off on this Mac, so \(write.phrase) yet."
                + (agent ? " Try again later." : " Turn team databases on again on this Mac first.")
        }
    }

    /// What a change that waits for the database is told: it's kept here, and when it goes.
    public static func kept(_ reach: TeamReach) -> String {
        switch reach {
        case .reachable: ""
        case .unreachable: "The team's database can't be reached from this Mac right now, so this is kept here and goes to the team's board when it's back."
        case .off: "Team databases are turned off on this Mac, so this is kept here and goes to the team's board once they're turned on again."
        }
    }

    /// A change that waits while the database is connected but hasn't answered within the wait.
    public static let notAnsweredYet = "The team's database hasn't answered yet, so this is kept here and goes to the team's board once it does."

    /// A change the database decides, taken back from the outbox because the database didn't answer within the wait:
    /// "The team's database didn't answer within 5 seconds, so this Mac took back the claim: nothing changed. Try again
    /// later."
    public static func withdrawn(_ call: TeamCall, agent: Bool) -> String {
        "The team's database didn't answer within \(Int(agent ? agentWait : personWait)) seconds, so this Mac took back the \(TeamRefusalLine.what(call)): nothing changed."
            + (agent ? " Try again later." : " Try again in a moment.")
    }

    /// One already on its way when the wait ran out: it may have gone through. It isn't sent again unless the database
    /// has it.
    public static func unknown(_ call: TeamCall, agent: Bool) -> String {
        "The team's database didn't answer within \(Int(agent ? agentWait : personWait)) seconds, so this Mac can't tell yet whether the \(TeamRefusalLine.what(call)) went through."
            + (agent ? " get_task in a minute says; it isn't sent again unless the database already has it." : " The card shows it once the database answers.")
    }

    /// Settings → Team's status line while connected to a database that doesn't answer.
    public static let notAnswering = "Connected, but the team database isn't answering. Taking, moving and finishing cards waits until it does; other changes wait on this Mac. Check that your VPN (such as Covee) is connected."

    /// Why one left in the outbox past `decideWithin` wasn't sent (TeamRefusalLine puts it after "didn't go through").
    public static let notSentLate = "The team's database didn't answer in time, so Binders didn't send it again."

    /// The line over a board shared through the database while it's off or out of reach: what waits, what's kept, and
    /// what to do. Nil when it's reachable.
    public static func boardLine(_ reach: TeamReach) -> String? {
        switch reach {
        case .reachable:
            return nil
        case .unreachable:
            return "This Mac can't reach your team's database right now. Taking, moving and finishing cards waits until it's back; comments, reports and new cards are kept here and go then. Check that your VPN (such as Covee) is connected."
        case .off:
            return "This board is shared through your team's database, which is turned off on this Mac. Taking, moving and finishing cards waits until it's on again; comments, reports and new cards are kept here for it."
        }
    }
}
