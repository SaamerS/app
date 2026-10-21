import CryptoKit
import Foundation

// The decision model, chosen in Settings → AI: its pure parts. What the setting holds, how a model is read, which model it
// is (a fingerprint of its bytes, or of everything a server says about itself), whether its tokenizer and chat template
// let Binders read one letter as its answer, and the bands each model gets: built in for Tev1 0.8B bf16, from a measure on
// this Mac for any other, and suggestion bands only for a model never measured. The Mac reads folders, runs models and
// talks to servers; everything here is plain values, so it's tested without a model.

// MARK: - The choice

/// What Settings → AI → Decision model holds, parsed. A Hugging Face name has a slash; a path starts with / or ~; an
/// address starts with http:// or https:// (https is refused later, by LoopbackRule, with the reason). "" until you
/// choose: Tev1 0.8B on Apple silicon, Off on an Intel Mac. On an Intel Mac every MLX kind reads as Off, so a preferences
/// file brought over from an Apple silicon Mac can't make it build an MLX backend.
public enum DecisionChoice: Equatable, Hashable, Sendable {
    case off, tev1
    /// "org/name": downloaded into Models/MLX/org--name.
    case huggingFace(String)
    /// A folder's path, as chosen.
    case folder(String)
    /// The address as typed; LoopbackRule checks it before any connection.
    case server(String)

    public init(stored: String, appleSilicon: Bool) {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let choice: DecisionChoice
        if trimmed.isEmpty || lower == "tev1" {
            choice = .tev1
        } else if lower == "off" {
            choice = .off
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            choice = .server(trimmed)
        } else if stored.hasPrefix("/") || stored.hasPrefix("~") {
            // A path as the open panel gave it: a folder's name may end in a space.
            choice = .folder(stored)
        } else if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            choice = .folder(trimmed)
        } else if trimmed.contains("/") {
            choice = .huggingFace(trimmed)
        } else {
            // Nothing Settings writes: read as Off rather than guessed at.
            choice = .off
        }
        self = choice.isMLX && !appleSilicon ? .off : choice
    }

    /// What Settings stores for it: "tev1", "off", the name, the path or the address.
    public var stored: String {
        switch self {
        case .off: "off"
        case .tev1: "tev1"
        case .huggingFace(let id): id
        case .folder(let path): path
        case .server(let address): address
        }
    }

    /// A model run inside Binders with MLX: Tev1, a Hugging Face download or a folder. Never on an Intel Mac.
    public var isMLX: Bool {
        switch self {
        case .tev1, .huggingFace, .folder: true
        case .off, .server: false
        }
    }
}

/// Model names as people type them.
public enum ModelNames {
    /// Tev1 0.8B under any name: its owner or its name, compared without case, holds "tev1"
    /// (togethercomputer/Tev1-0.8B-experimental, a re-upload such as someone/TEV1-0.8b-mlx). Binders doesn't download Tev1
    /// until Together publishes its weights' licence, so MLXModels.download refuses such a name for both menus; a model
    /// whose name merely holds those four letters is refused too, which costs little.
    /// The name is read as typed and with its "%" escapes decoded (as a server decodes an address), so
    /// togethercomputer/Tev%31-0.8B-experimental is Tev1 too.
    public static func isTev1(_ id: String) -> Bool {
        var name = id
        for _ in 0..<4 {
            if holdsTev1(name) { return true }
            guard let decoded = name.removingPercentEncoding, decoded != name else { return false }
            name = decoded
        }
        return holdsTev1(name)
    }

    private static func holdsTev1(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.contains("tev1") }
    }

    /// A Hugging Face model's name as the Hub spells one: its owner, one slash and its name, each of letters, digits, ".",
    /// "_" and "-" and starting with a letter or a digit. Nothing else is stored from Another Hugging Face Model… or put
    /// into a download's address: a "%" escape, a "?", a space or another slash could make the address name another model
    /// than the one checked.
    public static func isRepoName(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        func plain(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        return parts.allSatisfy { part in
            guard let first = part.unicodeScalars.first, plain(first) else { return false }
            return part.unicodeScalars.allSatisfy { plain($0) || $0 == "." || $0 == "_" || $0 == "-" }
        }
    }
}

// MARK: - How a model is read

/// How a decision model is asked and read. The number after the dot (`version`) goes up with any change to how a prompt is
/// built or read: Tev1Prompt, the chat frame's rules, the system-message fallback, the letter read, the pieces or the
/// warm-up questions. A measure made the old way then keeps its key and no longer applies, so the model is unmeasured
/// until it's measured again. DecisionReaderTests pins the bytes of one prompt per reader and version.
public enum DecisionReader: String, CaseIterable, Sendable {
    /// Tev1's family (config.json: model_type qwen3_5, a tied embedding, a vocabulary of 248,320): Tev1Prompt byte for byte,
    /// run in 256-token pieces, the hidden state from mlx-swift-lm's drafter hook times the tied embedding's float32 rows
    /// for the letters. Tev1's conversions in any folder, and any Qwen 3.5 model built the same way.
    case tev1
    /// Every other MLX model: the same system line and JSON in the frame of the model's own chat template, thinking off
    /// (ChatFrame), in 256-token pieces, the letter read from the logits at the answer's first position.
    case chat
    /// A decision server on this Mac, over the Jev API (JevAPI).
    case jev

    public static let version = 1
    /// The prompt runs in pieces of this many tokens.
    public static let pieces = 256
    /// What Tev1's family says in its config.json.
    public static let tev1ModelType = "qwen3_5"
    public static let tev1Vocabulary = 248_320

    /// "tev1.1/256", "chat.1/256", "jev.1": the reader in a model's identity and in the tuning log.
    public var id: String {
        switch self {
        case .tev1, .chat: "\(rawValue).\(Self.version)/\(Self.pieces)"
        case .jev: "\(rawValue).\(Self.version)"
        }
    }

    /// The reader for an MLX model folder, from its config.json: Tev1's family, else the chat reader.
    public static func forConfig(_ config: [String: Any]) -> DecisionReader {
        isTev1Family(config) ? .tev1 : .chat
    }

    /// config.json says Tev1's family: model_type qwen3_5, and in text_config a tied embedding and a vocabulary of
    /// 248,320 tokens, which is what gives the float32 letter rows the built-in bands were measured on.
    public static func isTev1Family(_ config: [String: Any]) -> Bool {
        let text = config["text_config"] as? [String: Any] ?? [:]
        return config["model_type"] as? String == tev1ModelType && text["tie_word_embeddings"] as? Bool == true
            && (text["vocab_size"] as? NSNumber)?.intValue == tev1Vocabulary
    }

    /// The prompt an MLX reader encodes for a question: Tev1Prompt's bytes for Tev1's family; the chat frame around the
    /// same system line and JSON for the rest. Nil for the chat reader without a frame, and for a server, which is asked
    /// with a request (JevAPI.request).
    public func prompt(_ question: DecisionQuestion, frame: ChatFrame? = nil) -> String? {
        switch self {
        case .tev1: Tev1Prompt.prompt(question)
        case .chat: frame?.prompt(question)
        case .jev: nil
        }
    }
}

// MARK: - Which model it is

/// Which model answers, and how it's read: the key its bands and measures are kept under. Never a folder's name or a
/// model's: a fingerprint of the folder's bytes (DecisionFingerprint.folder) or, for a server, of everything it says about
/// itself (DecisionFingerprint.server), with the reader's id.
public struct DecisionIdentity: Codable, Equatable, Hashable, Sendable {
    /// "mlx1-…" or "jev1-…", 24 hex digits.
    public var fingerprint: String
    /// DecisionReader.id: "tev1.1/256", "chat.1/256", "jev.1".
    public var reader: String
    /// For a server: the parts its fingerprint was made from, for ServerMatch.
    public var server: Server?

    /// What a decision server says about itself, and how it answered the three probes (RouterQuestions.warmUps).
    public struct Server: Codable, Equatable, Hashable, Sendable {
        /// Its address, normalised (LoopbackAddress.normalized): http://127.0.0.1:18708.
        public var address: String
        /// The names /v1/models gave, in order.
        public var names: [String]
        /// Its fixed fields (JevAPI.Served), as key=value lines sorted by key.
        public var fields: [String]
        /// The models its probes' answers said answered them (Laya's routing.model, OpenJev's model), sorted.
        public var answeredBy: [String]
        /// The three probes' probabilities, each in option order.
        public var probes: [[Double]]

        public init(address: String, names: [String], fields: [String], answeredBy: [String], probes: [[Double]]) {
            self.address = address
            self.names = names
            self.fields = fields.sorted()
            self.answeredBy = Array(Set(answeredBy)).sorted()
            self.probes = probes
        }

        /// Whether a card's answer came from a model the probes reached: the one it names is among those the probes'
        /// answers named, or it names none and neither did they. A card Laya sent to a checkpoint no probe reached, or one
        /// answered by another model now behind the port, files and names but starts nothing.
        public func reached(_ model: String?) -> Bool {
            guard let model else { return answeredBy.isEmpty }
            return answeredBy.contains(model)
        }
    }

    public init(fingerprint: String, reader: String, server: Server? = nil) {
        self.fingerprint = fingerprint
        self.reader = reader
        self.server = server
    }

    /// A server's identity, its fingerprint made from its parts.
    public init(server: Server) {
        self.init(fingerprint: DecisionFingerprint.server(server), reader: DecisionReader.jev.id, server: server)
    }

    /// "<fingerprint> <reader>": what measures, verdicts and the built-in bands are kept under.
    public var key: String { "\(fingerprint) \(reader)" }

    /// The same model: equal keys, or for two servers read the same way, ServerMatch's rule, which lets a probability that
    /// sits on a rounding edge move a little.
    public func sameModel(as other: DecisionIdentity) -> Bool {
        if key == other.key { return true }
        guard reader == other.reader, let mine = server, let theirs = other.server else { return false }
        return ServerMatch.same(mine, theirs)
    }
}

// MARK: - Fingerprints

/// A model's fingerprint, so its bands follow its bytes and never a folder's name or place.
///
/// A folder's: the SHA-256 of a manifest of its weights, config and tokenizer files (`counts`), each with its size and its
/// own SHA-256, sorted by name; "mlx1-" and the first 24 hex digits (96 bits). The Mac reads and hashes the files
/// (4 MiB at a time, once per folder, cached by each file's size, dates and inode); the manifest is made here. Tev1 0.8B
/// bf16 as lane R1 used it is `mlx1-b73a343455582c89eed2254a`.
///
/// A server's: the SHA-256 of everything it says about itself and its three probes' probabilities to 3 places; "jev1-"
/// and 24 hex digits. ServerMatch decides when two that differ are still one model.
public enum DecisionFingerprint {
    /// One file of a model folder, as hashed.
    public struct File: Equatable, Sendable {
        public var name: String
        public var size: Int64
        /// Its SHA-256, in lowercase hex.
        public var sha256: String

        public init(name: String, size: Int64, sha256: String) {
            self.name = name
            self.size = size
            self.sha256 = sha256
        }
    }

    public static let folderPrefix = "mlx1-"
    public static let serverPrefix = "jev1-"
    public static let manifestHeader = "binders-decision-folder/1\n"
    public static let serverHeader = "binders-decision-server/2\n"
    /// What a weight index is called; mlx-swift-lm reads no other.
    public static let indexName = "model.safetensors.index.json"

    /// Whether a top-level entry of a model folder is part of its fingerprint: a regular file (a link to one counts) whose
    /// name ends in .safetensors, .json, .jinja, .tiktoken or .model, or is merges.txt or vocab.txt, in any case (the
    /// Mac's disk ignores case, so the loader can open Config.JSON as config.json): its weights, config and tokenizer, the
    /// set MLXDownload fetches. Not hidden files (.DS_Store, .cache), README.md, a licence, a half-downloaded .part, or
    /// a folder.
    public static func counts(_ name: String, isDirectory: Bool = false) -> Bool {
        guard !isDirectory, !name.isEmpty, !name.hasPrefix(".") else { return false }
        let lower = name.lowercased()
        return [".safetensors", ".json", ".jinja", ".tiktoken", ".model"].contains { lower.hasSuffix($0) } || ["merges.txt", "vocab.txt"].contains(lower)
    }

    /// "binders-decision-folder/1\n", then "<name>\t<size>\t<sha256>\n" for each file, sorted by the name's UTF-8 bytes.
    public static func manifest(_ files: [File]) -> String {
        manifestHeader + files.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
            .map { "\($0.name)\t\($0.size)\t\($0.sha256)\n" }.joined()
    }

    /// A folder's fingerprint from its counted files.
    public static func folder(_ files: [File]) -> String {
        folderPrefix + String(sha256Hex(manifest(files)).prefix(24))
    }

    /// What a server's fingerprint is made from, one tagged line each, values as JSON strings so no name can pass for
    /// another line: its address, its names in order, its fixed fields sorted, the models its probes' answers named
    /// sorted, then each probe's probabilities to 3 places, joined by commas.
    public static func serverManifest(_ server: DecisionIdentity.Server) -> String {
        var text = serverHeader + "address\t\(PythonText.jsonString(server.address))\n"
        for name in server.names { text += "name\t\(PythonText.jsonString(name))\n" }
        for field in server.fields.sorted() { text += "field\t\(PythonText.jsonString(field))\n" }
        for model in Set(server.answeredBy).sorted() { text += "answered-by\t\(PythonText.jsonString(model))\n" }
        for probe in server.probes {
            // -0.0 and 0.0 are one answer.
            text += "probe\t" + probe.map { String(format: "%.3f", $0 == 0 ? 0.0 : $0) }.joined(separator: ",") + "\n"
        }
        return text
    }

    /// A server's fingerprint: "jev1-" and the first 24 hex digits of its manifest's SHA-256.
    public static func server(_ server: DecisionIdentity.Server) -> String {
        serverPrefix + String(sha256Hex(serverManifest(server)).prefix(24))
    }

    /// Why a folder's model.safetensors.index.json can't be used, in words after "Its folder isn't usable:", or nil.
    /// mlx-swift-lm takes the files an index names whenever they all exist, and its own comment says an index may map
    /// weights into a subfolder; then a weight could come from a file the fingerprint, the folder's stamp and
    /// SafetensorsCheck never saw. So every file it names must be a plain name in the folder's top level: no "/", not "."
    /// or "..", not empty. A name that isn't there is fine: the loader then goes by the files' names, and uploads often
    /// carry an index from the model they were converted from.
    public static func indexProblem(_ index: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: index) as? [String: Any], let map = object["weight_map"] as? [String: Any],
              map.values.allSatisfy({ $0 is String }) else {
            return "its \(indexName) can't be read"
        }
        for name in Set(map.values.compactMap { $0 as? String }).sorted() where !isPlainName(name) {
            return "its \(indexName) puts weights in \(name), outside the folder's top level, and Binders only uses a model whose weights are all beside its config.json"
        }
        return nil
    }

    /// A file name in a folder's top level: not empty, not "." or "..", no "/" and no NUL.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.unicodeScalars.contains("\u{0}")
    }

    /// The SHA-256 of a string's UTF-8 bytes, in lowercase hex.
    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The letters

/// The 24 letters a decision model answers with, A to X, as token ids in its own tokenizer: worked out in the helper
/// process from the tokenizer, before anything loads. Each must encode to exactly one token, that token must be the
/// vocabulary's own entry for the bare letter, and the 24 must differ: a tokenizer that marks a lone letter as a word's
/// start encodes "A" as "▁A", one token but not the one a model writes after "assistant\n", and reading its probability
/// would read another answer.
public enum LetterTokens {
    public static let letters: [String] = Tev1Prompt.letters.map(String.init)

    /// Why a tokenizer can't give the letters. The words go after "It can't sort cards:".
    public enum Problem: Error, Equatable, Sendable {
        /// The letter alone encodes to more than one token, or to none.
        case notOneToken(String)
        /// Its one token isn't the vocabulary's own entry for the bare letter.
        case notTheLetter(String)
        /// Two letters are one token.
        case same(String, String)

        public var words: String {
            switch self {
            case .notOneToken(let letter):
                "in its tokenizer, “\(letter)” isn't a token of its own, and Binders reads the model's choice as one letter from A to X"
            case .notTheLetter(let letter):
                "in its tokenizer, “\(letter)” on its own doesn't become its token for the letter \(letter), and Binders reads the model's choice as one letter from A to X"
            case .same(let one, let other):
                "in its tokenizer, “\(one)” and “\(other)” are one token, and Binders reads the model's choice as one letter from A to X"
            }
        }
    }

    /// The 24 ids, A to X, from each letter's encoding (`encode(text: letter, addSpecialTokens: false)`) and the
    /// vocabulary's own id for the bare letter (`convertTokenToId(letter)`), both in letter order; or the first problem.
    public static func check(encoded: [[Int]], bare: [Int?]) -> Result<[Int], Problem> {
        var ids: [Int] = []
        var seen: [Int: String] = [:]
        for (index, letter) in letters.enumerated() {
            let tokens = index < encoded.count ? encoded[index] : []
            guard tokens.count == 1 else { return .failure(.notOneToken(letter)) }
            guard index < bare.count, let own = bare[index], own == tokens[0] else { return .failure(.notTheLetter(letter)) }
            if let earlier = seen[own] { return .failure(.same(earlier, letter)) }
            seen[own] = letter
            ids.append(own)
        }
        return .success(ids)
    }

    /// The same, asking a tokenizer for each letter.
    public static func check(encode: (String) -> [Int], bare: (String) -> Int?) -> Result<[Int], Problem> {
        check(encoded: letters.map(encode), bare: letters.map(bare))
    }

    /// Tev1's family has A to X at 32 to 55 (lane R1's check after a load, moved before it): nil when it does, else why,
    /// after "Its folder isn't usable:".
    public static func tev1Problem(_ ids: [Int]) -> String? {
        ids == Tev1Prompt.letterTokenIDs(count: 24) ? nil : "its letters A to X aren't one token each, 32 to 55"
    }
}

// MARK: - The chat frame

/// The words a model's chat template puts around the system line and the question, with thinking off: worked out once, in
/// the helper process and never in Binders, from renderings of the template with marker strings in place of the two, and
/// held to the template's own rendering of the three warm-up questions, id for id. A model read as chat.1/256 is asked
/// `before + system line + between + question JSON + after`, so no template runs in Binders or while a card waits. For a
/// template that refuses a system message, the system line heads the user message, then a blank line, then the question.
public struct ChatFrame: Codable, Hashable, Sendable {
    /// Before the system line: the template's head and the system message's opening, or with `systemInUser` the user
    /// message's.
    public var before: String
    /// Between the system line and the question; nil when the system line goes in the user message (`systemInUserGap`).
    public var between: String?
    /// After the question: the user message's end and the assistant's opening, thinking off.
    public var after: String

    public var systemInUser: Bool { between == nil }

    /// Between the system line and the question when both go in the user message.
    public static let systemInUserGap = "\n\n"
    /// The most of its own words a template may put in one piece, in UTF-8 bytes.
    public static let maxPiece = 16 * 1024
    /// The marker strings the helper renders the template with: two pairs of other lengths, plain ASCII a template has no
    /// reason to change.
    public static let markers: [(system: String, user: String)] = [
        ("BindersSystemMarkerQ7K3", "BindersUserMarkerM2XV"),
        ("BindersSystemMarkerNumberTwoJ8D4W", "BindersUser9"),
    ]

    public init(before: String, between: String?, after: String) {
        self.before = before
        self.between = between
        self.after = after
    }

    /// The whole prompt for a system line and a user message.
    public func text(system: String, user: String) -> String {
        before + system + (between ?? Self.systemInUserGap) + user + after
    }

    /// A question as the chat reader asks it: Tev1's system line and the question's JSON, in this frame.
    public func prompt(_ question: DecisionQuestion) -> String {
        text(system: Tev1Prompt.system, user: Tev1Prompt.userJSON(question))
    }

    /// Why a chat template can't be used. The words go after "It can't sort cards:".
    public enum Problem: Error, Equatable, Sendable {
        case noTemplate
        case changesWords
        case tooLong
        /// The helper's limit for filling in the template ran out.
        case tookTooLong(seconds: Double)
        case thinks

        public var words: String {
            switch self {
            case .noTemplate: "it has no chat template, so Binders can't put a question to it"
            case .changesWords: "its chat template changes the question's words, so Binders can't be sure what the model reads"
            case .tooLong: "its chat template wraps a question in more than 16 KB of its own words"
            case .tookTooLong(let seconds):
                "filling in its chat template took more than \(String(format: "%g", seconds)) \(seconds == 1 ? "second" : "seconds")"
            case .thinks: "it thinks before it answers, and its chat template can't turn that off"
            }
        }
    }

    /// One rendering of the template with marker strings in place of the system line and the user's message (with
    /// `systemInUser`, one user message holding the system marker, a blank line and the user marker).
    public struct Rendering: Equatable, Sendable {
        public var text: String
        public var system: String
        public var user: String

        public init(text: String, system: String, user: String) {
            self.text = text
            self.system = system
            self.user = user
        }
    }

    /// The frame two or more renderings agree on: each holds its system marker once and its user marker once, the system
    /// first, and the three pieces around them are the same bytes in every rendering. With `systemInUser`, the blank line
    /// between the markers must come through as it went in. Each piece is at most `maxPiece`.
    public static func frame(_ renderings: [Rendering], systemInUser: Bool = false) -> Result<ChatFrame, Problem> {
        guard renderings.count >= 2 else { return .failure(.changesWords) }
        var found: ChatFrame?
        for rendering in renderings {
            let text = Array(rendering.text.utf8), system = Array(rendering.system.utf8), user = Array(rendering.user.utf8)
            let systemAt = occurrences(of: system, in: text), userAt = occurrences(of: user, in: text)
            guard systemAt.count == 1, userAt.count == 1, systemAt[0] + system.count <= userAt[0] else { return .failure(.changesWords) }
            let middle = Array(text[(systemAt[0] + system.count)..<userAt[0]])
            if systemInUser, middle != Array(systemInUserGap.utf8) { return .failure(.changesWords) }
            let frame = ChatFrame(before: String(decoding: text[..<systemAt[0]], as: UTF8.self),
                                  between: systemInUser ? nil : String(decoding: middle, as: UTF8.self),
                                  after: String(decoding: text[(userAt[0] + user.count)...], as: UTF8.self))
            if let found, found != frame { return .failure(.changesWords) }
            found = frame
        }
        guard let found else { return .failure(.changesWords) }
        guard [found.before, found.between ?? "", found.after].allSatisfy({ $0.utf8.count <= maxPiece }) else { return .failure(.tooLong) }
        return .success(found)
    }

    /// The template's own rendering of the warm-ups (swift-transformers' applyChatTemplate, as token ids) against the
    /// frame's prompt for each, encoded: nil when every one is the same, id for id.
    public static func check(templateIDs: [[Int]], frameIDs: [[Int]]) -> Problem? {
        !templateIDs.isEmpty && templateIDs == frameIDs ? nil : .changesWords
    }

    /// Whether the end of a prompt leaves the model inside its thinking: an `open` after the last `close` in the decoded
    /// last tokens of the frame (the template's own markers; after a load, the model's own reasoning markers too).
    public static func thinkingOpen(_ tail: String, open: String = "<think>", close: String = "</think>") -> Bool {
        let text = Array(tail.utf8)
        guard let opened = occurrences(of: Array(open.utf8), in: text).last else { return false }
        guard let closed = occurrences(of: Array(close.utf8), in: text).last else { return true }
        return opened > closed
    }

    /// Where `needle` starts in `haystack`, every time.
    static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var found: [Int] = []
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] && Array(haystack[start..<(start + needle.count)]) == needle {
            found.append(start)
        }
        return found
    }

    // The pieces are compared and hashed by their bytes: two strings Swift calls equal can differ in what a model reads.
    public static func == (lhs: ChatFrame, rhs: ChatFrame) -> Bool {
        Array(lhs.before.utf8) == Array(rhs.before.utf8) && lhs.between.map { Array($0.utf8) } == rhs.between.map { Array($0.utf8) }
            && Array(lhs.after.utf8) == Array(rhs.after.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(before.utf8))
        hasher.combine(between.map { Array($0.utf8) })
        hasher.combine(Array(after.utf8))
    }

    private enum CodingKeys: String, CodingKey { case beforeSystem, between, afterUser, systemInUser, beforeUser }

    /// As the helper writes it: {"beforeSystem", "between", "afterUser"}, or {"systemInUser": true, "beforeUser",
    /// "afterUser"} for a template that refuses a system message.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .systemInUser) == true {
            self.init(before: try container.decode(String.self, forKey: .beforeUser), between: nil,
                      after: try container.decode(String.self, forKey: .afterUser))
        } else {
            self.init(before: try container.decode(String.self, forKey: .beforeSystem), between: try container.decode(String.self, forKey: .between),
                      after: try container.decode(String.self, forKey: .afterUser))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let between {
            try container.encode(before, forKey: .beforeSystem)
            try container.encode(between, forKey: .between)
        } else {
            try container.encode(true, forKey: .systemInUser)
            try container.encode(before, forKey: .beforeUser)
        }
        try container.encode(after, forKey: .afterUser)
    }
}

// MARK: - A server's match

/// Whether two of a server's identities are one model: the same address, names, fixed fields and models its answers
/// named, and for each probe the same top option and every probability within 0.02 in log-odds, each clipped to
/// 0.005 … 0.995 first. Log-odds weigh a change of 0.003 at 0.01 as the large change it is, where a flat 0.002 at every
/// option didn't; the clip keeps the tiny probabilities, which servers round to 4 places, from deciding. Used to find a
/// server's measure when its strict fingerprint (to 3 places) differs, for its warm-up check, at the end of a measure,
/// and right before a start.
public enum ServerMatch {
    public static let tolerance = 0.02
    public static let clip = 0.005...0.995

    public static func same(_ a: DecisionIdentity.Server, _ b: DecisionIdentity.Server) -> Bool {
        a.address == b.address && a.names == b.names && a.fields.sorted() == b.fields.sorted()
            && Set(a.answeredBy) == Set(b.answeredBy) && sameProbes(a.probes, b.probes)
    }

    /// Every probe answered alike.
    public static func sameProbes(_ a: [[Double]], _ b: [[Double]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { sameProbe($0, $1) }
    }

    /// One probe answered alike: the same top option, and every probability within the tolerance in log-odds.
    public static func sameProbe(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == b.count, !a.isEmpty, RouterMath.argmax(a) == RouterMath.argmax(b) else { return false }
        return zip(a, b).allSatisfy { abs(logOdds($0) - logOdds($1)) <= tolerance }
    }

    /// The largest log-odds difference between two answers to one probe, for the dev tools.
    public static func distance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs(logOdds($0) - logOdds($1)) }.max() ?? 0
    }

    /// log(p / (1 - p)), p clipped first.
    public static func logOdds(_ p: Double) -> Double {
        let clipped = min(max(p, clip.lowerBound), clip.upperBound)
        return log(clipped / (1 - clipped))
    }
}

// MARK: - The measure's record

/// One measure on this Mac, as decision-measures.json keeps it: keyed by the model's fingerprint and reader, with the
/// date, this Mac, the app's build, the warm-up goldens and letter shares of the load it was measured on, the bands the
/// measure's rules found (MeasureRules), why it starts no agent on its own if it doesn't, and the bench's numbers on dev
/// and test; and its Auto level (`bands.auto`), or why it has none (`noAuto`), with what Auto would have handed over
/// (`auto`). A record with neither `bands.auto` nor `noAuto` was measured before Auto (`measuredBeforeAuto`). Nothing of
/// yours: the cards are the bench's made-up ones. Every field after `key` is Optional, and one that doesn't read is left
/// out rather than losing the record, so another build's records don't break this one's.
public struct DecisionMeasure: Codable, Equatable, Sendable {
    /// DecisionIdentity.key: "<fingerprint> <reader>".
    public var key: String
    public var fingerprint: String?
    public var reader: String?
    /// A server's parts at the measure, so it's found by ServerMatch as well as by its key.
    public var server: DecisionIdentity.Server?
    public var at: Date?
    /// The app's build, and this Mac ("Mac17,6, Apple M5 Max").
    public var build: String?
    public var mac: String?
    /// The load's three warm-ups (a server's probes), one per RouterQuestions.warmUps question: every later load's are
    /// held to them within 0.002.
    public var golden: [[Double]]?
    /// The offered letters' share of the whole vocabulary's probability at each warm-up's first answer position (an MLX
    /// model's only).
    public var letterShare: [Double]?
    public var bands: Bands?
    /// Why it starts no agent on its own; nil when it may (its bands then have a start level).
    public var noStart: NoStart?
    public var dev: Numbers?
    public var test: Numbers?
    /// For a server: the models its answers said answered them during the measure.
    public var answeredBy: [String]?
    /// A card's time with it during the measure, in milliseconds.
    public var ms: Timing?
    /// Why the measure found no Auto level (MeasureRules.auto); nil when it found one (`bands.auto`), and in a record
    /// from before Auto, which has neither.
    public var noAuto: MeasureRules.NoAuto?
    /// What Auto would have handed over on dev and test, counted at its level (MeasureRules.AutoOutcome).
    public var auto: Auto?

    /// Measured before Auto: neither an Auto level nor a reason for none. Auto hands nothing over with it until it's
    /// measured again, but for Tev1 0.8B bf16 itself, read as built in (DecisionBands.resolve).
    public var measuredBeforeAuto: Bool { bands?.auto == nil && noAuto == nil }

    /// Why a measured model starts no agent on its own.
    public enum NoStart: String, Codable, Sendable, CaseIterable {
        /// It names no agent: at every suggest level, fewer than 5 named or fewer than 7 in 10 of them right.
        case namesNone
        /// At every level from 0.95 to 0.99, dev had a wrong start, or a wrong pick within 0.005 under the level.
        case noLevel
        /// At the lowest level with nothing wrong, dev had fewer than 2 starts.
        case fewStarts
        /// The test split had a wrong start at the level dev found.
        case testWrong
        /// The test split had no start at that level, or fewer than 5 with dev's.
        case testFew
        /// An earlier measure's test took starting away for this model, and that holds.
        case testBefore
        /// A server answered with more than one model, so no one model was held to a level.
        case severalModels
    }

    /// The bands as kept: `suggest` nil for a model that names no agent, `auto` nil for one Auto hands nothing over with.
    public struct Bands: Codable, Equatable, Sendable {
        public var start: Double?
        public var suggest: Double?
        public var generalBelow: Double?
        public var generalBelowTitlesOnly: Double?
        /// Auto's level (MeasureRules.auto).
        public var auto: Double?

        public init(start: Double?, suggest: Double?, generalBelow: Double?, generalBelowTitlesOnly: Double?, auto: Double? = nil) {
            self.start = start
            self.suggest = suggest
            self.generalBelow = generalBelow
            self.generalBelowTitlesOnly = generalBelowTitlesOnly
            self.auto = auto
        }

        public init(_ bands: RouterBands) {
            self.init(start: bands.start, suggest: bands.suggest >= RouterBands.never ? nil : bands.suggest, generalBelow: bands.generalBelow,
                      generalBelowTitlesOnly: bands.generalBelowTitlesOnly, auto: bands.auto)
        }

        /// As the router reads them: no suggest level names no agent (RouterBands.never), and a General threshold left
        /// out is a model's with no measure.
        public var routerBands: RouterBands {
            RouterBands(start: start, suggest: suggest ?? RouterBands.never, generalBelow: generalBelow ?? DecisionBands.unmeasured.generalBelow,
                        generalBelowTitlesOnly: generalBelowTitlesOnly ?? generalBelow ?? DecisionBands.unmeasured.generalBelowTitlesOnly, auto: auto)
        }

        /// The same bands, Auto's level aside: the ones R2's measure kept, for a record from before Auto.
        func sameBesidesAuto(_ other: RouterBands) -> Bool {
            var mine = routerBands, theirs = other
            mine.auto = nil
            theirs.auto = nil
            return mine == theirs
        }
    }

    /// What Auto would have handed over on one split, at the Auto level (the suggest band when there's none): the model's
    /// own picks to agents that draft first, how many went to the right agent and how many to an agent where the answer
    /// was nobody; and the named ones, counted apart, as a name decides by itself.
    public struct AutoCounts: Codable, Equatable, Sendable {
        public var picks: Int
        public var right: Int
        public var falseAssignments: Int
        public var named: Int
        public var namedRight: Int

        public init(picks: Int = 0, right: Int = 0, falseAssignments: Int = 0, named: Int = 0, namedRight: Int = 0) {
            self.picks = picks
            self.right = right
            self.falseAssignments = falseAssignments
            self.named = named
            self.namedRight = namedRight
        }

        private enum CodingKeys: String, CodingKey { case picks, right, falseAssignments = "false", named, namedRight }
    }

    /// The counts behind an Auto level, dev and test.
    public struct Auto: Codable, Equatable, Sendable {
        public var dev: AutoCounts?
        public var test: AutoCounts?

        public init(dev: AutoCounts?, test: AutoCounts?) {
            self.dev = dev
            self.test = test
        }
    }

    /// The bench's numbers on one split: its own scoring (each card's first picks, General never chosen) and how many
    /// agents Binders' rules would have started at `level`, wrong ones included.
    public struct Numbers: Codable, Equatable, Sendable {
        public var items: Int?
        public var binderOK: Int?
        public var agentOK: Int?
        /// (binderOK + agentOK) / (2 × items).
        public var score: Double?
        public var starts: Int?
        public var wrongStarts: Int?
        /// Dev only: binders right by the first pick when every binder is described by its titles alone.
        public var titlesBinderOK: Int?
        /// The level the starts were counted at: the start level, or the one dev found before something took it away,
        /// else 0.95, the lowest the rules try.
        public var level: Double?

        public init(items: Int? = nil, binderOK: Int? = nil, agentOK: Int? = nil, score: Double? = nil, starts: Int? = nil, wrongStarts: Int? = nil,
                    titlesBinderOK: Int? = nil, level: Double? = nil) {
            self.items = items
            self.binderOK = binderOK
            self.agentOK = agentOK
            self.score = score
            self.starts = starts
            self.wrongStarts = wrongStarts
            self.titlesBinderOK = titlesBinderOK
            self.level = level
        }
    }

    public struct Timing: Codable, Equatable, Sendable {
        public var p50: Int?
        public var p95: Int?

        public init(p50: Int?, p95: Int?) {
            self.p50 = p50
            self.p95 = p95
        }
    }

    /// A measure whose test took starting away (testWrong or testFew), or raised Auto's level or took it away
    /// (MeasureRules.auto). The first of each holds for the model (its key, or a server's by ServerMatch): a later measure
    /// of it keeps its own filing and naming bands and starts nothing (`testBefore`), and gets no lower Auto level than
    /// `autoLevel`, or none after `noAuto`, so a model can't be measured until its test happens to pass. Delete, or another
    /// key (another reader version, other bytes), ends it. One with only Auto's parts (`noStart` nil) leaves starting as it was.
    public struct TestVerdict: Codable, Equatable, Sendable {
        public var key: String
        public var server: DecisionIdentity.Server?
        public var at: Date?
        public var level: Double?
        public var noStart: NoStart?
        /// The Auto level a test raised it to: later measures give no lower one.
        public var autoLevel: Double?
        /// A test took Auto away (testShare): later measures give none (testBefore).
        public var noAuto: MeasureRules.NoAuto?

        public init(key: String, server: DecisionIdentity.Server? = nil, at: Date?, level: Double?, noStart: NoStart?, autoLevel: Double? = nil,
                    noAuto: MeasureRules.NoAuto? = nil) {
            self.key = key
            self.server = server
            self.at = at
            self.level = level
            self.noStart = noStart
            self.autoLevel = autoLevel
            self.noAuto = noAuto
        }

        /// It took starting away (rather than saying only what a test did to Auto).
        public var tookStart: Bool { noStart != nil }

        /// What `MeasureRules.auto` reads of it; nil when it says nothing about Auto.
        public var autoBefore: (level: Double?, noAuto: MeasureRules.NoAuto?)? {
            autoLevel == nil && noAuto == nil ? nil : (autoLevel, noAuto)
        }
    }

    public init(key: String, fingerprint: String? = nil, reader: String? = nil, server: DecisionIdentity.Server? = nil, at: Date? = nil,
                build: String? = nil, mac: String? = nil, golden: [[Double]]? = nil, letterShare: [Double]? = nil, bands: Bands? = nil,
                noStart: NoStart? = nil, dev: Numbers? = nil, test: Numbers? = nil, answeredBy: [String]? = nil, ms: Timing? = nil,
                noAuto: MeasureRules.NoAuto? = nil, auto: Auto? = nil) {
        self.key = key
        self.fingerprint = fingerprint
        self.reader = reader
        self.server = server
        self.at = at
        self.build = build
        self.mac = mac
        self.golden = golden
        self.letterShare = letterShare
        self.bands = bands
        self.noStart = noStart
        self.dev = dev
        self.test = test
        self.answeredBy = answeredBy
        self.ms = ms
        self.noAuto = noAuto
        self.auto = auto
    }

    private enum CodingKeys: String, CodingKey {
        case key, fingerprint, reader, server, at, build, mac, golden, letterShare, bands, noStart, dev, test, answeredBy, ms, noAuto, auto
    }

    /// Only `key` must read; any other field that doesn't (a reason a later build added, say) is left out.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        fingerprint = try? container.decodeIfPresent(String.self, forKey: .fingerprint)
        reader = try? container.decodeIfPresent(String.self, forKey: .reader)
        server = try? container.decodeIfPresent(DecisionIdentity.Server.self, forKey: .server)
        at = try? container.decodeIfPresent(Date.self, forKey: .at)
        build = try? container.decodeIfPresent(String.self, forKey: .build)
        mac = try? container.decodeIfPresent(String.self, forKey: .mac)
        golden = try? container.decodeIfPresent([[Double]].self, forKey: .golden)
        letterShare = try? container.decodeIfPresent([Double].self, forKey: .letterShare)
        bands = try? container.decodeIfPresent(Bands.self, forKey: .bands)
        noStart = try? container.decodeIfPresent(NoStart.self, forKey: .noStart)
        dev = try? container.decodeIfPresent(Numbers.self, forKey: .dev)
        test = try? container.decodeIfPresent(Numbers.self, forKey: .test)
        answeredBy = try? container.decodeIfPresent([String].self, forKey: .answeredBy)
        ms = try? container.decodeIfPresent(Timing.self, forKey: .ms)
        noAuto = try? container.decodeIfPresent(MeasureRules.NoAuto.self, forKey: .noAuto)
        auto = try? container.decodeIfPresent(Auto.self, forKey: .auto)
    }
}

/// decision-measures.json, in the data folder: the measures made on this Mac, one per model, and the test verdicts that
/// hold. Clear… of the sorting record and Delete all history leave it; Delete of a downloaded model removes its part.
public struct DecisionMeasures: Codable, Equatable, Sendable {
    public static let currentSchema = "binders-decision-measures/2"

    public var schema: String
    public var measures: [DecisionMeasure]
    public var testVerdicts: [DecisionMeasure.TestVerdict]
    /// Records in the file whose seal in the Keychain differs, or that have none since Binders first sealed the file
    /// (MeasureSeals): changed outside Binders. Never read for bands: such a model reads as not measured, and row E says
    /// why. Kept in the file as they are, never sealed, until a measure of that model takes their place. Not in the JSON.
    public var changed: [DecisionMeasure] = []
    /// The verdicts list in the file didn't match its seal: read as verdicts that take starting and Auto away from every
    /// model it names. Not in the JSON.
    public var verdictsChanged = false

    public init(measures: [DecisionMeasure] = [], testVerdicts: [DecisionMeasure.TestVerdict] = []) {
        schema = Self.currentSchema
        self.measures = measures
        self.testVerdicts = testVerdicts
    }

    /// A record changed outside Binders for a model: the one under its key, else, for a server, one ServerMatch finds.
    public func changedMeasure(for identity: DecisionIdentity) -> DecisionMeasure? {
        if let exact = changed.last(where: { $0.key == identity.key }) { return exact }
        return changed.last { Self.sameServer($0.key, $0.server, identity.key, identity.server) }
    }

    /// The measure for a model: the one under its key, else, for a server, one ServerMatch finds to be the same model.
    public func measure(for identity: DecisionIdentity) -> DecisionMeasure? {
        if let exact = measures.last(where: { $0.key == identity.key }) { return exact }
        return measures.last { Self.sameServer($0.key, $0.server, identity.key, identity.server) }
    }

    /// The test verdict that holds for a model: the first under its key, else, for a server, the first ServerMatch finds.
    public func verdict(for identity: DecisionIdentity) -> DecisionMeasure.TestVerdict? {
        if let exact = testVerdicts.first(where: { $0.key == identity.key }) { return exact }
        return testVerdicts.first { Self.sameServer($0.key, $0.server, identity.key, identity.server) }
    }

    /// A new measure takes the place of the model's last one; a test that took starting away becomes the model's verdict
    /// unless one holds for it already (the first holds). What a test did to Auto is added to the verdict that holds: the
    /// first that took Auto away holds, and a level a test raised it to never goes down.
    public mutating func keep(_ measure: DecisionMeasure, verdict: DecisionMeasure.TestVerdict? = nil) {
        measures.removeAll { $0.key == measure.key || Self.sameServer($0.key, $0.server, measure.key, measure.server) }
        changed.removeAll { $0.key == measure.key || Self.sameServer($0.key, $0.server, measure.key, measure.server) }
        measures.append(measure)
        guard let verdict else { return }
        guard let index = testVerdicts.firstIndex(where: { $0.key == verdict.key || Self.sameServer($0.key, $0.server, verdict.key, verdict.server) }) else {
            testVerdicts.append(verdict)
            return
        }
        var held = testVerdicts[index]
        if held.noStart == nil, verdict.noStart != nil {
            held.noStart = verdict.noStart
            held.level = verdict.level
            held.at = verdict.at
        }
        if held.noAuto == nil {
            if let noAuto = verdict.noAuto {
                held.noAuto = noAuto
            } else if let level = verdict.autoLevel {
                held.autoLevel = max(held.autoLevel ?? level, level)
            }
        }
        testVerdicts[index] = held
    }

    /// Two keys for one server's model: read the same way (the key's last word is the reader), and ServerMatch's rule.
    static func sameServer(_ key: String, _ server: DecisionIdentity.Server?, _ otherKey: String, _ other: DecisionIdentity.Server?) -> Bool {
        guard let server, let other, key.split(separator: " ").last == otherKey.split(separator: " ").last else { return false }
        return ServerMatch.same(server, other)
    }

    /// Delete of a downloaded model: its measures and verdicts go, under every reader.
    public mutating func remove(fingerprint: String) {
        measures.removeAll { $0.fingerprint == fingerprint || $0.key.hasPrefix("\(fingerprint) ") }
        changed.removeAll { $0.fingerprint == fingerprint || $0.key.hasPrefix("\(fingerprint) ") }
        testVerdicts.removeAll { $0.key.hasPrefix("\(fingerprint) ") }
    }

    private enum CodingKeys: String, CodingKey { case schema, measures, testVerdicts }

    /// A record that doesn't read is skipped, not the file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? container.decodeIfPresent(String.self, forKey: .schema)) ?? Self.currentSchema
        measures = ((try? container.decodeIfPresent([Lenient<DecisionMeasure>].self, forKey: .measures)) ?? []).compactMap(\.value)
        testVerdicts = ((try? container.decodeIfPresent([Lenient<DecisionMeasure.TestVerdict>].self, forKey: .testVerdicts)) ?? []).compactMap(\.value)
    }

    /// The file's contents: keys sorted, dates in ISO 8601.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// The file read; nil when it isn't one.
    public static func decode(_ data: Data) -> DecisionMeasures? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DecisionMeasures.self, from: EarlierSpellings.json(data))
    }
}

/// One element of a list that is kept when it reads and skipped when it doesn't.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - The bands

/// The bands a model is held to, with the goldens its warm-ups must match and where both came from.
public struct ResolvedBands: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Tev1 0.8B bf16's, built in (DecisionBands.builtIn).
        case builtIn
        /// From a measure on this Mac, on that date.
        case measured(Date)
        /// A model with no measure: suggestion bands only (DecisionBands.unmeasured).
        case unmeasured

        /// For the tuning log's `bands`.
        public var logName: String {
            switch self {
            case .builtIn: "built-in"
            case .measured: "measured"
            case .unmeasured: "unmeasured"
            }
        }
    }

    public var identity: DecisionIdentity
    public var bands: RouterBands
    /// One per warm-up question. Nil for a model never measured: its numbers then never match, nor differ.
    public var golden: [[Double]]?
    public var source: Source
    /// The measure the bands came from.
    public var measure: DecisionMeasure?
    /// A test verdict that holds for the model, which took its start level away.
    public var verdict: DecisionMeasure.TestVerdict?
    /// Its measure record was changed outside Binders (DecisionMeasures.changed): read as not measured (`source` is
    /// `.unmeasured`), with no start level and no Auto level, until Measure Again.
    public var changed: Bool

    public init(identity: DecisionIdentity, bands: RouterBands, golden: [[Double]]?, source: Source, measure: DecisionMeasure? = nil,
                verdict: DecisionMeasure.TestVerdict? = nil, changed: Bool = false) {
        self.identity = identity
        self.bands = bands
        self.golden = golden
        self.source = source
        self.measure = measure
        self.verdict = verdict
        self.changed = changed
    }

    /// Why Auto hands nothing over with these bands, as far as they can say: not measured, measured before Auto, or a
    /// measure (or a test verdict) that found no level. Nil when there's a level. The Mac adds what only it knows (Off, a
    /// model still being checked or unusable, numbers that differ this launch, a record changed outside Binders).
    public var whyNoAuto: AutoReach.Why? {
        guard bands.auto == nil else { return nil }
        if changed { return .changed }
        switch source {
        case .unmeasured: return .unmeasured
        case .builtIn: return .noLevel
        case .measured: return measure?.measuredBeforeAuto == true && verdict?.noAuto == nil ? .measuredBefore : .noLevel
        }
    }
}

/// Which bands a model gets: a measure on this Mac for its key (a server's, by ServerMatch too), then the one built-in
/// entry (Tev1 0.8B bf16), then the bands for a model with no measure, which name agents and start none.
public enum DecisionBands {
    /// R1's numbers for Tev1 0.8B bf16, beside which every measure is shown.
    public struct BuiltIn: Equatable, Sendable {
        /// Auto's level among them: the measure's Auto rule on R1's own runs (MeasureRules.auto).
        public var bands: RouterBands
        /// One per warm-up question.
        public var golden: [[Double]]
        public var dev: DecisionMeasure.Numbers
        public var test: DecisionMeasure.Numbers
        /// What Auto would have handed over at its level, on R1's runs.
        public var auto: DecisionMeasure.Auto?
    }

    /// Tev1 0.8B bf16, the conversion lane R1 measured (dm/dl/tev1-0.8b-mlx-bf16, the folder the founder has), read as
    /// tev1.1/256. Spelled out, not made from DecisionReader.version: another version of the reader gets nothing built in.
    public static let tev1BF16 = DecisionIdentity(fingerprint: "mlx1-b73a343455582c89eed2254a", reader: "tev1.1/256")

    /// Tev1 0.8B bf16 read as tev1.1/256: lane R1's bands from the Swift runtime's own numbers on the bench's 111 dev items
    /// (start 0.97: dev's one wrong Codex, named-13, is at 0.9602; the measure's rules give the same, lane R2's DESIGN.md
    /// 7.5), and its warm-up goldens from the Mac they were set on (Mac17,6, an M5 Max): lane R1's for the binder warm-up,
    /// and R1's dev run's answers for the two agent warm-ups (short-02 and fr-06, measure-tev1-bf16.json). Nothing else is
    /// built in: the 8-bit and 4-bit conversions, and every other model, get bands only from a measure on this Mac.
    ///
    /// Auto's level, 0.60, is what the measure's Auto rule gives on those same runs (lane Y1's DESIGN.md 3.1 and 10.2): on
    /// dev the model's own picks to agents that draft first are 23 at 0.60 or more, 19 of them right, 1 to an agent where
    /// the answer was nobody; on test 31, all right; and the named ones, dev 4 and test 6, all right. From 0.50 to 0.60 its
    /// picks were right only 6 times in 10.
    public static let builtIn: [String: BuiltIn] = [
        tev1BF16.key: BuiltIn(
            bands: RouterBands(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33, auto: 0.60),
            golden: [
                [0.0021477993990387774, 0.0011615317992045198, 0.63407359939928831, 0.00096142962259295178, 0.28634882491180019,
                 0.06968396977361406, 0.0004620289534555946, 0.0027519072059366922, 0.00047501622624390532, 0.00014431246735977928,
                 0.0017895802414652218],
                [0.07880409922463824, 0.6538652532380578, 0.0013868627879794284, 0.012132901045145, 0.0005378314963631202,
                 0.0008510172575729763, 7.273761578558036e-05, 8.622579374798957e-05, 0.25226307154070987],
                [0.001545325169063136, 0.0016935019285743284, 0.3285382346027754, 0.010277335971405118, 0.010554259469587183,
                 0.0012692697702884376, 0.38486498607377795, 0.0010961152775724034, 0.26016097173695596],
            ],
            dev: DecisionMeasure.Numbers(items: 111, binderOK: 98, agentOK: 73, score: Double(98 + 73) / 222, starts: 3, wrongStarts: 0,
                                         titlesBinderOK: 92, level: 0.97),
            test: DecisionMeasure.Numbers(items: 167, binderOK: 147, agentOK: 118, score: Double(147 + 118) / 334, starts: 4, wrongStarts: 0,
                                          level: 0.97),
            auto: DecisionMeasure.Auto(dev: .init(picks: 23, right: 19, falseAssignments: 1, named: 4, namedRight: 4),
                                       test: .init(picks: 31, right: 31, falseAssignments: 0, named: 6, namedRight: 6))),
    ]

    /// Tev1 0.8B bf16's built-in entry, for the numbers every measure is shown beside.
    public static var tev1: BuiltIn? { builtIn[tev1BF16.key] }

    /// How far a warm-up's probabilities may be from the golden recorded with the bands: lane R1's. The runtime is
    /// deterministic, so a difference past it means another GPU family or another mlx-swift build.
    public static let goldenTolerance = 0.002

    /// This launch's warm-ups held to the goldens recorded with the bands: as many warm-ups, as many options in each, and
    /// every probability within `goldenTolerance`. False with no golden (a model never measured), with no warm-up yet, and
    /// for a value that isn't a number.
    public static func warmUpsMatch(_ warmUps: [[Double]], _ golden: [[Double]]?) -> Bool {
        guard let golden, !golden.isEmpty, golden.count == warmUps.count else { return false }
        return zip(golden, warmUps).allSatisfy { kept, now in
            !kept.isEmpty && kept.count == now.count && zip(kept, now).allSatisfy { abs($0 - $1) <= goldenTolerance }
        }
    }

    /// A model with no measure on this Mac: it files cards (General below 0.35 in both forms, which on every dev run on
    /// the bench lost no binder against never falling back) and names an agent for Give to at 0.50 (where the picks that
    /// pass the takers rule were right 60% to 82% of the time in 15 dev runs of two model families), and never starts one.
    public static let unmeasured = RouterBands(start: nil, suggest: 0.50, generalBelow: 0.35, generalBelowTitlesOnly: 0.35)

    /// The bands for a model: its measure on this Mac, then the built-in entry, then the unmeasured bands. A measure that
    /// found no start level, or a test verdict that took starting away and holds for the model, leaves no start level.
    ///
    /// Auto's level is the measure's (`bands.auto`). A record from before Auto has none, but for Tev1 0.8B bf16 itself:
    /// a record under the built-in key whose bands are the built-in ones and whose goldens match the built-in entry's
    /// within `goldenTolerance` is R1's model, read R1's way, giving R1's numbers, so it gets the built-in level. A verdict
    /// that took Auto away leaves none; one that raised it, no lower.
    ///
    /// A record changed outside Binders (DecisionMeasures.changed) gives the unmeasured bands, whatever it says, and for
    /// Tev1 0.8B bf16's key too: Measure Again puts it right.
    public static func resolve(_ identity: DecisionIdentity, measures: DecisionMeasures) -> ResolvedBands {
        let verdict = measures.verdict(for: identity)
        if measures.changedMeasure(for: identity) != nil {
            return ResolvedBands(identity: identity, bands: unmeasured, golden: nil, source: .unmeasured, verdict: verdict, changed: true)
        }
        if let measure = measures.measure(for: identity), let kept = measure.bands {
            var bands = kept.routerBands
            if verdict?.tookStart == true || measure.noStart != nil { bands.start = nil }
            if measure.measuredBeforeAuto, let built = builtIn[identity.key], measure.key == identity.key, kept.sameBesidesAuto(built.bands),
               let golden = measure.golden, warmUpsMatch(golden, built.golden) {
                bands.auto = built.bands.auto
            }
            bands.auto = auto(bands.auto, after: verdict)
            return ResolvedBands(identity: identity, bands: bands, golden: measure.golden, source: .measured(measure.at ?? .distantPast),
                                 measure: measure, verdict: verdict)
        }
        if let built = builtIn[identity.key] {
            var bands = built.bands
            if verdict?.tookStart == true { bands.start = nil }
            bands.auto = auto(bands.auto, after: verdict)
            return ResolvedBands(identity: identity, bands: bands, golden: built.golden, source: .builtIn, verdict: verdict)
        }
        return ResolvedBands(identity: identity, bands: unmeasured, golden: nil, source: .unmeasured, verdict: verdict)
    }

    /// An Auto level as a verdict leaves it: none after one that took Auto away, no lower than one a test raised it to.
    static func auto(_ level: Double?, after verdict: DecisionMeasure.TestVerdict?) -> Double? {
        guard let level else { return nil }
        if verdict?.noAuto != nil { return nil }
        return max(level, verdict?.autoLevel ?? level)
    }
}

// MARK: - Seals: a measure changed outside Binders

/// decision-measures.json lives in the data folder with no check of its own, and an agent that runs a command runs as you:
/// it could write a record that gives a model a start level or an Auto level it never earned, with the real goldens copied
/// across so its numbers still match. So the store seals what it writes: a SHA-256 of each record, and of the verdicts list,
/// as JSON with its keys sorted (`seal`), kept in the Keychain, where an agent can't write. Read back, a record whose seal
/// differs, or that has none, is changed outside Binders (DecisionMeasures.changed: not measured, no start, no Auto); a
/// verdicts list whose seal differs takes starting and Auto away from every model it names. The first time a build with
/// this check reads the file (`firstRead`), what has no seal yet is taken as it is and sealed once, as an earlier build
/// wrote it; after that only the store's own write seals anything.
public enum MeasureSeals {
    /// What a read found, held to the seals.
    public struct Checked: Equatable, Sendable {
        /// The measures as they may be read: the trusted records, the changed ones apart, the verdicts (or the ones that take
        /// everything away).
        public var measures: DecisionMeasures
        /// Seals to write now, by record key: the first read's, for records that had none.
        public var adopted: [String: String]
        /// The verdicts list's seal to write now, when the first read took it as it was.
        public var adoptedVerdicts: String?
    }

    /// A record's seal: the SHA-256 of its JSON, keys sorted, dates in ISO 8601 (to the second), as the file has it. A
    /// record read back from the file gives the seal it was written with.
    public static func seal(_ measure: DecisionMeasure) -> String {
        DecisionFingerprint.sha256Hex(encoded(measure))
    }

    /// The verdicts list's seal, likewise; an empty list has one too.
    public static func seal(verdicts: [DecisionMeasure.TestVerdict]) -> String {
        DecisionFingerprint.sha256Hex(encoded(verdicts))
    }

    private static func encoded<Value: Encodable>(_ value: Value, earlier: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if earlier { encoder.keyEncodingStrategy = .custom { EarlierKey(EarlierSpellings.earlier($0.last?.stringValue ?? "")) } }
        return (try? encoder.encode(value)) ?? Data()
    }

    /// A seal as an earlier test build computed it, over its own names for Auto's keys: what it sealed still reads as
    /// sealed, and is sealed again as today's.
    static func earlierSeal(_ measure: DecisionMeasure) -> String { DecisionFingerprint.sha256Hex(encoded(measure, earlier: true)) }
    static func earlierSeal(verdicts: [DecisionMeasure.TestVerdict]) -> String { DecisionFingerprint.sha256Hex(encoded(verdicts, earlier: true)) }

    private struct EarlierKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// The file as read, held to the seals kept: `kept(key)` is a record's seal (nil or empty for none), `keptVerdicts` the
    /// list's. `firstRead`: no build with this check has read this file before, so what has no seal is adopted. A record
    /// whose seal is there but differs is changed, first read or not.
    public static func check(_ file: DecisionMeasures, kept: (String) -> String?, keptVerdicts: String?, firstRead: Bool) -> Checked {
        var trusted = DecisionMeasures(measures: [], testVerdicts: [])
        trusted.schema = file.schema
        var adopted: [String: String] = [:]
        for measure in file.measures {
            let seal = seal(measure)
            switch kept(measure.key).flatMap({ $0.isEmpty ? nil : $0 }) {
            case seal?: trusted.measures.append(measure)
            case let kept? where kept == earlierSeal(measure):
                trusted.measures.append(measure)
                adopted[measure.key] = seal
            case nil where firstRead:
                trusted.measures.append(measure)
                adopted[measure.key] = seal
            default: trusted.changed.append(measure)
            }
        }
        let verdictsSeal = seal(verdicts: file.testVerdicts)
        var adoptedVerdicts: String?
        switch keptVerdicts.flatMap({ $0.isEmpty ? nil : $0 }) {
        case verdictsSeal?:
            trusted.testVerdicts = file.testVerdicts
        case let kept? where kept == earlierSeal(verdicts: file.testVerdicts):
            trusted.testVerdicts = file.testVerdicts
            adoptedVerdicts = verdictsSeal
        case nil where firstRead || file.testVerdicts.isEmpty:
            // Nothing to take away from an empty list: it holds no verdict an agent could have removed.
            trusted.testVerdicts = file.testVerdicts
            if firstRead { adoptedVerdicts = verdictsSeal }
        default:
            trusted.verdictsChanged = true
            trusted.testVerdicts = file.testVerdicts.map(tookEverything)
        }
        return Checked(measures: trusted, adopted: adopted, adoptedVerdicts: adoptedVerdicts)
    }

    /// A verdict from a list changed outside Binders: whatever it said, it takes starting and Auto away for its model.
    static func tookEverything(_ verdict: DecisionMeasure.TestVerdict) -> DecisionMeasure.TestVerdict {
        DecisionMeasure.TestVerdict(key: verdict.key, server: verdict.server, at: verdict.at, level: verdict.level, noStart: .testBefore,
                                    autoLevel: nil, noAuto: .testBefore)
    }

    /// The file as the store writes it: the trusted records, and the changed ones as they were, so they still read as
    /// changed (never sealed) until a measure of that model replaces them.
    public static func file(_ measures: DecisionMeasures) -> DecisionMeasures {
        var file = DecisionMeasures(measures: measures.measures + measures.changed, testVerdicts: measures.testVerdicts)
        file.schema = measures.schema
        return file
    }
}
