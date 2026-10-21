import Foundation

/// A small TOML value reader: strings (basic and literal), integers, booleans, arrays and inline tables. Enough to read
/// back the `-c key=value` overrides Binders gives Codex, as Codex reads them, for the self-test's stand-in and the tests.
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var array: [TOMLValue]? { if case .array(let value) = self { value } else { nil } }
    public var table: [String: TOMLValue]? { if case .table(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }

    /// The value at a dotted path in a table.
    public subscript(path: String) -> TOMLValue? {
        var value: TOMLValue? = self
        for key in path.split(separator: ".") { value = value?.table?[String(key)] }
        return value
    }

    /// One value, all of `text`; nil when it isn't one.
    public static func parse(_ text: String) -> TOMLValue? {
        var parser = Parser(Array(text.unicodeScalars))
        guard let value = parser.value() else { return nil }
        parser.skip()
        return parser.atEnd ? value : nil
    }

    /// Codex's `-c key=value` overrides in an argument list, as one table: the key splits at the first "=", its path at
    /// every ".", and a value that isn't TOML is the raw text, as Codex reads them.
    public static func overrides(_ arguments: [String]) -> TOMLValue {
        var root: [String: TOMLValue] = [:]
        var index = 0
        while index < arguments.count {
            defer { index += 1 }
            guard ["-c", "--config"].contains(arguments[index]), index + 1 < arguments.count else { continue }
            index += 1
            let assignment = arguments[index]
            guard let equals = assignment.firstIndex(of: "=") else { continue }
            let path = assignment[..<equals].split(separator: ".").map(String.init)
            let raw = String(assignment[assignment.index(after: equals)...])
            set(&root, path: path, value: parse(raw) ?? .string(raw))
        }
        return .table(root)
    }

    private static func set(_ table: inout [String: TOMLValue], path: [String], value: TOMLValue) {
        guard let first = path.first else { return }
        if path.count == 1 {
            if case .table(let new) = value, case .table(var old)? = table[first] {
                for (key, item) in new { old[key] = item }
                table[first] = .table(old)
            } else {
                table[first] = value
            }
            return
        }
        var inner = table[first]?.table ?? [:]
        set(&inner, path: Array(path.dropFirst()), value: value)
        table[first] = .table(inner)
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index >= scalars.count }
        var current: Unicode.Scalar? { atEnd ? nil : scalars[index] }

        mutating func skip() {
            while let scalar = current, scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { index += 1 }
        }

        mutating func value() -> TOMLValue? {
            skip()
            switch current {
            case "\"": return basic().map(TOMLValue.string)
            case "'": return literal().map(TOMLValue.string)
            case "[": return list()
            case "{": return inlineTable()
            default: return bare()
            }
        }

        mutating func basic() -> String? {
            index += 1
            var out = String.UnicodeScalarView()
            while let scalar = current {
                index += 1
                switch scalar {
                case "\"": return String(out)
                case "\\":
                    guard let escaped = current else { return nil }
                    index += 1
                    switch escaped {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{8}")
                    case "f": out.append("\u{C}")
                    case "u", "U":
                        let count = escaped == "u" ? 4 : 8
                        guard index + count <= scalars.count,
                              let code = UInt32(String(String.UnicodeScalarView(scalars[index..<index + count])), radix: 16),
                              let decoded = Unicode.Scalar(code) else { return nil }
                        out.append(decoded)
                        index += count
                    default: return nil
                    }
                default:
                    out.append(scalar)
                }
            }
            return nil
        }

        mutating func literal() -> String? {
            index += 1
            var out = String.UnicodeScalarView()
            while let scalar = current {
                index += 1
                if scalar == "'" { return String(out) }
                out.append(scalar)
            }
            return nil
        }

        mutating func list() -> TOMLValue? {
            index += 1
            var items: [TOMLValue] = []
            while true {
                skip()
                if current == "]" { index += 1; return .array(items) }
                guard let item = value() else { return nil }
                items.append(item)
                skip()
                if current == "," { index += 1; continue }
                guard current == "]" else { return nil }
            }
        }

        mutating func key() -> [String]? {
            var parts: [String] = []
            while true {
                skip()
                switch current {
                case "\"": guard let part = basic() else { return nil }; parts.append(part)
                case "'": guard let part = literal() else { return nil }; parts.append(part)
                default:
                    var out = String.UnicodeScalarView()
                    while let scalar = current, scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                        out.append(scalar)
                        index += 1
                    }
                    guard !out.isEmpty else { return nil }
                    parts.append(String(out))
                }
                skip()
                if current == "." { index += 1; continue }
                return parts
            }
        }

        mutating func inlineTable() -> TOMLValue? {
            index += 1
            var table: [String: TOMLValue] = [:]
            skip()
            if current == "}" { index += 1; return .table(table) }
            while true {
                guard let path = key() else { return nil }
                skip()
                guard current == "=" else { return nil }
                index += 1
                guard let item = value() else { return nil }
                TOMLValue.set(&table, path: path, value: item)
                skip()
                if current == "," { index += 1; continue }
                guard current == "}" else { return nil }
                index += 1
                return .table(table)
            }
        }

        mutating func bare() -> TOMLValue? {
            var out = String.UnicodeScalarView()
            while let scalar = current, !" \t\r\n,]}".unicodeScalars.contains(scalar) {
                out.append(scalar)
                index += 1
            }
            let word = String(out)
            switch word {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return Int(word.replacingOccurrences(of: "_", with: "")).map(TOMLValue.integer)
            }
        }
    }
}
