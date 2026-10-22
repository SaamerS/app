import Foundation

/// How much of a note the language model reads at once, and how long it may write: from the model's context, in tokens,
/// where Binders knows it (`LLMClient.contextTokens`), else a size that fits a model with an 8,000-token context.
public struct DistillBudget: Equatable, Sendable {
    /// The model's context, in tokens, when Binders knows it.
    public var contextTokens: Int?
    /// The most of the note one part holds, in characters.
    public var partCharacters: Int
    /// How long the answer may be, in tokens.
    public var replyTokens: Int
    /// Room on top of the answer for a model that thinks before it answers, so its thinking doesn't use up the answer's.
    public var thinkingTokens: Int
    /// The context, not the reading's own limit, set how much a part holds: a note with many headings makes its parts
    /// smaller to match.
    public var contextBound: Bool

    public init(contextTokens: Int?, partCharacters: Int, replyTokens: Int, thinkingTokens: Int, contextBound: Bool = false) {
        self.contextTokens = contextTokens
        self.partCharacters = partCharacters
        self.replyTokens = replyTokens
        self.thinkingTokens = thinkingTokens
        self.contextBound = contextBound
    }

    /// What the stream may write in all: the answer, and room to think first.
    public var streamTokens: Int { replyTokens + thinkingTokens }

    /// The most of a note a part holds however long the model's context: about 2,700 words. Past it, local models start to
    /// lose the instructions in the note (the list turns into a summary in prose).
    public static let readsWell = 16_000
    /// A part when Binders doesn't know the model's context: about 3,000 tokens of English, so with the instructions and a
    /// whole answer it fits a model that reads 8,000 tokens, as nearly all do.
    public static let unknown = 12_000
    /// The least a part holds, however small the context.
    static let smallest = 2_000
    /// Characters to a token, counted low (English is nearer 4; Markdown, numbers and other languages take more tokens).
    static let charactersPerToken = 3
    /// What the instructions, the part's framing, the headings and the titles before it take, in tokens.
    static let promptTokens = (DistillPrompt.system.count + 3_000) / charactersPerToken
    /// Left free in the context, in tokens.
    static let margin = 256
    public static let thinkingRoom = 2_000

    /// The budget for a model whose context is `tokens` (nil: not known).
    public static func forContext(_ tokens: Int?) -> DistillBudget {
        guard let tokens, tokens > 0 else {
            return DistillBudget(contextTokens: nil, partCharacters: unknown, replyTokens: DistillPrompt.maxTokens, thinkingTokens: thinkingRoom)
        }
        var reply = DistillPrompt.maxTokens
        let room = tokens - promptTokens - margin - reply
        if room * charactersPerToken >= readsWell {
            let thinking = min(thinkingRoom, room - readsWell / charactersPerToken)
            return DistillBudget(contextTokens: tokens, partCharacters: readsWell, replyTokens: reply, thinkingTokens: thinking)
        }
        if room * charactersPerToken >= smallest * 2 {
            return DistillBudget(contextTokens: tokens, partCharacters: room * charactersPerToken, replyTokens: reply, thinkingTokens: 0, contextBound: true)
        }
        // A small context: a shorter answer (fewer items a part), so a part still holds something.
        reply = min(DistillPrompt.maxTokens, max(1_000, tokens - promptTokens - margin - smallest / charactersPerToken))
        let left = tokens - promptTokens - margin - reply
        return DistillBudget(contextTokens: tokens, partCharacters: max(smallest, left * charactersPerToken), replyTokens: reply, thinkingTokens: 0,
                             contextBound: true)
    }

    /// How much of the note a part holds, with `header` characters of title and headings before it: a context-bound
    /// budget gives up what the headings take past the allowance.
    public func capacity(header: Int) -> Int {
        guard contextBound else { return partCharacters }
        return max(Self.smallest, partCharacters - max(0, header - 1_000))
    }

    /// Half as much in each part: for a model that turned a part down as too long without saying how much it reads.
    public var halved: DistillBudget {
        var budget = self
        budget.partCharacters = max(Self.smallest, partCharacters / 2)
        budget.thinkingTokens = 0
        budget.contextBound = true
        return budget
    }

    /// Whether a server's error says the prompt was longer than the model's context.
    public static func isTooLong(_ message: String) -> Bool {
        let lower = message.lowercased()
        return ["exceed_context_size", "context length", "context size", "context window", "maximum context", "too many tokens",
                "prompt is too long", "input is too long", "reduce the length"].contains { lower.contains($0) }
    }

    /// The context, in tokens, a server's too-long error gives: llama.cpp's `"n_ctx": 4096`, vLLM's and hosted APIs'
    /// "maximum context length is 8192 tokens", LM Studio's "context length of only 4096 tokens".
    public static func context(fromError message: String) -> Int? {
        let patterns = [#""n_ctx"\s*:\s*(\d+)"#, #"(?i)maximum context length is\s*(\d+)"#, #"(?i)context length of only\s*(\d+)"#,
                        #"(?i)context (?:length|size|window) (?:is|of)\s*(\d+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let range = Range(match.range(at: 1), in: message), let tokens = Int(message[range]), tokens > 0 else { continue }
            return tokens
        }
        return nil
    }
}

/// A note too long to read well at once, read in parts: section by section ("## " headings, as `DistillSections` splits
/// it), in as few parts as fit, as even as they go; a section longer than a part is cut between its paragraphs, each piece
/// under its heading. The readings of the parts become one (`merge`).
public enum DistillParts {
    /// A section, or a piece of one, in a part.
    public struct Piece: Equatable, Sendable {
        /// Its heading; nil for the note's opening.
        public var heading: String?
        /// For a section cut in pieces: which this is, and how many there are.
        public var piece: Int?
        public var pieces: Int?

        public init(heading: String?, piece: Int? = nil, pieces: Int? = nil) {
            self.heading = heading
            self.piece = piece
            self.pieces = pieces
        }

        var name: String {
            let name = heading.map { "“\($0)”" } ?? "the opening"
            guard let piece, let pieces else { return name }
            return "\(name) (piece \(piece) of \(pieces))"
        }
    }

    public struct Part: Equatable, Sendable {
        public var number: Int
        public var count: Int
        /// What it holds, in the note's order.
        public var pieces: [Piece]
        /// What the model reads: each section under its "## " heading. The whole note's text when it's read in one part.
        public var text: String

        public init(number: Int, count: Int, pieces: [Piece], text: String) {
            self.number = number
            self.count = count
            self.pieces = pieces
            self.text = text
        }

        /// What it holds, as the prompt says it: `the sections "A" and "B"`, `the note's opening and the section "A"`,
        /// `the section "C" (piece 2 of 3, cut from a longer section)`.
        public var holds: String {
            func cut(_ piece: Piece) -> String {
                guard let number = piece.piece, let of = piece.pieces else { return "" }
                return " (piece \(number) of \(of), cut from a longer section)"
            }
            var said: [String] = []
            if let opening = pieces.first(where: { $0.heading == nil }) { said.append("the note's opening" + cut(opening)) }
            let named = pieces.compactMap { piece in piece.heading.map { "\"\($0)\"" + cut(piece) } }
            if !named.isEmpty {
                let list = named.count == 1 ? named[0] : named.dropLast().joined(separator: ", ") + " and " + named.last!
                said.append((named.count == 1 ? "the section " : "the sections ") + list)
            }
            return said.joined(separator: " and ")
        }

        /// Its first and last sections, for a person: `“A” to “D”`, `“A”`, `the opening to “B”`.
        public var span: String {
            guard let first = pieces.first, let last = pieces.last else { return "" }
            let a = first.heading.map { "“\($0)”" } ?? "the opening", b = last.heading.map { "“\($0)”" } ?? "the opening"
            return first.heading == last.heading ? (first.piece != nil ? first.name : a) : "\(a) to \(b)"
        }
    }

    /// The parts of `text`, each at most `capacity` characters: one part, the note as it is, when it fits.
    public static func plan(_ text: String, capacity: Int) -> [Part] {
        let capacity = max(capacity, 500)
        let sections = DistillSections.sections(of: text)
        guard text.count > capacity, !sections.isEmpty else {
            return [Part(number: 1, count: 1, pieces: sections.map { Piece(heading: $0.heading) }, text: text)]
        }
        var atoms: [(piece: Piece, text: String)] = []
        for section in sections {
            let head = section.heading.map { "## \($0)\n\n" } ?? ""
            let whole = head + section.text
            guard whole.count > capacity else {
                atoms.append((Piece(heading: section.heading), whole))
                continue
            }
            let bodies = cut(section.text, limit: max(200, capacity - head.count))
            for (index, body) in bodies.enumerated() {
                atoms.append((Piece(heading: section.heading, piece: index + 1, pieces: bodies.count), head + body))
            }
        }
        let sizes = atoms.map(\.text.count)
        // Fewest parts at the capacity; then the smallest limit that still makes that few, so they come out even.
        let fewest = pack(sizes, limit: capacity).count
        var low = sizes.max() ?? capacity, high = capacity
        while low < high {
            let middle = (low + high) / 2
            if pack(sizes, limit: middle).count <= fewest { high = middle } else { low = middle + 1 }
        }
        let groups = pack(sizes, limit: low)
        return groups.enumerated().map { number, group in
            Part(number: number + 1, count: groups.count, pieces: group.map { atoms[$0].piece },
                 text: group.map { atoms[$0].text }.joined(separator: "\n\n"))
        }
    }

    /// Consecutive sizes into groups of at most `limit` (a blank line between each): each group as full as it goes, which
    /// makes the fewest groups.
    static func pack(_ sizes: [Int], limit: Int) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        var total = 0
        for (index, size) in sizes.enumerated() {
            if !current.isEmpty, total + 2 + size > limit {
                groups.append(current)
                current = []
                total = 0
            }
            total += current.isEmpty ? size : 2 + size
            current.append(index)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// A section's text in pieces of at most `limit` characters: between paragraphs, else between lines, else between
    /// words.
    static func cut(_ text: String, limit: Int) -> [String] {
        func join(_ units: [String], separator: String, finer: ((String) -> [String])?) -> [String] {
            var pieces: [String] = []
            var current = ""
            for unit in units {
                if unit.count > limit, let finer {
                    if !current.isEmpty { pieces.append(current); current = "" }
                    pieces += finer(unit)
                    continue
                }
                if current.isEmpty {
                    current = unit
                } else if current.count + separator.count + unit.count <= limit {
                    current += separator + unit
                } else {
                    pieces.append(current)
                    current = unit
                }
            }
            if !current.isEmpty { pieces.append(current) }
            return pieces
        }
        func words(_ line: String) -> [String] {
            var pieces: [String] = []
            var rest = Substring(line)
            while rest.count > limit {
                let window = rest.prefix(limit)
                let end = window.lastIndex(of: " ").map { $0 } ?? window.endIndex
                let piece = rest[..<end]
                pieces.append(String(piece))
                rest = rest[end...].drop { $0 == " " }
            }
            if !rest.isEmpty { pieces.append(String(rest)) }
            return pieces
        }
        func lines(_ paragraph: String) -> [String] {
            join(paragraph.components(separatedBy: "\n"), separator: "\n", finer: words)
        }
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return join(paragraphs, separator: "\n\n", finer: lines)
    }

    /// The parts' readings, in order, as one: repeats left out (a later part's item with an earlier title), a wait across
    /// parts kept by the title it names (an item's, else a section heading's: every item from that section), in the note's
    /// order of sections, at most `DistillPrompt.maxItems` in all (the first, in that order), never waiting in a circle.
    public static func merge(_ reads: [DistillReading.Result], headings: [String]) -> DistillReading.Result {
        var result = DistillReading.Result(items: [])
        var items: [DistillReading.Item] = []
        /// Waits by position in `items`.
        var waits: [Set<Int>] = []
        var byTitle: [String: Int] = [:]
        for read in reads {
            result.skipped += read.skipped
            result.repeats += read.repeats
            result.over += read.over
            result.droppedWaits += read.droppedWaits
            result.cutOff = result.cutOff || read.cutOff
            result.thought = result.thought || read.thought
            var local: [Int] = []
            var first: [Bool] = []
            for item in read.items {
                let key = LoopGuard.normalize(item.title)
                if let earlier = byTitle[key] {
                    result.repeats += 1
                    local.append(earlier)
                    first.append(false)
                    continue
                }
                byTitle[key] = items.count
                local.append(items.count)
                first.append(true)
                var kept = item
                kept.waitsFor = []
                items.append(kept)
                waits.append([])
            }
            for (index, item) in read.items.enumerated() where first[index] {
                let me = local[index]
                for wait in item.waitsFor where local[wait] != me { waits[me].insert(local[wait]) }
            }
        }
        // Waits across parts, now that every part is read: an item by its title, else the items of a section by its heading.
        for me in items.indices {
            for title in items[me].waitsElsewhere {
                if let target = byTitle[LoopGuard.normalize(DistillReading.clean(title))] {
                    if target != me { waits[me].insert(target) }
                } else if let heading = DistillSections.match(title, in: headings) {
                    let targets = items.indices.filter { $0 != me && items[$0].section == heading }
                    if targets.isEmpty { result.droppedWaits += 1 }
                    waits[me].formUnion(targets)
                } else {
                    result.droppedWaits += 1
                }
            }
            items[me].waitsElsewhere = []
        }
        // The note's order: by section; an item whose section matched none stays after the one read before it.
        let rank = Dictionary(headings.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        var ranks: [Int] = []
        for item in items {
            if let section = item.section, let place = rank[section] {
                ranks.append(place)
            } else if item.unknownSection != nil {
                ranks.append(ranks.last ?? 0)
            } else {
                ranks.append(0)
            }
        }
        let order = items.indices.sorted { ranks[$0] != ranks[$1] ? ranks[$0] < ranks[$1] : $0 < $1 }
        let kept = Array(order.prefix(DistillPrompt.maxItems))
        result.over += order.count - kept.count
        let position = Dictionary(kept.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var lists: [[Int]] = []
        for old in kept {
            var list: [Int] = []
            for target in waits[old].sorted() {
                if let new = position[target] { list.append(new) } else { result.droppedWaits += 1 }
            }
            lists.append(list.sorted())
        }
        let acyclic = CardWaits.acyclic(lists)
        result.droppedWaits += acyclic.dropped.count
        result.items = kept.enumerated().map { new, old in
            var item = items[old]
            item.waitsFor = acyclic.waits[new]
            return item
        }
        return result
    }
}

/// Distill's reading of a note by the language model: the note in as few parts as the model reads well (`DistillBudget`,
/// `DistillParts`), each asked once more with a reminder when its reply has no list in it, the parts' items made one. The
/// model is asked through `ask`, so the Mac's clients, the self-tests' stand-ins and the kit's tests all go the same way.
public enum DistillRun {
    /// One question to the model. The system prompt is always `DistillPrompt.system`.
    public struct Ask: Equatable, Sendable {
        public var user: String
        /// What the stream may write in all (`DistillBudget.streamTokens`).
        public var maxTokens: Int
        /// The answer's own limit, its thinking left out: `DistillReading.stopWhen(replyTokens:)`.
        public var replyTokens: Int
        public var part: Int
        public var parts: Int
        /// 1, or 2 for the try with the reminder.
        public var attempt: Int
        /// The note's "## " headings, in order: the sections a reply held to `schema` may name (lane DS3).
        public var headings: [String] = []

        public init(user: String, maxTokens: Int, replyTokens: Int, part: Int, parts: Int, attempt: Int, headings: [String] = []) {
            self.user = user
            self.maxTokens = maxTokens
            self.replyTokens = replyTokens
            self.part = part
            self.parts = parts
            self.attempt = attempt
            self.headings = headings
        }

        /// When to stop the reply early.
        public var stopWhen: @Sendable (String) -> Bool { DistillReading.stopWhen(replyTokens: replyTokens) }

        /// The JSON schema this question's reply is held to where the model allows it (`DistillSchema`): its sections are
        /// the note's headings, and a wait may name another part's item by its title when the note is read in parts.
        public func schema(bounded: Bool) -> String {
            DistillSchema.json(headings: headings, waitsByTitle: parts > 1, bounded: bounded)
        }

        /// When to stop a reply held to the schema early: only when it loops. Its length is the schema's to bring to a
        /// close (MLX), or the server's `max_tokens`.
        public var stopWhenHeld: @Sendable (String) -> Bool { { DistillReading.isLooping($0) } }
    }

    /// Thrown by `ask` when the model turned the prompt down as longer than its context: the reading starts again in
    /// smaller parts, sized from the context it said, else half as big.
    public struct TooLong: Error, Equatable, Sendable {
        public var contextTokens: Int?
        public init(contextTokens: Int?) { self.contextTokens = contextTokens }
    }

    /// How one part went.
    public struct PartOutcome: Equatable, Sendable {
        public var number: Int
        public var count: Int
        public var pieces: [DistillParts.Piece]
        public var span: String
        /// How many times it was asked: 2 when the first reply had no list.
        public var tries: Int
        /// Its replies had no list, the second one too.
        public var noList: Bool
        /// They were only thinking.
        public var onlyThinking: Bool
        /// What the model wrote first, its thinking left out, when there was no list.
        public var firstLines: String?
        /// It couldn't be asked: the error, in words.
        public var error: String?
        public var items: Int
    }

    public struct Outcome: Equatable, Sendable {
        /// Every part's items, made one.
        public var result: DistillReading.Result
        public var parts: [PartOutcome]
        /// How much of the note a part held, in characters.
        public var capacity: Int
        public var budget: DistillBudget
    }

    /// Reads `text` (the note titled `title`). Errors from `ask` end the reading when no part has been read yet (as a
    /// reading in one part always did); a later part's error is noted in its outcome and the rest go on. `TooLong` starts
    /// again in smaller parts, twice at most.
    public static func read(title: String, text: String, budget: DistillBudget,
                            ask: @escaping @Sendable (Ask) async throws -> String) async throws -> Outcome {
        let headings = DistillSections.sections(of: text).compactMap(\.heading)
        var budget = budget
        var tries = 0
        while true {
            let header = title.count + DistillPrompt.headingsLine(headings).count
            let capacity = budget.capacity(header: header)
            do {
                return try await readParts(DistillParts.plan(text, capacity: capacity), title: title, headings: headings, budget: budget,
                                           capacity: capacity, ask: ask)
            } catch let tooLong as TooLong where tries < 2 {
                tries += 1
                var smaller = tooLong.contextTokens.map { DistillBudget.forContext($0) } ?? budget.halved
                if smaller.capacity(header: header) >= capacity { smaller = budget.halved }
                budget = smaller
            }
        }
    }

    private static func readParts(_ parts: [DistillParts.Part], title: String, headings: [String], budget: DistillBudget, capacity: Int,
                                  ask: @escaping @Sendable (Ask) async throws -> String) async throws -> Outcome {
        var reads: [DistillReading.Result] = []
        var outcomes: [PartOutcome] = []
        var earlier: [String] = []
        for part in parts {
            let user = parts.count == 1 ? DistillPrompt.user(title: title, sections: headings, text: part.text)
                : DistillPrompt.part(title: title, sections: headings, part: part, earlier: earlier)
            var outcome = PartOutcome(number: part.number, count: part.count, pieces: part.pieces, span: part.span, tries: 0, noList: false,
                                      onlyThinking: false, firstLines: nil, error: nil, items: 0)
            var read: DistillReading.Result?
            for attempt in 1...2 {
                outcome.tries = attempt
                let reply: String
                do {
                    reply = try await ask(Ask(user: attempt == 1 ? user : DistillPrompt.again(user), maxTokens: budget.streamTokens,
                                              replyTokens: budget.replyTokens, part: part.number, parts: part.count, attempt: attempt,
                                              headings: headings))
                } catch let error as TooLong {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The first part, or the only one: the reading can't start, as before. A later one: noted, and on.
                    if part.number == 1 { throw error }
                    outcome.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    break
                }
                let reading = DistillReading.read(reply, headings: headings, elsewhere: parts.count > 1)
                if !reading.noList {
                    read = reading
                    break
                }
                outcome.noList = true
                outcome.onlyThinking = reading.onlyThinking
                outcome.firstLines = reading.firstLines ?? outcome.firstLines
            }
            if let read {
                outcome.noList = false
                outcome.onlyThinking = false
                outcome.firstLines = nil
                outcome.items = read.items.count
                reads.append(read)
                for item in read.items where !earlier.contains(item.title) { earlier.append(item.title) }
            }
            outcomes.append(outcome)
        }
        var result: DistillReading.Result
        if parts.count == 1 {
            result = reads.first ?? DistillReading.Result(items: [], noList: true)
        } else {
            result = DistillParts.merge(reads, headings: headings)
            result.noList = reads.isEmpty
        }
        if reads.isEmpty {
            result.onlyThinking = outcomes.contains { $0.noList } && outcomes.filter(\.noList).allSatisfy(\.onlyThinking)
            result.firstLines = outcomes.compactMap(\.firstLines).first
        }
        return Outcome(result: result, parts: outcomes, capacity: capacity, budget: budget)
    }
}

extension DistillRun.Outcome {
    /// Read in more than one part.
    public var inParts: Bool { parts.count > 1 }
    /// No part's reply had a list in it, even asked again.
    public var noList: Bool { result.items.isEmpty && parts.contains { $0.noList } && parts.allSatisfy { $0.noList || $0.error != nil } }
    /// Parts that gave nothing: no list after two tries, or an error.
    public var missing: [DistillRun.PartOutcome] { parts.filter { $0.noList || $0.error != nil } }
    /// What the model wrote first in the replies with no list, its thinking left out.
    public var firstLines: String? { parts.compactMap(\.firstLines).first }

    /// Why a reading made no list at all, in words for the Work bar and the alert: for a note read in parts, that it may be
    /// too long for `model`, with the choice of an agent (`agents`: one of yours can read the note).
    public func noListWords(model: String, agents: Bool) -> String {
        let model = model.isEmpty ? "this model" : model
        let instead = agents ? "Distill it with one of your agents instead, or choose another model in Settings → AI."
            : "Choose another model in Settings → AI, or split the note into shorter ones."
        if result.onlyThinking {
            let each = inParts ? " for each of the \(parts.count) parts of this note" : ""
            return "\(model) spent its whole reply thinking\(each) and never wrote the list, even when asked again. "
                + (agents ? "Choose a model that doesn't think first in Settings → AI, or Distill with one of your agents."
                   : "Choose a model that doesn't think first in Settings → AI.")
        }
        if inParts {
            return "The model answered without a list of work items for each of the \(parts.count) parts of this note, even when asked again, "
                + "so the note may be too long for \(model). " + instead
        }
        return "The model answered without a list of work items, even when asked again. Try again, or "
            + (agents ? "choose another model in Settings → AI, or Distill with one of your agents." : "choose another model in Settings → AI.")
    }

    /// For the review sheet and the Work bar: the parts that gave nothing, and why, or nil when every part was read.
    public var partsNote: String? {
        let missing = missing
        guard inParts, !missing.isEmpty else { return nil }
        let lines = missing.map { part -> String in
            let which = "Part \(part.number) of \(part.count) (\(part.span))"
            if let error = part.error { return "\(which) couldn't be read: \(error)" }
            let wrote = part.onlyThinking ? " The model only thought." : part.firstLines.map { " The model wrote: “\($0)”" } ?? ""
            return "\(which) had no list of work items, even when asked again, so its work isn't here.\(wrote)"
        }
        return lines.joined(separator: " ") + " Distill Again to read the note again."
    }

    /// "in 4 parts": how the review sheet says it read the note, or nil for one part.
    public var partsLine: String? { inParts ? "in \(parts.count) parts" : nil }
}
