import Foundation

// What an agent sees besides the card: when a card first goes to an agent, Binders writes on it what the card's binder
// already knows about it, a few lines from its notes and meetings, as a comment of its own ("From your binders"). These
// are the parts that can be worked out and tested away from the app: which passages match a card, what each one says, and
// what an agent that may read less doesn't get.

/// What a tool or an agent may read besides your notes and meetings, as Settings → MCP allows it for that tool: captures
/// (what All-day capture heard), meeting transcripts and teammates' items. Each is off until you allow it.
public struct AgentReads: Equatable, Sendable {
    public var captures: Bool
    public var transcripts: Bool
    public var team: Bool

    public init(captures: Bool = false, transcripts: Bool = false, team: Bool = false) {
        self.captures = captures
        self.transcripts = transcripts
        self.team = team
    }

    /// Notes and meetings alone: what every tool may read.
    public static let nothing = AgentReads()
}

/// The comment Binders writes on a card the first time it goes to an agent: up to three passages from the notes and
/// meetings in the card's binder that match the card, each its title and one line. A capture or a teammate's item only for
/// an agent whose reads allow it; never a transcript, which isn't a source at all.
public enum AgentContext {
    /// The comment's first words, and its name on the card.
    public static let heading = "From your binders"
    /// How many passages it holds at most.
    public static let limit = 3
    /// The longest line it quotes from a passage, in characters.
    public static let lineLimit = 160

    /// Something in the card's binder that might go with it.
    public struct Source: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case note, meeting, capture
        }

        public var kind: Kind
        public var title: String
        /// Its words: a note's text, a meeting's or a capture's notes. Never a transcript.
        public var text: String
        /// A teammate's, shared with you.
        public var teammate: Bool
        public var date: Date

        public init(kind: Kind, title: String, text: String, teammate: Bool = false, date: Date = .distantPast) {
            self.kind = kind
            self.title = title
            self.text = text
            self.teammate = teammate
            self.date = date
        }

        /// What the comment calls it: "note", "meeting", "capture", "teammate's note".
        var label: String { (teammate ? "teammate's " : "") + kind.rawValue }
    }

    /// One passage, as the comment has it.
    public struct Snippet: Equatable, Sendable {
        public var title: String
        public var line: String
        public var label: String

        public init(title: String, line: String, label: String) {
            self.title = title
            self.line = line
            self.label = label
        }
    }

    // MARK: Which passages

    /// The passages from `sources` that match a card titled `title` with `details`, best first, at most `limit`, one per
    /// source. A source matches when it shares a word of the card's title with it, and at least two of the card's words in
    /// all when the card has two or more; words every source shares count for less. Captures and teammates' items are
    /// left out unless `reads` allows them.
    public static func snippets(title: String, details: String = "", from sources: [Source], reads: AgentReads, limit: Int = limit) -> [Snippet] {
        let titleTerms = Set(terms(title))
        let cardTerms = titleTerms.union(terms(String(details.prefix(400))))
        guard !titleTerms.isEmpty else { return [] }
        let allowed = sources.filter { (reads.captures || $0.kind != .capture) && (reads.team || !$0.teammate) }
        // The start of each is enough to tell what it's about, and keeps a hand-off quick in a big binder.
        let indexed = allowed.map { source in (source: source, title: Set(terms(source.title)), text: Set(terms(String(source.text.prefix(8_000))))) }
        // How many sources each of the card's words is in: one they all share tells little.
        var spread: [String: Int] = [:]
        for item in indexed {
            for term in cardTerms where item.title.contains(term) || item.text.contains(term) { spread[term, default: 0] += 1 }
        }
        let count = Double(indexed.count)
        func weight(_ term: String) -> Double {
            (titleTerms.contains(term) ? 2 : 1) * log((count + 1) / (Double(spread[term] ?? 0) + 0.5))
        }
        let needed = cardTerms.count >= 2 ? 2 : 1
        var scored: [(source: Source, score: Double)] = []
        for item in indexed {
            let found = cardTerms.filter { item.title.contains($0) || item.text.contains($0) }
            guard found.count >= needed, !found.isDisjoint(with: titleTerms) else { continue }
            let score = found.reduce(0) { $0 + weight($1) * ((item.title.contains($1) ? 3 : 0) + (item.text.contains($1) ? 1 : 0)) }
            scored.append((item.source, score))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.source.date > $1.source.date }
        var picked: [Snippet] = []
        var seen: Set<String> = []
        for (source, _) in scored {
            let key = source.label + "|" + source.title.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            picked.append(Snippet(title: shortened(source.title, to: 80), line: line(in: source.text, for: cardTerms, besides: source.title), label: source.label))
            if picked.count == limit { break }
        }
        return picked
    }

    /// The comment for these passages, or "" for none: the heading, then a line each.
    ///
    ///     From your binders:
    ///     • “Ignite booth plan” (note): Booth 14 in Hall B, two tables.
    public static func comment(_ snippets: [Snippet]) -> String {
        guard !snippets.isEmpty else { return "" }
        let lines = snippets.map { snippet in
            "• “\(snippet.title)” (\(snippet.label))" + (snippet.line.isEmpty ? "" : ": \(snippet.line)")
        }
        return ([heading + ":"] + lines).joined(separator: "\n")
    }

    /// The comment as an agent that may read only `reads` sees it: without the passages from captures or teammates' items
    /// it may not read. "" when nothing of it is left. A comment you rewrote keeps whatever no longer says where it's from.
    public static func keeping(_ comment: String, readableBy reads: AgentReads) -> String {
        var lines = comment.components(separatedBy: "\n")
        lines.removeAll { line in
            guard line.hasPrefix("• ") else { return false }
            return (!reads.captures && line.contains("” (capture)")) || (!reads.team && line.contains("” (teammate's "))
        }
        guard lines.contains(where: { $0.hasPrefix("• ") }) || !comment.hasPrefix(heading) else { return "" }
        return lines.joined(separator: "\n")
    }

    /// Where its passages may come from, for saying so before a card goes to an agent: "notes and meetings", "notes,
    /// meetings and captures", with "(yours and your teammates')" when it may read theirs.
    public static func describe(_ reads: AgentReads) -> String {
        (reads.captures ? "notes, meetings and captures" : "notes and meetings") + (reads.team ? " (yours and your teammates')" : "")
    }

    // MARK: Words

    /// The words that say what something is about, lowercased and in the order they come: no common words, nothing under
    /// three letters but numbers, and plurals as one ("banners" is "banner").
    static func terms(_ text: String) -> [String] {
        var seen: Set<String> = []
        var found: [String] = []
        for raw in text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) {
            let isNumber = !raw.isEmpty && raw.allSatisfy(\.isNumber)
            guard raw.count >= 3 || (isNumber && raw.count >= 2), !stopWords.contains(raw) else { continue }
            let term = isNumber ? raw : singular(raw)
            if seen.insert(term).inserted { found.append(term) }
        }
        return found
    }

    static func singular(_ word: String) -> String {
        guard word.count > 4 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("ss") || word.hasSuffix("us") || word.hasSuffix("is") { return word }
        return word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    /// The line of `text` that says most about the card: the one with most of its words, else the first that isn't a
    /// heading or its title (`besides`) again. Bullets and checkboxes go; a long line is cut at a word.
    static func line(in text: String, for cardTerms: Set<String>, besides title: String = "") -> String {
        let title = cleaned(title)
        let candidates = text.components(separatedBy: .newlines).map(cleaned).filter { line in
            !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("SPEAKERS:") && line.contains(where: { $0.isLetter || $0.isNumber })
                && line.caseInsensitiveCompare(title) != .orderedSame
        }
        guard let first = candidates.first else { return "" }
        var best = first, most = 0
        for candidate in candidates {
            let matched = Set(terms(candidate)).intersection(cardTerms).count
            if matched > most {
                best = candidate
                most = matched
            }
        }
        return shortened(best, to: lineLimit)
    }

    private static func cleaned(_ line: String) -> String {
        var line = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "- ", "* ", "• ", "+ ", "> "] where line.hasPrefix(marker) {
            line = String(line.dropFirst(marker.count))
            break
        }
        if let range = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) { line.removeSubrange(range) }
        return line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// At most `limit` characters, cut at a word with "…" when it's longer.
    static func shortened(_ text: String, to limit: Int) -> String {
        let text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit - 1))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-")) + "…"
    }

    /// Words that are in nearly everything, and the words of asking for work: they say nothing about what a card is about.
    static let stopWords: Set<String> = [
        "about", "after", "again", "all", "also", "and", "any", "are", "back", "because", "been", "before", "being", "best", "but",
        "call", "can", "come", "could", "day", "did", "does", "done", "down", "each", "even", "every", "find", "first", "for",
        "from", "get", "give", "going", "good", "got", "had", "has", "have", "her", "here", "him", "his", "how", "into", "its",
        "just", "know", "last", "let", "like", "look", "made", "make", "many", "may", "more", "most", "much", "must", "need",
        "new", "next", "not", "now", "off", "one", "only", "other", "our", "out", "over", "please", "put", "really", "right",
        "said", "same", "say", "see", "she", "should", "some", "still", "such", "take", "than", "thank", "thanks", "that", "the",
        "their", "them", "then", "there", "these", "they", "thing", "things", "think", "this", "those", "time", "too", "two",
        "use", "very", "want", "was", "way", "well", "went", "were", "what", "when", "where", "which", "while", "who", "why",
        "will", "with", "work", "would", "yeah", "year", "yes", "yet", "you", "your", "yours", "add", "ask", "check", "draft",
        "send", "write", "update", "fix", "set", "sure", "note", "notes", "card", "cards", "board", "binder", "binders", "todo",
        "task", "tasks", "item", "items", "stuff", "maybe", "today", "tomorrow", "week", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday", "summary", "decision", "decisions", "promise", "promises", "idea", "ideas",
        "people", "mentioned", "meeting", "meetings",
    ]
}
