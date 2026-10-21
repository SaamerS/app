import Darwin
import Foundation
import Hub
import Jinja
import Tokenizers
import BindersKit

/// A decision model folder's tokenizer and chat template, read outside Binders: `Binders --check-decision-folder <folder>
/// --reader tev1|chat` is this executable with a flag, as `--mcp` is, run once per folder, stamp and build. It reads the
/// tokenizer as the loader does (swift-transformers, not strict), finds the letters A to X as tokens (LetterTokens), and
/// then either holds Tev1's family to its own ids, or, for the chat reader, fills in the folder's chat template with
/// marker strings (swift-jinja, as swift-transformers does) to find its frame (ChatFrame), held to the template's own
/// rendering of the three warm-up questions, id for id, with thinking off. It reads the folder and nothing else, writes
/// nothing, and prints one JSON object on stdout.
///
/// swift-transformers ends the process on some tokenizer.json files (its fatalErrors, and a force unwrap in `encode` for
/// text its vocabulary can't hold), and a template can run without end, so this work runs only here: Binders gives it 20
/// seconds, then kills it, and a crash or a timeout is a refusal kept for the folder's stamp (FolderFingerprints), so a
/// folder that ends the check costs one short process, once, and Binders goes on. The process never makes an
/// NSApplication, so a crash in it shows no window and Launch Services never lists it as Binders.
enum DecisionFolderCheck {
    static let flag = "--check-decision-folder"
    static let schema = "binders-decision-check/1"
    /// How long Binders gives the check before killing it.
    static let limit: Duration = .seconds(20)
    /// The most of the check's stdout Binders reads (its answer), and of its stderr.
    static let maxOutput = 256 * 1024
    static let maxErrors = 64 * 1024
    /// The largest tokenizer.json Binders lets the check read.
    static let maxTokenizer: Int64 = 64 * 1_048_576
    /// What the check writes on stderr as it goes, so a timeout or a crash says which step it was in.
    static let stagePrefix = "binders-decision-check stage: "

    /// What the check prints: the letters and Tev1's ids or the chat frame, or why the folder is refused.
    struct Report: Codable, Equatable, Sendable {
        var schema: String
        var problem: String?
        /// "folder" or "cantAnswer" (Outcome.Kind), with `problem`.
        var kind: String?
        var letters: [Int]?
        var tev1: Tev1?
        var frame: ChatFrame?

        struct Tev1: Codable, Equatable, Sendable {
            var special: [String: Int]
            var start: [Int]
            var end: [Int]
        }
    }

    /// What Binders takes from the check.
    enum Outcome: Equatable, Sendable {
        /// The letters A to X as token ids, and the chat frame for the chat reader.
        case passed(letters: [Int], frame: ChatFrame?)
        /// Why it can't be used, in row A's words, and of which kind.
        case refused(String, Kind)

        enum Kind: String, Codable, Sendable {
            /// "Its folder isn't usable: …"
            case folder
            /// "It can't sort cards: …"
            case cantAnswer
        }

        /// As the backend's state says it.
        var unavailable: DecisionBackendState.Unavailable? {
            switch self {
            case .passed: nil
            case .refused(let why, .folder): .folder(why)
            case .refused(let why, .cantAnswer): .cantAnswer(why)
            }
        }
    }

    // MARK: The words

    /// The check ended without an answer: a fatalError in swift-transformers, any signal, no JSON, too much output.
    static let tokenizerStopped = "its tokenizer stopped Binders' check, so this Binders can't read it"
    static let templateStopped = "its chat template stopped Binders' check, so this Binders can't use it"
    /// Some character a card may hold has no token, and swift-transformers would end Binders on it.
    static let notEveryCharacter = "its tokenizer can't read every character a card may hold"

    static func tookTooLong(reading seconds: Double) -> String {
        "reading its tokenizer took more than \(String(format: "%g", seconds)) \(seconds == 1 ? "second" : "seconds")"
    }

    // MARK: In the helper process

    /// `Binders --check-decision-folder <folder> --reader tev1|chat`, from main.swift before anything else: the check, its
    /// JSON on stdout, and the process ends.
    static func run(_ arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            guard let at = arguments.firstIndex(of: flag), arguments.indices.contains(at + 1) else { return nil }
            return arguments[at + 1]
        }
        guard let path = value(flag), let reader = DecisionReader(rawValue: value("--reader") ?? ""), reader != .jev else {
            FileHandle.standardError.write(Data("Usage: Binders \(flag) <model folder> --reader tev1|chat\n".utf8))
            exit(2)
        }
        // Its stdout is the answer's alone: what swift-transformers prints as it reads (a warning about the tokenizer's
        // class, say) goes to stderr.
        let answer = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        signal(SIGPIPE, SIG_IGN)
        let found = Found()
        let done = DispatchSemaphore(value: 0)
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        Task.detached {
            found.report = await check(folder, reader: reader)
            done.signal()
        }
        done.wait()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let report = found.report ?? Report(schema: schema, problem: tokenizerStopped, kind: Outcome.Kind.folder.rawValue)
        var data = (try? encoder.encode(report)) ?? Data()
        data.append(0x0A)
        FileHandle(fileDescriptor: answer, closeOnDealloc: false).write(data)
        exit(0)
    }

    /// The report, from the check's task to the waiting thread.
    private final class Found: @unchecked Sendable {
        var report: Report?
    }

    private static func stage(_ name: String) {
        FileHandle.standardError.write(Data((stagePrefix + name + "\n").utf8))
    }

    private static func refusal(_ why: String, _ kind: Outcome.Kind) -> Report {
        Report(schema: schema, problem: why, kind: kind.rawValue)
    }

    /// The check itself, in the helper process.
    static func check(_ folder: URL, reader: DecisionReader) async -> Report {
        stage("tokenizer")
        // A Hub that never reaches the network or a token: the folder is all it reads.
        let hub = HubApi(downloadBase: FileManager.default.temporaryDirectory, cache: nil, hfToken: "none", endpoint: "https://huggingface.co",
                         useBackgroundSession: false, useOfflineMode: true)
        let configuration = LanguageModelConfigurationFromHub(modelFolder: folder, hubApi: hub)
        let tokenizerConfig: Config
        let tokenizer: PreTrainedTokenizer
        do {
            guard let found = try await configuration.tokenizerConfig else { throw TokenizerError.missingConfig }
            tokenizerConfig = found
            // As the loader reads it (RouterTokenizerLoader: AutoTokenizer.from(modelFolder:strict: false)).
            tokenizer = try PreTrainedTokenizer(tokenizerConfig: found, tokenizerData: try await configuration.tokenizerData, strict: false)
        } catch {
            return refusal("its tokenizer can't be read: \(firstLine(error.localizedDescription))", .folder)
        }
        let letters: [Int]
        switch LetterTokens.check(encode: { safeEncode(tokenizer, $0) ?? [] }, bare: { bare(tokenizer, $0) }) {
        case .failure(let problem): return refusal(problem.words, .cantAnswer)
        case .success(let ids): letters = ids
        }
        guard safeEncode(tokenizer, coverage) != nil else { return refusal(notEveryCharacter, .cantAnswer) }
        switch reader {
        case .tev1:
            return tev1Report(tokenizer, letters: letters)
        case .chat, .jev:
            stage("template")
            return chatReport(tokenizer, config: tokenizerConfig, letters: letters)
        }
    }

    /// Lane R1's checks after a load, moved before it, as they need only the tokenizer: A to X are 32 to 55, the four
    /// special tokens are Tev1's, and the warm-up prompt starts and ends as every prompt does.
    private static func tev1Report(_ tokenizer: PreTrainedTokenizer, letters: [Int]) -> Report {
        if let problem = LetterTokens.tev1Problem(letters) { return refusal(problem, .folder) }
        for (token, id) in MLXDecisionBackend.specialTokens.sorted(by: { $0.value < $1.value }) where tokenizer.convertTokenToId(token) != id {
            return refusal("its \(token) isn't \(id)", .folder)
        }
        guard let ids = safeEncode(tokenizer, Tev1Prompt.prompt(RouterQuestions.warmUps[0])), Array(ids.prefix(3)) == MLXDecisionBackend.promptStart,
              Array(ids.suffix(5)) == MLXDecisionBackend.promptEnd else {
            return refusal("its tokenizer doesn't read the prompt's template as Tev1's", .folder)
        }
        return Report(schema: schema, letters: letters, tev1: .init(special: MLXDecisionBackend.specialTokens, start: Array(ids.prefix(3)), end: Array(ids.suffix(5))))
    }

    /// The text's token ids as `encode(text:addSpecialTokens: false)` gives them, or nil where `encode` would end the
    /// process: a piece of the text that maps to no id, in a vocabulary with no unknown token and no byte for it.
    static func safeEncode(_ tokenizer: PreTrainedTokenizer, _ text: String) -> [Int]? {
        guard tokenizer.tokenize(text: text).allSatisfy({ tokenizer.convertTokenToId($0) != nil }) else { return nil }
        return tokenizer.encode(text: text, addSpecialTokens: false)
    }

    /// The vocabulary's own id for a bare letter; nil when it has none, or it's only the unknown token's.
    private static func bare(_ tokenizer: PreTrainedTokenizer, _ letter: String) -> Int? {
        guard let id = tokenizer.convertTokenToId(letter), id != tokenizer.unknownTokenId else { return nil }
        return id
    }

    /// Characters a card may hold, across scripts, accents, symbols and emoji: a tokenizer that reads bytes, or has an
    /// unknown token, reads them all.
    static let coverage = (32...126).map { String(UnicodeScalar(UInt8($0))) }.joined()
        + "\n\t éàüßñçøåœ €£¥ ΩЖж עברית العربية हिन्दी 漢字かなカナ한국어 🙂👍🏽 e\u{0301} \u{200D}"

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}

// MARK: - The chat frame, in the helper process

extension DecisionFolderCheck {
    /// The special-token settings swift-transformers puts in a template's context (its `specialTokenAttributes`).
    static let specialTokenAttributes = ["bos_token", "eos_token", "unk_token", "sep_token", "pad_token", "cls_token", "mask_token",
                                         "additional_special_tokens"]

    /// The frame the folder's chat template puts around a system line and a question, with thinking off: two renderings
    /// with marker strings, each holding each marker once, the three pieces around them the same bytes in both; for a
    /// template that refuses a system message, one user message with the system marker, a blank line and the user marker.
    /// Then held to the real path: for each warm-up question, swift-transformers' own applyChatTemplate (its rendering and
    /// encoding) must give the very ids the frame's prompt encodes to. And the frame must not end inside the model's
    /// thinking.
    fileprivate static func chatReport(_ tokenizer: PreTrainedTokenizer, config: Config, letters: [Int]) -> Report {
        guard let text = chatTemplate(config) else { return refusal(ChatFrame.Problem.noTemplate.words, .cantAnswer) }
        let template: Jinja.Template
        do {
            template = try Jinja.Template(text, with: .init(lstripBlocks: true, trimBlocks: true))
        } catch {
            return refusal("its chat template can't be filled in: \(firstLine(String(describing: error)))", .cantAnswer)
        }
        func render(_ messages: [Tokenizers.Message]) throws -> String {
            try template.render(context(messages, config: config))
        }
        var systemInUser = false
        var renderings: [ChatFrame.Rendering] = []
        do {
            for (system, user) in ChatFrame.markers {
                let rendered = try render([["role": "system", "content": system], ["role": "user", "content": user]])
                renderings.append(.init(text: rendered, system: system, user: user))
            }
        } catch {
            // A template that refuses a system message: the system line heads the user message.
            systemInUser = true
            renderings = []
            do {
                for (system, user) in ChatFrame.markers {
                    let rendered = try render([["role": "user", "content": system + ChatFrame.systemInUserGap + user]])
                    renderings.append(.init(text: rendered, system: system, user: user))
                }
            } catch {
                return refusal(ChatFrame.Problem.noTemplate.words, .cantAnswer)
            }
        }
        let frame: ChatFrame
        switch ChatFrame.frame(renderings, systemInUser: systemInUser) {
        case .success(let found): frame = found
        case .failure(let problem): return refusal(problem.words, .cantAnswer)
        }
        var templateIDs: [[Int]] = []
        var frameIDs: [[Int]] = []
        for question in RouterQuestions.warmUps {
            guard let framed = safeEncode(tokenizer, frame.prompt(question)) else { return refusal(notEveryCharacter, .cantAnswer) }
            let messages: [Tokenizers.Message] = systemInUser
                ? [["role": "user", "content": Tev1Prompt.system + ChatFrame.systemInUserGap + Tev1Prompt.userJSON(question)]]
                : [["role": "system", "content": Tev1Prompt.system], ["role": "user", "content": Tev1Prompt.userJSON(question)]]
            do {
                templateIDs.append(try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: ["enable_thinking": false]))
            } catch {
                return refusal(ChatFrame.Problem.changesWords.words, .cantAnswer)
            }
            frameIDs.append(framed)
        }
        if let problem = ChatFrame.check(templateIDs: templateIDs, frameIDs: frameIDs) { return refusal(problem.words, .cantAnswer) }
        // Thinking is off where the answer begins: the decoded end of the prompt holds no <think> after its last </think>.
        let tail = tokenizer.decode(tokens: Array((frameIDs.first ?? []).suffix(16)), skipSpecialTokens: false)
        if ChatFrame.thinkingOpen(tail) { return refusal(ChatFrame.Problem.thinks.words, .cantAnswer) }
        return Report(schema: schema, letters: letters, frame: frame)
    }

    /// The chat template as swift-transformers takes it: chat_template.jinja, else chat_template.json's, else
    /// tokenizer_config.json's `chat_template` (all merged into the config it reads), its "default" entry for a list.
    static func chatTemplate(_ config: Config) -> String? {
        let value: Config = config.chatTemplate
        if let text = value.string() { return text }
        guard let list = value.array() else { return nil }
        return list.first { $0["name"].string() == "default" }?["template"].string()
    }

    /// The context swift-transformers fills a template with: the messages, the generation prompt, thinking off (as
    /// MLXClient asks for it), and the config's special tokens.
    static func context(_ messages: [Tokenizers.Message], config: Config) throws -> [String: Jinja.Value] {
        var context: [String: Jinja.Value] = [
            "messages": .array(try messages.map { try Jinja.Value(any: $0) }),
            "add_generation_prompt": .boolean(true),
            "enable_thinking": .boolean(false),
        ]
        for (key, value) in config.dictionary(or: [:]) where specialTokenAttributes.contains(key.string) && !value.isNull() {
            if let text = value.string() {
                context[key.string] = .string(text)
            } else if let dictionary = value.dictionary() {
                let token = Config(dictionary)
                if let text = token.string() ?? token.content.string() { context[key.string] = .string(text) }
            } else if let list: [String] = value.get() {
                context[key.string] = .array(list.map { .string($0) })
            } else {
                context[key.string] = try Jinja.Value(any: value)
            }
        }
        return context
    }
}

// MARK: - In Binders: running the check

extension DecisionFolderCheck {
    private static let counter = Counter()

    /// For the self-test: how many checks have been started, and the last one's process.
    static var runs: Int { counter.runs }
    static var lastProcess: pid_t { counter.pid }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var lastPID: pid_t = 0

        var runs: Int { lock.withLock { started } }
        var pid: pid_t { lock.withLock { lastPID } }

        func began(_ pid: pid_t) {
            lock.withLock {
                started += 1
                lastPID = pid
            }
        }
    }

    /// The check for a folder as it is now: what's kept for its stamp and this build (FolderFingerprints), else the
    /// check's answer, kept, so a folder that ended the check is refused at every later launch from the cache alone. Nil
    /// for a folder with no counted file. Before the check, Binders' own: tokenizer.json is there and at most 64 MB.
    static func checked(_ folder: URL, reader: DecisionReader, fingerprints: FolderFingerprints = .shared,
                        within limit: Duration = DecisionFolderCheck.limit) async -> Outcome? {
        let stamp = FolderFingerprints.stamp(of: folder)
        guard !stamp.isEmpty else { return nil }
        let tokenizer = folder.appendingPathComponent("tokenizer.json")
        // Its size with a link followed (MLXModels.fileSize).
        guard let size = MLXModels.fileSize(tokenizer) else { return .refused("tokenizer.json is missing", .folder) }
        guard size <= maxTokenizer else { return .refused("its tokenizer.json is over 64 MB", .folder) }
        let path = FolderFingerprints.path(folder)
        if let entry = fingerprints.entry(path: path, stamp: stamp), entry.checked, entry.reader == reader.id, let kept = outcome(entry) {
            return kept
        }
        let found = await ask(folder: folder, reader: reader, within: limit)
        // Kept only for the files it read.
        if FolderFingerprints.stamp(of: folder) == stamp { fingerprints.keepCheck(found, reader: reader, path: path, stamp: stamp) }
        return found
    }

    /// What's kept from an earlier check.
    static func outcome(_ entry: FolderFingerprints.Entry) -> Outcome? {
        if let problem = entry.problem { return .refused(problem, Outcome.Kind(rawValue: entry.kind ?? "") ?? .folder) }
        return entry.letters.map { .passed(letters: $0, frame: entry.frame) }
    }

    /// Runs the check in a process of its own, this executable with the flag: no stdin, an environment of HOME, PATH and
    /// TMPDIR only, at most 256 KB of stdout and 64 KB of stderr read (the rest drained, so it never blocks on a full
    /// pipe), and `within` to answer before it's ended (SIGTERM, and SIGKILL a second later). An exit by a signal, a non-zero
    /// status, no JSON, or more than 256 KB is a refusal, in the words for the step it was in.
    static func ask(folder: URL, reader: DecisionReader, within limit: Duration = DecisionFolderCheck.limit) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runCheck(folder: folder, reader: reader, within: limit))
            }
        }
    }

    private static func runCheck(folder: URL, reader: DecisionReader, within limit: Duration) -> Outcome {
        guard let executable = Bundle.main.executableURL else { return .refused(tokenizerStopped, .folder) }
        let process = Process()
        process.executableURL = executable
        process.arguments = [flag, folder.path, "--reader", reader.rawValue]
        var environment: [String: String] = [:]
        for key in ["HOME", "PATH", "TMPDIR"] { environment[key] = ProcessInfo.processInfo.environment[key] }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .refused("Binders couldn't start its check of the folder: \(error.localizedDescription)", .folder)
        }
        let pid = process.processIdentifier
        counter.began(pid)
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        let ended = Flag()
        let timedOut = Flag()
        // Signals go only to a check that's still running, never to a process that has since taken its number.
        let stop = DispatchWorkItem {
            guard !ended.isSet, process.isRunning else { return }
            timedOut.set()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if !ended.isSet, process.isRunning { kill(pid, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: stop)
        let errorText = Drained()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorText.read(errors.fileHandleForReading, keeping: maxErrors)
            group.leave()
        }
        let answer = Drained()
        // More than it may say: it's ended at once.
        answer.read(output.fileHandleForReading, keeping: maxOutput) { if process.isRunning { kill(pid, SIGKILL) } }
        group.wait()
        process.waitUntilExit()
        ended.set()
        stop.cancel()
        let stage = errorText.text.components(separatedBy: "\n").last { $0.hasPrefix(stagePrefix) }.map { String($0.dropFirst(stagePrefix.count)) }
        let inTemplate = stage == "template"
        // An answer it finished wins over a limit that came as it ended.
        guard process.terminationReason == .exit, process.terminationStatus == 0, !answer.overflowed, let report = report(answer.data) else {
            if timedOut.isSet {
                return inTemplate ? .refused(ChatFrame.Problem.tookTooLong(seconds: seconds).words, .cantAnswer)
                    : .refused(tookTooLong(reading: seconds), .folder)
            }
            return inTemplate ? .refused(templateStopped, .cantAnswer) : .refused(tokenizerStopped, .folder)
        }
        let stopped: Outcome = inTemplate ? .refused(templateStopped, .cantAnswer) : .refused(tokenizerStopped, .folder)
        if let problem = report.problem { return .refused(problem, Outcome.Kind(rawValue: report.kind ?? "") ?? .folder) }
        guard let letters = report.letters, letters.count == LetterTokens.letters.count else { return stopped }
        guard reader == .tev1 || report.frame != nil else { return stopped }
        return .passed(letters: letters, frame: reader == .chat ? report.frame : nil)
    }

    /// The check's one JSON object: all of stdout, else its last line.
    private static func report(_ data: Data) -> Report? {
        let decoder = JSONDecoder()
        if let whole = try? decoder.decode(Report.self, from: data), whole.schema == schema { return whole }
        let last = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map { Data($0.utf8) } ?? Data()
        guard let report = try? decoder.decode(Report.self, from: last), report.schema == schema else { return nil }
        return report
    }

    /// A pipe read to its end, keeping at most `keeping` bytes and draining the rest.
    private final class Drained: @unchecked Sendable {
        private(set) var data = Data()
        private(set) var overflowed = false
        var text: String { String(decoding: data, as: UTF8.self) }

        func read(_ handle: FileHandle, keeping cap: Int, overflow: (() -> Void)? = nil) {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                let room = cap - data.count
                if room > 0 { data.append(chunk.prefix(room)) }
                if chunk.count > room, !overflowed {
                    overflowed = true
                    overflow?()
                }
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
