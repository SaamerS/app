import Foundation

/// What `Binders --mcp` offers, from what started it (BINDERS_TOOLS, BINDERS_RUN, BINDERS_CARD, BINDERS_AGENT), read once.
/// Every run Binders starts for a card sets BINDERS_TOOLS=board and BINDERS_RUN: that card's board tools as that agent, or
/// no tools at all when the card or the agent's name didn't arrive, so a tool that passes the values on badly gets nothing
/// rather than every card on every board. BINDERS_TOOLS stays "board" because a Binders before this one (Mac 0.8.0, say,
/// put back in /Applications while a run goes on) reads any other value as your own host, with every tool; it ignores
/// BINDERS_RUN and still offers that card's board tools only.
public enum MCPConfinement: Equatable, Sendable {
    /// Your own hosts: every tool.
    case everything
    /// An agent you set up its own server for (`AgentMCPEntry`): the board tools, one card's when BINDERS_CARD is set.
    case board(card: UUID?)
    /// A run Binders started: the board tools but create_task, for this card only.
    case card(UUID)
    /// A run Binders started that didn't get its card or its name: no tools at all.
    case nothing

    public static func read(_ environment: [String: String]) -> MCPConfinement {
        let card = environment["BINDERS_CARD"].flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
        // A run Binders started, whatever BINDERS_TOOLS says ("card" was this build's first way of saying so).
        if environment["BINDERS_RUN"] != nil || environment["BINDERS_TOOLS"] == "card" {
            let agent = (environment["BINDERS_AGENT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let card, !agent.isEmpty, !BoardRules.isReserved(agent) else { return .nothing }
            return .card(card)
        }
        return environment["BINDERS_TOOLS"] == "board" ? .board(card: card) : .everything
    }

    /// The one card it may see and change, if it's confined to one.
    public var card: UUID? {
        switch self {
        case .board(let card): card
        case .card(let card): card
        case .everything, .nothing: nil
        }
    }

    /// Whether it offers the board's tools alone (or none), as an agent.
    public var boardOnly: Bool { self != .everything }

    /// What the server says about itself when it offers nothing.
    public static let nothingInstructions = "Binders started this server for one card but didn't say which, so it offers no tools."
}
