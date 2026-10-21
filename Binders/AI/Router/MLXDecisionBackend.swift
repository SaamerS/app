import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Tokenizers
import BindersKit

/// A decision model run inside Binders by the app's own mlx-swift-lm, in a slot of its own: never through MLXRuntime, which
/// keeps the chat model and would let it go on every card. The model is a folder: Tev1 0.8B's in the data folder's Models
/// (Binders never downloads it and no build bundles it, as its weights' licence is still "being finalized"), one downloaded
/// into Models/MLX, or a folder chosen. DecisionModels makes one for each choice, with a marker of its own, and gives it the
/// goldens of the bands that apply; its identity is the folder's fingerprint and how it's read.
///
/// Two readers, decided from config.json (DecisionReader). Tev1's family is read as lane R1 read Tev1 (`tev1.1/256`): the
/// prompt BindersKit builds (Tev1Prompt) in 256-token pieces through the model's own cache, the hidden state at the last
/// position from mlx-swift-lm's drafter hook (`mtpEmitFlagKey`), times the tied embedding's float32 rows for the option
/// letters, softmaxed in Double; the model's own logits stay lazy and its 248k-row head never runs for a card. Every other
/// model is read through the frame its chat template puts around the same system line and question, with thinking off
/// (`chat.1/256`, the frame found by the folder check): every token but the last in pieces, then the last alone, and the
/// offered letters' logits at that position, the first of the answer.
///
/// Guarded every way the router can be. Nothing touches MLX until a load starts, and a load starts only once the checks
/// before it passed on Apple silicon: the folder's files in Binders (each .safetensors file against its header, the weight
/// index, Tev1's config and conversion), its tokenizer and chat template in a short-lived helper process
/// (DecisionFolderCheck, so nothing in them can end or hang Binders), and its fingerprint, both kept by the folder's stamp;
/// so a Mac without the folder, an Intel Mac or a VM never starts MLX for the router (nothing at init, in `state()` or for
/// Settings). Every MLX step on the router's own task runs inside `withError`, so an MLX error is a throw. A marker beside
/// the data says a load or a pass is under way, so a launch after a crash in there starts failed rather than loading it
/// again; a quit marks it, and that isn't a crash. Each card has one time budget, a load 20 seconds and a pass 10. At each
/// load, three warm-up questions build Metal's kernels and are held to the goldens, and at each the offered letters must
/// hold at least half of what the model would say first. A container is used only with the files it was loaded from.
/// Retired (switched away from, deleted, or quitting), it starts no load or pass, and a load under way is dropped when it
/// lands. It loads on first use, lets go after Free its memory's minutes unused or at once under memory pressure, and keeps
/// the parsed tokenizer to load again quickly.
actor MLXDecisionBackend: DecisionBackend {
    /// What it was made for: Tev1 0.8B (the folder must be Tev1's family, and a missing one is Tev1's missing folder), a
    /// model downloaded into Models/MLX (missing: not downloaded yet), or a folder chosen.
    enum Kind: Sendable { case tev1, downloaded, folder }

    /// The conversion Tev1 0.8B is chosen from, in the data folder's Models: lane R1's folder.
    static let tev1FolderName = "tev1-0.8b-mlx-bf16"
    static var tev1Folder: URL {
        AppPaths.support.appendingPathComponent("Models", isDirectory: true).appendingPathComponent(tev1FolderName, isDirectory: true)
    }
    /// The prompt runs in pieces of this many tokens: for Tev1 the MLX peak falls from 2,395 to 1,848 MiB for about 8 ms.
    static let defaultPieces = DecisionReader.pieces
    /// What a card may take, waiting and a cold load included, and what a load may take.
    static let cardBudget: Duration = .seconds(4)
    static let loadLimit: TimeInterval = 20
    /// Unused this long, it lets the weights go, unless Free its memory says otherwise.
    static let defaultIdleMinutes = 5
    /// This Mac must have at least this much memory, and a model's weights may take a quarter of it at most. A load needs
    /// the weights and `headroom` free or reclaimable, `freeToLoad` at least (about lane R1's 2.5 GB for Tev1).
    static let minimumMemory: UInt64 = 16 * 1_073_741_824
    static let freeToLoad: UInt64 = 2_500_000_000
    static let headroom: UInt64 = 1_000_000_000
    /// MLX's cache cap, process-wide, set at the start of a load: the value MLXRuntime sets too, never another.
    static let cacheLimit = 512 * 1024 * 1024
    /// Tev1's family: the tokens every prompt starts and ends with, and the special tokens' ids, which the folder check
    /// holds its tokenizer to.
    static let promptStart = [248_045, 8678, 198]
    static let promptEnd = [198, 248_068, 271, 248_069, 271]
    static let specialTokens = ["<|im_start|>": 248_045, "<|im_end|>": 248_046, "<think>": 248_068, "</think>": 248_069]
    /// At every warm-up, the offered letters must hold at least this share of the whole vocabulary's probability at the
    /// first position of the answer: Tev1's hold 0.9990 to 1.0000, while a model that starts its answer with a space, a word
    /// or a thinking mark of its own puts most of it elsewhere, and its letters' softmax would look as sure as an answer.
    static let letterShareFloor = 0.5
    /// What a marker reads after a quit, behind its step ("load quit", "decide quit"): the next launch passes over it.
    static let quitSuffix = " quit"

    nonisolated let folder: URL
    nonisolated let kind: Kind
    /// The prompt's pieces: 256, or for the dev tools other sizes (nil: whole prompts), which no bands were measured with.
    nonisolated let pieces: Int?
    /// Where the marker goes: "load" or "decide" while one is under way. One per choice (DecisionModels.marker(for:)).
    nonisolated let marker: URL
    private let fingerprints: FolderFingerprints
    /// A pass still running this long fails the backend for the launch.
    private let watchdog: TimeInterval
    /// A load, its checks and warm-ups included, still going this long fails the backend for the launch.
    private let loadWithin: TimeInterval
    /// Memory free or reclaimable that a load needs, when the self-test says; else from the weights.
    private let needsFreeGiven: UInt64?
    /// How a folder becomes a model in memory: mlx-swift-lm's own loader. The self-test puts a stand-in here.
    typealias Loader = @Sendable (URL) async throws -> ModelContainer
    private let loader: Loader
    /// What the folder check says for a folder read one way: the helper process (DecisionFolderCheck), its answer kept by
    /// the folder's stamp. The self-test puts a stand-in here for folders whose tokenizer it doesn't write whole.
    typealias Checker = @Sendable (URL, DecisionReader) async -> DecisionFolderCheck.Outcome?
    private let checker: Checker
    /// The checker is the helper's, whose answers decision-fingerprints.json keeps: a launch reads them from there.
    private let usesKept: Bool

    /// A model in memory, with what it was loaded from: the folder's stamp when the load began, the identity kept for that
    /// stamp, and the generation it was loaded in (retire, revive and unload each start a new one).
    private struct Loaded: Sendable {
        let container: ModelContainer
        let reader: DecisionReader
        /// Tev1's family: the tied embedding's rows for A to X, as float32.
        let rows: RowsBox?
        /// A to X as token ids, from the folder check.
        let letters: [Int]
        /// The chat reader's frame, from the folder check.
        let frame: ChatFrame?
        let resident: Int64
        let stamp: String
        let identity: DecisionIdentity
        let generation: Int
        /// The load's three warm-ups, and the offered letters' share of the whole vocabulary at each.
        let warmUps: [[Double]]
        let shares: [Double]
    }

    /// What Binders' own checks found for one stamp of the folder: why it can't be used, or the reader it takes.
    struct Preflight: Sendable {
        let stamp: String
        let problem: DecisionBackendState.Unavailable?
        let reader: DecisionReader?
        /// The top-level .safetensors files' bytes.
        let weights: Int64
        /// config.json's model_type.
        let modelType: String?
    }

    /// What the folder check and the hash found for one stamp of the folder.
    private struct Checked: Sendable {
        let stamp: String
        let outcome: DecisionFolderCheck.Outcome
        /// The folder's fingerprint; nil when it was refused, or its files couldn't be read.
        let fingerprint: String?
    }

    /// What a load is to load: the files as they were checked, and the generation it belongs to.
    private struct LoadPlan: Sendable {
        let stamp: String
        let identity: DecisionIdentity
        let reader: DecisionReader
        let letters: [Int]
        let frame: ChatFrame?
        let generation: Int
    }

    /// A load that found the model can't answer with a letter, or thinks before it answers: kept for the folder's stamp
    /// like the folder check's refusals, and never counted as a load that failed.
    private struct Refused: Error {
        let problem: DecisionBackendState.Unavailable
    }

    private var loaded: Loaded?
    private var loading: Task<Loaded, Error>?
    private var preflighted: Preflight?
    private var checked: Checked?
    private var checking: (stamp: String, task: Task<Checked?, Never>)?
    /// The goldens of the bands that apply (DecisionModels gives them), one per warm-up.
    private var golden: [[Double]]?
    /// Switched away from, deleted, or quitting: nothing loads or decides until it's revived.
    private var retired = false
    private var quitting = false
    /// Bumped by retire(), revive() and every unload: a load that began in an earlier one is dropped when it lands.
    private var generation = 0
    private var idleMinutes = MLXDecisionBackend.defaultIdleMinutes
    private var failure: String?
    /// The failure came from the marker: only Try Again clears it.
    private var failedByMarker = false
    private var loadFailures = 0
    /// This launch's warm-ups and the letters' shares at them, and the stamp of the files they ran on: nil until a load
    /// ran them, and again once those files changed.
    private var warmUps: [[Double]] = []
    private var letterShares: [Double] = []
    private var warmUpStamp: String?
    /// MLX work the router gave up on that goes on regardless: a load past its limit (mlx-swift-lm reads the weights on
    /// GCD threads that never look at cancellation), or a pass past the watchdog. Nothing loads again until it has
    /// ended, and its marker stays until then, so a crash in it still leaves the marker for the next launch.
    private var overrun: Task<Void, Never>?
    private var abandonedPass: Int?
    private var stillRunning: Bool { overrun != nil || abandonedPass != nil }
    /// The steps under way that the marker stands for, a load's or a pass's: the marker is there while any is.
    private var markerSteps: [String] = []
    private var loads = 0
    /// For the self-test: how many loads have begun.
    var loadsBegun: Int { loads }
    /// A load of this backend's has started MLX (its cache cap set, inside the guard). Until then nothing here calls
    /// MLX, not even to empty its cache.
    private var mlxStarted = false
    /// For the self-test: whether this backend has called MLX at all.
    var startedMLX: Bool { mlxStarted }
    private var unloadTask: Task<Void, Never>?
    private var unloadAt: Date?
    private var pressure: DispatchSourceMemoryPressure?
    private var passes = 0
    /// For the self-test: how many passes have begun.
    var passCount: Int { passes }
    /// The pass running now, and its watchdog.
    private var running: (pass: Int, watch: Task<Void, Never>)?
    /// What the last load kept found, for the dev tools.
    private(set) var report = LoadReport()

    struct LoadReport: Sendable {
        var loadMs: Double = 0
        var warmUpMs: Double = 0
        var modelType = ""
        var reader = ""
        var rowsAbout = ""
        /// The three warm-ups' probabilities, and the offered letters' share of the whole vocabulary at each.
        var warmUps: [[Double]] = []
        var letterShares: [Double] = []
        var hiddenStateHook = false
        var checks: [String] = []
    }

    init(folder: URL, kind: Kind = .folder, pieces: Int? = MLXDecisionBackend.defaultPieces, watchdog: TimeInterval = 10,
         loadLimit: TimeInterval = MLXDecisionBackend.loadLimit, needsFree: UInt64? = nil, marker: URL,
         fingerprints: FolderFingerprints = .shared, checker: Checker? = nil, loader: Loader? = nil) {
        let folder = folder.standardizedFileURL
        self.folder = folder
        self.kind = kind
        self.pieces = pieces
        self.watchdog = watchdog
        loadWithin = loadLimit
        needsFreeGiven = needsFree
        self.marker = marker
        self.fingerprints = fingerprints
        usesKept = checker == nil
        self.checker = checker ?? { folder, reader in await DecisionFolderCheck.checked(folder, reader: reader, fingerprints: fingerprints) }
        self.loader = loader ?? { folder in try await Self.loadContainer(folder) }
        // No MLX here: the cache cap is set when a load starts (loadSteps), so making the backend, as DecisionModels and
        // Settings do on every Mac, starts nothing. A marker a quit left counts for nothing; any other is a crash in a
        // load or a pass, and the model starts failed until Try Again.
        if FileManager.default.fileExists(atPath: marker.path) {
            let text = (try? Data(contentsOf: marker)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if Self.isQuitMark(text) {
                try? FileManager.default.removeItem(at: marker)
            } else {
                failure = Self.markerFound
                failedByMarker = true
            }
        }
    }

    static let markerFound = "Binders quit while its decision model was working"
    static let stillRunningWhy = "what it gave up on is still running, so it waits until that ends"
    static let stillChecking = "Binders is still checking it"

    /// A folder loaded as LLMModelFactory's `loadContainer(from:using:)` loads it (the factory directly: the free
    /// loadModelContainer reports only the last factory's error), with the message generator given: otherwise the loader
    /// fills in a Llama or Apertus model's chat template to try a system message, and no template is filled in inside
    /// Binders (the folder check did that once, in its own process). Tev1's Qwen 3.5 code takes the same generator anyway.
    nonisolated static func loadContainer(_ folder: URL) async throws -> ModelContainer {
        var configuration = ResolvedModelConfiguration(directory: folder)
        configuration.messageGenerator = DefaultMessageGenerator()
        let factory = LLMModelFactory.shared
        return factory._wrap(try await factory._load(configuration: configuration, tokenizerLoader: RouterTokenizerLoader()))
    }

    /// A marker's text written at a quit: its step, then " quit".
    nonisolated static func isQuitMark(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(quitSuffix)
    }

    // MARK: DecisionBackend

    /// What Settings and the router see, without waiting: `.checking` while the folder check or the hash for the files
    /// there now hasn't answered (it's started then, in the background).
    func state() -> DecisionBackendState {
        letGoIfChanged()
        forgetIfFolderChanged()
        if let failure { return .failed(failure) }
        if stillRunning { return .failed(Self.stillRunningWhy) }
        if let problem = preflight() { return .unavailable(problem) }
        if let loaded { return .loaded(bytes: MLXModels.size(of: folder), resident: loaded.resident, until: unloadAt) }
        guard let stamp = preflighted?.stamp, let found = checkNow(stamp) else {
            if let stamp = preflighted?.stamp { startChecking(stamp) }
            return .checking
        }
        if let refusal = Self.refusal(found) { return .unavailable(refusal) }
        return .ready(bytes: MLXModels.size(of: folder))
    }

    /// The model that answers next: a container in memory's own, else the files there now, by their fingerprint (kept by
    /// their stamp, hashed once, off the actor) and the reader their config.json takes. Nil when the folder isn't usable,
    /// or isn't known by `deadline`.
    func identity(by deadline: ContinuousClock.Instant) async -> DecisionIdentity? {
        letGoIfChanged()
        if let loaded { return loaded.identity }
        guard preflight() == nil, let reader = preflighted?.reader, let stamp = preflighted?.stamp else { return nil }
        var found = checkNow(stamp)
        if found == nil, let task = startChecking(stamp) {
            let seconds = Self.seconds(until: deadline)
            guard seconds > 0 else { return nil }
            found = (try? await TimeLimit.run(within: seconds) { await task.value }) ?? nil
        }
        guard let found, found.stamp == stamp, case .passed = found.outcome, let fingerprint = found.fingerprint else { return nil }
        return DecisionIdentity(fingerprint: fingerprint, reader: readerID(reader))
    }

    /// The model that would answer now, without hashing or waiting: the container in memory's own, else what's kept for
    /// the files there now. Nil when nothing is known for them.
    private func identityNow() -> DecisionIdentity? {
        if let loaded { return loaded.identity }
        guard preflight() == nil, let reader = preflighted?.reader, let stamp = preflighted?.stamp, let found = checkNow(stamp),
              case .passed = found.outcome, let fingerprint = found.fingerprint else { return nil }
        return DecisionIdentity(fingerprint: fingerprint, reader: readerID(reader))
    }

    /// The reader's id in the identity: "tev1.1/256" or "chat.1/256", or with the dev tools' other pieces, which no bands
    /// were measured with.
    nonisolated func readerID(_ reader: DecisionReader) -> String {
        pieces == DecisionReader.pieces ? reader.id : "\(reader.rawValue).\(DecisionReader.version)/\(pieces.map(String.init) ?? "whole")"
    }

    /// The goldens of the bands that apply, one per warm-up; a golden given after the load is held to the warm-ups already
    /// run.
    func setGolden(_ golden: [[Double]]?) {
        self.golden = golden
    }

    /// This launch's three warm-ups matched the goldens, each probability within 0.002.
    func numbersMatch() -> Bool {
        warmUpStamp != nil && failure == nil && DecisionBands.warmUpsMatch(warmUps, golden)
    }

    /// A golden set, a warm-up run, and no match: never for a model with no golden (one never measured).
    func numbersDiffer() -> Bool {
        golden != nil && warmUpStamp != nil && !DecisionBands.warmUpsMatch(warmUps, golden)
    }

    /// This launch's warm-ups, for the measure to record: nil before a load, and once the files they ran on changed.
    func warmUp() -> [[Double]]? {
        warmUpStamp == nil ? nil : warmUps
    }

    /// The letters' shares at this launch's warm-ups, with them.
    func warmUpShares() -> [Double]? {
        warmUpStamp == nil ? nil : letterShares
    }

    func decide(_ questions: [DecisionQuestion], expecting expected: DecisionIdentity?,
                by deadline: ContinuousClock.Instant) async throws -> DecisionAnswers {
        guard !retired else { throw DecisionError.retired }
        letGoIfChanged()
        // Its answers must come from the files its bands are for: the router passes the bands' identity, the measure its own.
        if let expected, identityNow()?.key != expected.key { throw DecisionError.changed }
        return DecisionAnswers(probs: try await decide(questions, by: deadline, expecting: expected), answeredBy: nil)
    }

    /// Loaded now, with its warm-ups, by `deadline`: for the measure, which mustn't spend a card's 4 s on a cold load.
    func prepare(by deadline: ContinuousClock.Instant) async throws {
        guard !retired else { throw DecisionError.retired }
        let seconds = Self.seconds(until: deadline)
        guard seconds > 0 else { throw DecisionError.timedOut }
        do {
            _ = try await TimeLimit.run(within: seconds) { [self] in try await ready() }
        } catch is TimeLimit.Exceeded {
            throw DecisionError.timedOut
        }
    }

    /// Right before a start: not retired or failed, and the files there still the ones the answer came from (the
    /// container's, whose answer `decide(expecting:)` held to the identity). A `stat` of each file, no hashing.
    func stillSame(_ identity: DecisionIdentity, by deadline: ContinuousClock.Instant) -> StillSame {
        letGoIfChanged()
        guard !retired, failure == nil, !stillRunning, let now = identityNow(), now.key == identity.key else { return .changed }
        return .same
    }

    func setIdle(minutes: Int) {
        idleMinutes = max(0, minutes)
        if loaded != nil { idle() }
    }

    /// Switched away from, or deleted: nothing loads or decides from now on, and the weights go now. A load under way goes
    /// on (MLX can't be interrupted) and is dropped when it lands; a pass under way finishes, and its card gets its answer,
    /// which `confirm` won't let start anything.
    func retire() {
        retired = true
        unload()
    }

    /// Chosen again. A load still running from before belongs to an older generation, so it's still dropped.
    func revive() {
        retired = false
        quitting = false
        generation += 1
    }

    /// Binders is quitting: nothing new loads or decides, a pass under way may finish within `within` (its marker goes
    /// with it), and a marker still there then (a load, which can take 20 s, or a pass past it) is marked as a quit, which
    /// the next launch passes over. Nothing waits when nothing is under way.
    func prepareForQuit(within: Duration) async {
        retired = true
        quitting = true
        let deadline = ContinuousClock.now + within
        while !markerSteps.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if let step = markerSteps.last { writeMarkerFile(step) }
    }

    /// For the self-test: retired, whether a container is in memory, a load under way, and a pass running.
    var retiredNow: Bool { retired }
    var hasContainer: Bool { loaded != nil }
    var isLoading: Bool { loading != nil }
    var passRunning: Bool { running != nil }

    private static func seconds(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let left = ContinuousClock.now.duration(to: deadline)
        return Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
    }

    /// Lane R1's decision, for the dev tools: each question's probabilities in the order given, by `deadline`.
    func decide(_ questions: [DecisionQuestion], by deadline: ContinuousClock.Instant) async throws -> [[Double]] {
        try await decide(questions, by: deadline, expecting: nil)
    }

    private func decide(_ questions: [DecisionQuestion], by deadline: ContinuousClock.Instant,
                        expecting expected: DecisionIdentity?) async throws -> [[Double]] {
        guard !retired else { throw DecisionError.retired }
        forgetIfFolderChanged()
        guard failure == nil else { throw DecisionError.unavailable(failure ?? "") }
        guard !questions.isEmpty else { return [] }
        guard questions.allSatisfy({ Tev1Prompt.options.contains($0.options.count) }) else { throw DecisionError.refused }
        let seconds = Self.seconds(until: deadline)
        guard seconds > 0 else { throw DecisionError.timedOut }
        do {
            return try await TimeLimit.run(within: seconds) { [self] in try await work(questions, expecting: expected) }
        } catch is TimeLimit.Exceeded {
            throw DecisionError.timedOut
        }
    }

    /// Unload now, idle or memory pressure: the weights go, and a load under way doesn't come back into memory behind it.
    func unload() {
        generation += 1
        unloadTask?.cancel()
        unloadTask = nil
        unloadAt = nil
        guard loaded != nil else { return }
        loaded = nil
        emptyCache()
    }

    func tryAgain() {
        failure = nil
        failedByMarker = false
        loadFailures = 0
        preflighted = nil
        // Work it gave up on that's still running keeps its marker until it ends, and nothing loads until then.
        if !stillRunning, markerSteps.isEmpty { removeMarkerFile() }
    }

    // MARK: Checking the folder

    /// A failure that isn't the marker's goes when the folder changes (a good copy in place of a broken one, say), so the
    /// folder is looked at before a failure is reported. Not while MLX work it gave up on is still running.
    private func forgetIfFolderChanged() {
        guard failure != nil, !failedByMarker, !stillRunning else { return }
        _ = preflight()
    }

    /// A container is used only with the files it was loaded from, and this launch's warm-ups describe only those: when
    /// the folder's files changed (a `stat` of each), both go first.
    private func letGoIfChanged() {
        guard loaded != nil || warmUpStamp != nil else { return }
        let stamp = FolderFingerprints.stamp(of: folder)
        if let loaded, loaded.stamp != stamp {
            self.loaded = nil
            unloadTask?.cancel()
            unloadTask = nil
            unloadAt = nil
            emptyCache()
        }
        if let warmUpStamp, warmUpStamp != stamp {
            self.warmUpStamp = nil
            warmUps = []
            letterShares = []
        }
    }

    /// Why it can't be used on this Mac or from this folder, from Binders' own checks, cheaply, without loading anything
    /// or reading the tokenizer; nil when it can. Worked out again when the folder's stamp changes.
    func preflight() -> DecisionBackendState.Unavailable? {
        #if !arch(arm64)
        return .thisMac(Self.needsAppleSilicon)
        #else
        guard ProcessInfo.processInfo.physicalMemory >= Self.minimumMemory else { return .thisMac(Self.needsMemory) }
        let stamp = FolderFingerprints.stamp(of: folder)
        if let preflighted, preflighted.stamp == stamp { return preflighted.problem }
        // The folder changed: a failure from before it (not the marker's, and with nothing it gave up on still running)
        // is forgotten.
        if preflighted != nil, !failedByMarker, !stillRunning {
            failure = nil
            loadFailures = 0
        }
        let found = Self.preflight(folder, kind: kind, stamp: stamp)
        preflighted = found
        return found.problem
        #endif
    }

    /// Binders' own checks of a folder, cheaply first, each refusal in row A's words: a model there (config.json and a
    /// .safetensors file), its weights at most a quarter of this Mac's memory, config.json readable, every top-level
    /// .safetensors file against its header (before MLX reads a byte of it), a weight index naming only files beside
    /// config.json, Tev1's config for the Tev1 choice and the conversion check for Tev1's family, and tokenizer.json there
    /// and at most 64 MB. And the reader config.json takes: Tev1's family, else the chat reader.
    nonisolated static func preflight(_ folder: URL, kind: Kind, stamp: String) -> Preflight {
        let manager = FileManager.default
        func refused(_ problem: DecisionBackendState.Unavailable) -> Preflight {
            Preflight(stamp: stamp, problem: problem, reader: nil, weights: 0, modelType: nil)
        }
        var isFolder: ObjCBool = false
        let there = manager.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
        guard there, MLXModels.isModel(folder) else {
            switch kind {
            case .tev1: return refused(.noFolder)
            case .downloaded: return refused(.notDownloaded)
            case .folder: return refused(there ? .folder(noModel) : .noFolder)
            }
        }
        let names = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".safetensors") && !$0.hasPrefix(".") }.sorted()
        // Sizes with a link followed (MLXModels.fileSize): a link's own few bytes would pass any model.
        let weights = names.reduce(Int64(0)) { total, name in
            total + (MLXModels.fileSize(folder.appendingPathComponent(name)) ?? 0)
        }
        let memory = ProcessInfo.processInfo.physicalMemory
        guard UInt64(max(0, weights)) <= memory / 4 else { return refused(.thisMac(tooBig(weights, memory: memory))) }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return refused(.folder("config.json is missing or can't be read"))
        }
        for name in names {
            if let problem = safetensorsProblem(folder.appendingPathComponent(name)) { return refused(.folder(problem)) }
        }
        let index = folder.appendingPathComponent(DecisionFingerprint.indexName)
        if manager.fileExists(atPath: index.path) {
            guard let listed = try? Data(contentsOf: index) else { return refused(.folder("its \(DecisionFingerprint.indexName) can't be read")) }
            if let problem = DecisionFingerprint.indexProblem(listed) { return refused(.folder(problem)) }
        }
        let family = DecisionReader.isTev1Family(config)
        if kind == .tev1, let problem = tev1ConfigProblem(config) { return refused(.folder(problem)) }
        // Bands go by the fingerprint, but a Tev1 conversion copied in under another conversion's name is still refused.
        if family, let mismatch = conversionMismatch(config: config, folderName: folder.lastPathComponent) { return refused(.folder(mismatch)) }
        let tokenizer = folder.appendingPathComponent("tokenizer.json")
        guard let size = MLXModels.fileSize(tokenizer) else { return refused(.folder("tokenizer.json is missing")) }
        guard size <= DecisionFolderCheck.maxTokenizer else { return refused(.folder("its tokenizer.json is over 64 MB")) }
        return Preflight(stamp: stamp, problem: nil, reader: family ? .tev1 : .chat, weights: weights, modelType: config["model_type"] as? String)
    }

    /// The Tev1 choice's folder must be Tev1's family, in lane R1's words: its model type, a tied embedding (the float32
    /// letter rows come from it) and Tev1's vocabulary.
    nonisolated static func tev1ConfigProblem(_ config: [String: Any]) -> String? {
        let text = config["text_config"] as? [String: Any] ?? [:]
        guard config["model_type"] as? String == DecisionReader.tev1ModelType else { return "it isn't a Tev1 0.8B conversion (model_type)" }
        guard text["tie_word_embeddings"] as? Bool == true else { return "its embedding isn't tied, which this Binders can't read choices from" }
        guard (text["vocab_size"] as? NSNumber)?.intValue == DecisionReader.tev1Vocabulary else { return "its vocabulary isn't Tev1's" }
        return nil
    }

    /// What's wrong with a folder for the Tev1 choice, in words after "Its folder isn't usable:", or nil: for the dev tools
    /// and the self-test, which check folders they cut or write.
    nonisolated static func problem(in folder: URL, kind: Kind = .tev1) -> String? {
        switch preflight(folder, kind: kind, stamp: FolderFingerprints.stamp(of: folder)).problem {
        case nil: nil
        case .folder(let why), .cantAnswer(let why), .thisMac(let why), .address(let why), .unreachable(let why): why
        case .noFolder, .notDownloaded: "there's no model in it"
        }
    }

    /// Whether config.json is the conversion the folder's name says: a folder named for bf16 holds no quantized weights,
    /// and one named for 8-bit or 4-bit holds those bits. Bands go by the folder's fingerprint, not its name, but a 4-bit
    /// conversion copied in under the bf16 name is still refused, as a copy put under the wrong name. A name that says
    /// neither is taken as it is. For Tev1's family only.
    nonisolated static func conversionMismatch(config: [String: Any], folderName: String) -> String? {
        let text = config["text_config"] as? [String: Any] ?? [:]
        let quantization = ["quantization", "quantization_config"].lazy.compactMap { config[$0] ?? text[$0] }.first as? [String: Any]
        let bits = (quantization?["bits"] as? NSNumber)?.intValue
        let said = quantization == nil ? "bf16" : bits.map { "\($0)-bit" } ?? "quantized"
        let name = folderName.lowercased()
        if name.hasSuffix("bf16") {
            return quantization == nil ? nil : "its config.json says it's a \(said) conversion, not the bf16 one its folder is named for"
        }
        if let range = name.range(of: #"(\d+)bit$"#, options: .regularExpression), let named = Int(name[range].dropLast(3)), named != bits {
            return "its config.json says it's a \(said) conversion, not the \(named)-bit one its folder is named for"
        }
        return nil
    }

    /// A safetensors file's header against its size, reading only the header.
    nonisolated static func safetensorsProblem(_ file: URL) -> String? {
        let name = file.lastPathComponent
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "\(name) can't be read" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard let first = try? handle.read(upToCount: 8), first.count == 8 else { return "\(name) is shorter than its header says" }
        let length = first.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard length < 100_000_000, 8 &+ length <= size else { return "\(name) is shorter than its header says" }
        let header = (try? handle.read(upToCount: Int(length))) ?? Data()
        return SafetensorsCheck.problem(headerLength: length, header: header, fileSize: size, name: name)
    }

    /// What the folder check and the hash found for the files at `stamp`: this backend's last answer for it, else what
    /// decision-fingerprints.json keeps for it; nil when they haven't answered for these files yet.
    private func checkNow(_ stamp: String) -> Checked? {
        if let checked, checked.stamp == stamp { return checked }
        guard usesKept, let reader = preflighted?.reader, preflighted?.stamp == stamp,
              let entry = fingerprints.entry(path: FolderFingerprints.path(folder), stamp: stamp), entry.checked, entry.reader == reader.id,
              let outcome = DecisionFolderCheck.outcome(entry) else { return nil }
        // Checked, but not hashed yet.
        if case .passed = outcome, entry.fingerprint == nil { return nil }
        let found = Checked(stamp: stamp, outcome: outcome, fingerprint: entry.fingerprint)
        checked = found
        return found
    }

    /// The folder check, the model type and the hash for the files at `stamp`, once, in a detached task at utility
    /// priority that whoever needs them awaits, so cards don't queue on the actor behind a second of hashing. Nil when
    /// Binders' own checks haven't passed for those files.
    @discardableResult
    private func startChecking(_ stamp: String) -> Task<Checked?, Never>? {
        if let checking, checking.stamp == stamp { return checking.task }
        guard let reader = preflighted?.reader, preflighted?.stamp == stamp, preflighted?.problem == nil else { return nil }
        let folder = folder, checker = checker, fingerprints = fingerprints, keeps = usesKept, modelType = preflighted?.modelType ?? ""
        let task = Task.detached(priority: .utility) { [weak self] () -> Checked? in
            // Nothing to check: its files went meanwhile. The next look finds the folder's new stamp.
            guard var outcome = await checker(folder, reader) else {
                await self?.endChecking(stamp)
                return nil
            }
            // A model type this Binders' mlx-swift-lm can't build is refused now, not three loads from now.
            if case .passed = outcome, !(await LLMTypeRegistry.shared.contains(modelType)) {
                outcome = .refused(Self.unsupported(modelType), .cantAnswer)
                if keeps, FolderFingerprints.stamp(of: folder) == stamp {
                    fingerprints.keepCheck(outcome, reader: reader, path: FolderFingerprints.path(folder), stamp: stamp)
                }
            }
            var fingerprint: String?
            if case .passed = outcome { fingerprint = await fingerprints.fingerprint(of: folder) }
            let found = Checked(stamp: stamp, outcome: outcome, fingerprint: fingerprint)
            await self?.recordCheck(found)
            return found
        }
        checking = (stamp, task)
        return task
    }

    /// A check's answer, kept unless it's for files that have changed since and a newer one is kept.
    private func recordCheck(_ found: Checked) {
        endChecking(found.stamp)
        if checked == nil || found.stamp == preflighted?.stamp { checked = found }
    }

    private func endChecking(_ stamp: String) {
        if checking?.stamp == stamp { checking = nil }
    }

    /// The folder check's and the hash's answer for the files there now, waiting for them while they run.
    private func checkResult() async -> Checked? {
        guard let stamp = preflighted?.stamp else { return nil }
        if let found = checkNow(stamp) { return found }
        guard let task = startChecking(stamp) else { return nil }
        return await task.value
    }

    /// Why what the checks found can't be used: the folder check's refusal, or files that couldn't be read for a hash.
    private static func refusal(_ found: Checked) -> DecisionBackendState.Unavailable? {
        if let refused = found.outcome.unavailable { return refused }
        return found.fingerprint == nil ? .folder(unhashable) : nil
    }

    /// A refusal from a load (the letters' share, thinking with the model's own markers), kept like the folder check's
    /// for the folder's stamp and the app's build, so it isn't loaded again just to be refused.
    private func refuse(_ problem: DecisionBackendState.Unavailable, stamp: String) {
        guard case .cantAnswer(let why) = problem else { return }
        let outcome = DecisionFolderCheck.Outcome.refused(why, .cantAnswer)
        checked = Checked(stamp: stamp, outcome: outcome, fingerprint: checked?.stamp == stamp ? checked?.fingerprint : nil)
        if usesKept, let reader = preflighted?.reader, FolderFingerprints.stamp(of: folder) == stamp {
            fingerprints.keepCheck(outcome, reader: reader, path: FolderFingerprints.path(folder), stamp: stamp)
        }
        Log.app.info("The decision model can't sort cards: \(why, privacy: .public)")
    }

    /// A folder chosen that holds no model, after "Its folder isn't usable:".
    static let noModel = "there's no MLX model in it: it needs its config.json and .safetensors weights"
    /// Its files couldn't be read through for the fingerprint.
    static let unhashable = "Binders couldn't read its files to tell which model it is"

    nonisolated static func unsupported(_ modelType: String) -> String {
        "its model type, \(modelType.isEmpty ? "none" : modelType), isn't one this Binders can run"
    }

    nonisolated static func tooBig(_ weights: Int64, memory: UInt64) -> String {
        "At \(ByteCountFormatter.string(fromByteCount: weights, countStyle: .file)) it's more than a quarter of this Mac's "
            + "\(memory / 1_073_741_824) GB of memory: choose a smaller model to sort cards"
    }

    nonisolated static func notALetter(_ share: Double) -> String {
        "it doesn't answer with a letter: on a made-up card, the letters it was offered held \(String(format: "%.2f", share)) of what it would say first"
    }

    // MARK: Deciding

    private func work(_ questions: [DecisionQuestion], expecting expected: DecisionIdentity?) async throws -> [[Double]] {
        let model = try await ready()
        // A container loaded from other files than the bands are for gives no answer.
        if let expected, model.identity.key != expected.key { throw DecisionError.changed }
        var answers: [[Double]] = []
        for question in questions {
            // Work still waiting when its card has gone on never runs.
            try Task.checkCancellation()
            answers.append(try await pass(question, on: model).probs)
        }
        if loaded?.container === model.container {
            idle()
        } else {
            // Let go while it answered: MLX's cache is emptied once this pass's hold on the container has gone too.
            Task { self.emptyCache() }
        }
        return answers
    }

    /// One question's letter logits and probabilities, with the prompt's token ids, through the model's reader. The
    /// marker and the watchdog cover the pass itself, from when it has the model, not the wait for it; a backend retired
    /// meanwhile begins none.
    private func pass(_ question: DecisionQuestion, on model: Loaded) async throws -> (ids: [Int], logits: [Double], probs: [Double]) {
        guard let prompt = model.reader.prompt(question, frame: model.frame) else { throw DecisionError.refused }
        let count = question.options.count
        let pieces = pieces, reader = model.reader, rows = model.rows, letters = model.letters
        passes += 1
        let pass = passes
        do {
            let result = try await model.container.perform { context -> Answer in
                try Task.checkCancellation()
                guard await self.begin(pass) else { throw DecisionError.retired }
                let outcome = Result {
                    try Self.guarded { () throws -> Answer in
                        switch reader {
                        case .tev1:
                            guard let rows else { throw Self.unreadable }
                            let ids = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
                            return Answer(ids: ids, logits: try Self.letterLogits(context.model, rows: rows.array, ids: ids, count: count, pieces: pieces).logits)
                        case .chat, .jev:
                            guard let ids = Self.encodeAll(context.tokenizer, prompt) else { throw Self.unencodable }
                            let read = try Self.chatLetterLogits(context.model, ids: ids, letters: letters, count: count, pieces: pieces, share: false)
                            return Answer(ids: ids, logits: read.logits)
                        }
                    }
                }
                await self.ended(pass)
                return try outcome.get()
            }
            return (result.ids, result.logits, RouterMath.softmax(result.logits))
        } catch let error as DecisionError {
            if case .mlx(let message) = error { fail("MLX: \(message)") }
            throw error
        }
    }

    private struct Answer: Sendable {
        let ids: [Int]
        let logits: [Double]
    }

    /// A pass begins, unless it was retired since its card asked: the marker, and the watchdog.
    private func begin(_ pass: Int) -> Bool {
        guard !retired else { return false }
        markerBegin("decide")
        let watch = Task { [watchdog] in
            try? await Task.sleep(for: .seconds(watchdog))
            guard !Task.isCancelled else { return }
            self.watchdogFired(pass)
        }
        running = (pass, watch)
        return true
    }

    private func ended(_ pass: Int) {
        if abandonedPass == pass { abandonedPass = nil }
        markerEnd("decide")
        guard running?.pass == pass else { return }
        running?.watch.cancel()
        running = nil
    }

    /// MLX work can't be interrupted: a pass still running now fails the backend for this launch. Cards waiting on it go
    /// on at their own deadlines, and later cards don't ask. The pass finishes in the background, holding the model, and
    /// nothing loads again until it has (its marker stays till then).
    private func watchdogFired(_ pass: Int) {
        guard running?.pass == pass else { return }
        abandonedPass = pass
        fail("a decision took more than \(Int(watchdog.rounded())) seconds")
    }

    private func fail(_ why: String) {
        failure = why
        Log.app.error("The decision model stopped: \(why, privacy: .public)")
        loaded = nil
        emptyCache()
    }

    /// MLX's cache emptied, inside the guard, and only once a load of this backend's has started MLX: never on a Mac
    /// where it didn't start, or couldn't.
    private func emptyCache() {
        guard mlxStarted else { return }
        try? Self.guarded { MLX.Memory.clearCache() }
    }

    // MARK: Loading

    /// The model, loaded once: a load already under way is waited for, in its own task, so it finishes for the next card
    /// even when this card's time runs out first. A load begins only once the folder check and the hash have answered for
    /// the files there now (a card waits for them within its own time), and with the memory free for it.
    private func ready() async throws -> Loaded {
        guard !retired else { throw DecisionError.retired }
        letGoIfChanged()
        if let loaded {
            idle()
            return loaded
        }
        if let loading { return try await loading.value }
        try canLoad()
        let found = await checkResult()
        // Anything may have happened while it waited.
        guard !retired else { throw DecisionError.retired }
        if let loaded {
            idle()
            return loaded
        }
        if let loading { return try await loading.value }
        try canLoad()
        guard let preflighted, let reader = preflighted.reader, let found, found.stamp == preflighted.stamp else {
            throw DecisionError.unavailable(Self.stillChecking)
        }
        if let refusal = Self.refusal(found) { throw DecisionError.unavailable(Self.words(refusal)) }
        guard case .passed(let letters, let frame) = found.outcome, let fingerprint = found.fingerprint else {
            throw DecisionError.unavailable(Self.stillChecking)
        }
        guard Self.reclaimableMemory() >= needsFree(preflighted.weights) else { throw DecisionError.memory }
        let plan = LoadPlan(stamp: found.stamp, identity: DecisionIdentity(fingerprint: fingerprint, reader: readerID(reader)), reader: reader,
                            letters: letters, frame: frame, generation: generation)
        let task = Task { try await self.loadAndKeep(plan) }
        loading = task
        return try await task.value
    }

    /// What stops a load before anything is asked of the folder check: a failure, work it gave up on still running, or
    /// Binders' own checks.
    private func canLoad() throws {
        forgetIfFolderChanged()
        if let failure { throw DecisionError.unavailable(failure) }
        if stillRunning { throw DecisionError.unavailable(Self.stillRunningWhy) }
        if let problem = preflight() { throw DecisionError.unavailable(Self.words(problem)) }
    }

    /// The free or reclaimable memory a load needs: the weights and 1 GB, 2.5 GB at least.
    private func needsFree(_ weights: Int64) -> UInt64 {
        needsFreeGiven ?? max(Self.freeToLoad, UInt64(max(0, weights)) + Self.headroom)
    }

    /// A load, kept only if nothing changed while it ran: not retired, not let go since (its generation), and the files
    /// still the ones it began with. Otherwise what it loaded goes at once, MLX's cache emptied once it has, and its
    /// cards get no answer. Every card waiting on it gets the same outcome.
    private func loadAndKeep(_ plan: LoadPlan) async throws -> Loaded {
        let landed: Landed
        do {
            landed = try await load(plan)
        } catch let refused as Refused {
            loading = nil
            refuse(refused.problem, stamp: plan.stamp)
            throw DecisionError.unavailable(Self.words(refused.problem))
        } catch {
            loading = nil
            loadFailures += 1
            if case DecisionError.mlx(let message) = error {
                fail("MLX: \(message)")
            } else if loadFailures >= 3 {
                fail(error.localizedDescription)
            }
            Log.app.error("The decision model didn't load: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        loading = nil
        loadFailures = 0
        let stampNow = FolderFingerprints.stamp(of: folder)
        guard !retired, plan.generation == generation, stampNow == plan.stamp else {
            Task { self.emptyCache() }
            throw stampNow == plan.stamp ? DecisionError.retired : DecisionError.changed
        }
        let model = landed.loaded
        loaded = model
        warmUps = model.warmUps
        letterShares = model.shares
        warmUpStamp = model.stamp
        report = landed.report
        if let golden, !DecisionBands.warmUpsMatch(model.warmUps, golden) {
            Log.app.info("The decision model's numbers on this Mac differ from its goldens: it suggests agents but starts none on its own")
        }
        watchPressure()
        idle()
        return model
    }

    private struct Landed: Sendable {
        let loaded: Loaded
        let report: LoadReport
    }

    /// A load, with its checks and its warm-ups, within `loadWithin`. Past it, the router stops for the launch: the load
    /// goes on regardless (mlx-swift-lm reads the weights on GCD threads that never look at cancellation, and a warm-up
    /// pass can't be interrupted), so no second load may start beside it, and the marker stays until it has really ended,
    /// however it ends: a crash in it still leaves the marker for the next launch. Cards are bounded by their own budgets
    /// meanwhile.
    private func load(_ plan: LoadPlan) async throws -> Landed {
        loads += 1
        markerBegin("load")
        let steps = Task { try await self.loadSteps(plan) }
        do {
            let landed = try await TimeLimit.run(within: loadWithin) { try await steps.value }
            markerEnd("load")
            return landed
        } catch is TimeLimit.Exceeded {
            let limit = String(format: "%g", loadWithin)
            let why = "it took more than \(limit) \(limit == "1" ? "second" : "seconds") to load"
            fail(why)
            overrun = Task { [weak self] in
                _ = try? await steps.value
                await self?.overrunEnded()
            }
            throw DecisionError.unavailable(why)
        } catch {
            markerEnd("load")
            throw error
        }
    }

    /// The load the router gave up on has ended, loaded or not: what it made goes, and so does its marker.
    private func overrunEnded() {
        overrun = nil
        markerEnd("load")
        emptyCache()
    }

    private func loadSteps(_ plan: LoadPlan) async throws -> Landed {
        let started = Date()
        // MLX starts here and nowhere earlier: only `ready()` loads, once the folder passed its checks on Apple silicon,
        // so a Mac without the folder, an Intel Mac or a VM never gets this far. The cap goes first, inside the guard (an
        // MLX that can't start on this Mac is a throw) and inside the marker (a crash in it is found next launch).
        guard MLXModels.isSupported else { throw DecisionError.unavailable(Self.words(.thisMac(Self.needsAppleSilicon))) }
        let before = try Self.guarded { () -> Int in
            MLX.Memory.cacheLimit = Self.cacheLimit
            return MLX.Memory.activeMemory
        }
        mlxStarted = true
        // LLMModelFactory directly: the free loadModelContainer reports only the last factory's error.
        let container = try await loader(folder)
        let loadMs = Date().timeIntervalSince(started) * 1000
        let pieces = pieces
        let warmed = try await container.perform { context in
            try Self.guarded { () throws -> Warmed in try Self.warmUp(context, plan: plan, pieces: pieces) }
        }
        let after = try Self.guarded { () -> Int in
            MLX.Memory.clearCache()
            return MLX.Memory.activeMemory
        }
        // At every warm-up the offered letters hold at least half of what the model would say first, or it isn't
        // answering with a letter, and its letters' softmax would look as sure as an answer.
        if let low = warmed.shares.first(where: { !($0 >= Self.letterShareFloor) }) {
            throw Refused(problem: .cantAnswer(Self.notALetter(low)))
        }
        let report = LoadReport(loadMs: loadMs, warmUpMs: warmed.ms, modelType: warmed.modelType, reader: plan.identity.reader, rowsAbout: warmed.rowsAbout,
                                warmUps: warmed.probs, letterShares: warmed.shares, hiddenStateHook: plan.reader == .tev1, checks: warmed.checks)
        let loaded = Loaded(container: container, reader: plan.reader, rows: warmed.rows, letters: plan.letters, frame: plan.frame,
                            resident: Int64(max(0, after - before)), stamp: plan.stamp, identity: plan.identity, generation: plan.generation,
                            warmUps: warmed.probs, shares: warmed.shares)
        return Landed(loaded: loaded, report: report)
    }

    /// What a load's own checks and warm-ups found.
    private struct Warmed: Sendable {
        let rows: RowsBox?
        let probs: [[Double]]
        let shares: [Double]
        let ms: Double
        let modelType: String
        let rowsAbout: String
        let checks: [String]
    }

    /// A load's own checks, then its three warm-ups (RouterQuestions.warmUps) through the model's reader, inside the
    /// guard. Tev1's family: no lm_head, the tied embedding's rows for A to X as float32, and the warm-up prompt starting
    /// and ending as every prompt does. A chat model: thinking off by its own reasoning markers too, where it has them.
    /// Each warm-up gives its probabilities and the offered letters' share of the whole vocabulary's probability at the
    /// first position of the answer, from the model's own logits there (for Tev1's family, once per load, for this alone).
    nonisolated private static func warmUp(_ context: ModelContext, plan: LoadPlan, pieces: Int?) throws -> Warmed {
        var checks: [String] = []
        let tokenizer = context.tokenizer
        var rows: MLXArray?
        var rowsAbout = ""
        switch plan.reader {
        case .tev1:
            guard plan.letters == Tev1Prompt.letterTokenIDs(count: 24) else {
                throw DecisionError.unavailable("its letters A to X aren't one token each, 32 to 55")
            }
            checks.append("the folder check found letters A-X as ids 32-55, and Tev1's special tokens")
            let named = context.model.namedModules()
            guard !named.contains(where: { $0.0.hasSuffix("lm_head") }) else {
                throw DecisionError.unavailable("it has an lm_head, which this Binders can't read choices from")
            }
            guard let entry = named.first(where: { $0.0 == "language_model.model.embed_tokens" }), let embedding = entry.1 as? Embedding else {
                throw DecisionError.unavailable("its embed_tokens can't be read")
            }
            let found = embedding(MLXArray(Tev1Prompt.letterTokenIDs(count: 24).map { Int32($0) })).asType(.float32)
            eval(found)
            rows = found
            rowsAbout = "\(entry.0) (\(type(of: embedding)))"
            checks.append("letter rows from \(rowsAbout)")
        case .chat, .jev:
            guard let frame = plan.frame else { throw DecisionError.unavailable(ChatFrame.Problem.noTemplate.words) }
            checks.append("the folder check found letters A-X as \(plan.letters.count) tokens of their own, and the chat template's frame")
            if let reasoning = context.configuration.reasoningConfig {
                guard let ids = encodeAll(tokenizer, frame.prompt(RouterQuestions.warmUps[0])) else { throw unencodable }
                let tail = tokenizer.decode(tokenIds: Array(ids.suffix(16)), skipSpecialTokens: false)
                if ChatFrame.thinkingOpen(tail, open: reasoning.startDelimiter, close: reasoning.endDelimiter) {
                    throw Refused(problem: .cantAnswer(ChatFrame.Problem.thinks.words))
                }
                checks.append("thinking is off where its answer begins, by its own markers (\(reasoning.startDelimiter) \(reasoning.endDelimiter))")
            }
        }
        let started = Date()
        var probs: [[Double]] = []
        var shares: [Double] = []
        for (index, question) in RouterQuestions.warmUps.enumerated() {
            guard let prompt = plan.reader.prompt(question, frame: plan.frame) else { throw DecisionError.refused }
            let count = question.options.count
            let offered = Array(plan.letters.prefix(count))
            switch plan.reader {
            case .tev1:
                guard let rows else { throw unreadable }
                let ids = tokenizer.encode(text: prompt, addSpecialTokens: false)
                if index == 0 {
                    guard Array(ids.prefix(3)) == promptStart, Array(ids.suffix(5)) == promptEnd else {
                        throw DecisionError.unavailable("its tokenizer doesn't read the prompt's template as Tev1's")
                    }
                    checks.append("the warm-up prompt starts and ends as every prompt does")
                    if let pieces, pieces > 0 {
                        checks.append("the first warm-up runs in \((ids.count + pieces - 1) / pieces) pieces of \(pieces) tokens (\(ids.count) tokens)")
                    }
                }
                let read = try letterLogits(context.model, rows: rows, ids: ids, count: count, pieces: pieces, shareOf: offered)
                probs.append(RouterMath.softmax(read.logits))
                shares.append(read.share ?? 0)
            case .chat, .jev:
                guard let ids = encodeAll(tokenizer, prompt) else { throw unencodable }
                let read = try chatLetterLogits(context.model, ids: ids, letters: plan.letters, count: count, pieces: pieces, share: true)
                probs.append(RouterMath.softmax(read.logits))
                shares.append(read.share ?? 0)
            }
        }
        if plan.reader == .tev1 { checks.append("the hidden state comes from the model (mtpEmitFlagKey)") }
        checks.append("three warm-ups, the letters' share of what it would say first: "
            + shares.map { String(format: "%.4f", $0) }.joined(separator: ", "))
        return Warmed(rows: rows.map(RowsBox.init), probs: probs, shares: shares, ms: Date().timeIntervalSince(started) * 1000,
                      modelType: String(describing: type(of: context.model)), rowsAbout: rowsAbout, checks: checks)
    }

    /// Lets the weights go after `idleMinutes` without a decision; 0 keeps them.
    private func idle() {
        unloadTask?.cancel()
        unloadTask = nil
        guard idleMinutes > 0 else {
            unloadAt = nil
            return
        }
        let seconds = TimeInterval(idleMinutes * 60)
        unloadAt = Date().addingTimeInterval(seconds)
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    /// Under memory pressure, the weights go at once.
    private func watchPressure() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.unload() }
        }
        source.resume()
        pressure = source
    }

    // MARK: The marker

    /// A load or a pass begins: the marker says so, with the step.
    private func markerBegin(_ step: String) {
        markerSteps.append(step)
        writeMarkerFile(step)
    }

    /// One ends: the marker goes once nothing it stands for is under way.
    private func markerEnd(_ step: String) {
        if let index = markerSteps.lastIndex(of: step) { markerSteps.remove(at: index) }
        if let last = markerSteps.last {
            writeMarkerFile(last)
        } else {
            removeMarkerFile()
        }
    }

    /// While Binders quits, the step is marked as a quit ("load quit"): the next launch passes over it.
    private func writeMarkerFile(_ step: String) {
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((quitting ? step + Self.quitSuffix : step).utf8).write(to: marker, options: .atomic)
    }

    private func removeMarkerFile() {
        try? FileManager.default.removeItem(at: marker)
    }

    // MARK: The pass itself

    /// MLX errors inside `body` become a throw (`DecisionError.mlx`) rather than ending Binders: every router step on the
    /// router's own task runs inside it. The load's own threads are out of its reach (mlx-swift-lm loads weights on GCD
    /// threads), which is what the folder checks and the marker are for.
    nonisolated static func guarded<R>(_ body: () throws -> R) throws -> R {
        do {
            return try MLX.withError { try body() }
        } catch let error as MLX.MLXError {
            switch error {
            case .caught(let message): throw DecisionError.mlx(message)
            }
        }
    }

    /// Tev1's family (`tev1.1/256`), lane R1's path unchanged: the offered letters' logits at the last position, in
    /// float32, the prompt in `pieces`-token pieces through the model's cache (the path generation's prefill takes), only
    /// the last asking for the hidden state; or, with `pieces` nil, the whole prompt in one pass. Throws when the model
    /// doesn't publish its hidden state: never a fall back to the full head. With `shareOf`, a load's warm-up also reads
    /// the offered letters' share of the whole vocabulary from the model's own logits at that position, after the letters
    /// were evaluated, so their numbers are a card's.
    nonisolated static func letterLogits(_ model: any LanguageModel, rows: MLXArray, ids: [Int], count: Int, pieces: Int?,
                                         shareOf offered: [Int]? = nil) throws -> (logits: [Double], share: Double?) {
        guard !ids.isEmpty, (1...24).contains(count) else { throw DecisionError.refused }
        let tokens = MLXArray(ids.map { Int32($0) })
        var state = LMOutput.State()
        state[mtpEmitFlagKey] = true
        let hidden: MLXArray
        // The model's own logits at the last position, left lazy: evaluated for a warm-up's share alone.
        let head: MLXArray
        if let pieces, pieces > 0 {
            let cache = try model.newCache(parameters: nil)
            var start = 0
            while ids.count - start > pieces {
                try Task.checkCancellation()
                _ = model(LMInput.Text(tokens: tokens[start ..< start + pieces].reshaped(1, pieces)), cache: cache, state: nil)
                eval(cache.flatMap(\.state))   // the piece's logits stay lazy and are dropped
                start += pieces
            }
            let rest = ids.count - start
            let output = model(LMInput.Text(tokens: tokens[start...].reshaped(1, rest)), cache: cache, state: state)
            guard let published = output.state?[mtpLastHiddenStatesKey] else { throw unreadable }
            hidden = published[0, rest - 1]
            head = output.logits[0, rest - 1]
        } else {
            let output = model(LMInput.Text(tokens: tokens.reshaped(1, ids.count)), cache: nil, state: state)
            guard let published = output.state?[mtpLastHiddenStatesKey] else { throw unreadable }
            hidden = published[0, ids.count - 1]
            head = output.logits[0, ids.count - 1]
        }
        let letters = matmul(rows[0 ..< count], hidden.asType(.float32))
        eval(letters)
        let logits = letters.asArray(Float.self).map(Double.init)
        guard let offered else { return (logits, nil) }
        return (logits, try share(of: offered, in: head))
    }

    /// The chat reader (`chat.1/256`): the offered letters' logits at the first position of the answer. Every prompt
    /// token but the last goes through the model's cache in `pieces`-token pieces, their logits left lazy and never
    /// evaluated; then the last token alone, so the model's head runs for that one position. With `share`, also the
    /// offered letters' share of the whole vocabulary's probability there (one logsumexp over the row the head made
    /// anyway). Throws if the logits don't reach the letters' ids, or aren't numbers.
    nonisolated static func chatLetterLogits(_ model: any LanguageModel, ids: [Int], letters: [Int], count: Int, pieces: Int?,
                                             share: Bool) throws -> (logits: [Double], share: Double?) {
        guard ids.count >= 2, Tev1Prompt.options.contains(count), letters.count >= count else { throw DecisionError.refused }
        let offered = Array(letters[0 ..< count])
        let tokens = MLXArray(ids.map { Int32($0) })
        let cache = try model.newCache(parameters: nil)
        let body = ids.count - 1
        let step = max(1, pieces ?? body)
        var start = 0
        while start < body {
            try Task.checkCancellation()
            let end = min(start + step, body)
            _ = model(LMInput.Text(tokens: tokens[start ..< end].reshaped(1, end - start)), cache: cache, state: nil)
            eval(cache.flatMap(\.state))
            start = end
        }
        let output = model(LMInput.Text(tokens: tokens[body...].reshaped(1, 1)), cache: cache, state: nil)
        let last = output.logits[0, 0].asType(.float32)
        guard last.ndim == 1, let highest = offered.max(), last.dim(0) > highest else { throw unreadable }
        let picked = take(last, MLXArray(offered.map { Int32($0) }))
        eval(picked)
        let logits = picked.asArray(Float.self).map(Double.init)
        guard logits.allSatisfy(\.isFinite) else { throw unreadable }
        return (logits, share ? try Self.share(of: offered, in: last) : nil)
    }

    /// The offered letters' share of the whole vocabulary's probability, from the model's own logits at one position, the
    /// row summed in Double (a load's warm-ups alone ask, three rows a load).
    nonisolated static func share(of offered: [Int], in logits: MLXArray) throws -> Double {
        let row = logits.asType(.float32)
        guard row.ndim == 1, let highest = offered.max(), row.dim(0) > highest else { throw unreadable }
        eval(row)
        let values = row.asArray(Float.self).map(Double.init)
        guard let top = values.max(), top.isFinite else { throw unreadable }
        let whole = top + log(values.reduce(0.0) { $0 + exp($1 - top) })
        let share = offered.reduce(0.0) { $0 + exp(values[$1] - whole) }
        guard share.isFinite else { throw unreadable }
        return share
    }

    /// A prompt's ids as `encode(text:addSpecialTokens: false)` gives them, or nil where encoding would end Binders: a
    /// piece of text its vocabulary has no id for (swift-transformers force-unwraps each id). The folder check refused any
    /// tokenizer that can't read a wide probe of characters; this covers a card's own. Tev1's family reads bytes.
    nonisolated static func encodeAll(_ tokenizer: any MLXLMCommon.Tokenizer, _ text: String) -> [Int]? {
        guard let bridge = tokenizer as? RouterTokenizerBridge else { return tokenizer.encode(text: text, addSpecialTokens: false) }
        return bridge.encodeAll(text)
    }

    static let unreadable = DecisionError.unavailable("this Binders can't read the model's choices")
    static let unencodable = DecisionError.unavailable("its tokenizer can't read every character of this card")

    // MARK: For the dev tools

    /// Loads it now, for the dev tools, and says what the load found.
    func loadNow() async throws -> LoadReport {
        _ = try await ready()
        return report
    }

    /// One question's token ids, letter logits and probabilities, timed: for the dev tools, which hold them to fixtures.
    func probe(_ question: DecisionQuestion) async throws -> (ids: [Int], logits: [Double], probs: [Double], ms: Double) {
        let model = try await ready()
        let started = Date()
        let result = try await pass(question, on: model)
        return (result.ids, result.logits, result.probs, Date().timeIntervalSince(started) * 1000)
    }

    /// The token ids a prompt encodes to, without running the model.
    func encode(_ prompt: String) async throws -> [Int] {
        let model = try await ready()
        return await model.container.perform { context in context.tokenizer.encode(text: prompt, addSpecialTokens: false) }
    }

    /// A step that fails inside the guard the decisions use (a broadcast of a [2, 5] and a [3, 5] array), for the
    /// self-test alone, on Apple silicon: it calls MLX, and must throw, and Binders go on.
    nonisolated static func failingStep() throws {
        _ = try guarded { () -> Bool in
            let a = MLXArray(0 ..< 10, [2, 5])
            let b = MLXArray(0 ..< 15, [3, 5])
            let c = a + b
            eval(c)
            return true
        }
    }

    // MARK: This Mac

    /// Memory free or reclaimable now: free, inactive and purgeable pages.
    nonisolated static func reclaimableMemory() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return .max }
        let page = UInt64(vm_kernel_page_size)
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)) * page
    }

    /// The process's phys_footprint, what Activity Monitor calls Memory.
    nonisolated static func physFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    /// What this Mac lacks for a decision model inside Binders.
    static let needsAppleSilicon = "Built-in decision models need a Mac with Apple silicon"
    static var needsMemory: String {
        "Built-in decision models need a Mac with 16 GB of memory; this one has \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB"
    }

    /// Why it isn't usable, in words for the log and the status row.
    nonisolated static func words(_ problem: DecisionBackendState.Unavailable) -> String {
        switch problem {
        case .noFolder: "The decision model isn't on this Mac."
        case .notDownloaded: "The decision model isn't downloaded yet."
        case .thisMac(let why): "\(why)."
        case .folder(let why): "Its folder isn't usable: \(why)."
        case .cantAnswer(let why): "It can't sort cards: \(why)."
        case .address(let why), .unreachable(let why): why
        }
    }
}

/// The letter rows, which aren't Sendable, kept beside the container that made them and only used through it.
private final class RowsBox: @unchecked Sendable {
    let array: MLXArray
    init(_ array: MLXArray) { self.array = array }
}

/// Reads a decision model folder's tokenizer. Tev1's conversions' tokenizer_config.json names `Qwen3_5Tokenizer`, which
/// swift-transformers refuses when strict, as the chat model's loader is; not strict, it uses the BPE model it maps
/// `Qwen2Tokenizer` to. The parsed tokenizer is kept for the folder (keyed by tokenizer.json's size and date), so a load
/// after an idle unload takes about 0.09 s instead of 0.88 s. The folder check read the same file the same way, in a
/// process of its own, before any load.
struct RouterTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let file = directory.appendingPathComponent("tokenizer.json")
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(directory.standardizedFileURL.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let kept = RouterTokenizers.shared.tokenizer(for: key) { return kept }
        let tokenizer = RouterTokenizerBridge(try await AutoTokenizer.from(modelFolder: directory, strict: false))
        RouterTokenizers.shared.keep(tokenizer, for: key)
        return tokenizer
    }
}

/// The one tokenizer kept, for the folder it came from.
private final class RouterTokenizers: @unchecked Sendable {
    static let shared = RouterTokenizers()
    private let lock = NSLock()
    private var kept: (key: String, tokenizer: any MLXLMCommon.Tokenizer)?

    func tokenizer(for key: String) -> (any MLXLMCommon.Tokenizer)? {
        lock.withLock { kept?.key == key ? kept?.tokenizer : nil }
    }

    func keep(_ tokenizer: any MLXLMCommon.Tokenizer, for key: String) {
        lock.withLock { kept = (key, tokenizer) }
    }
}

/// swift-transformers' tokenizer as mlx-swift-lm's, as MLXClient's bridge does it.
private struct RouterTokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    /// The ids `encode(text:addSpecialTokens: false)` gives, or nil when a token of the text has no id, where `encode`
    /// would end the process.
    func encodeAll(_ text: String) -> [Int]? {
        guard upstream.tokenize(text: text).allSatisfy({ upstream.convertTokenToId($0) != nil }) else { return nil }
        return upstream.encode(text: text, addSpecialTokens: false)
    }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
