import CryptoKit
import Darwin
import Foundation
import Observation
import BindersKit

/// The decision model chosen in Settings → AI, as a backend, with its bands. CardRouter asks it on every card; Settings
/// shows it; the measure runs here, and is kept here. Nothing else knows which model it is: the router gets answers and
/// bands, never a model's name.
///
/// The choice is AppSettings.decisionModel, parsed (DecisionChoice): Tev1 0.8B until you choose, on Apple silicon, from
/// lane R1's folder and with its marker, so a Mac that ran R1 sorts exactly as it did; Off on an Intel Mac. A switch takes
/// effect for the next card: the old backend is retired (its memory goes, and a load under way is dropped when it lands),
/// and nothing starts on its own until the new model's bands are known. The bands come from the model's fingerprint and
/// reader (DecisionBands.resolve): a measure on this Mac, else the built-in entry for Tev1 bf16, else the bands for a model
/// with no measure, which name agents and start none.
@MainActor
@Observable
final class DecisionModels {
    static let shared = DecisionModels()

    /// AppSettings.decisionModel, parsed: Off on an Intel Mac whatever it says.
    private(set) var choice: DecisionChoice
    /// The chosen model's backend; nil for Off.
    private(set) var backend: (any DecisionBackend)?
    /// The bands for the backend's model, once its identity is known.
    private(set) var resolved: ResolvedBands?
    /// The measure under way and how far it's got; nil when none runs.
    private(set) var measuring: MeasureProgress?
    /// Why the last measure stopped or didn't begin, in row E's words; nil once one finished, and before any.
    private(set) var lastMeasureProblem: String?
    /// How many measures have ended, kept or not: Settings looks at the model again when it changes.
    private(set) var measuresEnded = 0
    /// decision-measures.json.
    let measures: DecisionMeasureStore
    /// decision-fingerprints.json.
    let fingerprints: FolderFingerprints
    /// Makes the backend for a choice; the self-test puts stand-ins here.
    @ObservationIgnored var makeBackend: (DecisionChoice) -> (any DecisionBackend)?
    /// The backend switched away from last, kept so that choosing it again revives the same one: a choice never has two
    /// backends, with two loads and one marker between them.
    @ObservationIgnored private var previous: (choice: DecisionChoice, backend: any DecisionBackend)?
    /// The last switch's retire and revive, in order: each switch waits for the one before, and every question about the
    /// bands waits for them, so a backend chosen again is revived before it's asked.
    @ObservationIgnored private var switching: Task<Void, Never>?
    /// The measure under way, and why it's being stopped (Cancel, a switch, Delete, a quit), said before it's cancelled.
    @ObservationIgnored private var measureTask: Task<DecisionMeasureRun.Result?, Never>?
    @ObservationIgnored private var measureStop: String?
    /// Binders is quitting: no measure begins.
    @ObservationIgnored private var quitting = false

    init(choice: DecisionChoice? = nil, measures: DecisionMeasureStore = .shared, fingerprints: FolderFingerprints = .shared,
         makeBackend: ((DecisionChoice) -> (any DecisionBackend)?)? = nil) {
        let choice = choice ?? DecisionChoice(stored: AppSettings.shared.decisionModel, appleSilicon: MLXModels.isSupported)
        let make = makeBackend ?? { Self.backend(for: $0, fingerprints: fingerprints) }
        self.choice = choice
        self.measures = measures
        self.fingerprints = fingerprints
        self.makeBackend = make
        // Making it reads the setting and makes the backend, which touches no MLX and no file beyond a folder listing.
        backend = make(choice)
        if let backend { Self.idle(backend) }
    }

    /// At launch: the chosen model's identity and bands, worked out in the background ten seconds on (on a Mac that ran
    /// R1, the folder's one-time hash), so neither launch nor the first card waits on them in the usual case. A card that
    /// comes sooner waits for them inside its own time.
    func checkSoon() {
        Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            _ = await self?.bands(by: .now + .seconds(60))
        }
    }

    /// A choice made in Settings, for the next card. The same choice again changes nothing. A measure under way stops and
    /// keeps nothing. The backend switched away from is retired: it starts nothing more, a load under way is dropped when it
    /// lands, and its memory goes; a pass still running finishes first (MLX can't be interrupted), and the card it was for
    /// is held to its old bands and never started (confirm). Choosing that model again revives the same backend. The new
    /// model's bands are worked out in the background, so Settings can show them before the first card.
    func choose(_ choice: DecisionChoice) {
        guard choice != self.choice else { return }
        stopMeasure(DecisionMeasureRun.switched)
        // Why the last measure stopped was about the model switched away from; one stopping now says the switch stopped it.
        if measureTask == nil { lastMeasureProblem = nil }
        let old = backend.map { (choice: self.choice, backend: $0) }
        var revived: (any DecisionBackend)?
        let next: (any DecisionBackend)?
        if let previous, previous.choice == choice {
            next = previous.backend
            revived = previous.backend
        } else {
            next = makeBackend(choice)
        }
        // Free its memory as it's set now, also for the backend chosen again.
        if let next { Self.idle(next) }
        previous = old
        self.choice = choice
        backend = next
        resolved = nil
        let before = switching
        switching = Task {
            await before?.value
            await old?.backend.retire()
            await revived?.revive()
        }
        if next != nil {
            Task { _ = await self.bands(by: .now + .seconds(30)) }
        }
    }

    /// Once the last switch's retire and revive have happened.
    func settled() async {
        await switching?.value
    }

    /// The recent choices Also on this Mac lists, at most.
    static let recentChoices = 6

    /// A choice made in Settings → AI: kept in Binders' preferences, first among the recent ones for Also on this Mac (Off
    /// and Tev1 0.8B aren't kept there, as the menu always has them), and chosen for the next card.
    func use(_ choice: DecisionChoice) {
        let settings = AppSettings.shared
        settings.decisionModel = choice.stored
        if choice != .off, choice != .tev1 {
            settings.decisionModelsUsed = Array(([choice.stored] + settings.decisionModelsUsed.filter { $0 != choice.stored }).prefix(Self.recentChoices))
        }
        choose(choice)
    }

    /// Another Hugging Face Model…'s Use: the name, trimmed, chosen. Nil when it was, else why not in row A's words, which
    /// row A shows until the next choice. A name taken for Tev1 0.8B isn't stored, as Binders doesn't download Tev1 until
    /// its weights' licence is published; a name without its owner would be read as no model at all.
    func useHuggingFace(_ typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if ModelNames.isTev1(name) { return MLXModels.tev1Refused }
        guard case .huggingFace = DecisionChoice(stored: name, appleSilicon: true), ModelNames.isRepoName(name) else { return Self.needsOwner }
        use(.huggingFace(name))
        return nil
    }

    static let needsOwner = "Type the model's Hugging Face name with its owner, such as mlx-community/Qwen3.5-4B-MLX-4bit."

    /// A server Binders measured, whose probes now answer as another model: its last measure at that address.
    func formerMeasure(of identity: DecisionIdentity) -> DecisionMeasure? {
        guard let server = identity.server else { return nil }
        return measures.all.measures.last { $0.server?.address == server.address }
    }

    /// The bands for a backend's model (the router's override in the self-tests), once its identity is known by
    /// `deadline`; nil until then. The backend is given the goldens those bands were recorded with, so its warm-ups are
    /// held to the right numbers.
    func bands(for backend: any DecisionBackend, by deadline: ContinuousClock.Instant) async -> ResolvedBands? {
        await settled()
        guard let identity = await backend.identity(by: deadline) else { return nil }
        let found = DecisionBands.resolve(identity, measures: measures.all)
        if backend === self.backend {
            if found != resolved { await backend.setGolden(found.golden) }
            // A switch meanwhile leaves the new one's alone.
            if backend === self.backend { resolved = found }
        } else {
            await backend.setGolden(found.golden)
        }
        return found
    }

    /// The bands for the chosen model.
    func bands(by deadline: ContinuousClock.Instant) async -> ResolvedBands? {
        guard let backend else { return nil }
        return await bands(for: backend, by: deadline)
    }

    /// Whether an agent you let start on cards Binders sends it can start now: a model chosen and usable, bands with a start
    /// level (built in, or from a measure that found one), and its numbers not found to differ this launch. Before the first
    /// load nothing is known to differ, as in R1.
    func startsPossible() async -> Bool {
        guard let backend, await backend.state().isUsable, let resolved = await bands(by: .now + .seconds(2)),
              resolved.bands.start != nil else { return false }
        return await !backend.numbersDiffer()
    }

    /// Why nothing starts on its own now, as a clause for the start switch's footer and alert and for Sorting new cards:
    /// the first reason that applies, or nil when an agent can start.
    func whyNoStarts() async -> String? {
        guard let backend else { return "the decision model is off" }
        let name = Self.name(choice)
        let state = await backend.state()
        if state == .checking { return "Binders is still checking \(name)" }
        guard state.isUsable else { return "\(name) can't sort cards now" }
        guard let resolved = await bands(by: .now + .seconds(2)) else { return "Binders is still checking \(name)" }
        if resolved.changed { return "\(name)'s measure was changed outside Binders, so Binders reads it as not measured" }
        if resolved.source == .unmeasured {
            // A server Binders measured whose probes no longer match: another model answers there now.
            if formerMeasure(of: resolved.identity) != nil { return "\(name)'s answers differ from when it was measured" }
            return "\(name) hasn't been measured, and only a measured model starts agents"
        }
        if resolved.bands.start == nil {
            if resolved.verdict?.tookStart != true, resolved.measure?.noStart == .severalModels {
                return "\(name) answered with more than one model when it was measured"
            }
            return "\(name)'s measure found no level at which it started only the right agents, often enough to trust"
        }
        if await backend.numbersDiffer() { return "\(name)'s numbers on this Mac differ from the ones it was measured with" }
        return nil
    }

    /// Auto's level for the chosen model now, for each moment heard in Auto (RouterRules.AutoCheck.levelNow): a model
    /// chosen and usable, bands with an Auto level (built in, or from a measure that found one), and its numbers not found
    /// to differ this launch, as for starts. Nil otherwise: Auto hands nothing over.
    func autoLevel() async -> Double? {
        guard let backend, await backend.state().isUsable, let resolved = await bands(by: .now + .seconds(2)),
              let level = resolved.bands.auto else { return nil }
        return await backend.numbersDiffer() ? nil : level
    }

    /// Whether Auto can hand anything over now, for list_agents and Settings: a model chosen and usable, bands with an Auto
    /// level, its numbers not found to differ this launch (`autoLevel`).
    func autoPossible() async -> Bool {
        await autoLevel() != nil
    }

    /// What Auto can do now, as list_agents tells an iPhone in Auto's reach: hands over, at what level, with which model,
    /// or why not. The model by its name in Settings → AI, never a path.
    func autoReach() async -> AutoReach {
        let model = backend == nil ? nil : Self.name(choice)
        if let level = await autoLevel() { return AutoReach(handsOver: true, model: model, level: level) }
        return AutoReach(handsOver: false, why: (await whyNoAuto() ?? .noLevel).rawValue, model: model)
    }

    /// Why Auto hands nothing over now, for the moment being decided: the first reason that applies, in the order
    /// `whyNoStarts` asks, or nil when it can. Asked for each moment, never kept, so a line never names a reason that has
    /// gone since. A record changed outside Binders is the bands' own reason (ResolvedBands.whyNoAuto). The words are
    /// AutoText.macWhy's.
    func whyNoAuto() async -> AutoReach.Why? {
        guard let backend else { return .off }
        let state = await backend.state()
        if state == .checking { return .checking }
        guard state.isUsable else { return .unusable }
        guard let resolved = await bands(by: .now + .seconds(2)) else { return .checking }
        if let why = resolved.whyNoAuto { return why }
        if await backend.numbersDiffer() { return .numbers }
        return nil
    }

    /// Right before a start, after the decision: nil to go ahead, else why not. The answer's backend must still be the one
    /// chosen (a switch since the decision means no start), and still the model its identity names (MLX: the files it was
    /// read from; a server: its fields and probes asked again now). An answer from a backend the router was given in place
    /// of the chosen one (the self-tests' override) never starts.
    func confirm(_ answer: CardRouter.ModelAnswer, by deadline: ContinuousClock.Instant) async -> RouterRules.NotStarted? {
        guard let backend, answer.backend === backend else { return .modelChanged }
        // A server's card answered by a model its probes didn't reach (Laya's other checkpoint, or another model now behind
        // the port) files and names, but starts nothing; the backend is already probing it again.
        if let server = answer.identity.server, !server.reached(answer.answeredBy) { return .modelChanged }
        switch await backend.stillSame(answer.identity, by: deadline) {
        case .same: break
        case .changed: return .modelChanged
        case .notConfirmed: return .notConfirmed
        }
        guard let current = self.backend, current === answer.backend else { return .modelChanged }
        return nil
    }

    /// Delete, for a model Binders downloaded: every backend kept for its folder is retired first (a load under way is
    /// dropped when it lands, and the container in memory goes), then the folder goes to the Trash, with its measures and
    /// its fingerprint. The choice stays; nothing can load until it's downloaded again, so the backends are revived for then.
    func deleteDownloaded() async {
        await settled()
        guard case .huggingFace(let id) = choice, let folder = Self.folder(for: choice) else { return }
        stopMeasure(DecisionMeasureRun.deleted)
        let fingerprint = fingerprints.entry(for: folder)?.fingerprint ?? resolved?.identity.fingerprint
        var affected: [any DecisionBackend] = backend.map { [$0] } ?? []
        if let previous, Self.folder(for: previous.choice) == folder { affected.append(previous.backend) }
        for kept in affected { await kept.retire() }
        MLXModels.shared.delete(id)
        if let fingerprint { measures.remove(fingerprint: fingerprint) }
        fingerprints.forget(folder)
        resolved = nil
        for kept in affected { await kept.revive() }
    }

    /// Binders is quitting (applicationShouldTerminate, which a logout and an update go through too): a measure stops and
    /// keeps nothing, the backend starts nothing more, a pass under way may finish within `within` and takes its marker
    /// with it, and a marker still there then is marked as a quit, so the next launch doesn't start the model failed.
    /// Nothing waits when nothing is under way.
    func prepareForQuit(within: Duration) async {
        quitting = true
        let deadline = ContinuousClock.now + within
        stopMeasure(DecisionMeasureRun.quit)
        await backend?.prepareForQuit(within: within)
        if let measureTask {
            let left = LoopbackHTTP.seconds(ContinuousClock.now.duration(to: deadline))
            _ = try? await TimeLimit.run(within: left) { await measureTask.value }
        }
    }

    // MARK: The measure

    /// Measure: the chosen model sorts the made-up cards that come with Binders (DecisionMeasureRun), and what it finds is
    /// kept for its fingerprint and reader, its bands worked out again and its goldens given to it. Refused while Off,
    /// while one runs and while Binders quits; a model that can't sort cards now isn't measured, and row E says why. It
    /// goes on with Settings closed: DecisionModels owns it. `bench`: the dev tool's own, else the bundled copy.
    /// `onProgress`: each call done. The task gives the result once it's kept, nil when it stopped.
    @discardableResult
    func measure(bench: RouterBench.Data? = nil, onProgress: (@MainActor (Int) -> Void)? = nil) -> Task<DecisionMeasureRun.Result?, Never>? {
        guard measuring == nil, !quitting, let backend else { return nil }
        let data: RouterBench.Data
        do {
            data = try bench ?? DecisionMeasureRun.bundledBench()
        } catch {
            lastMeasureProblem = DecisionMeasureRun.words(error)
            return nil
        }
        lastMeasureProblem = nil
        measureStop = nil
        measuring = MeasureProgress(done: 0, of: DecisionMeasureRun.calls, started: nil)
        let measures = self.measures
        let task = Task { [weak self] () -> DecisionMeasureRun.Result? in
            let ran: Result<DecisionMeasureRun.Result, Error>
            do {
                // A verdict that took starting away holds for starts; one that raised Auto's level or took it away, for
                // Auto's (a verdict may hold either part alone).
                ran = .success(try await DecisionMeasureRun.run(backend, bench: data, testBefore: { measures.all.verdict(for: $0)?.tookStart == true },
                                                                autoBefore: { measures.all.verdict(for: $0)?.autoBefore }) { done, started in
                    await MainActor.run {
                        self?.measuring = MeasureProgress(done: done, of: DecisionMeasureRun.calls, started: started)
                        onProgress?(done)
                    }
                })
            } catch {
                ran = .failure(error)
            }
            return await self?.measureEnded(ran, backend: backend)
        }
        measureTask = task
        return task
    }

    /// Cancel: the pass under way finishes, and nothing is kept.
    func cancelMeasure() {
        stopMeasure(DecisionMeasureRun.cancelled)
    }

    /// The measure under way stops, for the reason given, and keeps nothing.
    private func stopMeasure(_ why: String) {
        guard let measureTask else { return }
        if measureStop == nil { measureStop = why }
        measureTask.cancel()
    }

    /// A measure that finished is kept for the model it measured, and its bands are worked out again; one that stopped
    /// keeps nothing, and says why.
    private func measureEnded(_ ran: Result<DecisionMeasureRun.Result, Error>, backend: any DecisionBackend) async -> DecisionMeasureRun.Result? {
        defer {
            measuring = nil
            measureTask = nil
            measureStop = nil
            measuresEnded += 1
        }
        if let measureStop {
            lastMeasureProblem = measureStop
            return nil
        }
        switch ran {
        case .failure(let error):
            lastMeasureProblem = DecisionMeasureRun.words(error)
            return nil
        case .success(let result):
            guard backend === self.backend, !quitting else {
                lastMeasureProblem = DecisionMeasureRun.switched
                return nil
            }
            measures.keep(result.measure, verdict: result.verdict)
            resolved = nil
            _ = await bands(for: backend, by: .now + .seconds(10))
            return result
        }
    }

    private static func idle(_ backend: any DecisionBackend) {
        let minutes = AppSettings.shared.decisionIdleMinutes
        Task { await backend.setIdle(minutes: minutes) }
    }

    // MARK: Which backend for which choice

    /// The backend for a choice: Tev1 0.8B from lane R1's folder with R1's marker, so a crash under R1 still counts; a
    /// downloaded model or a folder with a marker of its own, so a crash in one model starts that model failed at the next
    /// launch and not the others; a decision server on this Mac through the Jev API (JevDecisionBackend), on any Mac, as
    /// nothing of it runs in Binders. Off has none, and an Intel Mac never gets an MLX backend.
    static func backend(for choice: DecisionChoice, fingerprints: FolderFingerprints = .shared) -> (any DecisionBackend)? {
        if case .server(let address) = choice { return JevDecisionBackend(address: address) }
        #if arch(arm64)
        guard let folder = folder(for: choice) else { return nil }
        switch choice {
        case .off, .server:
            return nil
        case .tev1:
            return MLXDecisionBackend(folder: folder, kind: .tev1, marker: marker(for: choice), fingerprints: fingerprints)
        case .huggingFace:
            return MLXDecisionBackend(folder: folder, kind: .downloaded, marker: marker(for: choice), fingerprints: fingerprints)
        case .folder:
            return MLXDecisionBackend(folder: folder, kind: .folder, marker: marker(for: choice), fingerprints: fingerprints)
        }
        #else
        return nil
        #endif
    }

    /// Where an MLX choice's model is: Tev1's folder in Models, a download in Models/MLX/<org--name>, or the folder chosen,
    /// with ~ expanded.
    static func folder(for choice: DecisionChoice) -> URL? {
        switch choice {
        case .tev1: MLXDecisionBackend.tev1Folder.standardizedFileURL
        case .huggingFace(let id): MLXModels.folder.appendingPathComponent(MLXModels.folderName(id), isDirectory: true).standardizedFileURL
        case .folder(let path): URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        case .off, .server: nil
        }
    }

    /// The file that says a load or a pass is under way: R1's `router-running` for Tev1, else one per choice,
    /// `router-running-<8 hex>` from the SHA-256 of what Settings stores for it.
    static func marker(for choice: DecisionChoice) -> URL {
        guard choice != .tev1 else { return AppPaths.support.appendingPathComponent("router-running") }
        let hex = SHA256.hash(data: Data(choice.stored.utf8)).map { String(format: "%02x", $0) }.joined()
        return AppPaths.support.appendingPathComponent("router-running-\(hex.prefix(8))")
    }

    /// The choice by the name people recognise: Tev1 0.8B, a Hugging Face model's name after its slash, a folder's last
    /// component, the server's address and port, or Off.
    static func name(_ choice: DecisionChoice) -> String {
        switch choice {
        case .off: "Off"
        case .tev1: "Tev1 0.8B"
        case .huggingFace(let id): id.split(separator: "/").last.map(String.init) ?? id
        case .folder(let path): URL(fileURLWithPath: (path as NSString).expandingTildeInPath).lastPathComponent
        case .server(let address): "Server at " + ((try? LoopbackRule.check(address).get())?.display ?? address)
        }
    }
}

// MARK: - Fingerprints, kept

/// decision-fingerprints.json in the data folder: each model folder's fingerprint (DecisionFingerprint.folder), hashed once
/// and kept by the folder's stamp and the app's build, with what the folder check found (DecisionFolderCheck): the reader,
/// the letters' ids, the chat frame, or why it was refused, a crash of the check included. A hit (the same path, stamp and
/// build) costs a stat of each file: no hashing, and no check. At most 16 folders, the least recently used dropped. It
/// holds paths, so it's like the preferences: local, never in the tuning log, never sent anywhere. Shared by DecisionModels
/// and the backends; lock-guarded.
final class FolderFingerprints: @unchecked Sendable {
    static let shared = FolderFingerprints(url: AppPaths.support.appendingPathComponent("decision-fingerprints.json"))
    static let schema = "binders-decision-fingerprints/1"
    static let capacity = 16
    /// Bytes read at a time while hashing: flat memory, and a chance to stop between pieces.
    static let piece = 4 * 1_048_576

    /// One folder as it was hashed and checked.
    struct Entry: Codable, Equatable, Sendable {
        var path: String
        /// The app's build it was worked out with: a new build checks the folder again, as its swift-transformers may
        /// read the tokenizer differently.
        var build: String
        var stamp: String
        var fingerprint: String?
        /// What the folder check found: the reader it was checked for, the letters A to X as token ids, the chat frame.
        var reader: String?
        var letters: [Int]?
        var frame: ChatFrame?
        /// Why the folder check refused it, in row A's words, and of which kind ("folder" or "cantAnswer").
        var problem: String?
        var kind: String?
        var used: Date?

        /// The folder check ran for this stamp and build: it gave the letters, or a refusal.
        var checked: Bool { letters != nil || problem != nil }
    }

    private struct File: Codable {
        var schema: String
        var folders: [Entry]
    }

    /// One counted file of a folder, as its stamp and its hash read it.
    struct CountedFile: Equatable, Sendable {
        var name: String
        var url: URL
        var size: Int64
        var modified: String
        var changed: String
        var inode: UInt64
    }

    let url: URL
    let build: String
    private let lock = NSLock()
    private var entries: [Entry]?
    private var hashing: [String: Task<String?, Never>] = [:]
    private var hashed = 0

    init(url: URL, build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") {
        self.url = url
        self.build = build
    }

    /// For the self-test: how many folders have been hashed (each read whole) since launch.
    var hashes: Int { lock.withLock { hashed } }

    // MARK: Stamps

    /// A folder's counted files (DecisionFingerprint.counts: its weights, config and tokenizer, a link followed to its
    /// file), sorted by their names' UTF-8 bytes; none for a folder that isn't there.
    static func files(in folder: URL) -> [CountedFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var found: [CountedFile] = []
        for name in names {
            let file = folder.appendingPathComponent(name)
            var info = stat()
            guard stat(file.path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG, DecisionFingerprint.counts(name, isDirectory: false) else { continue }
            found.append(CountedFile(name: name, url: file, size: Int64(info.st_size), modified: time(info.st_mtimespec),
                                     changed: time(info.st_ctimespec), inode: UInt64(info.st_ino)))
        }
        return found.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
    }

    /// A folder's stamp: for each counted file, its name, size, modification date, status-change date and inode, one line
    /// each. No app can set a status-change date back, so a file rewritten with its old modification date put back still
    /// changes it, and a copy elsewhere has other inodes. "" for a folder with no counted file.
    static func stamp(of folder: URL) -> String {
        stamp(files(in: folder))
    }

    static func stamp(_ files: [CountedFile]) -> String {
        files.map { "\($0.name) \($0.size) \($0.modified) \($0.changed) \($0.inode)" }.joined(separator: "\n")
    }

    private static func time(_ spec: timespec) -> String {
        "\(spec.tv_sec).\(String(format: "%09ld", spec.tv_nsec))"
    }

    // MARK: Looking up

    /// What's kept for the folder as it is now (its path, its stamp now, and this build), or nil: a stat of each file.
    func entry(for folder: URL) -> Entry? {
        let stamp = Self.stamp(of: folder)
        return stamp.isEmpty ? nil : entry(path: Self.path(folder), stamp: stamp)
    }

    func entry(path: String, stamp: String) -> Entry? {
        lock.withLock {
            loadLocked()
            return entries?.first { $0.path == path && $0.stamp == stamp && $0.build == build }
        }
    }

    /// The folder's fingerprint: kept, or hashed now (once at a time per folder and stamp, in a detached task at utility
    /// priority, so whoever waits isn't holding anything meanwhile), then kept. Nil for a folder with no counted file, or
    /// one that changed while it was read.
    func fingerprint(of folder: URL) async -> String? {
        let path = Self.path(folder)
        let files = Self.files(in: folder)
        let stamp = Self.stamp(files)
        guard !stamp.isEmpty else { return nil }
        if let kept = entry(path: path, stamp: stamp)?.fingerprint { return kept }
        let key = path + "\n" + stamp
        let task: Task<String?, Never> = lock.withLock {
            if let running = hashing[key] { return running }
            hashed += 1
            let task = Task.detached(priority: .utility) { Self.hash(files) }
            hashing[key] = task
            return task
        }
        let found = await task.value
        lock.withLock { hashing[key] = nil }
        // Changed while it was read: what was hashed may be neither the old files nor the new.
        guard let found, Self.stamp(of: folder) == stamp else { return nil }
        update(path: path, stamp: stamp) { $0.fingerprint = found }
        return found
    }

    /// Each file's SHA-256, 4 MiB at a time, then the manifest's: "mlx1-" and 24 hex digits.
    static func hash(_ files: [CountedFile]) -> String? {
        var hashed: [DecisionFingerprint.File] = []
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            var size: Int64 = 0
            var ended = false
            while !ended {
                if Task.isCancelled { return nil }
                let read: Bool = autoreleasepool {
                    do {
                        // Nil, or nothing, at the end of the file.
                        guard let data = try handle.read(upToCount: piece), !data.isEmpty else {
                            ended = true
                            return true
                        }
                        hasher.update(data: data)
                        size += Int64(data.count)
                        return true
                    } catch {
                        return false
                    }
                }
                guard read else { return nil }
            }
            hashed.append(DecisionFingerprint.File(name: file.name, size: size, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()))
        }
        return hashed.isEmpty ? nil : DecisionFingerprint.folder(hashed)
    }

    // MARK: Keeping

    /// Changes what's kept for a folder at a stamp, for this build: one entry per folder, so a new stamp or build replaces
    /// the old one; the least recently used go past 16 folders.
    func update(path: String, stamp: String, _ change: (inout Entry) -> Void) {
        lock.withLock {
            loadLocked()
            var list = entries ?? []
            var entry = list.first { $0.path == path && $0.stamp == stamp && $0.build == build } ?? Entry(path: path, build: build, stamp: stamp)
            change(&entry)
            entry.used = Date()
            list.removeAll { $0.path == path }
            list.append(entry)
            if list.count > Self.capacity {
                list = Array(list.sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }.prefix(Self.capacity))
            }
            entries = list
            writeLocked()
        }
    }

    /// What the folder check found for the folder at a stamp (DecisionFolderCheck): kept with its fingerprint, so a launch
    /// doesn't run the check again, and a folder that ended it is refused from here alone.
    func keepCheck(_ outcome: DecisionFolderCheck.Outcome, reader: DecisionReader, path: String, stamp: String) {
        update(path: path, stamp: stamp) { entry in
            entry.reader = reader.id
            switch outcome {
            case .passed(let letters, let frame):
                entry.letters = letters
                entry.frame = frame
                entry.problem = nil
                entry.kind = nil
            case .refused(let why, let kind):
                entry.problem = why
                entry.kind = kind.rawValue
                entry.letters = nil
                entry.frame = nil
            }
        }
    }

    /// Delete of a downloaded model: nothing kept for its folder.
    func forget(_ folder: URL) {
        let path = Self.path(folder)
        lock.withLock {
            loadLocked()
            entries?.removeAll { $0.path == path }
            writeLocked()
        }
    }

    static func path(_ folder: URL) -> String { folder.standardizedFileURL.path }

    private func loadLocked() {
        guard entries == nil else { return }
        let file = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.iso8601.decode(File.self, from: $0) }
        entries = file?.schema == Self.schema ? file?.folders ?? [] : []
    }

    private func writeLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(File(schema: Self.schema, folders: entries ?? [])) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Measures, kept

/// decision-measures.json in the data folder (DecisionMeasures): the measures made on this Mac, one per model, and the test
/// verdicts that hold. Read once, written whole and atomically. Clear… of the sorting record and Delete all history leave
/// it, as a measure is about the model, not about you; Delete of a downloaded model removes that model's part.
///
/// Sealed (MeasureSeals): each write keeps a SHA-256 of every record, and of the verdicts list, in the Keychain, where an
/// agent that runs as you can't write. Read back, a record whose seal differs, or that has none, was changed outside Binders
/// and reads as not measured; a verdicts list that differs takes starting and Auto away from every model it names. The
/// first time a build with this check reads the file, what has no seal yet is taken as an earlier build wrote it and sealed
/// once (a mark in the Keychain says it's done). The Keychain items are per file, by its path, so each data folder, and
/// each of a self-test's stores, keeps its own.
final class DecisionMeasureStore: @unchecked Sendable {
    static let shared = DecisionMeasureStore(url: AppPaths.support.appendingPathComponent("decision-measures.json"))

    let url: URL
    private let lock = NSLock()
    private var loaded: DecisionMeasures?
    /// The record keys sealed in the Keychain now, so a write clears the seals of records it no longer holds.
    private var sealedKeys: Set<String> = []

    init(url: URL) {
        self.url = url
    }

    /// Everything kept that may be read, as the bands are resolved from it: a record changed outside Binders is apart
    /// (`changed`).
    var all: DecisionMeasures { lock.withLock { loadLocked() } }

    /// A new measure takes the place of the model's last one; a test that took starting away becomes its verdict unless
    /// one holds already.
    func keep(_ measure: DecisionMeasure, verdict: DecisionMeasure.TestVerdict? = nil) {
        lock.withLock {
            var measures = loadLocked()
            measures.keep(measure, verdict: verdict)
            save(measures)
        }
    }

    /// A model's measures and verdicts, under every reader.
    func remove(fingerprint: String) {
        lock.withLock {
            var measures = loadLocked()
            measures.remove(fingerprint: fingerprint)
            save(measures)
        }
    }

    // MARK: Seals

    /// A Keychain item's name for this file: `decision-measure-<16 hex>` per record (the SHA-256 of the file's path and the
    /// record's key), `decision-measures-verdicts-<16 hex>` and `decision-measures-read-<16 hex>` (of the path), named as
    /// AgentRegistry names its items, so a self-test's never touch yours.
    private func keychainKey(_ name: String, record: String? = nil) -> String {
        // The path as the store was given it: standardizing it reads the disk (/private/tmp is /tmp once the file exists).
        let hex = DecisionFingerprint.sha256Hex(url.absoluteURL.path + (record.map { "\n" + $0 } ?? ""))
        return AgentRegistry.keychainKey("\(name)-\(hex.prefix(16))")
    }

    private func sealKey(_ record: String) -> String { keychainKey("decision-measure", record: record) }
    private var verdictsKey: String { keychainKey("decision-measures-verdicts") }
    private var firstReadKey: String { keychainKey("decision-measures-read") }

    private func loadLocked() -> DecisionMeasures {
        if let loaded { return loaded }
        let file = (try? Data(contentsOf: url)).flatMap(DecisionMeasures.decode) ?? DecisionMeasures()
        let firstRead = Keychain.read(firstReadKey) != "1"
        let checked = MeasureSeals.check(file, kept: { Keychain.read(self.sealKey($0)) }, keptVerdicts: Keychain.read(verdictsKey), firstRead: firstRead)
        for (key, seal) in checked.adopted { Keychain.write(seal, for: sealKey(key)) }
        if let seal = checked.adoptedVerdicts { Keychain.write(seal, for: verdictsKey) }
        if firstRead { Keychain.write("1", for: firstReadKey) }
        sealedKeys = Set(checked.measures.measures.map(\.key))
        loaded = checked.measures
        return checked.measures
    }

    /// Written whole: the trusted records sealed, the changed ones written back unsealed, the verdicts list sealed, and the
    /// seals of records no longer here cleared. The seals go first, so a write cut short reads as changed, never as trusted.
    private func save(_ measures: DecisionMeasures) {
        loaded = measures
        let keys = Set(measures.measures.map(\.key))
        for measure in measures.measures { Keychain.write(MeasureSeals.seal(measure), for: sealKey(measure.key)) }
        for gone in sealedKeys.subtracting(keys) { Keychain.write("", for: sealKey(gone)) }
        sealedKeys = keys
        Keychain.write(MeasureSeals.seal(verdicts: measures.testVerdicts), for: verdictsKey)
        Keychain.write("1", for: firstReadKey)
        guard let data = try? MeasureSeals.file(measures).encoded() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
