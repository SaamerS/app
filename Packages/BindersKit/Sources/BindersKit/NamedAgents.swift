import Foundation

/// The agents a to-do or a card hands work to by name: "Give the login bug to Codex", "Ask Pennant to book…", "Kestrel,
/// check in with…". An agent counts only when its short name (the part of its board name before " · ") stands as whole
/// words, with the agent's own capitals, inside a phrase that hands work to it. So "Book the coach to the airport" never
/// names an agent called Coach, "Make Claude Code faster" and "Codex should never touch the release branch" are only
/// about one, and a name followed by 's ("Codex's reviewer") is never the one handed the work. In a text with no capital
/// letter at all ("give this to codex"), the name matches without case. English, with the bench's other languages'
/// usual ways of asking (Portuguese, Spanish, French, German). Pure: the Mac's moments, Command Mode and typed cards read
/// it, and the kit's tests hold it to the router bench's items.
public enum NamedAgents {
    /// The agents named in any of `texts`, in the order of `agents` (board names, as stored). Two agents that share a
    /// short name ("Claude Code · app", "Claude Code · site") both come back, for the router to settle.
    ///
    /// `thinkingAloud` (lane Y2, for a capture's item on its own sentences and a sentence kept without a cue): the ways
    /// thinking out loud names one, and only those that say you mean it. The soft words before the verb gain "I/we should,
    /// must, ought to"; "I want / I'd like / I need N to <verb>" names N (never "to be", "to stop" or a verb of knowing);
    /// and "N <modal> <verb>" keeps only the modals of intent (should, must, needs to, has to, ought to), so "Codex could
    /// fix that" names no one. False, every caller reads exactly as before.
    public static func find(in texts: [String], agents: [String], thinkingAloud: Bool = false) -> [String] {
        let texts = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !texts.isEmpty else { return [] }
        return agents.filter { agent in
            let name = short(agent)
            guard !name.isEmpty else { return false }
            return texts.contains { text in
                let caseFree = !text.contains(where: \.isUppercase)
                return patterns(name, caseFree: caseFree, thinkingAloud: thinkingAloud).contains { pattern in
                    guard let regex = compiled(pattern) else { return false }
                    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                }
            }
        }
    }

    /// "Claude Code · binders-io/app" → "Claude Code".
    public static func short(_ board: String) -> String {
        (board.components(separatedBy: " · ").first ?? board).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Mentioned, and heard

    /// The agents whose short name stands in any of `texts` as whole words, with the agent's own capitals (any case in a
    /// text with no capital letter), whatever the words around it, a possessive too: every agent `find` could name, and
    /// the ones it doesn't. An agent here and not in `find` is only mentioned ("Look over what Claude Code changed",
    /// "Pennant's invoice came in"), which Auto never takes for the agent's work.
    public static func mentioned(in texts: [String], agents: [String]) -> [String] {
        let texts = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !texts.isEmpty else { return [] }
        return agents.filter { agent in
            let name = short(agent)
            guard !name.isEmpty else { return false }
            return texts.contains { text in
                let caseFree = !text.contains(where: \.isUppercase)
                var pattern = before + wordsPattern(name) + #"(?![\p{L}\p{N}])"#
                if caseFree { pattern = "(?i:" + pattern + ")" }
                guard let regex = compiled(pattern) else { return false }
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
    }

    /// The agents whose short name a run of one to three words in `texts` could be a mishearing of, with the words heard:
    /// the same letters with the spaces moved ("ink well", "hour glass", "a bacus"); one letter off for a name of up to 7
    /// letters, two for 8 or more, the run within two letters of the name's length ("pendant", "grok but", "cloud code");
    /// the same consonants (c, k and q alike, x as ks, vowels, y, w and h left out, a doubled letter once) for a name with
    /// four or more of them ("castrel", "co decks", "clawed code"); or the first word of a two-word name, of four letters or
    /// more and not a common word (TextNorm.commonWords: "Grok", "Claude"). Never a common word alone ("code"), never words
    /// that are part of another agent's name as written, always the name's first sound. The name as written isn't heard
    /// loosely: `find` and `mentioned` take it. In `agents`' order, each with the first words heard for it.
    public static func heard(in texts: [String], agents: [String]) -> [(agent: String, words: String)] {
        var found: [String: String] = [:]
        for text in texts {
            for run in heardRuns(in: text, agents: agents) where found[run.agent] == nil {
                found[run.agent] = run.words
            }
        }
        return agents.compactMap { agent in found[agent].map { (agent: agent, words: $0) } }
    }

    /// `text` with what `heard` found written as the agents' short names (in lowercase in a text with no capital letter),
    /// so `find` and `mentioned` read "give the sync bug to cloud code" as naming Claude Code, and "look over what cloud
    /// code changed" as only mentioning it. The rest of the text, its spaces and its punctuation, stays as it was.
    public static func asHeard(_ text: String, agents: [String]) -> String {
        let runs = heardRuns(in: text, agents: agents).sorted { $0.start < $1.start }
        guard !runs.isEmpty else { return text }
        let caseFree = !text.contains(where: \.isUppercase)
        let tokens = spokenWords(text)
        var kept: [(range: Range<String.Index>, name: String)] = []
        var next = 0
        for run in runs where run.start >= next {
            let name = short(run.agent)
            kept.append((tokens[run.start].core.lowerBound..<tokens[run.start + run.size - 1].core.upperBound, caseFree ? name.lowercased() : name))
            next = run.start + run.size
        }
        var result = text
        for replacement in kept.reversed() {
            result.replaceSubrange(replacement.range, with: replacement.name)
        }
        return result
    }

    /// One text's loose matches, by agent in `agents`' order: the words heard, and where they are among its spoken words.
    static func heardRuns(in text: String, agents: [String]) -> [(agent: String, words: String, start: Int, size: Int)] {
        let tokens = spokenWords(text)
        let words = tokens.map(\.word)
        guard !words.isEmpty else { return [] }
        // The words an agent's name, as written, takes: a loose run never overlaps them.
        var taken: Set<Int> = []
        for agent in agents {
            let parts = short(agent).lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard !parts.isEmpty, parts.count <= words.count else { continue }
            for start in 0...(words.count - parts.count) where Array(words[start..<(start + parts.count)]) == parts {
                taken.formUnion(start..<(start + parts.count))
            }
        }
        var found: [(agent: String, words: String, start: Int, size: Int)] = []
        for agent in agents {
            let name = short(agent)
            let letters = compact(name), sounds = skeleton(name)
            guard letters.count >= 4, mentioned(in: [text], agents: [agent]).isEmpty else { continue }
            var match: (words: String, start: Int, size: Int)?
            search: for size in 1...3 where size <= words.count {
                for start in 0...(words.count - size) {
                    let run = Array(words[start..<(start + size)])
                    let joined = run.joined(), spoken = run.joined(separator: " ")
                    if spoken == name.lowercased() { continue }
                    if size == 1, TextNorm.commonWords.contains(run[0]) { continue }
                    if (start..<(start + size)).contains(where: taken.contains) { continue }
                    guard firstSound(joined) == firstSound(letters) else { continue }
                    let near = abs(joined.count - letters.count) <= 2 && TextNorm.levenshtein(joined, letters) <= (letters.count <= 7 ? 1 : 2)
                    let sound = sounds.count >= 4 && skeleton(joined) == sounds && abs(joined.count - letters.count) <= 3
                    if joined == letters || near || sound {
                        match = (spoken, start, size)
                        break search
                    }
                }
            }
            // The first word of a two-word name, on its own: "Ask Grok to pull together…". Not one in another agent's name.
            let parts = name.split(whereSeparator: \.isWhitespace).map(String.init)
            if match == nil, parts.count == 2, parts[0].count >= 4, !TextNorm.commonWords.contains(parts[0].lowercased()),
               let at = words.indices.first(where: { words[$0] == parts[0].lowercased() && !taken.contains($0) }) {
                match = (words[at], at, 1)
            }
            if let match { found.append((agent, match.words, match.start, match.size)) }
        }
        return found
    }

    /// A text's spoken words: split at spaces, each without the punctuation around it, in lowercase, with where its
    /// letters are in the text. A word that is all punctuation isn't one.
    static func spokenWords(_ text: String) -> [(word: String, core: Range<String.Index>)] {
        var out: [(word: String, core: Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            var first = index, last = end
            while first < last, !isWordCharacter(text[first]) { first = text.index(after: first) }
            while last > first, !isWordCharacter(text[text.index(before: last)]) { last = text.index(before: last) }
            if first < last { out.append((String(text[first..<last]).lowercased(), first..<last)) }
            index = end
        }
        return out
    }

    private static func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }

    /// Lowercased letters and digits only: "Grok Bot" → "grokbot".
    static func compact(_ text: String) -> String { String(text.lowercased().filter(isWordCharacter)) }

    /// The consonants as they sound: c, k and q alike, x as ks, vowels, y, w, h and digits left out, a doubled one once.
    static func skeleton(_ text: String) -> String {
        var out: [Character] = []
        for character in compact(text) {
            if "aeiouywh".contains(character) || character.isNumber { continue }
            let sounds: [Character] = "ckq".contains(character) ? ["k"] : character == "x" ? ["k", "s"] : [character]
            for sound in sounds where out.last != sound { out.append(sound) }
        }
        return String(out)
    }

    /// The first letter, with c, k and q alike.
    private static func firstSound(_ text: String) -> Character? {
        guard let first = compact(text).first else { return nil }
        return "ckq".contains(first) ? "k" : first
    }

    /// Each pattern compiled once: the measure reads every bench item, a moment a few texts, and the patterns depend only on
    /// the agents' names. NSRegularExpression is immutable, so one can be shared between threads.
    private final class Compiled: @unchecked Sendable {
        private let lock = NSLock()
        private var regexes: [String: NSRegularExpression] = [:]

        func regex(_ pattern: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let known = regexes[pattern] { return known }
            guard let made = try? NSRegularExpression(pattern: pattern) else { return nil }
            if regexes.count > 4_000 { regexes.removeAll() }
            regexes[pattern] = made
            return made
        }
    }

    private static let compiledPatterns = Compiled()

    private static func compiled(_ pattern: String) -> NSRegularExpression? { compiledPatterns.regex(pattern) }

    /// A name's words, with any spaces between them.
    private static func wordsPattern(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
    }

    // MARK: Patterns

    /// No letter or digit before the name.
    private static let before = #"(?<![\p{L}\p{N}])"#
    /// No letter or digit after it, and not a possessive.
    private static let after = #"(?![\p{L}\p{N}])(?!['’]s\b)"#
    /// Where a clause starts: the text's start, after . ! ? ; : or a comma and a space, or after and, then or so.
    private static let clause = #"(?:^|(?<=[.!?;:])\s+|(?<=,)\s+|\band\s+|\bthen\s+|\bso\s+)"#
    /// Soft words before the verb: please, can you, remind me to, I need to…
    private static let soft = #"(?:(?:um+|uh+|ok|okay|so|and|then|please|just|can you|could you|would you|will you|i want you to|i'd like you to|remind me to|(?:i|we)\s+(?:need|have|want)\s+to|i've got to|don't forget to|remember to|i'll|let's)\s+)*"#
    private static let give = #"(?:give|hand|send|pass|assign|forward|leave|delegate|route)"#
    private static let negation = #"(?:n't|\s+not\b|\s+never\b|\s+no\s+longer\b|\s+hardly\b)"#
    private static let modal = #"(?:should|can|could|will|would|must|needs?\s+to|has\s+to|have\s+to|is\s+going\s+to|ought\s+to)(?!"# + negation + ")"
    /// After "ask N", "have N", "get N to": words that make it about N rather than work for it ("Let Chris know…").
    private static let notAfterCause = #"(?:know|knows|that|is|was|were|did|does|has|had|been|'s)\b"#
    /// A word that describes the agent rather than says what it should do: "faster", "running", "better", "aware".
    private static let adjective = #"(?:\w+(?:er|est|ing|ed|ly|able|ible|ful|less|ous|ive)|better|worse|aware|ready|available|good|bad|fast|slow|safe|quiet)\b"#

    /// The forms that hand work to the name, each a pattern: address, give to, give N, have N do, get N to do, make N do,
    /// put on N, for N, the other bench languages' ways of asking, and N should.
    static func patterns(_ name: String, caseFree: Bool, thinkingAloud: Bool = false) -> [String] {
        var n = before + name.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#) + after
        if caseFree { n = "(?i:" + n + ")" }
        let i = "(?i:"
        let soft = thinkingAloud ? softThinking : self.soft
        var list = [
            clause + i + soft + #"(?:(?:hey|ok|okay)\s+)?)"# + n + #"\s*[,:]"#,
            clause + i + soft + give + #"\b.{1,160}?\bto\s+)"# + n,
            clause + i + soft + give + #"\s+)"# + n + i + #"\s+(?:the|a|an|this|that|these|those|it|them|my|our|all)\b)"#,
            clause + i + soft + #"(?:ask|have|let|tell)\s+)"# + n + i + #"(?:\s+to)?\s+(?!"# + notAfterCause + ")[a-z])",
            clause + i + soft + #"get\s+)"# + n + i + #"\s+to\s+(?!"# + notAfterCause + ")[a-z])",
            clause + i + soft + #"make\s+)"# + n + i + #"\s+(?!"# + notAfterCause + "|" + adjective + ")[a-z])",
            clause + i + soft + #"(?:put|leave|drop)\s+.{1,120}?\s+on\s+)"# + n,
            i + #"(?:\b(?:this|that|it|these|those)(?:\s+one)?(?:'s|\s+is|\s+are)\s+for\s+|^for\s+))"# + n + #"(?:\s*[:,]|\s*$)"#,
            clause + i + #"(?:pede|peça|pedi|manda|passa|dá|dê|pide|pídele|dile|dale|pásale|demande|donne|passe|envoie|confie|lass|lasst|gib|frag|bitte)\s+(?:(?:ao|à|aos|a|al|au|aux|para\s+o|para\s+a)\s+)?)"#
                + n + i + #"(?:\s|,|$))"#,
            clause + i + soft + ")" + n + i + #"\s+"# + modal + #"\s+(?!be\b)[a-z])"#,
        ]
        guard thinkingAloud else { return list }
        // "N <modal> <verb>" with the modals of intent only, and "I want / I'd like / I need N to <verb>".
        list[list.count - 1] = clause + i + soft + ")" + n + i + #"\s+"# + modalOfIntent + #"\s+(?:probably\s+|really\s+|just\s+|also\s+)?(?!"#
            + notAfterIntent + ")[a-z])"
        list.append(clause + i + soft + #"(?:i|we)(?:'d)?\s+(?:really\s+)?(?:want|like|need)\s+)"# + n + i + #"\s+to\s+(?!"# + notAfterIntent + ")[a-z])")
        return list
    }

    /// The soft words for thinking out loud: today's, and "I/we (really, probably, just, definitely) should, must, ought to".
    private static let softThinking = #"(?:(?:um+|uh+|ok|okay|so|and|then|please|just|can you|could you|would you|will you|i want you to|i'd like you to|remind me to|(?:i|we)\s+(?:need|have|want)\s+to|i've got to|don't forget to|remember to|i'll|let's|(?:i|we)\s+(?:really\s+|probably\s+|just\s+|definitely\s+)?(?:should|must|ought\s+to))\s+)*"#
    /// The modals that say you mean it: never can, could, will, would, might or "is going to".
    private static let modalOfIntent = #"(?:should|must|needs?\s+to|has\s+to|have\s+to|ought\s+to)(?!"# + negation + ")"
    /// Never "be", "stop" or a verb of knowing after them.
    private static let notAfterIntent = #"(?:be|stop|know|knows|that|is|was|were|did|does|has|had|been|'s)\b"#
}
