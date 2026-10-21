import AVFoundation
import Foundation
import Observation
import UIKit

/// Listens for the Binders keyboard, which can't use the microphone itself. Opened from the keyboard, the app turns the
/// microphone on and listens straight away; you go back to where you were typing, and the words are typed there. After
/// that it keeps the microphone ready for a few minutes, so the keyboard's mic key starts at once, without the trip here.
/// While it's only ready, the audio is dropped as it comes: nothing is transcribed or kept until the key is tapped.
@MainActor
@Observable
final class KeyboardListener {
    static let shared = KeyboardListener()

    private(set) var state = KeyboardBridge.State()
    /// The microphone is on for the keyboard.
    var isOn: Bool { state.phase != .off }

    /// Set as the app starts, which can be after the keyboard has already turned the microphone on.
    @ObservationIgnored var connection: MacConnection? {
        didSet { if isOn { connection?.holdOpen = true } }
    }
    @ObservationIgnored private let audio = AVAudioEngine()
    @ObservationIgnored private let sink = AudioSink()
    @ObservationIgnored private var engine: SpeechEngine?
    @ObservationIgnored private var observers: [DarwinObserver] = []
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var lastUsed = Date()
    @ObservationIgnored private var lastWritten = Date.distantPast
    @ObservationIgnored private var tapped = false
    /// For tests: `-keyboardText "…"` stands in for what you'd say.
    @ObservationIgnored private let scripted = UserDefaults.standard.string(forKey: "keyboardText")
    private var isScripted: Bool { scripted != nil }

    private init() {
        observers = [
            DarwinObserver(KeyboardBridge.name(.start)) { [weak self] in Task { await self?.listen() } },
            DarwinObserver(KeyboardBridge.name(.stop)) { [weak self] in Task { await self?.finish() } },
            DarwinObserver(KeyboardBridge.name(.cancel)) { [weak self] in self?.cancel() },
            DarwinObserver(KeyboardBridge.name(.typed)) { [weak self] in self?.typed() },
        ]
        // A phone call or another app taking the microphone ends it.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            if began { MainActor.assumeIsolated { self?.turnOff() } }
        }
        // Whatever an earlier run said, this one hasn't turned anything on.
        publish()
    }

    // MARK: Dictating

    /// Starts a dictation for the keyboard, turning the microphone on first if it's off.
    func listen() async {
        guard state.phase != .listening, state.phase != .cleaning else { return }
        lastUsed = Date()
        let dictation = UUID()
        do {
            try await turnOn()
            state = KeyboardBridge.State(phase: .listening, dictation: dictation)
            publish()
            sink.begin()
            let engine: SpeechEngine = if let words = scripted {
                ScriptedEngine(words: words)
            } else {
                try await DictationSession.makeEngine()
            }
            engine.onText = { [weak self] words in
                guard let self, self.state.phase == .listening else { return }
                self.state.text = words
                self.publishSoon()
            }
            try await engine.prepare()
            // Cancelled, or a new one started, while the engine got ready.
            guard state.phase == .listening, state.dictation == dictation else { return }
            self.engine = engine
            sink.attach(engine)
        } catch {
            sink.end()
            fail(error.localizedDescription)
        }
    }

    /// Done talking: the transcript, cleaned up, for the keyboard to type.
    func finish() async {
        guard state.phase == .listening else { return }
        // Stopped before the engine was ready: give it a moment to catch up with what was said.
        let deadline = Date().addingTimeInterval(5)
        while engine == nil, state.phase == .listening, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        guard state.phase == .listening, let engine else { return }
        sink.end()
        self.engine = nil
        state.phase = .cleaning
        state.level = 0
        publish()
        let raw: String
        do {
            raw = try await engine.finish()
        } catch {
            fail(error.localizedDescription)
            return
        }
        guard !raw.isEmpty else {
            fail("Didn't catch anything. Try again, a little closer to the microphone.")
            return
        }
        // The app's own cleanup, so the keyboard waits about 4 s at most too.
        let cleaned = if let connection { await DictationSession.cleanUp(raw, connection: connection) } else { (text: raw, by: "") }
        state.text = cleaned.text
        state.phase = .done
        lastUsed = Date()
        publish()
        // Typed where you are, and kept on the Mac with its own dictations.
        await connection?.keepDictation(cleaned.text, heard: raw, app: "iPhone keyboard")
    }

    func cancel() {
        sink.end()
        engine = nil
        guard isOn else { return }
        state = KeyboardBridge.State(phase: .ready)
        publish()
    }

    /// The keyboard typed the result.
    private func typed() {
        guard state.phase == .done else { return }
        state = KeyboardBridge.State(phase: .ready)
        publish()
    }

    private func fail(_ message: String) {
        state.phase = .failed
        state.text = message
        state.level = 0
        publish()
    }

    private func heard(_ loudness: Double) {
        guard state.phase == .listening else { return }
        state.level = loudness
        publishSoon()
    }

    // MARK: The microphone

    /// Kept running between dictations, which is what lets the app listen from the background.
    private func turnOn() async throws {
        guard heartbeat == nil else { return }
        // Scripted words need no microphone, which the Simulator may not have.
        if !isScripted {
            guard await AVAudioApplication.requestRecordPermission() else { throw DictationError.microphone }
            // All-day capture lets go of the microphone while the keyboard has it.
            MicrophoneUsers.claim("keyboard")
            let session = AVAudioSession.sharedInstance()
            // Mixing, so music or a podcast keeps playing while the microphone is ready.
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            let input = audio.inputNode
            let sink = sink
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                guard let loudness = sink.take(buffer) else { return }
                Task { @MainActor in self?.heard(loudness) }
            }
            tapped = true
            audio.prepare()
            do {
                try audio.start()
            } catch {
                input.removeTap(onBus: 0)
                tapped = false
                MicrophoneUsers.release("keyboard")
                throw error
            }
        }
        connection?.holdOpen = true
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.beat()
            }
        }
    }

    /// Microphone off: the keyboard's mic key opens the app again.
    func turnOff() {
        sink.end()
        engine = nil
        heartbeat?.cancel()
        heartbeat = nil
        if tapped {
            audio.stop()
            audio.inputNode.removeTap(onBus: 0)
            tapped = false
            MicrophoneUsers.release("keyboard")
            // All-day capture, listening again, keeps the audio session.
            if !MicrophoneUsers.captureNeedsSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        state = KeyboardBridge.State(phase: .off)
        publish()
        // In the background, the link goes with the hold.
        connection?.holdOpen = false
    }

    /// Lets go of the microphone it keeps ready, unless you're dictating: All-day capture wants it back.
    func letGoIfIdle() {
        guard state.phase == .ready || state.phase == .failed || state.phase == .done else { return }
        turnOff()
    }

    /// Tells the keyboard it's still here, and lets the microphone go once it's been idle a while: five minutes, or half
    /// a minute when All-day capture is waiting for it.
    private func beat() {
        let warm = CaptureSession.shared.isWaitingForMicrophone ? 30 : KeyboardBridge.warmFor
        if state.phase == .ready || state.phase == .failed, Date().timeIntervalSince(lastUsed) > warm {
            turnOff()
        } else {
            publish()
        }
    }

    // MARK: Telling the keyboard

    private func publish() {
        lastWritten = Date()
        KeyboardBridge.write(state)
    }

    /// For the words and the meter as they change: at most ten times a second.
    private func publishSoon() {
        guard Date().timeIntervalSince(lastWritten) > 0.1 else { return }
        publish()
    }
}

/// Hears the same words every time: for tests, where there's no voice (`-keyboardText "…"`).
private final class ScriptedEngine: SpeechEngine {
    var onText: ((String) -> Void)?
    private let words: String

    init(words: String) { self.words = words }

    func prepare() async throws {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.onText?(self.words)
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {}

    func finish() async throws -> String { words }
}

/// Hands microphone audio to the dictation in progress, from the audio thread. Audio that comes while the engine gets
/// ready waits for it; audio outside a dictation is dropped.
private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var capturing = false
    private var target: SpeechEngine?
    private var waiting: [AVAudioPCMBuffer] = []

    func begin() {
        lock.withLock {
            capturing = true
            target = nil
            waiting = []
        }
    }

    func attach(_ engine: SpeechEngine) {
        lock.withLock {
            for buffer in waiting { engine.append(buffer) }
            waiting = []
            target = engine
        }
    }

    func end() {
        lock.withLock {
            capturing = false
            target = nil
            waiting = []
        }
    }

    /// How loud it is when it's part of a dictation; nil when it's dropped.
    func take(_ buffer: AVAudioPCMBuffer) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard capturing else { return nil }
        if let target {
            target.append(buffer)
        } else if waiting.count < 500, let copy = buffer.duplicate() {
            waiting.append(copy)
        }
        return DictationSession.loudness(buffer)
    }
}

private extension AVAudioPCMBuffer {
    func duplicate() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let from = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, destination) in zip(from, to) {
            guard let data = source.mData, let target = destination.mData else { continue }
            memcpy(target, data, Int(min(source.mDataByteSize, destination.mDataByteSize)))
        }
        return copy
    }
}
