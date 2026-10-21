import Foundation

extension CaptureOutcome {
    /// The binder a capture's line says it was filed in, among the binders `names`: "Filed in Events", then its title
    /// (": Ignite booth plan") and its to-dos (" · 2 to-dos") when it has them. The longest name that fits, as one binder's
    /// name can begin another's; nil for any other line, and for a binder that isn't among them. A capture keeps only the
    /// line, so this is how its row on the iPhone's Today wears its binder's colour.
    public static func filedBinder(in line: String, among names: some Sequence<String>) -> String? {
        let prefix = "Filed in "
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        return names
            .filter { name in
                guard !name.isEmpty, rest.hasPrefix(name) else { return false }
                let after = rest.dropFirst(name.count)
                return after.isEmpty || after.hasPrefix(":") || after.hasPrefix(" · ")
            }
            .max { $0.count < $1.count }
    }
}

extension CaptureOutcome {
    /// A filed capture's line in its parts, for a row that leads with its title: "Filed in Events: Ignite booth plan · 2
    /// to-dos" is the binder "Events", the title "Ignite booth plan" and the rest ["2 to-dos"]. The binder is the longest of
    /// `names` that fits, or else what comes before the first ": " or " · "; nil for a line that isn't a filed one.
    public static func filedParts(in line: String, among names: some Sequence<String>) -> (binder: String, title: String?, rest: [String])? {
        let prefix = "Filed in "
        guard line.hasPrefix(prefix) else { return nil }
        let body = String(line.dropFirst(prefix.count))
        let binder = filedBinder(in: line, among: names) ?? {
            let ends = [body.range(of: ": ")?.lowerBound, body.range(of: " · ")?.lowerBound].compactMap { $0 }
            return String(body[..<(ends.min() ?? body.endIndex)])
        }()
        guard !binder.isEmpty else { return nil }
        var after = String(body.dropFirst(binder.count))
        var title: String?
        if after.hasPrefix(": ") {
            after = String(after.dropFirst(2))
            let end = after.range(of: " · ")?.lowerBound ?? after.endIndex
            let words = after[..<end].trimmingCharacters(in: .whitespaces)
            title = words.isEmpty ? nil : words
            after = String(after[end...])
        }
        let rest = after.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (binder, title, rest)
    }
}
