import AppKit
import AVFoundation
import FluidAudio
import Foundation
import Observation
import BindersKit

/// All-day capture on this Mac: the microphone listens through the day, the day is cut into conversations the same way
/// the iPhone cuts it, and each one is written down here and kept as a conversation, with notes, its promises as to-dos
/// and the binder it belongs to. It lets go while a meeting is recorded (that's a meeting), and what you dictate isn't
/// kept as part of a conversation. Mute stops the microphone; it never turns itself back on after a quit without asking.
@MainActor
@Observable
final class AllDayCaptureService {
    enum Status: Equatable {
        case off, listening, muted
        case paused(String)

        var title: String {
            switch self {
            case .off: "Off"
            case .listening: "Listening"
            case .muted: "Muted"
            case .paused(let reason): "Paused \(reason)"
            }
        }
    }

    private(set) var status: Status = .off
    /// A conversation is open: from the first speech until three minutes of quiet close it. Not whether anyone is
    /// speaking now, which is `hearsSpeech()`.
    private(set) var inConversation = false
    private(set) var error: String?
    /// The conversation being written down, and what's happening to it.
    private(set) var working: UUID?
    private(set) var activity: String?
    /// Today's numbers.
    private(set) var speechSeconds: TimeInterval = 0
    private(set) var secondsOn: TimeInterval = 0

    var isOn: Bool { status != .off }
    var isListening: Bool { status == .listening }
    var isMuted: Bool { status == .muted }
    func onToday(now: Date = Date()) -> TimeInterval { secondsOn + (listeningSince.map { now.timeIntervalSince($0) } ?? 0) }

    @ObservationIgnored private weak var controller: DictationController?
    @ObservationIgnored private var worker: CaptureWorker!
    @ObservationIgnored private var source: CaptureSource?
    @ObservationIgnored private var feed: AsyncStream<([Float], Date)>.Continuation?
    @ObservationIgnored private var listeningSince: Date?
    @ObservationIgnored private var statsDay = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var diarizer: OfflineDiarizerManager?
    @ObservationIgnored private var started = false
    private var settings: AppSettings { .shared }

    init(controller: DictationController, splitting: ConversationSplitter.Settings = .init()) {
        self.controller = controller
        worker = CaptureWorker(settings: splitting) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    // MARK: On and off

    /// At launch: finishes what a quit left half done, and asks before listening again if it was on.
    func start() {
        guard !started else { return }
        started = true
        recover()
        observeChanges({ [weak self] in self?.isDictating ?? false }) { [weak self] dictating in
            guard let self else { return }
            Task { await self.worker.ignore(dictating) }
        }
        observeChanges({ [weak self] in self?.controller?.meetings.isRecording ?? false }) { [weak self] recording in
            self?.meetingChanged(recording)
        }
        if settings.allDayCapture { askToResume() }
    }

    func turnOn() async {
        guard status == .off || isPaused else { return }
        error = nil
        if !settings.allDayNoticeAcknowledged {
            guard RecordingNotice.confirmAllDay() else { return }
            settings.allDayNoticeAcknowledged = true
        }
        if Permissions.microphone != .authorized {
            guard await Permissions.requestMicrophone() else {
                error = CaptureError.microphone.localizedDescription
                return
            }
        }
        settings.allDayCapture = true
        if controller?.meetings.isRecording == true {
            status = .paused("while a meeting is recorded")
            return
        }
        startListening()
    }

    func turnOff() {
        stopListening()
        status = .off
        inConversation = false
        settings.allDayCapture = false
    }

    func mute() {
        guard status == .listening || isPaused else { return }
        stopListening()
        status = .muted
    }

    func unmute() {
        guard status == .muted else { return }
        if controller?.meetings.isRecording == true {
            status = .paused("while a meeting is recorded")
        } else {
            startListening()
        }
    }

    private var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    /// Holding the dictation key, or the words being written: none of it is part of a conversation.
    private var isDictating: Bool {
        guard let controller else { return false }
        if case .idle = controller.phase { return false }
        return true
    }

    private func askToResume() {
        let alert = NSAlert()
        alert.messageText = "Turn All-day capture back on?"
        alert.informativeText = "It was on when Binders last quit. Binders listens for conversations through the day, writes them down on this Mac, and keeps them in your binders."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await turnOn() }
        } else {
            settings.allDayCapture = false
        }
    }

    // MARK: Listening

    private func startListening() {
        do {
            let source = MicSource()
            let (stream, continuation) = AsyncStream<([Float], Date)>.makeStream()
            source.onAudio = { samples, time in continuation.yield((samples, time)) }
            try source.start()
            let worker = worker!
            Task.detached(priority: .userInitiated) {
                for await (samples, time) in stream { await worker.append(samples, at: time) }
                await worker.finish()
            }
            self.source = source
            feed = continuation
            status = .listening
            error = nil
            rollStats()
            listeningSince = Date()
            Task { await prepareDetector() }
        } catch {
            source?.stop()
            source = nil
            self.error = error.localizedDescription
            status = .paused("because the microphone wouldn't start")
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
        }
    }

    /// A meeting records the conversation itself: capture lets go until it's over.
    private func meetingChanged(_ recording: Bool) {
        if recording, status == .listening {
            stopListening()
            status = .paused("while a meeting is recorded")
        } else if !recording, status == .paused("while a meeting is recorded"), settings.allDayCapture {
            startListening()
        }
    }

    /// Silero, which hears when someone is speaking; until it has loaded, loudness stands in.
    func prepareDetector() async {
        let detector = try? await VadManager(config: VadConfig(defaultThreshold: 0.6))
        await worker.useDetector(detector)
        await worker.ignore(isDictating)
    }

    /// For the self-test: audio from a file instead of the microphone, heard at `time`.
    func hear(_ samples: [Float], at time: Date) async {
        await worker.append(samples, at: time)
    }

    func finishHearing() async {
        await worker.finish()
    }

    /// Someone is speaking now, as capture hears it, while it listens: what the waveform in Settings moves with, and holds
    /// still without through the quiet of a conversation that's still open. Asked only while it shows.
    func hearsSpeech(now: Date = Date()) async -> Bool {
        guard status == .listening else { return false }
        return await speechHeard(now: now)
    }

    /// Speech heard within a second of `now` (the gaps between words), listening or not: for the self-test, which feeds
    /// audio without the microphone.
    func speechHeard(now: Date = Date()) async -> Bool {
        ConversationSplitter.isSpeaking(lastSpeech: await worker.lastSpeech, now: now)
    }

    // MARK: Conversations

    private func handle(_ event: CaptureWorker.Event) {
        switch event {
        case .opened:
            inConversation = true
        case .closed:
            inConversation = false
            processWaiting()
        case .dropped:
            inConversation = false
        case .heard(let speech):
            rollStats()
            speechSeconds += speech
        case .unsaved(let message):
            Log.meeting.error("All-day capture: \(message)")
        case .moment, .absorbed, .voiceDetector:
            break
        }
    }

    /// Conversations with work left, oldest first.
    var waiting: [CapturedConversation] {
        CaptureFiles.all().filter { [.recorded, .transcribing, .labelling].contains($0.state) && FileManager.default.fileExists(atPath: CaptureFiles.audioURL($0.id).path) }
            .sorted { $0.started < $1.started }
    }

    func processWaiting() {
        sweep()
        guard run == nil else { return }
        run = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let next = self.waiting.first {
                guard await self.process(next) else { break }
            }
            self.working = nil
            self.activity = nil
            self.diarizer = nil
            self.run = nil
        }
    }

    /// Audio kept for checking, once its day is up; and audio still not written down three days after it was heard (no
    /// speech model all that time), which then fails, as audio is never kept longer than that.
    private func sweep() {
        for var conversation in CaptureFiles.all() where conversation.id != working {
            if let until = conversation.keepAudioUntil, until < Date() {
                try? FileManager.default.removeItem(at: CaptureFiles.audioURL(conversation.id))
                conversation.keepAudioUntil = nil
                CaptureFiles.write(conversation)
            }
            if [.recorded, .transcribing, .labelling].contains(conversation.state), !conversation.audioDeleted,
               conversation.ended < Date().addingTimeInterval(-CapturedConversation.failedAudioKept) {
                try? FileManager.default.removeItem(at: CaptureFiles.audioURL(conversation.id))
                conversation.audioDeleted = true
                conversation.state = .failed
                conversation.error = "It wasn't written down within three days, so its audio was deleted."
                CaptureFiles.write(conversation)
            }
        }
    }

    /// Conversations a quit or crash left open become recorded, with what reached their file; short ones go. Week-old
    /// sent ones go too.
    private func recover() {
        for var conversation in CaptureFiles.all() {
            if conversation.state == .sent, conversation.started < Date().addingTimeInterval(-7 * 86_400) { CaptureFiles.remove(conversation.id) }
            guard conversation.state == .recording else { continue }
            let heard = max(0, conversation.spans.fileDuration - 2 * CaptureWorker.padding)
            guard heard >= ConversationSplitter.Settings().minSpeech, let last = conversation.spans.spans.last else {
                CaptureFiles.remove(conversation.id)
                continue
            }
            conversation.state = .recorded
            conversation.ended = last.wallStart.addingTimeInterval(last.duration - CaptureWorker.padding)
            conversation.speech = heard
            CaptureFiles.write(conversation)
        }
        processWaiting()
    }

    /// Writes one conversation down and keeps it. False when it has to wait (no speech model yet).
    private func process(_ conversation: CapturedConversation) async -> Bool {
        guard let controller else { return false }
        // The library didn't open: it waits here, audio and all, for a Binders that can keep it, rather than be marked sent
        // into a stand-in that's gone at quit.
        guard Store.shared.canSave else { return false }
        var current = conversation
        working = current.id
        do {
            if current.segments == nil || current.state != .labelling {
                current.state = .transcribing
                CaptureFiles.write(current)
                activity = "Writing down what was said…"
                current.segments = try await transcribe(current, controller: controller)
                current.engine = settings.speechModel.rawValue
                current.words = current.segments?.reduce(0) { $0 + TextNorm.words($1.text).count }
                current.state = .labelling
                CaptureFiles.write(current)
            }
            activity = "Telling the voices apart…"
            let segments = current.segments ?? []
            var turns: [SpeakerTurn] = []
            if !segments.isEmpty, let result = try? await speakerLabeller().process(CaptureFiles.audioURL(current.id)) {
                turns = result.segments.map { SpeakerTurn(speakerID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            }
            let labelled = CaptureTranscript.label(segments, turns: turns).segments
            current.transcript = CaptureTranscript.onTheClock(labelled, spans: current.spans, started: current.started, ended: current.ended)
            current.speakers = [:]
            current.segments = nil
            if let payload = current.payload(device: "Mac") {
                controller.conversations.receive(payload)
                current.state = .sent
            } else {
                // Nothing intelligible after all.
                CaptureFiles.remove(current.id)
                return true
            }
            if settings.allDayKeepAudio {
                current.keepAudioUntil = Date().addingTimeInterval(86_400)
            } else {
                try? FileManager.default.removeItem(at: CaptureFiles.audioURL(current.id))
                current.audioDeleted = true
            }
            CaptureFiles.write(current)
            return true
        } catch is SpeechWait {
            return false
        } catch {
            // The Mac doesn't try a failed one again, so its audio goes now.
            current.state = .failed
            current.error = error.localizedDescription
            try? FileManager.default.removeItem(at: CaptureFiles.audioURL(current.id))
            current.audioDeleted = true
            CaptureFiles.write(current)
            return true
        }
    }

    private struct SpeechWait: Error {}

    /// What was said, in segments cut at pauses, with times in the audio file.
    private func transcribe(_ conversation: CapturedConversation, controller: DictationController) async throws -> [TranscriptSegment] {
        guard let engine = try? await controller.speech.waitUntilReady() else { throw SpeechWait() }
        let file = try AVAudioFile(forReading: CaptureFiles.audioURL(conversation.id))
        let vocabulary = Store.shared.vocabulary()
        var segments: [TranscriptSegment] = []
        var position: AVAudioFramePosition = 0
        while position < file.length {
            file.framePosition = position
            let count = AVAudioFrameCount(min(Int64(30 * 16_000), file.length - position))
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { break }
            try file.read(into: buffer, frameCount: count)
            guard let channel = buffer.floatChannelData?[0] else { break }
            let window = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            guard !window.isEmpty else { break }
            let length = max(1, SpeechChunker.nextBoundary(window[...], isFinal: true) ?? window.count)
            let chunk = Array(window.prefix(length))
            if !AudioMath.isSilent(chunk) {
                let text = try await engine.transcribe(AudioMath.normalize(chunk), language: settings.languageHint,
                                                       vocabulary: vocabulary, boost: settings.vocabularyBoost)
                if !text.isEmpty {
                    let start = Double(position) / 16_000
                    segments.append(TranscriptSegment(channel: .microphone, start: start, end: start + Double(chunk.count) / 16_000,
                                                      text: text, speaker: CaptureTranscript.unlabelled))
                }
            }
            position += AVAudioFramePosition(length)
        }
        return segments
    }

    private func speakerLabeller() async throws -> OfflineDiarizerManager {
        if let diarizer { return diarizer }
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        diarizer = manager
        return manager
    }

    // MARK: Today

    private func rollStats() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != statsDay else { return }
        statsDay = today
        secondsOn = 0
        speechSeconds = 0
        if let since = listeningSince, since < today { listeningSince = today }
    }

    /// This Mac's conversations today, newest first, with where each one is.
    func today() -> [CapturedConversation] {
        CaptureFiles.all().filter { Calendar.current.isDateInToday($0.started) }
    }
}

/// Binders files from the iPhone, by AirDrop, Files or Mail: each conversation in one is kept once, like one sent over
/// the link.
@MainActor
enum BindersFiles {
    /// Keeps what's in a Binders file. A file AirDrop left in Downloads goes to the Trash once kept, so the text doesn't
    /// sit there. Opened from inside a folder (the Captures page's Open a Binders File…), what's kept goes in `folder`
    /// when it lands in that folder's binder, and stays there once it's read.
    @discardableResult
    static func open(_ url: URL, controller: DictationController, folder: UUID? = nil) -> String {
        // Not while the library didn't open: the file stays where it is, to open again once Binders can keep it.
        guard Store.shared.allowsSave() else { return Store.unavailableMessage }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let transfer = try BindersTransfer.decode(Data(contentsOf: url))
            var kept = 0
            for conversation in transfer.conversations {
                guard case .kept(let id) = controller.conversations.receive(conversation) else { continue }
                kept += 1
                if let folder, let record = Store.shared.meeting(id), Store.shared.folder(folder)?.binderID == record.binderID {
                    try? Store.shared.move(record, toFolder: folder)
                }
            }
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath().path ?? ""
            if !downloads.isEmpty, url.resolvingSymlinksInPath().deletingLastPathComponent().path == downloads {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            let count = transfer.conversations.count
            let message: String
            if kept == 0 {
                message = count == 1 ? "Already had this capture" : "Already had these \(count) captures"
            } else {
                message = kept == 1 ? "Kept a capture from your iPhone" : "Kept \(kept) captures from your iPhone"
            }
            controller.flowBar.toast(message, symbol: "bubble.left.and.bubble.right", duration: 4)
            return message
        } catch {
            let message = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            controller.flowBar.toast(message, symbol: "exclamationmark.triangle", duration: 5)
            return message
        }
    }
}
