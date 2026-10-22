import CryptoKit
import Foundation

// Every change to the team database is one call of one of its functions, with an operation id: the board's actions,
// row writes, binders, agents and members. A call is plain data (function, named arguments, operation id), so it's kept
// in the outbox as it is and any later Binders can send it; the database checks the types.

/// One argument of a call: its name in the function, its SQL type, and its value as Postgres reads it from text (nil
/// for NULL). Every argument is bound as text and cast in the statement.
public struct TeamArgument: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var value: String?

    public init(_ name: String, _ type: String, _ value: String?) {
        self.name = name
        self.type = type
        self.value = value
    }

    public static func uuid(_ name: String, _ value: UUID?) -> TeamArgument { .init(name, "uuid", value?.uuidString.lowercased()) }
    public static func text(_ name: String, _ value: String?) -> TeamArgument { .init(name, "text", value) }
    public static func boolean(_ name: String, _ value: Bool?) -> TeamArgument { .init(name, "boolean", value.map { $0 ? "true" : "false" }) }
    public static func integer(_ name: String, _ value: Int?) -> TeamArgument { .init(name, "integer", value.map(String.init)) }
    public static func json(_ name: String, _ value: TeamJSON?) -> TeamArgument { .init(name, "jsonb", value?.text) }
}

/// A call of one of the database's functions: what goes in the outbox.
public struct TeamCall: Codable, Equatable, Sendable, Identifiable {
    /// The function, in schema `binders`.
    public var function: String
    public var arguments: [TeamArgument]
    /// Its operation id: the same on every try, so the database applies it once and answers every try the same.
    public var operation: UUID

    public var id: UUID { operation }

    public init(function: String, arguments: [TeamArgument], operation: UUID = UUID()) {
        self.function = function
        self.arguments = arguments
        self.operation = operation
    }

    /// The statement and its values, in order: `SELECT binders.claim_card(p_op => $1::uuid, …)::text`. Function and
    /// argument names that aren't plain lower-case identifiers are refused (nil), so nothing from a call can change the
    /// statement.
    public var statement: (sql: String, values: [String?])? {
        let identifier = "^[a-z_][a-z0-9_]*$"
        let types: Set<String> = ["uuid", "text", "boolean", "integer", "bigint", "jsonb", "timestamptz", "double precision", "uuid[]"]
        guard function.range(of: identifier, options: .regularExpression) != nil,
              arguments.allSatisfy({ $0.name.range(of: identifier, options: .regularExpression) != nil && types.contains($0.type) })
        else { return nil }
        let all = [TeamArgument.uuid("p_op", operation)] + arguments
        let list = all.enumerated().map { "\($1.name) => $\($0 + 1)::\($1.type)" }.joined(separator: ", ")
        return ("SELECT binders.\(function)(\(list))::text", all.map(\.value))
    }

    /// The same call with another operation id: for a change made again on purpose, never for a retry.
    public func again(operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: function, arguments: arguments, operation: operation)
    }

    /// The value of one of its arguments, as given.
    public func argument(_ name: String) -> String? {
        arguments.first { $0.name == name }?.value
    }
}

/// Operation ids made from a name, for a change that must happen at most once however often it's made: bringing a
/// local card into the team, say, uses the card's own id, so doing it again finds the first. Version 5 (SHA-1) UUIDs in
/// a namespace of Binders' own.
public enum TeamOperationID {
    public static let namespace = UUID(uuidString: "6b1d3a1c-5f0e-4c7b-9a51-2f3e6d0b8c41")!

    public static func derived(_ name: String, in namespace: UUID = namespace) -> UUID {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes += Array(name.utf8)
        var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }
}

// MARK: The board

/// A line a card's timeline gets without anything else changing (`log_card`).
public enum TeamCardLine: String, Sendable {
    /// What Binders found in the binder when the card first went to an agent; once a card.
    case context
    /// A note by Binders itself (written as a comment by Binders).
    case note
    /// The receipt for a wake, by the agent woken.
    case woke
    /// An edit worth a line.
    case edited
}

extension TeamCall {
    /// Taking a card: `agent` acts for this login's agent (nil: the person whose login it is).
    public static func claimCard(_ card: UUID, agent: UUID? = nil, note: String = "", operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "claim_card", arguments: [.uuid("p_card", card), .uuid("p_agent", agent), .text("p_note", note)], operation: operation)
    }

    public static func moveCard(_ card: UUID, to column: BoardColumn, agent: UUID? = nil, note: String = "", operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "move_card", arguments: [.uuid("p_card", card), .text("p_column", column.rawValue), .uuid("p_agent", agent),
                                                    .text("p_note", note)], operation: operation)
    }

    public static func report(_ card: UUID, progress: String, links: [String] = [], agent: UUID? = nil, renewing: Bool = true,
                              operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "report", arguments: [.uuid("p_card", card), .text("p_progress", progress), .json("p_links", TeamJSON(links)),
                                                 .uuid("p_agent", agent), .boolean("p_renewing", renewing)], operation: operation)
    }

    public static func keepAlive(_ card: UUID, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "keep_alive", arguments: [.uuid("p_card", card), .uuid("p_agent", agent)], operation: operation)
    }

    public static func ask(_ card: UUID, question: String, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "ask", arguments: [.uuid("p_card", card), .text("p_question", question), .uuid("p_agent", agent)], operation: operation)
    }

    /// A comment; a person's on a blocked card is its answer.
    public static func answer(_ card: UUID, text: String, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "answer", arguments: [.uuid("p_card", card), .text("p_text", text), .uuid("p_agent", agent)], operation: operation)
    }

    /// `text` as AgentApproval.timelineText writes it.
    public static func requestApproval(_ card: UUID, text: String, agent: UUID?, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "request_approval", arguments: [.uuid("p_card", card), .text("p_text", text), .uuid("p_agent", agent)],
                 operation: operation)
    }

    /// A person's decision. `approval`, the request's id when what decided showed it; `receipt`, AgentApproval.receipt.
    /// `agent`, when an agent tried: refused, as only a person decides.
    public static func decide(_ card: UUID, approve: Bool, reason: String = "", device: String, approval: UUID? = nil,
                              receipt: String? = nil, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "decide", arguments: [.uuid("p_card", card), .boolean("p_approve", approve), .text("p_reason", reason),
                                                 .text("p_device", device), .uuid("p_approval", approval), .text("p_receipt", receipt),
                                                 .uuid("p_agent", agent)], operation: operation)
    }

    public static func release(_ card: UUID, agent: UUID? = nil, note: String = "", operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "release", arguments: [.uuid("p_card", card), .uuid("p_agent", agent), .text("p_note", note)], operation: operation)
    }

    public static func finish(_ card: UUID, summary: String, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "finish", arguments: [.uuid("p_card", card), .text("p_summary", summary), .uuid("p_agent", agent)], operation: operation)
    }

    /// A new card. `fields`: details, column, position, due_at, links, source_kind / source_id / source_title, todo_id,
    /// distill_item_id, note_section, note_version_id, external_key, external_url, waits_for.
    public static func createCard(_ card: UUID, binder: UUID, title: String, fields: [String: TeamJSON] = [:], agent: UUID? = nil,
                                  operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "create_card", arguments: [.uuid("p_card", card), .uuid("p_binder", binder), .text("p_title", title),
                                                      .json("p_fields", .object(fields)), .uuid("p_agent", agent)], operation: operation)
    }

    /// `fields`: title, details, due_at (null clears it), links, position, external_key, external_url.
    public static func editCard(_ card: UUID, fields: [String: TeamJSON], agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "edit_card", arguments: [.uuid("p_card", card), .json("p_fields", .object(fields)), .uuid("p_agent", agent)],
                 operation: operation)
    }

    /// Who it's meant for; from an agent, or Binders' own (`suggesting`), a suggestion.
    public static func assignCard(_ card: UUID, to name: String?, agent: UUID? = nil, suggesting: Bool = false, why: String? = nil,
                                  operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "assign_card", arguments: [.uuid("p_card", card), .text("p_name", name), .uuid("p_agent", agent),
                                                      .boolean("p_suggesting", suggesting), .text("p_why", why)], operation: operation)
    }

    public static func deleteCard(_ card: UUID, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "delete_card", arguments: [.uuid("p_card", card)], operation: operation)
    }

    public static func addDependency(_ card: UUID, waitsFor other: UUID, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "add_dependency", arguments: [.uuid("p_card", card), .uuid("p_waits_for", other), .uuid("p_agent", agent)],
                 operation: operation)
    }

    public static func removeDependency(_ card: UUID, waitsFor other: UUID, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "remove_dependency", arguments: [.uuid("p_card", card), .uuid("p_waits_for", other), .uuid("p_agent", agent)],
                 operation: operation)
    }

    public static func logCard(_ card: UUID, _ line: TeamCardLine, text: String, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "log_card", arguments: [.uuid("p_card", card), .text("p_kind", line.rawValue), .text("p_text", text),
                                                   .uuid("p_agent", agent)], operation: operation)
    }
}

// MARK: Rows, binders, agents and members

extension TeamCall {
    /// One row of a table written by rows (TeamTable.writtenByRows), with its id: the columns it leaves out keep what
    /// they had.
    public static func put(_ row: TeamRow, in table: TeamTable, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "put_row", arguments: [.text("p_table", table.rawValue), .json("p_row", .object(row)), .uuid("p_agent", agent)],
                 operation: operation)
    }

    /// Several rows of one table, in order, all or none.
    public static func put(rows: [TeamRow], in table: TeamTable, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "put_rows", arguments: [.text("p_table", table.rawValue), .json("p_rows", .array(rows.map { .object($0) })),
                                                   .uuid("p_agent", agent)], operation: operation)
    }

    /// An item's index made again: its knowledge rows in `table` become `rows`, and the rest of that item's go.
    public static func replace(_ rows: [TeamRow], in table: TeamTable, binder: UUID, sourceKind: String, sourceID: String,
                               agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "replace_rows", arguments: [.text("p_table", table.rawValue), .uuid("p_binder", binder),
                                                       .text("p_source_kind", sourceKind), .text("p_source_id", sourceID),
                                                       .json("p_rows", .array(rows.map { .object($0) })), .uuid("p_agent", agent)],
                 operation: operation)
    }

    public static func delete(_ id: UUID, from table: TeamTable, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "delete_row", arguments: [.text("p_table", table.rawValue), .uuid("p_id", id), .uuid("p_agent", agent)],
                 operation: operation)
    }

    /// `fields`: color, icon, agents_may_finish, agents_may_place.
    public static func createBinder(_ binder: UUID, name: String, everyone: Bool = false, fields: [String: TeamJSON] = [:],
                                    operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "create_binder", arguments: [.uuid("p_binder", binder), .text("p_name", name), .boolean("p_everyone", everyone),
                                                        .json("p_fields", .object(fields))], operation: operation)
    }

    /// `fields`: name, color, icon, everyone, agents_may_finish, agents_may_place.
    public static func updateBinder(_ binder: UUID, fields: [String: TeamJSON], operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "update_binder", arguments: [.uuid("p_binder", binder), .json("p_fields", .object(fields))], operation: operation)
    }

    public static func shareBinder(_ binder: UUID, with member: UUID, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "share_binder", arguments: [.uuid("p_binder", binder), .uuid("p_member", member)], operation: operation)
    }

    public static func unshareBinder(_ binder: UUID, with member: UUID, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "unshare_binder", arguments: [.uuid("p_binder", binder), .uuid("p_member", member)], operation: operation)
    }

    public static func deleteBinder(_ binder: UUID, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "delete_binder", arguments: [.uuid("p_binder", binder)], operation: operation)
    }

    /// What the team sees of one of your agents. `fields`: name, kind, purpose, binder_ids, takes_team_cards, status,
    /// online_at, running_card_id. Nothing about how it runs.
    public static func putAgent(_ agent: UUID, fields: [String: TeamJSON], operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "put_agent", arguments: [.uuid("p_agent", agent), .json("p_fields", .object(fields))], operation: operation)
    }

    public static func agentStatus(_ agent: UUID, status: String, runningCard: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "agent_status", arguments: [.uuid("p_agent", agent), .text("p_status", status), .uuid("p_running_card", runningCard)],
                 operation: operation)
    }

    public static func removeAgent(_ agent: UUID, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "remove_agent", arguments: [.uuid("p_agent", agent)], operation: operation)
    }

    /// An admin adds a person, or a headless agent with its own login (`agent`: its id and name). `verifier` is
    /// TeamPassword.verifier of the one-time password. Sent at once, never kept in the outbox.
    public static func addMember(_ member: UUID, login: String, name: String, verifier: String, agent: (id: UUID, name: String)? = nil,
                                 operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "add_member", arguments: [.uuid("p_member", member), .text("p_login", login), .text("p_name", name),
                                                     .text("p_verifier", verifier), .text("p_kind", agent == nil ? "person" : "agent"),
                                                     .uuid("p_agent", agent?.id), .text("p_agent_name", agent?.name)], operation: operation)
    }

    /// An admin gives a member a new one-time password. Sent at once.
    public static func resetPassword(_ member: UUID, verifier: String, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "reset_password", arguments: [.uuid("p_member", member), .text("p_verifier", verifier)], operation: operation)
    }

    /// This login's own new password. Sent at once.
    public static func changePassword(verifier: String, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "change_password", arguments: [.text("p_verifier", verifier)], operation: operation)
    }

    public static func removeMember(_ member: UUID, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "remove_member", arguments: [.uuid("p_member", member)], operation: operation)
    }

    /// An admin pins another embedding model: every vector is emptied, and every Mac embeds its chunks again.
    public static func pinEmbeddingModel(_ pin: TeamEmbeddingPin, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "pin_embedding_model", arguments: [.text("p_model", pin.model), .integer("p_dimension", pin.dimension)],
                 operation: operation)
    }

    /// Calls that carry a password verifier: sent at once, never written to the outbox.
    public var carriesPassword: Bool { ["add_member", "reset_password", "change_password"].contains(function) }
}
