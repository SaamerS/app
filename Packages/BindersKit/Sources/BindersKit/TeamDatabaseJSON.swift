import Foundation

/// A JSON value as the team database writes and reads rows: every row comes back as JSON (`to_jsonb`), and row writes
/// go as JSON, so the Mac reads any table the same way and an unknown column is kept rather than fatal.
public enum TeamJSON: Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([TeamJSON])
    case object([String: TeamJSON])

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var double: Double? { if case .number(let value) = self { value } else { nil } }
    public var int: Int? { double.flatMap { $0.rounded() == $0 && abs($0) < 9.0e15 ? Int($0) : nil } }
    public var int64: Int64? { double.flatMap { $0.rounded() == $0 && abs($0) < 9.0e15 ? Int64($0) : nil } }
    public var array: [TeamJSON]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: TeamJSON]? { if case .object(let value) = self { value } else { nil } }
    public var isNull: Bool { self == .null }
    public var uuid: UUID? { string.flatMap(UUID.init(uuidString:)) }
    /// A `timestamptz` as Postgres writes it in JSON.
    public var date: Date? { string.flatMap(TeamJSON.date(from:)) }
    public var strings: [String]? { array?.compactMap(\.string) }

    public subscript(key: String) -> TeamJSON? { object?[key] }

    // MARK: Text

    /// The value as JSON text, keys sorted.
    public var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// JSON text read as a value; nil when it isn't JSON.
    public init?(text: String) {
        guard let value = try? JSONDecoder().decode(TeamJSON.self, from: Data(text.utf8)) else { return nil }
        self = value
    }

    // MARK: Dates

    /// Postgres' JSON timestamps: "2026-10-21T10:42:00.123456+00:00", with up to six digits of fraction, and "Z" or an
    /// offset. Nil for anything else.
    public static func date(from text: String) -> Date? {
        guard let found = timestamp?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(found.range(at: index), in: text).map { String(text[$0]) }
        }
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(identifier: "UTC")
        guard let year = group(1).flatMap(Int.init), let month = group(2).flatMap(Int.init), let day = group(3).flatMap(Int.init),
              let hour = group(4).flatMap(Int.init), let minute = group(5).flatMap(Int.init), let second = group(6).flatMap(Int.init)
        else { return nil }
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (year, month, day, hour, minute, second)
        guard let whole = parts.date else { return nil }
        let fraction = group(7).map { Double("0." + $0) ?? 0 } ?? 0
        var offset = 0
        if let zone = group(8), zone != "Z" {
            let sign = zone.hasPrefix("-") ? -1 : 1
            let digits = zone.dropFirst().filter(\.isNumber)
            let hours = Int(digits.prefix(2)) ?? 0
            let minutes = digits.count > 2 ? Int(digits.dropFirst(2).prefix(2)) ?? 0 : 0
            offset = sign * (hours * 3600 + minutes * 60)
        }
        return whole.addingTimeInterval(fraction - Double(offset))
    }

    /// Made once: catching up reads many dates. Matching with it is safe to share.
    private static let timestamp = try? NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}(?::?\d{2})?)?$"#)

    /// A date as Postgres reads it back exactly: UTC, with microseconds.
    public static func text(of date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        var micros = Int(((seconds - whole) * 1_000_000).rounded())
        var base = Date(timeIntervalSince1970: whole)
        if micros == 1_000_000 {
            micros = 0
            base = base.addingTimeInterval(1)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: base)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%06d+00:00", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, micros)
    }
}

extension TeamJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TeamJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: TeamJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension TeamJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: TeamJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, TeamJSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }

    public init(_ uuid: UUID?) { self = uuid.map { .string($0.uuidString.lowercased()) } ?? .null }
    public init(_ date: Date?) { self = date.map { .string(TeamJSON.text(of: $0)) } ?? .null }
    public init(_ text: String?) { self = text.map { .string($0) } ?? .null }
    public init(_ strings: [String]) { self = .array(strings.map { .string($0) }) }
    public init(_ uuids: [UUID]) { self = .array(uuids.map { .string($0.uuidString.lowercased()) }) }
    /// Bytes as Postgres reads `bytea` from text: "\x" and hex.
    public init(bytes: Data?) {
        guard let bytes else {
            self = .null
            return
        }
        // Byte by byte through a table (lane DB10): a note's document is kilobytes, and String(format:) per byte took
        // milliseconds for one.
        var hex = [UInt8]()
        hex.reserveCapacity(2 + bytes.count * 2)
        hex.append(UInt8(ascii: "\\"))
        hex.append(UInt8(ascii: "x"))
        for byte in bytes {
            hex.append(Self.hexDigits[Int(byte >> 4)])
            hex.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        self = .string(String(decoding: hex, as: UTF8.self))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// `bytea` as Postgres writes it in JSON ("\x0a1b…"); nil for anything else.
    public var bytes: Data? {
        guard let text = string else { return nil }
        let utf8 = text.utf8
        guard utf8.count >= 2, utf8.count % 2 == 0, utf8.starts(with: [UInt8(ascii: "\\"), UInt8(ascii: "x")]) else { return nil }
        func value(_ digit: UInt8) -> UInt8? {
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        var data = Data(capacity: (utf8.count - 2) / 2)
        var digits = utf8.dropFirst(2).makeIterator()
        while let high = digits.next() {
            guard let low = digits.next(), let first = value(high), let second = value(low) else { return nil }
            data.append(first << 4 | second)
        }
        return data
    }
}

/// A row of any table, as JSON: column name to value.
public typealias TeamRow = [String: TeamJSON]

extension Dictionary where Key == String, Value == TeamJSON {
    /// The row's id.
    public var rowID: UUID? { self["id"]?.uuid }
    /// When it was deleted, for a row that was.
    public var deletedAt: Date? { self["deleted_at"]?.date }
}
