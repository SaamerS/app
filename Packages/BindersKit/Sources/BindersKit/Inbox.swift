import Foundation

/// A write handed to the running app by a local tool such as the MCP server: a request file in the data folder's inbox,
/// a binders://apply link naming it, and a result file written back beside it. The app stays the only writer, so its
/// windows update, reminders get scheduled and the index picks the item up.
public struct InboxRequest: Codable, Equatable, Sendable {
    public var action: String
    public var fields: [String: String]

    public init(action: String, fields: [String: String] = [:]) {
        self.action = action
        self.fields = fields
    }
}

public struct InboxResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var id: String?
    public var message: String
    public var error: String?
    /// For a write about several things at once (move_item with ids): what became of each, in the order asked. Nil for
    /// every other write, and from a Mac before 0.10.0.
    public var items: [Item]?

    /// One of several things a write was about: whether it was done, and if not, why.
    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var done: Bool
        public var title: String?
        public var why: String?

        public init(id: String, done: Bool, title: String? = nil, why: String? = nil) {
            self.id = id
            self.done = done
            self.title = title
            self.why = why
        }

        /// As a tool's reply gives it: id, moved, and title and why when there are any.
        public var reply: [String: Any] {
            var reply: [String: Any] = ["id": id, "moved": done]
            if let title { reply["title"] = title }
            if let why { reply["why"] = why }
            return reply
        }
    }

    public init(ok: Bool, id: String? = nil, message: String = "", error: String? = nil, items: [Item]? = nil) {
        self.ok = ok
        self.id = id
        self.message = message
        self.error = error
        self.items = items
    }

    public static func failure(_ error: String) -> InboxResult {
        InboxResult(ok: false, error: error)
    }
}

public enum Inbox {
    public static let folder = "inbox"
    public static let actions = ["add_note", "append_to_note", "create_binder", "add_meeting", "set_todo_status", "add_todo", "add_to_calendar"]

    /// Request names are UUIDs, so a link can never point outside the inbox.
    public static func isValidName(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    public static func requestFile(_ name: String) -> String { "\(name).request.json" }
    public static func resultFile(_ name: String) -> String { "\(name).result.json" }
}
