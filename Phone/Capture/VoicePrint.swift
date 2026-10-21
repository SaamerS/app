import AVFoundation
import BindersKit
import CryptoKit
import FluidAudio
import Foundation
import Observation
import Security

/// Your voice as the diarizer hears it: one embedding, taken from twenty seconds of you reading, kept in the Keychain on
/// this iPhone only. In a conversation, the voice closest to it becomes "You"; without it, the Mac works out who's who
/// from what was said.
@MainActor
enum VoicePrint {
    private static let service = "io.binders.voice"
    private static let account = "you"
    /// How alike two voices must sound to be the same person, in a whole conversation.
    static let threshold: Float = 0.55
    /// How alike a few seconds said to yourself must sound to your print before it can be a moment: the one setting for
    /// it, read by the moment gate (MomentCenter.gate). Stricter than `threshold`, as a 2-5 s clip says less than a
    /// conversation. The calibration bench (Capture → Calibrate) sets it for about 1% false accepts on 2-5 s clips, from
    /// your phrases, other voices and TV; until then, and after Reset, it's `defaultMomentThreshold`. Kept with the print:
    /// forgetting the print, or teaching it again, goes back to the default.
    static var momentThreshold: Float {
        get { (UserDefaults.standard.object(forKey: momentThresholdKey) as? Double).map { Float($0) } ?? defaultMomentThreshold }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: momentThresholdKey)
            UserDefaults.standard.set(Date(), forKey: momentThresholdSetKey)
        }
    }

    /// A first guess, until the bench has been run.
    static let defaultMomentThreshold: Float = 0.65

    /// When the bench set `momentThreshold`; nil while it's the default.
    static var momentThresholdSet: Date? {
        guard UserDefaults.standard.object(forKey: momentThresholdKey) != nil else { return nil }
        return UserDefaults.standard.object(forKey: momentThresholdSetKey) as? Date
    }

    /// Back to the default.
    static func resetMomentThreshold() {
        UserDefaults.standard.removeObject(forKey: momentThresholdKey)
        UserDefaults.standard.removeObject(forKey: momentThresholdSetKey)
        UserDefaults.standard.removeObject(forKey: startThresholdKey)
    }

    /// How close a "Binders, …" said on its own must be to your voice for this iPhone to send its yes with it, so your Mac
    /// may start an agent you let start on cards Binders sends it (MomentAgreement): stricter than `momentThreshold`, and
    /// above every other voice and Not me the bench heard (MomentBench.startThreshold). Only Calibrate sets it, from at
    /// least 100 clips of other voices; nil until then. Reset, forgetting the print and teaching it again clear it.
    static var startThreshold: Float? {
        get { (UserDefaults.standard.object(forKey: startThresholdKey) as? Double).map { Float($0) } }
        set {
            if let newValue { UserDefaults.standard.set(Double(newValue), forKey: startThresholdKey) } else {
                UserDefaults.standard.removeObject(forKey: startThresholdKey)
            }
        }
    }

    private static let startThresholdKey = "voicePrintStartThreshold"

    private static let momentThresholdKey = "voicePrintMomentThreshold"
    private static let momentThresholdSetKey = "voicePrintMomentThresholdSet"

    /// A short name for the print you have now and how voices are scored against it, so the bench counts only scores
    /// that compare: a few hex digits of its hash, nothing that gives the print away, then the scoring ("3fa2c1d0.2").
    /// Nil without a print.
    static var fingerprint: String? {
        guard let print = load() else { return nil }
        let data = print.withUnsafeBufferPointer { Data(buffer: $0) }
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined() + ".\(scoring)"
    }

    /// How a clip said on its own is scored (ConversationProcessor.voiceScore). 2: the clip fills the diarizer's ten-second
    /// window with its own speech (AudioMath.filledForVoice). Before, padded with silence, a 2-5 s clip scored about 0.3
    /// whoever said it, so nothing passed the voice threshold and Calibrate's thresholds were set on the wrong scale.
    static let scoring = 2
    private static let scoringKey = "voicePrintScoring"

    /// Once, at launch, after an update to `scoring`: the voice threshold, the start bar and the Not me scores, all set
    /// from scores of the earlier scoring, go, so the default stands until Calibrate is run again. The print stays.
    static func upgradeScoring() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: scoringKey) < scoring else { return }
        resetMomentThreshold()
        defaults.removeObject(forKey: missesKey)
        defaults.set(scoring, forKey: scoringKey)
    }

    /// Things the gate let through as yours that you said weren't ("Not me"): how alike each sounded to the print (nil
    /// when it wasn't scored), the hard negatives the bench for `momentThreshold` needs. Numbers only, the last 50; they
    /// go with the print.
    static var misses: [Double?] {
        (UserDefaults.standard.array(forKey: missesKey) as? [Double] ?? []).map { $0 < 0 ? nil : $0 }
    }

    /// One more Not me, with its score if it had one. When that score was at or past the start bar Calibrate set, the bar
    /// goes up above it at once (MomentBench.raisedStartBar), so the same voice can't hand anything over without asking
    /// before the next Calibrate: true when it did.
    @discardableResult
    static func notMe(_ score: Double?) -> Bool {
        let kept = UserDefaults.standard.array(forKey: missesKey) as? [Double] ?? []
        UserDefaults.standard.set(Array((kept + [score ?? -1]).suffix(50)), forKey: missesKey)
        guard let score, let bar = startThreshold else { return false }
        let raised = MomentBench.raisedStartBar(current: Double(bar), notMe: score)
        guard raised > Double(bar) else { return false }
        startThreshold = Float(raised)
        return true
    }

    private static let missesKey = "voicePrintMisses"

    /// How alike a voice sounds to your print (cosine), or nil without a print.
    static func score(_ embedding: [Float]) -> Float? {
        guard let mine = load(), mine.count == embedding.count else { return nil }
        return cosine(mine, embedding)
    }

    static var isTaught: Bool { load() != nil }

    /// The speaker in `voices` (diarizer id → embedding) that sounds most like you, if any sounds enough like you.
    static func closest(among voices: [String: [Float]]) -> String? {
        guard let mine = load() else { return nil }
        let best = voices.compactMap { id, voice -> (String, Float)? in
            guard voice.count == mine.count else { return nil }
            return (id, cosine(mine, voice))
        }.max { $0.1 < $1.1 }
        guard let best, best.1 >= threshold else { return nil }
        return best.0
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, x: Float = 0, y: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            x += a[index] * a[index]
            y += b[index] * b[index]
        }
        return x > 0 && y > 0 ? dot / (x.squareRoot() * y.squareRoot()) : 0
    }

    static func save(_ embedding: [Float]) {
        forget()
        let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> [Float]? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              data.count % MemoryLayout<Float>.size == 0, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func forget() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: missesKey)
        // Set against this print, so it goes with it.
        resetMomentThreshold()
    }
}

/// "Teach Binders your voice": twenty seconds of you reading, turned into a voice print. Nothing of the recording is kept.
@MainActor
@Observable
final class VoiceTeaching {
    enum Phase: Equatable {
        case ready, listening, learning, done
        case failed(String)
    }

    static let seconds: TimeInterval = 20
    static let passage = """
        I keep my notes in Binders. During the day it listens for conversations, writes them down on this iPhone, and \
        sends the text to my Mac, where each one gets a summary and its promises become to-dos. This is my voice, so \
        when I'm talking, the transcript should say it's me.
        """

    private(set) var phase: Phase = .ready
    /// 0…1 through the twenty seconds.
    private(set) var progress: Double = 0

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private let collected = Collected()

    func start() async {
        guard phase != .listening, phase != .learning else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed(CaptureError.microphone.localizedDescription)
            return
        }
        MicrophoneUsers.claim("voice")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let converter = SixteenKilohertz(from: format)
            let collected = collected
            collected.reset()
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                if let samples = converter.convert(buffer) { collected.add(samples) }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            phase = .listening
            let started = Date()
            while phase == .listening, Date().timeIntervalSince(started) < Self.seconds {
                try? await Task.sleep(for: .milliseconds(200))
                progress = min(1, Date().timeIntervalSince(started) / Self.seconds)
            }
            guard phase == .listening else { return }
            stopMicrophone()
            await learn(collected.samples)
        } catch {
            stopMicrophone()
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        stopMicrophone()
        phase = .ready
        progress = 0
    }

    private func stopMicrophone() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        MicrophoneUsers.release("voice")
    }

    private func learn(_ samples: [Float]) async {
        phase = .learning
        guard samples.count > 8 * 16_000, !AudioMath.isSilent(samples) else {
            phase = .failed("Didn't hear enough. Try again somewhere quiet, reading the whole passage.")
            return
        }
        guard let diarizer = await CaptureModels.shared.speakerLabeller() else {
            phase = .failed("The model that tells voices apart downloads over Wi-Fi first. Connect to Wi-Fi and try again.")
            return
        }
        do {
            let result = try await diarizer.process(audio: samples)
            // The voice that spoke the most is yours.
            var spoken: [String: Float] = [:]
            for segment in result.segments { spoken[segment.speakerId, default: 0] += segment.durationSeconds }
            guard let you = spoken.max(by: { $0.value < $1.value })?.key, let print = result.speakerDatabase?[you] else {
                phase = .failed("Couldn't make out a voice. Try again somewhere quiet.")
                return
            }
            VoicePrint.save(print)
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Audio gathered from the audio thread.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var gathered: [Float] = []

    func reset() { lock.withLock { gathered = [] } }
    func add(_ samples: [Float]) { lock.withLock { gathered += samples } }
    var samples: [Float] { lock.withLock { gathered } }
}
