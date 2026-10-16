import AVFoundation
import BackgroundTasks
import BindersKit
import FluidAudio
import Foundation
import Observation
import UIKit
import UserNotifications

/// Turns each conversation All-day capture heard into text, on this iPhone: Parakeet writes down what was said, the
/// diarizer tells the voices apart, and your own voice, if you taught it, becomes "You". The text goes into the outbox
/// for the Mac, and only then is the audio deleted. It runs straight away while the app is open, and otherwise in the
/// background while the phone charges, where iOS lets the models run there (`CaptureModels.mayInferInBackground`);
/// every step is saved, so it picks up where it stopped.
@MainActor
@Observable
final class ConversationProcessor {
    static let shared = ConversationProcessor()
    static let taskIdentifier = "io.binders.app.conversations"
    static let reminderIdentifier = "capture-waiting"

    /// The conversation being worked on, and what's happening to it.
    private(set) var working: UUID?
    private(set) var activity: String?

    /// Developer setting: keep each conversation's audio for a day after its transcript is in the outbox, to check how
    /// well it was transcribed. Debug builds only: a release never keeps audio.
    var keepsAudio: Bool {
        didSet { UserDefaults.standard.set(keepsAudio, forKey: "captureKeepAudio") }
    }

    @ObservationIgnored weak var connection: MacConnection?
    @ObservationIgnored private var run: Task<Void, Never>?
    /// Failed conversations tried again since the app last came to the front: once each per visit.
    @ObservationIgnored private var retriedThisVisit: Set<UUID> = []
    /// The conversation being written down with the app in front. Still set at launch, it ended Binders: a failure.
    private static let attemptKey = "captureAttempt"
    private var store: CaptureStore { .shared }
    private var models: CaptureModels { .shared }

    private init() {
        #if DEBUG
        keepsAudio = UserDefaults.standard.bool(forKey: "captureKeepAudio")
        #else
        keepsAudio = false
        #endif
    }

    /// Conversations with work left before they can go to the Mac, oldest first.
    var waiting: [CapturedConversation] {
        store.conversations.filter { [.recorded, .transcribing, .labelling].contains($0.state) && !$0.audioDeleted }
            .sorted { $0.started < $1.started }
    }

    /// Failed with the app open and with tries left: tried again while the app is open, once a visit, oldest first.
    private var retryable: [CapturedConversation] {
        guard UIApplication.shared.applicationState == .active else { return [] }
        return store.conversations.filter { $0.canRetry && !retriedThisVisit.contains($0.id) }.sorted { $0.started < $1.started }
    }

    /// The app is open, or iOS lets the models run with it in the background.
    private var mayRunNow: Bool {
        UIApplication.shared.applicationState == .active || CaptureModels.mayInferInBackground
    }

    // MARK: When it runs

    /// Called once, as the app launches: the background task, and whatever a quit left half done.
    static func setUp() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in await ConversationProcessor.shared.runInBackground(task) }
        }
    }

    /// A conversation just ended: written down now if the app is open; otherwise while the phone charges, where iOS lets
    /// the models run in the background, with a quiet reminder that it's waiting.
    func conversationClosed(_ conversation: CapturedConversation) {
        if UIApplication.shared.applicationState == .active {
            processWaiting()
        } else {
            scheduleBackgroundRun()
            remindLater()
        }
    }

    func scheduleBackgroundRun() {
        // Where iOS keeps the models from background apps, a background run couldn't write anything down.
        guard CaptureModels.mayInferInBackground else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Works through what's waiting, one at a time, then what failed and has tries left, once each. With the app in the
    /// background it carries on only where iOS lets the models run there.
    func processWaiting() {
        guard run == nil else { return }
        run = Task { [weak self] in
            guard let self else { return }
            self.keepScreenOn(true)
            var tried: Set<UUID> = []
            while !Task.isCancelled, self.mayRunNow,
                  let next = (self.waiting + self.retryable).first(where: { !tried.contains($0.id) }) {
                tried.insert(next.id)
                if next.state == .failed { self.retriedThisVisit.insert(next.id) }
                let stopped = await self.process(next)
                if stopped { break }
            }
            self.keepScreenOn(false)
            self.working = nil
            self.activity = nil
            self.run = nil
            let inFront = UIApplication.shared.applicationState == .active
            // In the background the big models go once the work is done: iOS 27 counts their memory against the app.
            if !inFront { self.models.unloadLarge() }
            if self.waiting.isEmpty { self.clearReminder() } else if !inFront { self.remindLater() }
        }
    }

    /// The app came to the front: what's waiting is written down, failed ones get a try, and the reminder goes.
    func appBecameActive() {
        retriedThisVisit = []
        clearReminder()
        store.tidy()
        processWaiting()
    }

    /// The app left the front. An attempt cut short now isn't the capture's fault. Where iOS keeps the models from
    /// background apps (iOS 27), the run stops and the models are let go.
    func appLeftForeground(toBackground: Bool) {
        UserDefaults.standard.removeObject(forKey: Self.attemptKey)
        guard toBackground, !CaptureModels.mayInferInBackground else { return }
        run?.cancel()
        if run == nil { models.unloadLarge() }
    }

    /// Deleted while it's being written down: the work on it stops, it stays deleted, and the rest carry on.
    func forget(_ id: UUID) {
        guard working == id, let current = run else { return }
        current.cancel()
        Task { [weak self] in
            await current.value
            if UIApplication.shared.applicationState == .active { self?.processWaiting() }
        }
    }

    /// While it writes things down with the app in front, on an iOS that won't let it carry on in the background, the
    /// screen stays on: Auto-Lock would stop it.
    private func keepScreenOn(_ on: Bool) {
        guard !CaptureModels.mayInferInBackground else { return }
        UIApplication.shared.isIdleTimerDisabled = on && UIApplication.shared.applicationState == .active
    }

    private func runInBackground(_ task: BGProcessingTask) async {
        task.expirationHandler = {
            // Out of time: stop between steps; what's done is saved, the rest carries on next time.
            Task { @MainActor in ConversationProcessor.shared.run?.cancel() }
        }
        // A task an earlier version scheduled can still come after an update to iOS 27: then it only sends what's ready.
        if CaptureModels.mayInferInBackground {
            processWaiting()
            await run?.value
        }
        await connection?.flushOutbox()
        models.unloadLarge()
        if !waiting.isEmpty { scheduleBackgroundRun() }
        task.setTaskCompleted(success: waiting.isEmpty)
    }

    // MARK: Waiting

    /// A quiet notification, ten minutes on, that captures are waiting to be written down: at most one an hour, gone
    /// once the app opens or they're written down, and off with Notify me.
    private func remindLater() {
        guard SuggestionCenter.shared.notifies else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: "captureRemindedAt") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 3_600 else { return }
        defaults.set(Date(), forKey: "captureRemindedAt")
        let content = UNMutableNotificationContent()
        content.body = CaptureModels.mayInferInBackground
            ? "Captures are waiting to be written down. Open Binders to write them down now, or they're written down while your iPhone charges."
            : "Captures are waiting to be written down. Open Binders to write them down on this iPhone."
        content.threadIdentifier = Self.reminderIdentifier
        content.interruptionLevel = .passive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10 * 60, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.reminderIdentifier, content: content, trigger: trigger))
    }

    /// The app is open, or nothing's waiting any more: the reminder goes. One taken away before it showed doesn't count
    /// toward the hour.
    func clearReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.reminderIdentifier])
        let defaults = UserDefaults.standard
        if let at = defaults.object(forKey: "captureRemindedAt") as? Date, Date().timeIntervalSince(at) < 10 * 60 {
            defaults.removeObject(forKey: "captureRemindedAt")
        }
    }

    /// Conversations a quit or crash left open become recorded, with what reached their file; short ones go. An attempt
    /// that ended Binders with the app in front counts as a failure.
    func recover() {
        if let value = UserDefaults.standard.string(forKey: Self.attemptKey), let id = UUID(uuidString: value) {
            UserDefaults.standard.removeObject(forKey: Self.attemptKey)
            store.update(id) {
                let failures = ($0.failures ?? 0) + 1
                $0.failures = failures
                if failures >= CapturedConversation.maxFailures {
                    $0.state = .failed
                    $0.error = "Writing it down kept stopping Binders."
                }
            }
        }
        // What the diarizer was reading when Binders stopped: a full copy of the audio, in the temporary folder.
        let temporary = FileManager.default.temporaryDirectory
        for file in (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("fluidaudio-streaming-") {
            try? FileManager.default.removeItem(at: file)
        }
        for conversation in store.conversations where conversation.state == .recording {
            let spans = conversation.spans
            let heard = max(0, spans.fileDuration - 2 * CaptureWorker.padding)
            guard heard >= ConversationSplitter.Settings().minSpeech, let last = spans.spans.last else {
                store.delete(conversation.id)
                continue
            }
            store.update(conversation.id) {
                $0.state = .recorded
                $0.ended = last.wallStart.addingTimeInterval(last.duration - CaptureWorker.padding)
                $0.speech = heard
            }
        }
        store.tidy()
        requeueLostSends()
        if !waiting.isEmpty { scheduleBackgroundRun() }
    }

    /// Written down and waiting for the Mac, but not in the outbox (its write failed): it goes back in.
    private func requeueLostSends() {
        guard let connection else { return }
        let device = UIDevice.current.model
        for conversation in store.conversations where conversation.state == .queued && conversation.sharedVia == nil
        && !connection.outbox.contains(where: { $0.conversation == conversation.id }) {
            guard let payload = conversation.payload(device: device) else { continue }
            Task { await connection.keepConversation(payload) }
        }
    }

    // MARK: One conversation

    private enum Failure: LocalizedError {
        case noModel, unreadable

        var errorDescription: String? {
            switch self {
            case .noModel: "Waiting for the speech model, which downloads over Wi-Fi."
            case .unreadable: "Its audio couldn't be read."
            }
        }
    }

    /// True when it had to stop for now (no model yet, out of time, or kept from the models in the background): the rest
    /// wait too.
    private func process(_ conversation: CapturedConversation) async -> Bool {
        let id = conversation.id
        // A record from before failures were counted, already failed, counts once.
        let failedBefore = conversation.failures ?? (conversation.state == .failed ? 1 : 0)
        working = id
        if UIApplication.shared.applicationState == .active { UserDefaults.standard.set(id.uuidString, forKey: Self.attemptKey) }
        defer { UserDefaults.standard.removeObject(forKey: Self.attemptKey) }
        do {
            var current = conversation
            if current.segments == nil || current.state != .labelling {
                current.state = .transcribing
                current.error = nil
                store.save(current)
                activity = "Writing down what was said…"
                let (segments, engine) = try await transcribe(current)
                // Deleted while it was written down: it stays deleted, and nothing of it goes to the Mac.
                guard store.conversation(id) != nil else { return false }
                current.segments = segments
                current.engine = engine
                current.words = segments.reduce(0) { $0 + TextNorm.words($1.text).count }
                current.state = .labelling
                store.save(current)
            }
            try Task.checkCancellation()
            // Telling the voices apart needs the models too: where they can't run now, it waits with what's written.
            guard mayRunNow else { return true }
            activity = "Telling the voices apart…"
            let (segments, speakers) = try await label(current)
            try Task.checkCancellation()
            guard store.conversation(id) != nil else { return false }
            guard !segments.isEmpty else {
                // Nothing intelligible after all: it goes, audio and all.
                store.delete(id)
                return false
            }
            // Kept here too, to read on this iPhone and to share again.
            current.transcript = CaptureTranscript.onTheClock(segments, spans: current.spans, started: current.started, ended: current.ended)
            current.speakers = speakers
            current.segments = nil
            guard let payload = current.payload(device: UIDevice.current.model) else {
                store.delete(id)
                return false
            }
            activity = "Sending to your Mac…"
            current.state = .queued
            store.save(current)
            let sent = await connection?.keepConversation(payload) ?? false
            // The text is safe in the outbox now: the audio can go.
            if keepsAudio {
                store.update(id) { $0.keepAudioUntil = Date().addingTimeInterval(86_400) }
            } else {
                store.deleteAudio(id)
            }
            // Unless the Mac refused it, which marks it failed.
            if sent, store.conversation(id)?.state == .queued { store.update(id) { $0.state = .sent } }
            return false
        } catch is CancellationError {
            store.update(id) { if $0.state == .transcribing { $0.state = .recorded } }
            return true
        } catch Failure.unreadable {
            // Reading it again won't help.
            store.update(id) {
                $0.state = .failed
                $0.error = Failure.unreadable.localizedDescription
                $0.failures = CapturedConversation.maxFailures
            }
            return false
        } catch Failure.noModel {
            store.update(id) {
                $0.state = .recorded
                $0.error = Failure.noModel.localizedDescription
            }
            return true
        } catch {
            if !mayRunNow {
                // With the app in the background, iOS 27 keeps apps off the Neural Engine. That's no failure: it waits,
                // and is written down once the app is open.
                store.update(id) {
                    if $0.state == .transcribing { $0.state = .recorded }
                    $0.error = nil
                }
                return true
            }
            store.update(id) {
                $0.state = .failed
                $0.error = error.localizedDescription
                $0.failures = failedBefore + 1
            }
            retriedThisVisit.insert(id)
            return false
        }
    }

    // MARK: Transcribing

    /// What was said, in segments cut at pauses, with times in the audio file.
    private func transcribe(_ conversation: CapturedConversation) async throws -> ([TranscriptSegment], String) {
        let url = CaptureFiles.audioURL(conversation.id)
        guard let file = try? AVAudioFile(forReading: url) else { throw Failure.unreadable }
        let engine: String
        let write: ([Float]) async throws -> String
        if let parakeet = await models.transcriber() {
            engine = models.engineName
            write = { samples in
                var state = TdtDecoderState.make(decoderLayers: await parakeet.decoderLayerCount)
                return try await parakeet.transcribe(AudioMath.padded(samples, toAtLeast: 16_000), decoderState: &state, language: nil).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if #available(iOS 26.0, *), AnalyzerEngine.isSupported {
            // Until Parakeet is here: Apple's own engine, also on the device.
            engine = "apple-speech"
            write = { samples in try await Self.appleTranscribe(samples) }
        } else {
            throw Failure.noModel
        }

        var segments: [TranscriptSegment] = []
        var position: AVAudioFramePosition = 0
        while position < file.length {
            try Task.checkCancellation()
            let window = try Self.read(file, from: position, frames: 30 * 16_000)
            guard !window.isEmpty else { break }
            let length = max(1, SpeechChunker.nextBoundary(window[...], isFinal: true) ?? window.count)
            let chunk = Array(window.prefix(length))
            if !AudioMath.isSilent(chunk) {
                let text = try await write(AudioMath.normalize(chunk))
                if !text.isEmpty {
                    let start = Double(position) / 16_000
                    segments.append(TranscriptSegment(channel: .microphone, start: start, end: start + Double(chunk.count) / 16_000,
                                                      text: text, speaker: CaptureTranscript.unlabelled))
                }
            }
            position += AVAudioFramePosition(length)
        }
        return (segments, engine)
    }

    nonisolated static func read(_ file: AVAudioFile, from position: AVAudioFramePosition, frames: Int) throws -> [Float] {
        file.framePosition = position
        let count = AVAudioFrameCount(min(Int64(frames), file.length - position))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        try file.read(into: buffer, frameCount: count)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    @available(iOS 26.0, *)
    private static func appleTranscribe(_ samples: [Float]) async throws -> String {
        let engine = AnalyzerEngine()
        try await engine.prepare()
        if let buffer = AVAudioPCMBuffer(pcmFormat: SixteenKilohertz.format, frameCapacity: AVAudioFrameCount(samples.count)),
           let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            engine.append(buffer)
        }
        return try await engine.finish()
    }

    // MARK: Speakers

    /// Each segment gets the voice it overlaps most, "Speaker 1", "Speaker 2"… in the order they first speak; the one
    /// that sounds like the voice you taught Binders is "You".
    /// Throws when it was cut short or the models can't run now, so the conversation waits instead of going as one voice.
    private func label(_ conversation: CapturedConversation) async throws -> ([TranscriptSegment], [String: String]) {
        let segments = conversation.segments ?? []
        guard !segments.isEmpty else { return ([], [:]) }
        var turns: [SpeakerTurn] = []
        var voices: [String: [Float]] = [:]
        if let diarizer = await models.speakerLabeller() {
            do {
                let result = try await diarizer.process(CaptureFiles.audioURL(conversation.id))
                turns = result.segments.map { SpeakerTurn(speakerID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
                voices = result.speakerDatabase ?? [:]
            } catch {
                if error is CancellationError || Task.isCancelled || !mayRunNow { throw error }
                // Otherwise the diarizer found nothing to tell apart: one voice.
            }
        } else if !mayRunNow {
            throw CancellationError()
        }
        let (labelled, labels) = CaptureTranscript.label(segments, turns: turns)
        var speakers: [String: String] = [:]
        if let you = VoicePrint.closest(among: voices), let label = labels[you] { speakers[label] = TranscriptSegment.you }
        return (labelled, speakers)
    }

    // MARK: Trying it out

    /// Debug builds: runs the whole pipeline on a recording that ships with the app, for the Simulator, which can't listen.
    func processSample() {
        guard let sample = Bundle.main.url(forResource: "capture-sample", withExtension: "caf"),
              let file = try? AVAudioFile(forReading: sample) else { return }
        let id = UUID()
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        let started = Date().addingTimeInterval(-seconds)
        try? FileManager.default.copyItem(at: sample, to: CaptureFiles.audioURL(id))
        var spans = CaptureSpans()
        spans.append(wallStart: started, duration: seconds)
        store.save(CapturedConversation(id: id, started: started, ended: Date(), speech: seconds, state: .recorded, spans: spans))
        processWaiting()
    }
}
