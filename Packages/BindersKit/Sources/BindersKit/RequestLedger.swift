import Foundation

/// The writes done for requests that carried an id of their own (`request_id`), so one sent again because its reply was
/// lost on the way gets the first answer and is done once: the iPhone's outbox sends each note, to-do, answer and
/// hand-off with its id to a Mac that lists `LinkFeatures.dedupe`. Kept for a week, at most 5,000, newest kept.
public struct RequestLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The action, who sent it and its id (`key(action:requestID:sender:)`).
        public var key: String
        /// What the first answer said: the item's id and the message.
        public var id: String?
        public var message: String
        public var at: Date

        public init(key: String, id: String?, message: String, at: Date) {
            self.key = key
            self.id = id
            self.message = message
            self.at = at
        }
    }

    public static let keptFor: TimeInterval = 7 * 86_400
    public static let limit = 5_000

    /// Oldest first.
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries.sorted { $0.at < $1.at }
    }

    /// What a request is known by: its action, who sent it (an agent by its name; the iPhone and the app are you) and its
    /// id, so one sender's id never answers for another's. Nil without an id, or with one longer than 128 characters.
    public static func key(action: String, requestID: String, sender: String) -> String? {
        let id = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128, !action.isEmpty else { return nil }
        return "\(action)|\(sender)|\(id)"
    }

    /// The first answer to a request done within the week, if it was.
    public func answer(for key: String, now: Date = Date()) -> Entry? {
        entries.last { $0.key == key && now.timeIntervalSince($0.at) < Self.keptFor }
    }

    /// Keeps the answer to a request just done, and lets go of what's older than a week or past the limit.
    public mutating func remember(_ key: String, id: String?, message: String, at now: Date = Date()) {
        entries.removeAll { $0.key == key }
        entries.append(Entry(key: key, id: id, message: message, at: now))
        prune(now: now)
    }

    /// Drops what's older than a week, then the oldest past the limit.
    public mutating func prune(now: Date = Date()) {
        entries.removeAll { now.timeIntervalSince($0.at) >= Self.keptFor }
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}
