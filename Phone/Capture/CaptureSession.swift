import AVFoundation
import BindersKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Who else is using the microphone in this app: dictation, and the keyboard's warm microphone. While either has it,
/// All-day capture steps aside, and it carries on once they're done. Dictations aren't conversations; they're kept as
/// dictations.
@MainActor
enum MicrophoneUsers {
    private static var holders: Set<String> = []

    static func claim(_ who: String) {
        let first = holders.isEmpty
        holders.insert(who)
        if first { CaptureSession.shared.stepAside() }
    }

    static func release(_ who: String) {
        guard holders.remove(who) != nil, holders.isEmpty else { return }
        CaptureSession.shared.stepBack()
    }

    static var isClaimed: Bool { !holders.isEmpty }

    /// Once another user's engine is off: true when capture is listening again, so the audio session must stay on.
    static var captureNeedsSession: Bool { CaptureSession.shared.isListening }
}

/// All-day capture: the iPhone listens, cuts the day into conversations, and hands each one, once it's over, to be
/// transcribed here and sent to the Mac as text. It mixes with whatever's playing, keeps going with the screen locked,
/// and comes back after a call or Siri, or asks to be tapped when iOS won't let it. Mute stops the microphone
/// completely. It never turns itself on: after a quit it asks.
@MainActor
@Observable
final class CaptureSession {
    static let shared = CaptureSession()

    enum Status: Equatable {
        case off, starting, listening, muted
        case paused(String)

        var title: String {
            switch self {
            case .off: "Off"
            case .starting: "Starting…"
            case .listening: "Listening"
            case .muted: "Muted"
            case .paused: "Paused"
            }
        }
    }

    /// A stretch when capture wasn't listening though it was on: "paused 10:42–10:57".
    struct Gap: Codable, Equatable, Identifiable {
        var id: Date { from }
        var from: Date
        var to: Date?
        var reason: String
    }

    private(set) var status: Status = .off
    /// Someone is speaking, or was a moment ago: a conversation is open.
    private(set) var inConversation = false
    private(set) var error: String?
    /// Today's numbers.
    private(set) var gaps: [Gap] = []
    private(set) var speechSeconds: TimeInterval = 0
    private(set) var secondsOn: TimeInterval = 0
    /// It was on when the app last quit: ask before turning it back on.
    var askToResume = false

    var isOn: Bool { status != .off }
    var isListening: Bool { status == .listening }
    var isMuted: Bool { status == .muted }
    /// Paused while dictation or the keyboard has the microphone, to listen again once they let go.
    var isWaitingForMicrophone: Bool { steppedAside && isPaused }

    /// Hours listened today, so far.
    func onToday(now: Date = Date()) -> TimeInterval { secondsOn + (listeningSince.map { now.timeIntervalSince($0) } ?? 0) }

    /// Told when a conversation is over and ready to transcribe.
    @ObservationIgnored var onConversationClosed: ((CapturedConversation) -> Void)?
    @ObservationIgnored private var source: CaptureSource?
    @ObservationIgnored private var feed: AsyncStream<([Float], Date)>.Continuation?
    @ObservationIgnored private var listeningSince: Date?
    @ObservationIgnored private var steppedAside = false
    @ObservationIgnored private var statsDay = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private let worker = CaptureWorker { event in
        Task { @MainActor in CaptureSession.shared.handle(event) }
    }

    private static let onKey = "captureOn"
    private static let statsKey = "captureStats"
    /// `-captureSource silence` listens to nothing, for the Simulator and UI tests.
    private var simulated: Bool { UserDefaults.standard.string(forKey: "captureSource") == "silence" }

    private init() {
        loadStats()
        askToResume = UserDefaults.standard.bool(forKey: Self.onKey)
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { CaptureSession.shared.interrupted(info) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { CaptureSession.shared.routeChanged(reason) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaptureSession.shared.restartIfListening() }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaptureSession.shared.restartIfListening() }
        }
    }

    // MARK: On and off

    func turnOn() async {
        guard status == .off || isPaused else { return }
        error = nil
        status = .starting
        if !simulated {
            guard await AVAudioApplication.requestRecordPermission() else {
                status = .off
                error = CaptureError.microphone.localizedDescription
                return
            }
        }
        // For "paused, tap to resume" when iOS won't let it start again by itself.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        UserDefaults.standard.set(true, forKey: Self.onKey)
        askToResume = false
        if MicrophoneUsers.isClaimed {
            steppedAside = true
            status = .paused("While you dictate")
            return
        }
        startListening()
    }

    func turnOff() {
        stopListening()
        steppedAside = false
        status = .off
        inConversation = false
        UserDefaults.standard.set(false, forKey: Self.onKey)
        closeGap()
        deactivateSession()
    }

    /// Stops the microphone completely, so iOS's microphone indicator goes away; a conversation in progress ends here.
    func mute() {
        guard status == .listening || isPaused else { return }
        stopListening()
        steppedAside = false
        closeGap()
        status = .muted
        deactivateSession()
    }

    func unmute() {
        guard status == .muted else { return }
        if MicrophoneUsers.isClaimed {
            steppedAside = true
            status = .paused("While you dictate")
            return
        }
        startListening()
    }

    /// From the "paused, tap to resume" notification, or the Resume button.
    func resume() async {
        if status == .off {
            await turnOn()
        } else if isPaused, steppedAside {
            // The keyboard keeping the microphone ready lets go of it; a dictation in progress finishes first.
            KeyboardListener.shared.letGoIfIdle()
        } else if isPaused {
            startListening()
        }
    }

    /// Asked at launch, and declined: it stays off until turned on.
    func declineResume() {
        askToResume = false
        UserDefaults.standard.set(false, forKey: Self.onKey)
    }

    private var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    // MARK: Listening

    private func startListening() {
        do {
            try activateSession()
            let source: CaptureSource = simulated ? SilenceSource() : MicSource()
            let (stream, continuation) = AsyncStream<([Float], Date)>.makeStream()
            source.onAudio = { samples, time in continuation.yield((samples, time)) }
            try source.start()
            let worker = worker
            Task.detached(priority: .userInitiated) {
                for await (samples, time) in stream { await worker.append(samples, at: time) }
                // Stopped, muted or interrupted: an open conversation ends where its speech did.
                await worker.finish()
            }
            self.source = source
            feed = continuation
            status = .listening
            error = nil
            rollStats()
            listeningSince = Date()
            closeGap()
            Task {
                let detector = await CaptureModels.shared.voiceDetector()
                await worker.useDetector(detector)
            }
        } catch {
            source?.stop()
            source = nil
            self.error = error.localizedDescription
            status = .paused("Couldn't start the microphone")
            openGap("the microphone wouldn't start")
            notifyPaused()
        }
    }

    private func stopListening() {
        source?.stop()
        source = nil
        feed?.finish()
        feed = nil
        if let since = listeningSince {
            rollStats()
            secondsOn += Date().timeIntervalSince(since)
            listeningSince = nil
            saveStats()
        }
    }

    private func restartIfListening() {
        guard status == .listening else { return }
        stopListening()
        startListening()
    }

    private func activateSession() throws {
        guard !simulated else { return }
        let session = AVAudioSession.sharedInstance()
        // Mixed with whatever's playing, so music and podcasts carry on at full volume. Bluetooth headphones keep playing
        // in high quality (A2DP); listening through their microphone would switch them to call quality, so the iPhone's
        // own microphone listens.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
    }

    private func deactivateSession() {
        guard !simulated, !MicrophoneUsers.isClaimed else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Others using the microphone

    /// Dictation or the keyboard wants the microphone: let go of it until they're done.
    func stepAside() {
        guard status == .listening else { return }
        stopListening()
        steppedAside = true
        status = .paused("While you dictate")
    }

    /// They're done: listen again, before the audio session goes, so iOS lets it carry on in the background.
    func stepBack() {
        guard steppedAside else { return }
        steppedAside = false
        guard isPaused else { return }
        startListening()
    }

    // MARK: Interruptions

    private func interrupted(_ info: [AnyHashable: Any]) {
        guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            guard status == .listening else { return }
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
            let why = reason == .builtInMicMuted ? "the microphone was muted" : "a call, Siri or another app"
            stopListening()
            status = .paused("Interrupted by \(why)")
            openGap(why)
        case .ended:
            guard isPaused, !steppedAside else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if options.contains(.shouldResume) {
                startListening()
                if status == .listening { return }
            }
            notifyPaused()
        @unknown default:
            break
        }
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override: restartIfListening()
        default: break
        }
    }

    /// iOS wouldn't let it start again by itself: a tap on this brings it back.
    private func notifyPaused() {
        let content = UNMutableNotificationContent()
        content.title = "All-day capture paused"
        content.body = "Tap to resume."
        content.categoryIdentifier = Self.pausedCategory
        let request = UNNotificationRequest(identifier: Self.pausedCategory, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static let pausedCategory = "capture-paused"

    // MARK: Conversations

    private func handle(_ event: CaptureWorker.Event) {
        switch event {
        case .opened(let conversation):
            inConversation = true
            CaptureStore.shared.save(conversation)
        case .closed(let conversation):
            inConversation = false
            CaptureStore.shared.save(conversation)
            onConversationClosed?(conversation)
        case .dropped(let id):
            inConversation = false
            CaptureStore.shared.delete(id)
        case .heard(let speech):
            rollStats()
            speechSeconds += speech
            saveStats()
        }
    }

    // MARK: Today's numbers

    private struct Stats: Codable {
        var day: Date
        var secondsOn: TimeInterval
        var speechSeconds: TimeInterval
        var gaps: [Gap]
    }

    private func openGap(_ reason: String) {
        rollStats()
        if let last = gaps.last, last.to == nil { return }
        gaps.append(Gap(from: Date(), to: nil, reason: reason))
        saveStats()
    }

    private func closeGap() {
        guard let last = gaps.last, last.to == nil else { return }
        gaps[gaps.count - 1].to = Date()
        saveStats()
    }

    /// A new day starts the numbers again.
    private func rollStats() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != statsDay else { return }
        statsDay = today
        secondsOn = 0
        speechSeconds = 0
        gaps = gaps.filter { $0.to == nil }
        if let since = listeningSince, since < today { listeningSince = today }
    }

    private func loadStats() {
        guard let data = UserDefaults.standard.data(forKey: Self.statsKey), let stats = try? JSONDecoder().decode(Stats.self, from: data),
              Calendar.current.isDateInToday(stats.day) else { return }
        secondsOn = stats.secondsOn
        speechSeconds = stats.speechSeconds
        // A gap left open by a quit ended with it.
        gaps = stats.gaps.map { gap in
            var closed = gap
            if closed.to == nil { closed.to = closed.from }
            return closed
        }
    }

    private func saveStats() {
        let stats = Stats(day: statsDay, secondsOn: secondsOn, speechSeconds: speechSeconds, gaps: gaps)
        if let data = try? JSONEncoder().encode(stats) { UserDefaults.standard.set(data, forKey: Self.statsKey) }
    }
}
