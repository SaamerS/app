import CoreML
import FluidAudio
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

    private(set) var downloading = false
    /// 0…1 while the transcriber downloads.
    private(set) var progress: Double = 0
    private(set) var downloadError: String?
    /// On a network that isn't metered: Wi-Fi or Ethernet, not cellular or a phone's hotspot.
    private(set) var onWiFi = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var transcriberLoaded: (version: AsrModelVersion, manager: AsrManager)?
    @ObservationIgnored private var diarizer: OfflineDiarizerManager?
    @ObservationIgnored private var detector: VadManager?

    private init() {
        language = Language(rawValue: UserDefaults.standard.string(forKey: "captureLanguage") ?? "") ?? .english
        Self.keepModelsOutOfBackups()
        // Off Wi-Fi, a model that fails to load must not be deleted and fetched again over cellular, as FluidAudio would.
        ModelHub.offlineMode = true
        monitor.pathUpdateHandler = { [weak self] path in
            let unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            ModelHub.offlineMode = !unmetered
            Task { @MainActor in self?.onWiFi = unmetered }
        }
        monitor.start(queue: DispatchQueue(label: "io.binders.app.capture-network"))
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
        UIApplication.shared.applicationState == .active || Self.mayInferInBackground
    }

    var version: AsrModelVersion { language == .english ? .v2 : .v3 }
    /// How a transcript says which engine wrote it.
    var engineName: String { language == .english ? "parakeet-v2" : "parakeet-v3" }

    var isTranscriberDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// Parakeet, ready to transcribe: loaded from the phone, or downloaded first when on Wi-Fi. Nil when it isn't here and
    /// can't be fetched now.
    func transcriber() async -> AsrManager? {
        if let transcriberLoaded, transcriberLoaded.version == version { return transcriberLoaded.manager }
        guard mayLoadNow else { return nil }
        let version = version
        let downloaded = isTranscriberDownloaded
        guard downloaded || onWiFi else { return nil }
        if !downloaded {
            downloading = true
            progress = 0
            downloadError = nil
        }
        defer { downloading = false }
        do {
            let models = try await AsrModels.downloadAndLoad(version: version, progressHandler: { [weak self] update in
                let fraction = update.fractionCompleted
                Task { @MainActor in self?.progress = fraction }
            })
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            transcriberLoaded = (version, manager)
            downloadError = nil
            return manager
        } catch {
            downloadError = "Couldn't get the speech model: \(error.localizedDescription)"
            return nil
        }
    }

    /// Fetches the transcriber now, from Settings.
    func download() async {
        _ = await transcriber()
    }

    /// The offline diarizer, which tells voices apart in a whole conversation. Never on the GPU, which iOS doesn't let
    /// an app use in the background: left to choose, it would, and the voices would quietly come out as one.
    func speakerLabeller() async -> OfflineDiarizerManager? {
        if let diarizer { return diarizer }
        guard mayLoadNow else { return nil }
        let key = "captureDiarizerReady"
        let downloaded = UserDefaults.standard.bool(forKey: key)
        guard downloaded || onWiFi else { return nil }
        do {
            let manager = OfflineDiarizerManager()
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            if downloaded {
                // Already here: loaded as it is. prepareModels deletes and fetches it again after any failed load.
                manager.initialize(models: try await OfflineDiarizerModels.load(from: OfflineDiarizerModels.defaultModelsDirectory(),
                                                                                configuration: configuration))
            } else {
                try await manager.prepareModels(configuration: configuration)
            }
            diarizer = manager
            UserDefaults.standard.set(true, forKey: key)
            return manager
        } catch {
            return nil
        }
    }

    /// Silero, the small model that hears when someone is speaking. Until it's here, loudness stands in. It runs on the
    /// CPU: it's small, and it listens all day with the phone locked, where iOS 27 keeps apps off the Neural Engine
    /// (there, every chunk would fail and loudness would quietly take over).
    func voiceDetector() async -> VadManager? {
        if let detector { return detector }
        let key = "captureDetectorReady"
        guard UserDefaults.standard.bool(forKey: key) || onWiFi else { return nil }
        do {
            let manager = try await VadManager(config: VadConfig(defaultThreshold: 0.6, computeUnits: .cpuOnly))
            detector = manager
            UserDefaults.standard.set(true, forKey: key)
            return manager
        } catch {
            return nil
        }
    }

    /// Lets go of the big models once a batch of conversations is done, so the app stays small in the background.
    func unloadLarge() {
        transcriberLoaded = nil
        diarizer = nil
    }
}
