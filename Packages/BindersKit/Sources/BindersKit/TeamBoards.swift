import CryptoKit
import Foundation

// Boards and agents on the team database (lane DB2): the calls migration 5 added, how people and agents are named on
// each Mac, what the team sees of an agent, invites, a teammate's agent's consent, and the dispatcher's and the bell's
// rules for what comes from teammates. Pure, so it's tested without a database; the Mac's TeamBoard uses it.

// MARK: Calls (migration 5)

extension TeamCall {
    /// A card moves to another shared binder's board. `keepSuggestion`: who an agent suggested it for goes with it, when
    /// that agent takes the new board's cards.
    public static func moveCardToBinder(_ card: UUID, to binder: UUID, keepSuggestion: Bool, agent: UUID? = nil,
                                        operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "move_card_to_binder", arguments: [.uuid("p_card", card), .uuid("p_binder", binder),
                                                              .boolean("p_keep_suggestion", keepSuggestion), .uuid("p_agent", agent)],
                 operation: operation)
    }

    /// One of your cards onto a shared board, as it is. `fields`: details, column, position, holder ("you" or one of your
    /// agents' ids), lease_until, meant_for, meant_for_by_agent, due_at, links, source_kind / source_id / source_title,
    /// todo_id, external_key, external_url, distilled, created_by_name, created_by_agent, created_at. Its operation id is
    /// derived from the card's, so bringing a board in again makes nothing twice.
    public static func bringCard(_ card: UUID, binder: UUID, title: String, fields: [String: TeamJSON]) -> TeamCall {
        TeamCall(function: "bring_card", arguments: [.uuid("p_card", card), .uuid("p_binder", binder), .text("p_title", title),
                                                     .json("p_fields", .object(fields))],
                 operation: TeamOperationID.derived("bring card \(card.uuidString.lowercased())"))
    }

    /// A wait a card brought in already had: derived, so it's made once.
    public static func bringWait(_ card: UUID, waitsFor other: UUID) -> TeamCall {
        .addDependency(card, waitsFor: other,
                       operation: TeamOperationID.derived("bring wait \(card.uuidString.lowercased()) \(other.uuidString.lowercased())"))
    }

    /// Distill's Place on Board, in one go. `items`: TeamPlacing.item rows, in order.
    public static func placeWorkItems(binder: UUID, items: [TeamRow], column: BoardColumn, agent: UUID? = nil,
                                      operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "place_work_items", arguments: [.uuid("p_binder", binder), .json("p_items", .array(items.map { .object($0) })),
                                                           .text("p_column", column.rawValue), .uuid("p_agent", agent)],
                 operation: operation)
    }

    public static func setCardDistilled(_ card: UUID, _ distilled: TeamJSON?, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "set_card_distilled", arguments: [.uuid("p_card", card), .json("p_distilled", distilled), .uuid("p_agent", agent)],
                 operation: operation)
    }

    /// This Mac is around: how far along the feed it has applied, and its agents online.
    public static func seen(seq: Int64, agents: [UUID], operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "seen", arguments: [TeamArgument("p_seq", "bigint", String(seq)),
                                               TeamArgument("p_agents", "uuid[]", "{" + agents.map { $0.uuidString.lowercased() }.joined(separator: ",") + "}")],
                 operation: operation)
    }

    /// Operations and changes older than `keepDays` (at least 30) go, as migration 5's prune keeps what Macs still need.
    public static func prune(keepDays: Int = 30, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "prune", arguments: [.integer("p_keep_days", keepDays)], operation: operation)
    }

    /// An admin gives a headless agent to another person. Its Auto goes off with it (migration 8): the new owner turns it
    /// on.
    public static func handAgent(_ agent: UUID, to owner: UUID, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "hand_agent_to", arguments: [.uuid("p_agent", agent), .uuid("p_owner", owner)], operation: operation)
    }

    /// A headless agent's owner turns its Auto on or off (migration 8): on, it takes cards on its own in the binders shared
    /// with its login; off, it can't take one. Only its owner can.
    public static func setAgentAuto(_ agent: UUID, on: Bool, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "set_agent_auto", arguments: [.uuid("p_agent", agent), .boolean("p_on", on)], operation: operation)
    }

    /// The card a call is about, when it's about one.
    public var card: UUID? { argument("p_card").flatMap(UUID.init(uuidString:)) }
}

// MARK: Names

/// How people and agents are named. In the database an agent's name carries its owner, "Claude Code · app (Sam)", so
/// timelines, holders and refusals read the same on every Mac and to headless readers; on its owner's Mac it's the name
/// it goes by there.
public enum TeamNames {
    /// "Claude Code · app (Sam)": an agent's name in the team. One that already ends with its owner is left as it is.
    public static func published(_ name: String, owner: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces), owner = owner.trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, !name.hasSuffix(" (\(owner))") else { return name }
        return "\(name) (\(owner))"
    }

    /// The name again without its owner, as its owner's Mac knows it.
    public static func local(_ published: String, owner: String) -> String {
        let suffix = " (\(owner.trimmingCharacters(in: .whitespaces)))"
        guard published.hasSuffix(suffix), published.count > suffix.count else { return published }
        return String(published.dropLast(suffix.count))
    }

    /// The team's id for an agent that acted through this Mac without being set up in Settings → Agents (your own Claude
    /// Code session, say): the same every time for the same member and name.
    public static func sessionAgentID(member: UUID, name: String) -> UUID {
        TeamOperationID.derived("session agent \(member.uuidString.lowercased()) \(name.trimmingCharacters(in: .whitespaces).lowercased())")
    }

    /// A login made from a person's name: lower-case letters, digits and underscores, starting with a letter, and
    /// "_2", "_3"… when it's taken. "Sam Lee" → "sam_lee".
    public static func login(for name: String, taken: Set<String> = []) -> String {
        var base = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "_" }.reduce(into: "") { $0.append($1) }
        while base.contains("__") { base = base.replacingOccurrences(of: "__", with: "_") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if base.first.map({ !$0.isLetter }) ?? true { base = "member" + (base.isEmpty ? "" : "_" + base) }
        base = String(base.prefix(56)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if base.count < 2 { base += "_1" }
        var candidate = base
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(base)_\(number)"
            number += 1
        }
        return candidate
    }
}

/// Who's who in the team, as this Mac knows it: its own member, the members, the agents (as the database lists them), and
/// which of the agents are this Mac's own, by the name each goes by here. It names everyone on the cards it writes into
/// this Mac's copy: "You" for this Mac's member, a teammate by their name, this Mac's agents by their own names, and a
/// teammate's agent by its name with its owner.
public struct TeamDirectory: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var login: String
        /// "person", or "agent" for a headless agent's own login.
        public var kind: String
        public var isAdmin: Bool
        public var seenAt: Date?
        public var removed: Bool

        public init(id: UUID, name: String, login: String = "", kind: String = "person", isAdmin: Bool = false, seenAt: Date? = nil,
                    removed: Bool = false) {
            self.id = id
            self.name = name
            self.login = login
            self.kind = kind
            self.isAdmin = isAdmin
            self.seenAt = seenAt
            self.removed = removed
        }

        public init?(row: TeamRow) {
            guard let id = row["id"]?.uuid, let name = row["name"]?.string else { return nil }
            self.init(id: id, name: name, login: row["login"]?.string ?? "", kind: row["kind"]?.string ?? "person",
                      isAdmin: row["is_admin"]?.bool ?? false, seenAt: row["seen_at"]?.date, removed: row.deletedAt != nil)
        }
    }

    public struct Agent: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var owner: UUID
        /// A headless agent's own login (a member), when it has one.
        public var login: UUID?
        /// Its name in the team, which carries its owner.
        public var name: String
        public var kind: String
        public var purpose: String
        public var binders: [UUID]
        /// Whether it starts on teammates' cards on its own, as its owner's Mac says. What teammates are told; its owner's
        /// Mac goes by its own switches. For a headless agent, whose row no Mac publishes, its Auto (migration 8): what lets
        /// it take any card.
        public var takesTeamCards: Bool
        public var sendsTo: String
        public var status: String
        public var onlineAt: Date?
        public var runningCard: UUID?
        public var removed: Bool
        /// A headless agent's Auto (migration 8): whether its owner turned it on, so it takes cards on its own. Nil for an
        /// agent on a Mac, whose Auto stays on its owner's Mac, and from a database before migration 8 (off there too).
        /// Optional, so who's who saved by an earlier Binders reads as it was.
        public var auto: Bool?

        public init(id: UUID, owner: UUID, login: UUID? = nil, name: String, kind: String = "", purpose: String = "", binders: [UUID] = [],
                    takesTeamCards: Bool = true, sendsTo: String = "", status: String = "", onlineAt: Date? = nil, runningCard: UUID? = nil,
                    removed: Bool = false, auto: Bool? = nil) {
            self.id = id
            self.owner = owner
            self.login = login
            self.name = name
            self.kind = kind
            self.purpose = purpose
            self.binders = binders
            self.takesTeamCards = takesTeamCards
            self.sendsTo = sendsTo
            self.status = status
            self.onlineAt = onlineAt
            self.runningCard = runningCard
            self.removed = removed
            self.auto = auto
        }

        public init?(row: TeamRow) {
            guard let id = row["id"]?.uuid, let owner = row["owner_id"]?.uuid, let name = row["name"]?.string else { return nil }
            let login = row["login_id"]?.uuid
            let auto = login == nil ? nil : (row["auto"]?.bool ?? false)
            self.init(id: id, owner: owner, login: login, name: name, kind: row["kind"]?.string ?? "",
                      purpose: row["purpose"]?.string ?? "", binders: row["binder_ids"]?.array?.compactMap(\.uuid) ?? [],
                      takesTeamCards: auto ?? row["takes_team_cards"]?.bool ?? true, sendsTo: row["sends_to"]?.string ?? "",
                      status: row["status"]?.string ?? "", onlineAt: row["online_at"]?.date, runningCard: row["running_card_id"]?.uuid,
                      removed: row.deletedAt != nil, auto: auto)
        }

        /// Online: its Mac (or its own login) said so in the last 12 minutes.
        public func isOnline(at now: Date = Date()) -> Bool {
            onlineAt.map { now.timeIntervalSince($0) < 12 * 60 } ?? false
        }

        /// A headless agent: one with a login of its own, which acts on the team's boards with no Mac in between.
        public var isHeadless: Bool { login != nil }

        /// Whether it takes cards on its own, as the team is told: an agent on a Mac when its owner's Mac says it starts on
        /// teammates' cards; a headless agent once its owner turned its Auto on.
        public var takesCardsOnItsOwn: Bool { isHeadless ? (auto ?? false) : takesTeamCards }

        /// It takes cards from this binder's board: it named the binder, as its owner's Mac publishes it.
        public func takes(binder: UUID?) -> Bool {
            binder.map(binders.contains) ?? false
        }
    }

    /// This Mac's member.
    public var me: UUID?
    public var members: [UUID: Member]
    public var agents: [UUID: Agent]
    /// This Mac's own agents (Settings → Agents), by their id in the team: the name each goes by here.
    public var local: [UUID: String]

    public init(me: UUID? = nil, members: [UUID: Member] = [:], agents: [UUID: Agent] = [:], local: [UUID: String] = [:]) {
        self.me = me
        self.members = members
        self.agents = agents
        self.local = local
    }

    // MARK: Rows

    /// A `members` or `agents` row as the feed brings it: kept, or marked removed.
    public mutating func take(member row: TeamRow) {
        if let member = Member(row: row) { members[member.id] = member }
    }

    public mutating func take(agent row: TeamRow) {
        if let agent = Agent(row: row) { agents[agent.id] = agent }
    }

    // MARK: Who

    /// This Mac's member's name in the team.
    public var myName: String? { me.flatMap { members[$0]?.name } }

    public func memberName(_ id: UUID?) -> String? { id.flatMap { members[$0]?.name } }

    /// The person an agent belongs to, by name.
    public func ownerName(of agent: Agent) -> String { members[agent.owner]?.name ?? "a teammate" }

    /// Whether it's this member's: listed by this Mac, or a headless agent of theirs.
    public func isMine(_ agent: Agent) -> Bool { me != nil && agent.owner == me }

    /// An agent's name on this Mac: its own name for one of this Mac's agents, its name in the team for any other (with
    /// its owner, added when the row doesn't carry it), the name without " (owner)" for an MCP session of this member's
    /// that isn't set up here.
    public func name(of agent: Agent) -> String {
        if let mine = local[agent.id] { return mine }
        if isMine(agent), agent.login == nil, let me = myName { return TeamNames.local(agent.name, owner: me) }
        return TeamNames.published(agent.name, owner: ownerName(of: agent))
    }

    /// A person's or an agent's name on this Mac, from a row's ids (`kind`, `member`, `agent`) and the name it stored
    /// (`stored`), which a row whose member or agent this Mac doesn't know yet falls back on. Binders' own lines keep
    /// "Binders".
    public func actor(kind: String?, member: UUID?, agent: UUID?, stored: String?) -> BoardActor {
        if kind == "agent" {
            if let agent, let known = agents[agent] { return BoardActor(name: name(of: known), kind: .agent) }
            if let agent, let mine = local[agent] { return BoardActor(name: mine, kind: .agent) }
            return BoardActor(name: stored?.nilIfBlank ?? "An agent", kind: .agent)
        }
        if let member {
            if member == me { return .you }
            return BoardActor(name: members[member]?.name ?? stored?.nilIfBlank ?? "A teammate", kind: .person)
        }
        return BoardActor(name: stored?.nilIfBlank ?? "Binders", kind: .person)
    }

    /// Who a card is meant for, as a name on this Mac: this member's name is "You", one of this Mac's agents' names in the
    /// team is its own name here; anyone else stays as the team names them.
    public func localName(_ team: String?) -> String? {
        guard let team = team?.trimmingCharacters(in: .whitespaces), !team.isEmpty else { return nil }
        if let me = myName, team.localizedCaseInsensitiveCompare(me) == .orderedSame { return BoardActor.you.name }
        if let agent = agents.values.first(where: { !$0.removed && isMine($0) && $0.name.localizedCaseInsensitiveCompare(team) == .orderedSame }) {
            return name(of: agent)
        }
        return team
    }

    /// The other way: "You" is this member's name, one of this Mac's agents' names carries its owner.
    public func teamName(_ local: String?) -> String? {
        guard let local = local?.trimmingCharacters(in: .whitespaces), !local.isEmpty else { return nil }
        if BoardRules.isReserved(local) { return myName ?? local }
        if let id = agentID(named: local), let agent = agents[id] { return agent.name }
        if let me = myName, isLocalAgentName(local) { return TeamNames.published(local, owner: me) }
        return local
    }

    /// This Mac's agent by the name it goes by here: its id in the team.
    public func agentID(named name: String) -> UUID? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if let id = local.first(where: { $0.value.localizedCaseInsensitiveCompare(wanted) == .orderedSame })?.key { return id }
        guard let me = myName else { return nil }
        // One of this member's agents that isn't set up here (an MCP session that acted before).
        return agents.values.first { isMine($0) && $0.login == nil && !$0.removed
            && TeamNames.local($0.name, owner: me).localizedCaseInsensitiveCompare(wanted) == .orderedSame }?.id
    }

    private func isLocalAgentName(_ name: String) -> Bool {
        local.values.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// Teammates' agents, as the team lists them: not removed, not this member's.
    public var teammatesAgents: [Agent] {
        agents.values.filter { !$0.removed && !isMine($0) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The people in the team other than this Mac's member, not removed.
    public var teammates: [Member] {
        members.values.filter { !$0.removed && $0.kind == "person" && $0.id != me }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The member a card meant for `name` (as this Mac names it) is for: a person, or an agent's owner. Nil for no one,
    /// or a name the team doesn't know.
    public func memberFor(meantFor name: String?) -> UUID? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if BoardRules.isReserved(name) { return me }
        if let id = agentID(named: name) { return agents[id]?.owner ?? me }
        if let agent = agents.values.first(where: { !$0.removed && self.name(of: $0).localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return agent.owner
        }
        return members.values.first { !$0.removed && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.id
    }

    // MARK: Rings

    /// Whether a question or a request for approval that came from the team rings on this Mac: the agent asking is this
    /// member's (a headless one, or one acting for them), or the card is meant for this member or one of their agents.
    /// Questions this Mac's own agents ask ring as they always did, when they're asked here.
    public func rings(askedBy agent: UUID?, meantFor: String?) -> Bool {
        guard let me else { return false }
        if let agent, let asker = agents[agent], asker.owner == me { return true }
        return memberFor(meantFor: meantFor) == me
    }

    // MARK: Approvals

    /// The member an agent belongs to, by the name it goes by on this Mac: this Mac's member for one of this Mac's agents,
    /// its owner for any other the team lists (taken off the list since, too). Nil for a name the team doesn't know.
    public func owner(ofAgentNamed name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let id = agentID(named: name) { return agents[id]?.owner ?? me }
        let known = agents.values.sorted { !$0.removed && $1.removed }
        return known.first { self.name(of: $0).localizedCaseInsensitiveCompare(name) == .orderedSame }?.owner
    }

    /// Who decides on what an agent asked approval for on a shared card (BoardRules.deciders), as members: the owner of
    /// the agent asking (`askedBy`, as this Mac names it), and the member the card is meant for, unless an agent or Binders
    /// only suggested it.
    public func deciders(askedBy agent: String, meantFor: String?, suggested: Bool) -> [UUID] {
        BoardRules.deciders(askerOwner: owner(ofAgentNamed: agent), meantFor: memberFor(meantFor: meantFor), suggested: suggested)
    }

    /// Whether this Mac's member decides on it. Nil when this Mac can't tell (it doesn't know who it is in the team, or whose
    /// agent asked): the team database decides then.
    public func decides(askedBy agent: String, meantFor: String?, suggested: Bool) -> Bool? {
        guard let me else { return nil }
        let deciders = deciders(askedBy: agent, meantFor: meantFor, suggested: suggested)
        if deciders.contains(me) { return true }
        return owner(ofAgentNamed: agent) == nil ? nil : false
    }

    /// Who decides, in words for someone who doesn't (BoardRules.onlyDeciders), with everyone named as the team names them.
    public func onlyDeciders(askedBy agent: String, meantFor: String?, suggested: Bool) -> String {
        let owner = owner(ofAgentNamed: agent).flatMap { members[$0].flatMap { $0.removed ? nil : $0.name } }
        let meant = suggested ? nil : memberFor(meantFor: meantFor).flatMap { members[$0]?.name }
        return BoardRules.onlyDeciders(owner: owner, meantFor: meant)
    }
}

extension String {
    /// Nil for an empty or blank string.
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
