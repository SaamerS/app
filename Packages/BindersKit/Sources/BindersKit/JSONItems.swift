import Foundation

/// A JSON list read one item at a time. Read in one go, a list is lost to a single item that doesn't read (written
/// damaged, or by a newer build in a way this one doesn't know); read this way, that item is left out, with where it was
/// and why, and the rest are kept.
public enum JSONItems {
    /// The items that read, in their order, and the ones left out.
    public struct Read<Item> {
        public var items: [Item]
        public var skipped: [Skipped]
    }

    /// An item left out: its place in the list (from 0), and why, by the names of its fields only. It never quotes the
    /// item, which may hold what someone said.
    public struct Skipped: Equatable, Sendable {
        public let index: Int
        public let reason: String
    }

    /// Each item of the list in `data` on its own. Nil when the data isn't a JSON list at all.
    public static func decode<Item: Decodable>(_ type: Item.Type, from data: Data, using decoder: JSONDecoder = JSONDecoder()) -> Read<Item>? {
        guard let attempts = try? decoder.decode([Attempt<Item>].self, from: data) else { return nil }
        var read = Read<Item>(items: [], skipped: [])
        for (index, attempt) in attempts.enumerated() {
            switch attempt.result {
            case .success(let item): read.items.append(item)
            case .failure(let error): read.skipped.append(Skipped(index: index, reason: reason(error)))
            }
        }
        return read
    }

    /// One item, read on its own: a failure stays with it rather than ending the list.
    private struct Attempt<Item: Decodable>: Decodable {
        let result: Result<Item, Error>

        init(from decoder: Decoder) throws {
            result = Result { try Item(from: decoder) }
        }
    }

    /// Why an item didn't read: "it has no text", "created isn't the right kind of value".
    static func reason(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "it couldn't be read" }
        switch error {
        case .keyNotFound(let key, _): return "it has no \(key.stringValue)"
        case .typeMismatch(_, let context): return "\(field(context)) isn't the right kind of value"
        case .valueNotFound(_, let context): return "\(field(context)) is empty"
        case .dataCorrupted(let context): return "\(field(context)) is damaged"
        @unknown default: return "it couldn't be read"
        }
    }

    /// The field an error is about, without the item's place in the list: "created", "payload", or "it" for the item.
    private static func field(_ context: DecodingError.Context) -> String {
        let keys = context.codingPath.filter { $0.intValue == nil }.map(\.stringValue)
        return keys.isEmpty ? "it" : keys.joined(separator: ".")
    }
}
