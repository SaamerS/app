import AVFoundation
import BindersKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// The calibration bench for things said to yourself (Capture → Calibrate): phrases said one at a time, by you and by
/// someone else, a timed run of TV or a podcast, and the 40 lines that check automatic mode. Each clip is heard by a
/// detector of its own, the one capture runs (CaptureWorker, keeping no conversation), and goes through the real gate with
/// every check run for its score (MomentCenter.gate), and the binder it names and the day it's due are read as the rules
/// read them. Your Mac's model isn't on the bench: clips never go to the Mac. What's kept is scores, timings and labels
/// (MomentBench.Result), on
/// this iPhone and out of backups, until you delete them. Each clip's audio is let go once it's scored; its words are
/// shown with its result and never kept. While a run of phrases is open, and through a timed run, the microphone is the
/// bench's: All-day capture steps aside, as for a dictation, so nothing said for the bench becomes a moment, and carries
/// on once the screen closes or the timed run ends.
@MainActor
@Observable
final class CalibrationBench {
    static let shared = CalibrationBench()

    enum Phase: Equatable {
        /// Nothing in hand.
        case ready
        /// The microphone is on: for the phrase on screen, or for the timed run.
        case listening
        /// What was said is going through the checks.
        case checking
        /// It couldn't listen, or heard nothing: why, and what to do next.
        case problem(String)
    }

    /// What a result's clip was written down as: shown with it, never kept.
    struct Heard: Equatable {
        let result: UUID
        let words: String
    }

    private(set) var phase: Phase = .ready
    private(set) var store: MomentBench.Store
    /// The voice threshold the gate holds things said on its own to now, and when the bench set it (nil: the default),
    /// mirrored from VoicePrint so screens follow them.
    private(set) var threshold = VoicePrint.momentThreshold
    private(set) var thresholdSet = VoicePrint.momentThresholdSet
    /// The start bar (VoicePrint.startThreshold), mirrored the same way; nil until Calibrate sets it.
    private(set) var startBar = VoicePrint.startThreshold
    /// The print the voice scores are against now (VoicePrint.fingerprint).
    private(set) var voicePrint = VoicePrint.fingerprint
    /// How loud it is, 0…1, for the meter while listening.
    private(set) var level: Double = 0
    /// The voice detector isn't on this iPhone yet, so loudness stands in for it, as in capture.
    private(set) var byLoudness = false
    private(set) var heard: Heard?
    /// The timed run under way, and when it ends.
    private(set) var timedRun: MomentBench.Session?
    private(set) var timedRunEnds: Date?
    /// Keep the screen on through the timed run, so clips are scored as they come.
    var keepsScreenOn = true
    /// Clips of the timed run that couldn't be written down while the iPhone was locked: held in memory, and scored once
    /// it's open. And those let go unscored, past what can be held.
    private(set) var held = 0
    private(set) var unscored = 0
    /// Clips waiting for the checks, or going through them.
    private(set) var checking = 0
    /// Something took the microphone during the timed run (a call, Siri): it listens again once that's over.
    private(set) var interrupted = false

    @ObservationIgnored private var source: MicSource?
    @ObservationIgnored private var feed: AsyncStream<([Float], Date)>.Continuation?
    /// The detector listening now, and the token its events carry, so a stopped one's are ignored.
    @ObservationIgnored private var worker: CaptureWorker?
    @ObservationIgnored private var listening = UUID()
    @ObservationIgnored private var lastAudio = Date.distantPast
    @ObservationIgnored private var lastRestart = Date.distantPast
    /// Who holds the microphone for the bench: an open run of phrases, the timed run.
    @ObservationIgnored private var holding: Set<String> = []
    /// The phrase or line listened for.
    @ObservationIgnored private var target: Target?
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var queue: [Waiting] = []
    @ObservationIgnored private var scoring: Task<Void, Never>?
    @ObservationIgnored private var heldClips: [Waiting] = []
    /// Record or Start was tapped and the microphone is on its way: another tap waits.
    @ObservationIgnored private var starting = false

    /// MicrophoneUsers' names for the two.
    private static let phrasesUser = "bench"
    private static let timedUser = "bench-timed"
    /// The most audio held for scoring later, in seconds, about 40 MB.
    private static let mostHeld: TimeInterval = 600
    /// Listening for a phrase stops after this long with nothing heard on its own.
    private static let patience: TimeInterval = 30

    private struct Target {
        let phrase: String
        let run: MomentBench.Run
        let session: UUID
        let since: Date
    }

    private struct Waiting {
        let clip: CaptureWorker.MomentClip
        let arrived: Date
        let target: Target?
        let run: MomentBench.Run
        let session: UUID
        var later = false
    }

    private init() {
        store = Self.load()
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { CalibrationBench.shared.interruption(began: began) }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CalibrationBench.shared.restartSource() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CalibrationBench.shared.scoreHeld() }
        }
    }

    // MARK: The microphone

    /// A run of phrases is open: the microphone is the bench's until it closes, so All-day capture steps aside now, and
    /// anything you say while reading the next phrase stays out of it.
    func open() {
        refresh()
        hold(Self.phrasesUser)
    }

    /// It closed, or Binders left the screen: whatever was being listened for is let go, and capture carries on.
    func close() {
        cancelRecording()
        moveOn()
        release(Self.phrasesUser)
    }

    /// Asked as a run of phrases opens, the first time: iOS's question takes Binders out of the front for a moment, which
    /// would let go of a phrase being recorded.
    func askForMicrophone() async {
        guard AVAudioApplication.shared.recordPermission == .undetermined else { return }
        if !(await AVAudioApplication.requestRecordPermission()) { phase = .problem(CaptureError.microphone.localizedDescription) }
    }

    /// The voice threshold and print as they are now, after a change somewhere else (a print taught or forgotten).
    func refresh() {
        threshold = VoicePrint.momentThreshold
        thresholdSet = VoicePrint.momentThresholdSet
        startBar = VoicePrint.startThreshold
        voicePrint = VoicePrint.fingerprint
    }

    /// On to another phrase: the words heard for the last one go, and so does what went wrong with it.
    func moveOn() {
        heard = nil
        if case .problem = phase { phase = .ready }
    }

    var isTimedRunGoing: Bool { timedRun != nil }

    private func hold(_ who: String) {
        guard holding.insert(who).inserted else { return }
        MicrophoneUsers.claim(who)
        // The keyboard keeping the microphone ready lets go of it, unless you're dictating.
        KeyboardListener.shared.letGoIfIdle()
    }

    private func release(_ who: String) {
        guard holding.remove(who) != nil else { return }
        MicrophoneUsers.release(who)
        // All-day capture, listening again, keeps the audio session; so does anyone else still using it.
        if !MicrophoneUsers.isClaimed, !MicrophoneUsers.captureNeedsSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// The microphone on, as capture has it (mixed with what's playing, the iPhone's own microphone), feeding a detector of
    /// the bench's own. `primed`: for a phrase, it's told there was quiet before, as you were reading, not talking, so
    /// what you say next is heard as said on its own; the timed run hears the quiet for itself.
    private func startMicrophone(primed: Bool) async throws {
        stopMicrophone(deactivating: false)
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        try? audio.setPrefersNoInterruptionsFromSystemAlerts(true)
        try audio.setActive(true)
        let token = UUID()
        listening = token
        let worker = CaptureWorker(keepsConversations: false) { event in
            Task { @MainActor in CalibrationBench.shared.handle(event, from: token) }
        }
        await worker.useMoments(MomentDetector.Settings())
        let detector = await CaptureModels.shared.voiceDetector()
        await worker.useDetector(detector)
        byLoudness = detector == nil
        if primed {
            let quiet = MomentDetector.Settings().quietBefore + 0.5
            await worker.append([Float](repeating: 0, count: Int(quiet * 16_000)), at: Date().addingTimeInterval(-quiet))
        }
        let source = MicSource()
        let (stream, continuation) = AsyncStream<([Float], Date)>.makeStream()
        source.onAudio = { samples, time in continuation.yield((samples, time)) }
        do {
            try source.start()
        } catch {
            continuation.finish()
            throw error
        }
        self.worker = worker
        self.source = source
        feed = continuation
        lastAudio = Date()
        Task.detached(priority: .userInitiated) {
            var told = Date.distantPast
            for await (samples, time) in stream {
                await worker.append(samples, at: time)
                guard Date().timeIntervalSince(told) >= 0.1 else { continue }
                told = Date()
                let loudness = Self.loudness(samples)
                await MainActor.run { CalibrationBench.shared.heardAudio(loudness, from: token) }
            }
            // Stopped: anything still in hand is let go with it.
            await worker.finish()
        }
    }

    /// The microphone off, and the detector with it: what it held goes. The audio session goes too, unless capture or the
    /// keyboard needs it, or `deactivating` is off because capture is about to listen again in the background.
    private func stopMicrophone(deactivating: Bool = true) {
        source?.stop()
        source = nil
        feed?.finish()
        feed = nil
        worker = nil
        listening = UUID()
        level = 0
        if deactivating, !MicrophoneUsers.captureNeedsSession, !KeyboardListener.shared.isOn {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// A new microphone source into the same detector, while it listens: the route or the engine changed (AirPods, a
    /// reset), the audio stopped coming, or something that took the microphone is done with it.
    private func restartSource() {
        guard let feed else { return }
        lastRestart = Date()
        source?.stop()
        source = nil
        let source = MicSource()
        source.onAudio = { samples, time in feed.yield((samples, time)) }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try source.start()
            self.source = source
            lastAudio = Date()
            interrupted = false
        } catch {
            if timedRun != nil { interrupted = true } else { stopListening(problem: "The microphone stopped. Tap Record to try again.") }
        }
    }

    /// A call, Siri or another app took the microphone: a phrase is let go, to say again; the timed run pauses, and
    /// listens again once it's over.
    private func interruption(began: Bool) {
        guard feed != nil else { return }
        if began {
            if timedRun != nil {
                interrupted = true
            } else if target != nil {
                stopListening(problem: "A call or another app took the microphone. Tap Record to try again.")
            }
        } else if timedRun != nil, interrupted {
            restartSource()
        }
    }

    private func heardAudio(_ loudness: Double, from token: UUID) {
        guard token == listening else { return }
        lastAudio = Date()
        level = loudness
    }

    private func handle(_ event: CaptureWorker.Event, from token: UUID) {
        guard token == listening else { return }
        switch event {
        case .moment(let clip): arrived(clip)
        case .voiceDetector(let working): byLoudness = !working
        default: break
        }
    }

    // MARK: Phrases

    /// Listens for one phrase or line of `run`: the microphone comes on, and the next thing said on its own goes through
    /// the gate, once the detector hands it on after the quiet that follows it.
    func record(_ phrase: String, in run: MomentBench.Run) async {
        guard !starting, timedRun == nil, target == nil, phase != .checking, phase != .listening else { return }
        starting = true
        defer { starting = false }
        heard = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .problem(CaptureError.microphone.localizedDescription)
            return
        }
        let listeningFor = Target(phrase: phrase, run: run, session: pass(run).id, since: Date())
        target = listeningFor
        phase = .listening
        hold(Self.phrasesUser)
        do {
            try await startMicrophone(primed: true)
        } catch {
            target = nil
            phase = .problem("The microphone didn't start (\(error.localizedDescription)). Tap Record to try again.")
            return
        }
        guard target?.since == listeningFor.since else { return stopMicrophone() }
        watching?.cancel()
        watching = Task { await watch(listeningFor) }
    }

    /// Stop listening for the phrase, keeping nothing.
    func cancelRecording() {
        guard target != nil else { return }
        target = nil
        watching?.cancel()
        stopMicrophone()
        phase = .ready
    }

    /// While a phrase is listened for: the detector letting go of what was said ends it, once nothing more is being said,
    /// and half a minute with nothing heard on its own does too. A clip handed on ends it first (`arrived`).
    private func watch(_ listeningFor: Target) async {
        var quietSince: Date?
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let current = target, current.since == listeningFor.since, let worker else { return }
            let letGo = await worker.momentsLetGo, hearing = await worker.hearingMoment
            guard target?.since == listeningFor.since else { return }
            if letGo > 0, !hearing {
                let since = quietSince ?? Date()
                quietSince = since
                if Date().timeIntervalSince(since) >= 1.5 { return letGoOf(current) }
            } else {
                quietSince = nil
            }
            if Date().timeIntervalSince(current.since) > Self.patience {
                target = nil
                stopListening(problem: "Nothing was heard on its own. Tap Record, say it, then stay quiet for a few seconds.")
                return
            }
        }
    }

    private func stopListening(problem: String) {
        target = nil
        watching?.cancel()
        stopMicrophone()
        phase = .problem(problem)
    }

    /// The detector let it go before any check: too little speech, too long, or answered.
    private func letGoOf(_ listeningFor: Target) {
        target = nil
        stopMicrophone()
        keep(MomentBench.Result(run: listeningFor.run, session: listeningFor.session, heard: listeningFor.since, phrase: listeningFor.phrase,
                                detector: .letGo, threshold: Double(threshold), voicePrint: voicePrint))
        phase = .ready
    }

    private func arrived(_ clip: CaptureWorker.MomentClip) {
        let now = Date()
        if let timedRun {
            enqueue(Waiting(clip: clip, arrived: now, target: nil, run: .media, session: timedRun.id))
        } else if let listeningFor = target {
            target = nil
            watching?.cancel()
            stopMicrophone()
            phase = .checking
            enqueue(Waiting(clip: clip, arrived: now, target: listeningFor, run: listeningFor.run, session: listeningFor.session))
        }
        // Otherwise it was heard after what it was for was done with: let go.
    }

    // MARK: Passes

    /// The pass `run` is on: its latest, or a first one.
    @discardableResult
    func pass(_ run: MomentBench.Run) -> MomentBench.Session {
        store.latest(run) ?? startPass(run)
    }

    /// A new pass: your phrases again, the next person reading, the 40 lines again. Earlier passes keep their results.
    /// `sameReader`: someone else's phrases again from the start, by the reader of the latest pass.
    @discardableResult
    func startPass(_ run: MomentBench.Run, sameReader: Bool = false) -> MomentBench.Session {
        let latestReader = store.latest(.otherVoices)?.reader ?? 0
        let reader = run == .otherVoices ? (sameReader ? max(1, latestReader) : latestReader + 1) : nil
        let session = MomentBench.Session(run: run, started: Date(), reader: reader)
        store.sessions.append(session)
        save()
        return session
    }

    /// The latest pass of `run` holds voices scored against another print, or before voices were scored as now
    /// (VoicePrint.scoring): a new pass, so its phrases are said again and judged by today's scores, not shown as not
    /// taken for a score that no longer compares. Earlier passes keep their results.
    func startOverIfScoredOtherwise(_ run: MomentBench.Run) {
        guard run != .media, let print = voicePrint, let session = store.latest(run),
              store.results(in: session.id).values.contains(where: { $0.voice != nil && $0.voicePrint != print }) else { return }
        startPass(run, sameReader: true)
    }

    /// The latest pass's results, by phrase or line.
    func results(_ run: MomentBench.Run) -> [String: MomentBench.Result] {
        guard let session = store.latest(run) else { return [:] }
        return store.results(in: session.id)
    }

    // MARK: The timed run

    /// TV or a podcast for `minutes`: the microphone stays on, with the screen locked too, and everything the gate would
    /// have taken is a false accept. Stay quiet yourself: everything heard counts as the TV.
    func startTimedRun(minutes: Int) async {
        guard !starting, timedRun == nil, target == nil, phase != .checking, phase != .listening else { return }
        starting = true
        defer { starting = false }
        heard = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .problem(CaptureError.microphone.localizedDescription)
            return
        }
        let session = MomentBench.Session(run: .media, started: Date())
        timedRun = session
        phase = .listening
        hold(Self.timedUser)
        do {
            try await startMicrophone(primed: false)
        } catch {
            timedRun = nil
            release(Self.timedUser)
            phase = .problem("The microphone didn't start (\(error.localizedDescription)). Try again.")
            return
        }
        // Stopped while the microphone started.
        guard timedRun?.id == session.id else { return stopMicrophone() }
        store.sessions.append(session)
        save()
        let ends = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        timedRunEnds = ends
        interrupted = false
        unscored = 0
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled, Date() < ends {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
            guard !Task.isCancelled else { return }
            self?.stopTimedRun()
        }
    }

    /// Once a second through the timed run: the screen kept on while Binders is open, if you asked; a microphone that
    /// went quiet started again; and with Binders open, a pause iOS never said was over tried again, every ten seconds.
    private func tick() {
        let inFront = UIApplication.shared.applicationState == .active
        UIApplication.shared.isIdleTimerDisabled = keepsScreenOn && inFront
        guard Date().timeIntervalSince(lastRestart) > 10 else { return }
        if interrupted ? inFront : Date().timeIntervalSince(lastAudio) > 10 { restartSource() }
    }

    /// The timed run ends, at its time or when you stop it: capture carries on, and with the iPhone locked a notification
    /// says how it went.
    func stopTimedRun() {
        guard let session = timedRun else { return }
        timer?.cancel()
        timer = nil
        // Capture listens again before the audio session goes, so iOS lets it carry on in the background.
        stopMicrophone(deactivating: false)
        let started = store.sessions.firstIndex { $0.id == session.id }
        if let started { store.sessions[started].ended = Date() }
        save()
        timedRun = nil
        timedRunEnds = nil
        interrupted = false
        if phase == .listening { phase = .ready }
        UIApplication.shared.isIdleTimerDisabled = false
        release(Self.timedUser)
        if started != nil, UIApplication.shared.applicationState != .active { notifyTimedRunEnded(session.id) }
    }

    private func notifyTimedRunEnded(_ session: UUID) {
        let clips = store.results.filter { $0.session == session }
        let taken = clips.filter { $0.taken(at: Double(threshold)) }.count
        let content = UNMutableNotificationContent()
        content.title = "Calibration: the TV run is over"
        let heardLine = clips.count == 1 ? "1 clip was heard" : "\(clips.count) clips were heard"
        let takenLine = taken == 0 ? "none would have been taken" : taken == 1 ? "1 would have been taken" : "\(taken) would have been taken"
        content.body = "\(heardLine), and \(takenLine)." + (held > 0 ? " Open Binders to score the \(held) held while it was locked." : "")
        content.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "calibration-\(session.uuidString)", content: content, trigger: nil))
    }

    // MARK: Scoring

    private func enqueue(_ waiting: Waiting) {
        queue.append(waiting)
        checking = queue.count + (scoring == nil ? 0 : 1)
        guard scoring == nil else { return }
        scoring = Task { await scoreQueue() }
    }

    private func scoreQueue() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            checking = queue.count + 1
            await score(next)
        }
        checking = 0
        scoring = nil
    }

    /// One clip through the gate, every check run: its result kept, its audio let go. With the iPhone locked, a clip of
    /// the timed run that couldn't be written down is held, and scored once Binders is open.
    private func score(_ waiting: Waiting) async {
        let threshold = VoicePrint.momentThreshold
        let began = Date()
        let run = await MomentCenter.shared.gate(waiting.clip, threshold: threshold, scoringAll: true)
        if run.failures == [.notWrittenDown], waiting.run == .media, UIApplication.shared.applicationState == .background {
            return holdForLater(waiting)
        }
        let clip = waiting.clip
        let said = MomentBench.phrase(waiting.target?.phrase)?.text ?? MomentBench.line(waiting.target?.phrase)?.text
        // The binder it names and the day it's due, as the rules read them against the bench's own binders.
        let read = run.written.map { MomentBench.readBinderAndDue($0.text, heard: clip.started) }
        let model: String? = switch run.model {
        case .kind(let kind)?: kind.rawValue
        case .unavailable?: "unavailable"
        case .noAnswer?: "noAnswer"
        case nil: nil
        }
        let result = MomentBench.Result(
            run: waiting.run, session: waiting.session, heard: clip.started, phrase: waiting.target?.phrase,
            detector: clip.checkFirst == nil ? .onItsOwn : .inConversation, seconds: clip.ended.timeIntervalSince(clip.started),
            speech: clip.speech, endpointMillis: Int((waiting.arrived.timeIntervalSince(clip.ended) * 1000).rounded()),
            asrMillis: run.asrMillis, voiceMillis: run.voiceMillis, modelMillis: run.modelMillis,
            gateMillis: Int((Date().timeIntervalSince(began) * 1000).rounded()), engine: run.written?.engine,
            words: run.written.map { TextNorm.words($0.text).count },
            accuracy: run.written.flatMap { written in said.map { MomentBench.accuracy(heard: written.text, said: $0) } },
            wake: run.wake, cue: run.cue, voice: run.voice.map(Double.init), threshold: Double(threshold),
            rules: run.rules.map { $0.kind?.rawValue ?? "unsure" }, model: model, failures: run.failures, voicePrint: voicePrint,
            scoredLater: waiting.later ? true : nil, binder: read?.binder, due: read?.due, uncued: run.uncued, uncuedModel: run.uncuedModel)
        keep(result)
        guard waiting.target != nil else { return }
        if phase == .checking { phase = .ready }
        // Only for the phrase on screen, while it's open, and only until the next one: the words are never kept.
        guard holding.contains(Self.phrasesUser) else { return }
        heard = run.written.map { Heard(result: result.id, words: $0.text) }
    }

    private func holdForLater(_ waiting: Waiting) {
        let seconds = heldClips.reduce(0.0) { $0 + Double($1.clip.samples.count) / 16_000 }
        guard seconds + Double(waiting.clip.samples.count) / 16_000 <= Self.mostHeld else {
            unscored += 1
            return
        }
        var later = waiting
        later.later = true
        heldClips.append(later)
        held = heldClips.count
    }

    /// Binders is open again: the clips held while it was locked go through the gate now.
    private func scoreHeld() {
        guard !heldClips.isEmpty else { return }
        let clips = heldClips
        heldClips = []
        held = 0
        for clip in clips { enqueue(clip) }
    }

    // MARK: Results

    var report: MomentBench.Report {
        MomentBench.report(store, threshold: Double(threshold), voicePrint: voicePrint, notMe: VoicePrint.misses.compactMap { $0 },
                           startBar: VoicePrint.startThreshold.map(Double.init))
    }

    /// The voice threshold for things said on its own, from the bench's suggestion: never a hair under it, so what the
    /// bench counted is what the gate does.
    func useThreshold(_ value: Double) {
        let exact = Self.notUnder(value)
        let voice = report.voice
        VoicePrint.momentThreshold = exact
        // The start bar, from the same clips: never a hair under what the bench counted either.
        VoicePrint.startThreshold = MomentBench.startThreshold(others: voice.others, notMe: voice.notMe, momentThreshold: Double(exact)).map(Self.notUnder)
        refresh()
    }

    /// Sets the start bar alone, leaving the voice threshold as it is: Calibrate offers it (MomentBench.startBarOffer) when
    /// the threshold is already the one suggested, so Use isn't offered, and again once more clips moved the bar.
    func setStartBar(_ value: Double) {
        VoicePrint.startThreshold = Self.notUnder(value)
        refresh()
    }

    /// As a Float, never a hair under what the bench counted.
    private static func notUnder(_ value: Double) -> Float {
        var exact = Float(value)
        if Double(exact) < value { exact = exact.nextUp }
        return exact
    }

    func resetThreshold() {
        VoicePrint.resetMomentThreshold()
        refresh()
    }

    /// Every result as a CSV file for the share sheet, in a temporary folder; `shared` deletes it.
    func csvFile() -> URL? {
        let day = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Binders calibration \(day).csv")
        do {
            try MomentBench.csv(store, threshold: Double(threshold)).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    func shared(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Every result and pass gone, here and in the file.
    func deleteAll() {
        store = MomentBench.Store()
        heard = nil
        try? FileManager.default.removeItem(at: Self.file)
    }

    private func keep(_ result: MomentBench.Result) {
        store.record(result)
        save()
    }

    // MARK: Storage

    /// Inside the capture folder, so out of backups, in a folder of its own.
    private static var folder: URL {
        let folder = CaptureFiles.folder.appendingPathComponent("Calibration", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return folder
    }

    private static var file: URL { folder.appendingPathComponent("bench.json") }

    private static func load() -> MomentBench.Store {
        (try? JSONDecoder().decode(MomentBench.Store.self, from: EarlierSpellings.json(Data(contentsOf: file)))) ?? MomentBench.Store()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// How loud a stretch is, 0…1, from its root mean square, as dictation's meter has it.
    nonisolated private static func loudness(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        return Double(min(1, max(0, (20 * log10(max(rms, 0.000_01)) + 50) / 50)))
    }
}
