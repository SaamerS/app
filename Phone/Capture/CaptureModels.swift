import CoreML
@preconcurrency import FluidAudio
import Foundation
import Network
import Observation
import UIKit

/// The models All-day capture runs on this iPhone, the same ones the Mac uses for meetings: Parakeet writes down what was
/// said, the diarizer tells the voices apart, and a small voice detector hears when someone is speaking. Each downloads
/// once, on first use, and only over Wi-Fi; Parakeet is about 500 MB.
@MainActor
@Observable
final class CaptureModels {
    static let shared = CaptureModels()

    /// Whether Parakeet and the diarizer may run with the app in the background. iOS 27 keeps the Neural Engine from
    /// background apps unless they hold Apple's Background Inference entitlement
    /// (com.apple.developer.background-tasks.continued-processing.inference); `BindersBackgroundInference` in Info.plist
    /// says this build has it. Until then, conversations wait for the app to be opened.
    nonisolated static var mayInferInBackground: Bool {
        if #available(iOS 27, *) {
            return Bundle.main.object(forInfoDictionaryKey: "BindersBackgroundInference") as? Bool ?? false
        }
        return true
    }

    enum Language: String, CaseIterable, Identifiable {
        case english, multilingual
        var id: String { rawValue }
        var title: String { self == .english ? "English" : "Multilingual" }
        var detail: String { self == .english ? "Parakeet v2, the most accurate for English" : "Parakeet v3, 25 European languages" }
    }

    var language: Language {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "captureLanguage")
            transcriberLoaded = nil
        }
    }

    private(set) var downloading = false {
        didSet { updateOfflineMode() }
    }
    /// The diarizer's first download, in front or in the charging task: it needs the network too.
    @ObservationIgnored private var fetchingDiarizer = false {
        didSet { updateOfflineMode() }
    }
    /// Set by the charging task: there a first load, a compile for the Neural Engine, may happen in the background.
    @ObservationIgnored var mayCompileInBackground = false
    /// 0…1 while the transcriber downloads.
    private(set) var progress: Double = 0
    private(set) var downloadError: String?
    /// On a network that isn't metered: Wi-Fi or Ethernet, not cellular or a phone's hotspot.
    private(set) var onWiFi = false
    /// On any network that isn't in Low Data Mode, cellular included: enough for the 1 MB voice detector.
    @ObservationIgnored private var onNetwork = false
    /// The voice detector's first download: allowed over cellular, as long as nothing bigger is loading meanwhile.
    @ObservationIgnored private var fetchingDetector = false {
        didSet { updateOfflineMode() }
    }
    @ObservationIgnored private var loadingDetector: Task<VadManager?, Never>?

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var transcriberLoaded: (version: AsrModelVersion, manager: AsrManager)?
    @ObservationIgnored private var diarizer: OfflineDiarizerManager?
    @ObservationIgnored private var detector: VadManager?
    /// Loads under way, so two callers share one instead of loading a model twice.
    @ObservationIgnored private var loadingTranscriber: (version: AsrModelVersion, task: Task<AsrManager?, Never>)? {
        didSet { updateOfflineMode() }
    }
    @ObservationIgnored private var loadingDiarizer: Task<Bool, Never>? {
        didSet { updateOfflineMode() }
    }
    @ObservationIgnored private var inFront = true

    private init() {
        language = Language(rawValue: UserDefaults.standard.string(forKey: "captureLanguage") ?? "") ?? .english
        Self.keepModelsOutOfBackups()
        inFront = UIApplication.shared.applicationState != .background
        // A model that fails to load makes FluidAudio delete it and fetch it again. That's only allowed on Wi-Fi, with the
        // app in front or while a download started there finishes: never over cellular.
        ModelHub.offlineMode = true
        monitor.pathUpdateHandler = { [weak self] path in
            let unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            let reachable = path.status == .satisfied && !path.isConstrained
            Task { @MainActor in
                self?.onWiFi = unmetered
                self?.onNetwork = reachable
                self?.updateOfflineMode()
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.binders.app.capture-network"))
    }

    /// The app came to the front or left it.
    func appStateChanged(inFront: Bool) {
        self.inFront = inFront
        updateOfflineMode()
    }

    /// FluidAudio may fetch only on Wi-Fi with the app in front or a download running there, or, for the 1 MB voice
    /// detector alone, over any network while no big model is loading (one starting closes the network before it asks).
    private func updateOfflineMode() {
        ModelHub.offlineMode = !((onWiFi && (inFront || downloading || fetchingDiarizer))
                                 || (onNetwork && fetchingDetector && loadingTranscriber == nil && loadingDiarizer == nil))
    }

    /// The models (about 500 MB) download again whenever they're needed: they don't belong in an iCloud backup.
    private static func keepModelsOutOfBackups() {
        var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// The app is open, or iOS lets the models run with it in the background. Loading one anywhere else would fail, and
    /// a failed load can make FluidAudio delete it to fetch it again.
    private var mayLoadNow: Bool {
        UIApplication.shared.applicationState != .background || Self.mayInferInBackground
    }

    var version: AsrModelVersion { language == .english ? .v2 : .v3 }
    /// How a transcript says which engine wrote it.
    var engineName: String { Self.engineName(version) }
    static func engineName(_ version: AsrModelVersion) -> String { version == .v2 ? "parakeet-v2" : "parakeet-v3" }

    var isTranscriberDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// Parakeet, ready to transcribe: loaded from the phone, or downloaded first when on Wi-Fi. Nil when it isn't here and
    /// can't be fetched now.
    func transcriber() async -> AsrManager? {
        if let transcriberLoaded, transcriberLoaded.version == version {
            markCompiled(Self.parakeetCompiledKey, engineName)
            return transcriberLoaded.manager
        }
        // A load under way for this language is shared; one for the other language is left to finish on its own.
        if let loading = loadingTranscriber, loading.version == version { return await loading.task.value }
        guard mayLoadNow else { return nil }
        let version = version
        let downloaded = isTranscriberDownloaded
        guard downloaded || onWiFi else { return nil }
        let load = Task { () -> AsrManager? in
            if !downloaded {
                downloading = true
                progress = 0
                downloadError = nil
            }
            defer { downloading = false }
            do {
                let directory = try await AsrModels.download(version: version, progressHandler: { update in
                    let fraction = update.fractionCompleted
                    Task { @MainActor in self.progress = fraction }
                })
                // Fetched just now with the app gone from the front: its first load, a compile for the Neural Engine,
                // waits for the app or the charging task, never a pocket on battery.
                if !downloaded, !inFront, !mayCompileInBackground { return nil }
                // Pinned here, not left to FluidAudio's default (which floats with its version): never the GPU.
                let models = try await AsrModels.load(from: directory, configuration: Self.backgroundSafe(), version: version)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                // Kept only while it's the language chosen.
                if version == self.version { transcriberLoaded = (version, manager) }
                downloadError = nil
                markCompiled(Self.parakeetCompiledKey, Self.engineName(version))
                return manager
            } catch {
                downloadError = "Couldn't get the speech model: \(error.localizedDescription)"
                return nil
            }
        }
        loadingTranscriber = (version, load)
        // A download that stalls for good, or a load that never returns, doesn't hold everything behind it: it's given up
        // after 30 minutes (5 for a load from the phone), and picks up where it stopped next time.
        let deadline = Task {
            try? await Task.sleep(for: .seconds(downloaded ? 300 : 1800))
            guard !Task.isCancelled else { return }
            load.cancel()
        }
        let manager = await load.value
        deadline.cancel()
        if manager == nil, load.isCancelled {
            downloadError = downloaded ? "The speech model took too long to load. It's tried again next time."
                : "The speech model didn't finish downloading. It picks up where it stopped next time you're on Wi-Fi."
        }
        if loadingTranscriber?.version == version { loadingTranscriber = nil }
        return manager
    }

    /// Fetches the transcriber now, from the capture screen, and readies the diarizer with it while the app is open.
    func download() async {
        guard await transcriber() != nil, inFront else { return }
        _ = await speakerLabeller()
    }

    /// How Parakeet and the diarizer load: on the CPU and the Neural Engine, never the GPU, which iOS doesn't let an app
    /// use in the background. Parakeet's preprocessor runs on the CPU whatever this says (FluidAudio's own choice). It's
    /// FluidAudio's own default configuration with only the compute units pinned, so nothing else about how Core ML
    /// compiles and caches the models changes.
    nonisolated static func backgroundSafe() -> MLModelConfiguration {
        MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuAndNeuralEngine)
    }

    var isDiarizerDownloaded: Bool { UserDefaults.standard.bool(forKey: Self.diarizerKey) }
    private static let diarizerKey = "captureDiarizerReady"

    /// The offline diarizer, which tells voices apart in a whole conversation. Never on the GPU, which iOS doesn't let
    /// an app use in the background: left to choose, it would, and the voices would quietly come out as one.
    func speakerLabeller() async -> OfflineDiarizerManager? {
        if let diarizer {
            markCompiled(Self.diarizerCompiledKey, "diarizer")
            return diarizer
        }
        if let loadingDiarizer {
            _ = await loadingDiarizer.value
            return diarizer
        }
        guard mayLoadNow else { return nil }
        let downloaded = isDiarizerDownloaded
        guard downloaded || onWiFi else { return nil }
        let load = Task { () -> Bool in
            if !downloaded { fetchingDiarizer = true }
            defer { fetchingDiarizer = false }
            do {
                let manager = OfflineDiarizerManager()
                let configuration = Self.backgroundSafe()
                if downloaded {
                    // Already here: loaded as it is, never through prepareModels, which deletes it and fetches it again
                    // after any failed load. (A failed load here can still be retried by FluidAudio, offline unless on
                    // Wi-Fi with the app in front or a download running.)
                    manager.initialize(models: try await OfflineDiarizerModels.load(from: OfflineDiarizerModels.defaultModelsDirectory(),
                                                                                    configuration: configuration))
                } else {
                    try await manager.prepareModels(configuration: configuration)
                }
                diarizer = manager
                UserDefaults.standard.set(true, forKey: Self.diarizerKey)
                markCompiled(Self.diarizerCompiledKey, "diarizer")
                return true
            } catch {
                return false
            }
        }
        loadingDiarizer = load
        let deadline = Task {
            try? await Task.sleep(for: .seconds(downloaded ? 300 : 1800))
            guard !Task.isCancelled else { return }
            load.cancel()
        }
        _ = await load.value
        deadline.cancel()
        loadingDiarizer = nil
        return diarizer
    }

    /// Silero, the small model that hears when someone is speaking. Until it's here, loudness stands in. It runs on the
    /// CPU: it's small, and it listens all day with the phone locked, where iOS 27 keeps apps off the Neural Engine
    /// (there, every chunk would fail and loudness would quietly take over).
    /// The first time, it's fetched over any network (it's 1 MB), and given up after a minute to be tried again later.
    func voiceDetector() async -> VadManager? {
        if let detector { return detector }
        if let loadingDetector { return await loadingDetector.value }
        let key = "captureDetectorReady"
        let ready = UserDefaults.standard.bool(forKey: key)
        guard ready || onNetwork else { return nil }
        let load = Task { () -> VadManager? in
            if !ready { fetchingDetector = true }
            defer { fetchingDetector = false }
            do {
                let manager = try await VadManager(config: VadConfig(defaultThreshold: 0.6, computeUnits: .cpuOnly))
                detector = manager
                UserDefaults.standard.set(true, forKey: key)
                return manager
            } catch {
                return nil
            }
        }
        loadingDetector = load
        let deadline = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            load.cancel()
        }
        let manager = await load.value
        deadline.cancel()
        loadingDetector = nil
        return manager
    }

    /// Whether Parakeet is on the phone now, loaded or downloaded.
    var hasTranscriber: Bool { transcriberLoaded?.version == version || isTranscriberDownloaded }

    /// Lets go of the big models once a batch of conversations is done, so the app stays small in the background.
    func unloadLarge() {
        transcriberLoaded = nil
        diarizer = nil
    }

    /// Lets go of Parakeet alone, the big model, before the diarizer reads a whole conversation in the background: iOS 27
    /// counts Neural Engine memory against the app.
    func unloadTranscriber() {
        transcriberLoaded = nil
    }

    // MARK: Ready for the background

    /// A model's first load after an install, an update of Binders or of iOS compiles it for the Neural Engine, which can
    /// take a minute or two of heavy work: done with the app open (ConversationProcessor.prepareForBackground), never in a
    /// pocket, where iOS could stop the app and All-day capture with it. True once Parakeet, in the language chosen, and
    /// the diarizer have each loaded under this version of Binders and of iOS.
    var isReadyForBackground: Bool {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: Self.parakeetCompiledKey) == Self.compileKey(engineName)
            && defaults.string(forKey: Self.diarizerCompiledKey) == Self.compileKey("diarizer")
    }

    private func markCompiled(_ key: String, _ model: String) {
        UserDefaults.standard.set(Self.compileKey(model), forKey: key)
    }

    private static let parakeetCompiledKey = "captureCompiledParakeet"
    private static let diarizerCompiledKey = "captureCompiledDiarizer"
    private static func compileKey(_ model: String) -> String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(build)|\(ProcessInfo.processInfo.operatingSystemVersionString)|\(model)"
    }
}
