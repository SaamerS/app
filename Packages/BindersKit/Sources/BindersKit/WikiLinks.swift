import Foundation

/// A link to a note, meeting, person or binder, written as Obsidian does: [[Title]], or [[Title|what to show]].
public struct WikiLink: Equatable, Sendable {
    public let target: String
    /// What it reads as: the part after "|", or the target.
    public let label: String
    /// The whole [[…]], in UTF-16 offsets of the text it came from.
    public let range: NSRange

    /// Where it goes: the page, and a heading or block in it.
    public var destination: WikiTarget { WikiTarget(target) }
}

/// What a link's target names: a page (a note, meeting, person or binder), then, after "#", a heading or "^block" in it,
/// as Obsidian writes them: "Launch plan#Risks", "#Risks" for one in the same note, "Launch plan#^c3f1".
public struct WikiTarget: Equatable, Sendable {
    /// The note, meeting, person or binder; empty for a place in the same note.
    public let page: String
    /// The heading; of nested ones ("Plan#Risks#Open"), the last.
    public let heading: String?
    /// The block's id, written after "#^".
    public let block: String?

    public init(page: String, heading: String? = nil, block: String? = nil) {
        self.page = page
        self.heading = heading
        self.block = block
    }

    public init(_ target: String) {
        let string = target as NSString
        let split = Self.placeStart(in: target)
        var page = (split.map { string.substring(to: $0) } ?? target).trimmingCharacters(in: .whitespaces)
        if page.lowercased().hasSuffix(".md") { page = String(page.dropLast(3)) }
        self.page = page
        let places = split.map { string.substring(from: $0 + 1).split(separator: "#").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
        let place = places.last { !$0.isEmpty }
        if let place, place.hasPrefix("^") {
            heading = nil
            block = place.count > 1 ? String(place.dropFirst()) : nil
        } else {
            heading = place
            block = nil
        }
    }

    /// Where the "#" before the heading or block is, in UTF-16 offsets; nil when the target is only a page. A "#" right
    /// after a space is part of the name ("Issue #42"); Obsidian's own links never have one there.
    static func placeStart(in target: String) -> Int? {
        let string = target as NSString
        var search = NSRange(location: 0, length: string.length)
        while search.length > 0 {
            let found = string.range(of: "#", range: search)
            guard found.location != NSNotFound else { return nil }
            if found.location == 0 || string.character(at: found.location - 1) != 0x20 { return found.location }
            search = NSRange(location: found.upperBound, length: string.length - found.upperBound)
        }
        return nil
    }

    /// The heading, or "^" and the block's id: what follows the last "#".
    public var place: String? { heading ?? block.map { "^" + $0 } }

    /// A file kept with the note, such as "report.pdf", rather than a note.
    public var isFile: Bool { MarkdownMedia.isFile(page) }

    /// Where `place` (a heading, or "^" and a block's id) is in `text`: the start of its line. Headings match whatever
    /// their case, accents and punctuation, as Obsidian leaves some characters out of links to them.
    public static func location(of place: String, in text: String) -> Int? {
        if place.hasPrefix("^") {
            let id = NSRegularExpression.escapedPattern(for: String(place.dropFirst()))
            guard !id.isEmpty, let pattern = try? NSRegularExpression(pattern: #"(?m)(?:^|[ \t])\^"# + id + #"[ \t]*$"#),
                  let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
            return (text as NSString).lineRange(for: NSRange(location: match.range.location, length: 0)).location
        }
        let wanted = loose(place)
        guard !wanted.isEmpty else { return nil }
        return MarkdownOutline.headings(in: text).first { loose($0.title) == wanted }?.location
    }

    private static func loose(_ heading: String) -> String {
        String(String.UnicodeScalarView(heading.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
}

public enum WikiLinks {
    static let pattern = try! NSRegularExpression(pattern: #"\[\[([^\[\]\|\n]+?)(?:\|([^\[\]\n]+?))?\]\]"#)

    public static func links(in text: String) -> [WikiLink] {
        let string = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap { match in
            let target = string.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            // ![[photo.png]] shows a picture; it isn't a link to anything.
            if match.range.location > 0, string.character(at: match.range.location - 1) == 0x21, MarkdownMedia.kind(of: target) != .other { return nil }
            let alias = match.range(at: 2).location == NSNotFound ? nil : string.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            return WikiLink(target: target, label: alias.flatMap { $0.isEmpty ? nil : $0 } ?? target, range: match.range)
        }
    }

    /// The pages `[[Name]]`, `[[Name|shown text]]` and `[[Name#Heading]]` link to, in order, without duplicates: what
    /// the knowledge graph links. Places in the same note and files aren't pages.
    public static func targets(in text: String) -> [String] {
        var seen = Set<String>()
        return links(in: text).compactMap { link in
            let destination = link.destination
            return destination.page.isEmpty || destination.isFile ? nil : destination.page
        }.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Whether `text` has a link to `title`, or to a place in it. Case and spacing don't matter.
    public static func text(_ text: String, linksTo title: String) -> Bool {
        let wanted = key(title)
        return !wanted.isEmpty && links(in: text).contains { links($0, to: wanted) }
    }

    /// Whether `link` goes to the page whose `key(_:)` is `wanted`: its whole target, or the page before a heading.
    public static func links(_ link: WikiLink, to wanted: String) -> Bool {
        key(link.target) == wanted || key(link.destination.page) == wanted
    }

    /// Whether `title` can go in a link as it is: no brackets, "|" or line break, and nothing that reads as a heading
    /// ("#" with no space before it).
    public static func canLink(_ title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespaces)
        return !key(title).isEmpty && title.rangeOfCharacter(from: CharacterSet(charactersIn: "[]|\n")) == nil && WikiTarget(title).page == title
    }

    /// What to change in `text` so its links to `old` go to `new` instead: [[Old]], [[Old|shown]], [[Old#Heading]] and
    /// ![[Old]], in order. What a link shows and the heading it goes to stay as they were. Links in code are left
    /// alone, and nothing changes when `new` can't go in a link.
    public static func renameEdits(from old: String, to new: String, in text: String) -> [(range: NSRange, replacement: String)] {
        let wanted = key(old)
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, canLink(new), text.contains("[[") else { return [] }
        let string = text as NSString
        var code: [NSRange]?
        var edits: [(range: NSRange, replacement: String)] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let target = trimmed(match.range(at: 1), in: string)
            guard target.length > 0 else { continue }
            let written = string.substring(with: target)
            var edit: (range: NSRange, replacement: String)?
            if key(written) == wanted {
                edit = (target, new)
            } else {
                // The page before a "#Heading", with or without Obsidian's ".md".
                let page = trimmed(NSRange(location: target.location, length: WikiTarget.placeStart(in: written) ?? target.length), in: string)
                var name = string.substring(with: page)
                let suffix = name.lowercased().hasSuffix(".md") ? String(name.suffix(3)) : ""
                name = String(name.dropLast(suffix.count))
                if page.length > 0, key(name) == wanted { edit = (page, new + suffix) }
            }
            guard let edit else { continue }
            if code == nil { code = MarkdownSyntax.codeRanges(in: text) }
            if code?.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) == true { continue }
            edits.append(edit)
        }
        return edits
    }

    /// `text` with its links to `old` going to `new` instead (see `renameEdits`), and how many changed; nil if none did.
    public static func renaming(from old: String, to new: String, in text: String) -> (text: String, links: Int)? {
        let edits = renameEdits(from: old, to: new, in: text)
        guard !edits.isEmpty else { return nil }
        let result = NSMutableString(string: text)
        for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.replacement) }
        return (result as String, edits.count)
    }

    private static func trimmed(_ range: NSRange, in string: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start < end, [0x20, 0x09].contains(string.character(at: start)) { start += 1 }
        while end > start, [0x20, 0x09].contains(string.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The first place `text` mentions `title` in plain words, as a whole phrase and outside any [[link]]; nil if nowhere.
    public static func plainMention(of title: String, in text: String) -> NSRange? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 3 else { return nil }
        let string = text as NSString
        let linked = links(in: text).map(\.range)
        var from = 0
        while from < string.length {
            let found = string.range(of: title, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: string.length - from))
            guard found.location != NSNotFound else { return nil }
            let before = found.location > 0 ? string.substring(with: NSRange(location: found.location - 1, length: 1)) : " "
            let after = found.upperBound < string.length ? string.substring(with: NSRange(location: found.upperBound, length: 1)) : " "
            let wholeWords = !isWordCharacter(before) && !isWordCharacter(after)
            if wholeWords, !linked.contains(where: { NSIntersectionRange($0, found).length > 0 }) { return found }
            from = found.upperBound
        }
        return nil
    }

    /// `text` with its first plain mention of `title` made into a link: [[Title]], or [[Title|as written]] when the case
    /// differs. Nil when there is none.
    public static func linkingFirstMention(of title: String, in text: String) -> String? {
        guard let range = plainMention(of: title, in: text) else { return nil }
        let written = (text as NSString).substring(with: range)
        let link = written == title ? "[[\(title)]]" : "[[\(title)|\(written)]]"
        return (text as NSString).replacingCharacters(in: range, with: link)
    }

    /// When the cursor is in an unfinished link ("… see [[Laun"), the range of what's typed after the "[[", to suggest
    /// titles for. Nil elsewhere, and once a "|" starts the text to show.
    public static func partialLink(before cursor: Int, in text: String) -> NSRange? {
        let string = text as NSString
        guard cursor <= string.length else { return nil }
        let line = string.lineRange(for: NSRange(location: min(cursor, max(string.length - 1, 0)), length: 0))
        let start = min(line.location, cursor)
        let before = string.substring(with: NSRange(location: start, length: cursor - start))
        guard let open = before.range(of: "[[", options: .backwards) else { return nil }
        let typed = before[open.upperBound...]
        guard !typed.contains("]"), !typed.contains("|"), !typed.contains("[") else { return nil }
        let offset = start + (before as NSString).length - (String(typed) as NSString).length
        return NSRange(location: offset, length: cursor - offset)
    }

    /// Titles compared the way links should: case, accents and extra spaces aside.
    public static func key(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isWordCharacter(_ character: String) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
