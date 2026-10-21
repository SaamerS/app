import Foundation

// What the test builds before Auto mode took its name everywhere (iPhone 30–31, Mac 28–29) saved, read as today's names:
// UserDefaults keys and values, JSON records and files. Public builds never saved them. The one place their old word for
// Auto is still spelled; nothing here is ever written in it.

public enum EarlierSpellings {
    /// A name or raw value as an earlier test build spelled it, as today's. Its start in Auto mode had a name of its own,
    /// as "autoStart" was taken.
    public static func today(_ name: String) -> String {
        name.replacingOccurrences(of: "yolo_start", with: "auto_mode_start") // reads what an earlier test build saved
            .replacingOccurrences(of: "yoloStart", with: "autoModeStart") // reads what an earlier test build saved
            .replacingOccurrences(of: "YoloStart", with: "AutoModeStart") // reads what an earlier test build saved
            .replacingOccurrences(of: "yolo", with: "auto") // reads what an earlier test build saved
            .replacingOccurrences(of: "Yolo", with: "Auto") // reads what an earlier test build saved
    }

    /// A key of today's as an earlier test build wrote it, for a seal it computed over what it wrote.
    static func earlier(_ name: String) -> String {
        name.replacingOccurrences(of: "auto", with: "yolo").replacingOccurrences(of: "Auto", with: "Yolo") // what an earlier test build saved
    }

    /// Whether data holds the earlier spelling at all: what never had it is read as it is, without a second parse.
    static func holdsEarlier(_ data: Data) -> Bool {
        data.range(of: Data("yolo".utf8)) != nil || data.range(of: Data("Yolo".utf8)) != nil // reads what an earlier test build saved
    }

    /// Raw values today's builds save that an earlier test build spelled otherwise: the modes, an origin, the word for a
    /// card handed over, why a card wasn't started, and the link features a phone keeps of its Mac's. A string that is
    /// exactly one of these in the old spelling is read as today's; any other string (words you said, a title) is left as it is.
    static let rawValues: Set<String> = Set(MomentMode.allCases.map(\.rawValue) + RouteOrigin.allCases.map(\.rawValue)
        + RouterRules.NotStarted.allCases.map(\.rawValue) + [CaptureOutcome.Handed.auto, MomentPayload.autoFeature, ConversationPayload.soloFeature])

    /// JSON a record, a file or a cache held, as today's: each key in the old spelling under today's name (today's wins
    /// when both are there), and a raw value in the old spelling as today's. Anything else comes back as it was.
    public static func json(_ data: Data) -> Data {
        guard holdsEarlier(data),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let renamed = try? JSONSerialization.data(withJSONObject: renamed(object), options: [.fragmentsAllowed, .withoutEscapingSlashes])
        else { return data }
        return renamed
    }

    /// `json` for JSON kept as text.
    public static func json(_ text: String) -> String {
        String(decoding: json(Data(text.utf8)), as: UTF8.self)
    }

    static func renamed(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var out: [String: Any] = [:]
            for (key, inner) in dictionary {
                // Only a key that reads as a name of Binders' own: a dictionary keyed by an agent's name keeps it.
                let name = isName(key) ? today(key) : key
                if name != key, dictionary[name] != nil { continue }
                out[name] = renamed(inner)
            }
            return out
        case let array as [Any]:
            return array.map(renamed)
        case let string as String:
            let name = today(string)
            return name != string && rawValues.contains(name) ? name : string
        default:
            return value
        }
    }

    private static func isName(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Once, at launch: a UserDefaults key an earlier test build saved under its old name moves to today's (today's value
    /// wins when both are there) and the old one goes; a value it saved in the old spelling, a mode or JSON, is rewritten in
    /// today's. Marked done in `defaults`, so it never runs twice.
    public static func moveDefaults(in defaults: UserDefaults) {
        let done = "earlierSpellingsMoved"
        guard !defaults.bool(forKey: done) else { return }
        for (key, value) in defaults.dictionaryRepresentation() {
            let name = isName(key) ? today(key) : key
            let moved = renamedDefault(value)
            let changed = !(moved as AnyObject).isEqual(value)
            if name != key {
                if defaults.object(forKey: name) == nil { defaults.set(moved, forKey: name) }
                defaults.removeObject(forKey: key)
            } else if changed {
                defaults.set(moved, forKey: key)
            }
        }
        defaults.set(true, forKey: done)
    }

    private static func renamedDefault(_ value: Any) -> Any {
        switch value {
        case let data as Data: json(data)
        default: renamed(value)
        }
    }
}
