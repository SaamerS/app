import AVFoundation
import BindersKit
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
    /// How alike two voices must sound to be the same person.
    static let threshold: Float = 0.55

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
