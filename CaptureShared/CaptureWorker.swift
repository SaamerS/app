import AVFoundation
import BindersKit
import FluidAudio
import Foundation

/// The audio side of All-day capture, off the main thread: hears whether someone is speaking, cuts the day into
/// conversations, and writes only the speech (with a second either side) to one file per conversation. Nothing else
/// that's heard is kept.
actor CaptureWorker {
    enum Event: Sendable {
        case opened(CapturedConversation)
        /// Closed with enough speech to keep: ready to transcribe.
        case closed(CapturedConversation)
        /// Closed with too little speech: its audio and its file are already gone. The record, marked not kept as too
        /// short (only its time and the fact), is the iPhone's to keep as a row; the Mac lets it go.
        case dropped(CapturedConversation)
        /// Seconds of speech heard since the last report.
        case heard(speech: TimeInterval)
        /// Some of what was heard couldn't be saved (the disk full, say), told once per conversation.
        case unsaved(String)
        /// Something short said on its own, with quiet around it: maybe said to yourself. Only when moments are on.
        case moment(MomentClip)
        /// A moment took the words of the conversation that had just opened for them, and nothing else was said in it:
        /// that conversation goes, with nothing kept of it. Or, the moment not kept, that conversation's words went into
        /// the conversation open now, which holds them from here on (`takeBack`): it goes all the same.
        case absorbed(UUID)
        /// Whether the voice detector hears speech (true) or loudness stands in for it (false): told from the first chunk
        /// loudness has to take, and again from the first the detector reads after that.
        case voiceDetector(Bool)
    }

    /// The audio of a moment, about 17 seconds at most, kept in memory only until it's written down.
    struct MomentClip: Sendable {
        let id: UUID
        let started: Date
        let ended: Date
        let speech: TimeInterval
        let samples: [Float]
        /// The conversation open when it was said, which keeps the same words unless the moment takes them.
        let conversation: UUID?
        /// Said in a conversation (MomentDetector's wake-word check): a moment only if it opens with "Binders,", which
        /// the first this many samples tell (half a second before the first word, and about 1.5 s of it). Nil for
        /// something said on its own.
        var checkFirst: Int? = nil
        /// Said on its own, it took the words of the conversation that opened at its first word, with nothing else said in
        /// it or in the three minutes before it: that conversation was set aside when the clip was handed on (`hand`), so
        /// what's said next opens one of its own. `conversation` keeps its id, for a Mac that doesn't read `alone`. Whether
        /// it's still on its own once it's written down is `settleMoment`'s answer: a moment just before it that wasn't
        /// kept gives its words back, and with them a conversation.
        var alone = false
    }

    /// 256 ms at 16 kHz, the voice detector's step.
    static let chunk = VadManager.chunkSize
    static let chunkSeconds = Double(chunk) / 16_000
    /// Kept before speech starts and after it stops, so no word is clipped.
    static let padding: TimeInterval = 1

    private struct Open {
        var record: CapturedConversation
        var file: AVAudioFile
        /// The end of the last audio written.
        var writtenUntil: Date
        /// Seconds of quiet still to write after the last speech.
        var tail: TimeInterval
        var savedAt: Date
        /// What's written to the file, while it's no longer than `keptInMemory`: so a moment's conversation set aside can
        /// come back, and go into another, without reading a file back. Nil once it's longer.
        var early: [Float]? = []
        /// Lane Y2: a moment said in it was kept in Auto, so it's kept however short, for its vouch (`keptForMoment`).
        var holdsMoment = false
    }

    /// The most of a conversation's audio held in memory as it's written (`Open.early`): more than a moment and the second
    /// either side of it, and the few seconds of a conversation that opened while a moment was being written down.
    static let keptInMemory: TimeInterval = 30

    /// A conversation set aside for a moment (`hand`), until the moment is settled.
    private struct SetAside {
        var record: CapturedConversation
        /// The splitter's conversation, as it was set aside.
        var heard: ConversationSplitter.Conversation
        /// Its audio, as written to its file.
        var samples: [Float]
        /// The listening it was heard in: once listening stops or you wrap up, it can't come back.
        var listening: Int
    }

    private var splitter: ConversationSplitter
    private var gate = LoudnessGate()
    private var detector: VadManager?
    private var detectorState: VadStreamState?
    /// Chunks in a row the voice detector couldn't read: after about ten seconds of them, loudness takes over.
    private var detectorFailures = 0
    /// The voice detector is in use, rather than given up on or missing (each chunk it can't read still goes by loudness).
    var detectorWorking: Bool { detector != nil }
    /// When speech was last heard, while a conversation is open: what a listening glyph moves with, still in the quiet.
    var lastSpeech: Date? { splitter.current.map { Date(timeIntervalSince1970: $0.end) } }
    /// The detector, or its absence, was handed over: until then the first chunks of the first listen go by loudness only
    /// because it's still loading, which isn't worth telling.
    private var detectorHanded = false
    /// What was last told: true when the detector read the chunk, false when loudness stood in.
    private var toldVoice: Bool?
    /// Writes to this conversation's file that failed: said once.
    private var unsavedSaid = false
    /// Hearing moments, when they're on; the Mac's own capture never turns them on.
    private var moments: MomentDetector?
    private var clip: [Float] = []
    private var clipStart: Date?
    /// The conversations moments said on their own took the words of, by moment, until each is settled: kept, it goes; not
    /// kept, it comes back (`takeBack`), or else it's the too-short conversation it would have been.
    private var setAside: [UUID: SetAside] = [:]
    /// Counts each stop and wrap-up: a conversation set aside before one doesn't come back after it.
    private var listening = 0
    /// The end of the last chunk heard, on the splitter's clock.
    private var heardUntil: TimeInterval = 0
    /// When speech no kept moment holds ended, lately: each conversation that closed or went, and each one set aside for
    /// a moment that wasn't kept. A moment within `silenceToClose` after one isn't said on its own.
    private var looseEnds: [TimeInterval] = []
    private var pending: [Float] = []
    private var pendingStart: Date?
    private var recent: [(samples: [Float], start: Date)] = []
    private var open: Open?
    private var speechToReport: TimeInterval = 0
    /// While you dictate: what's heard counts as quiet and isn't written. Dictations are kept as dictations.
    private var ignoring = false
    /// Lane Y2: Said to yourself's mode now ("add", "auto", or nil while it's off), stamped on a conversation as it opens
    /// and lowered while it's open; and the last conversation closed by a cut, for the one that continues it.
    private var mode: String?
    private var lastCut: (id: UUID, end: Date, at: Date)?
    private let report: @Sendable (Event) -> Void
    /// Off for the calibration bench's own worker: it hears moments only, and no conversation is opened or written.
    private let keepsConversations: Bool
    /// For the calibration bench: moments the detector let go (too little speech, too long, or answered), so far.
    private(set) var momentsLetGo = 0
    /// For the calibration bench: something is being said, or waited on for an answer.
    var hearingMoment: Bool { moments?.isHearing ?? false }

    init(settings: ConversationSplitter.Settings = .init(), keepsConversations: Bool = true, report: @escaping @Sendable (Event) -> Void) {
        splitter = ConversationSplitter(settings: settings)
        self.keepsConversations = keepsConversations
        self.report = report
    }

    func ignore(_ ignoring: Bool) {
        self.ignoring = ignoring
    }

    func useDetector(_ detector: VadManager?) {
        self.detector = detector
        detectorState = nil
        detectorFailures = 0
        detectorHanded = true
        // The next chunk says which heard it, even if that's what was told before.
        toldVoice = nil
    }

    /// Audio from the source, heard at `time`.
    func append(_ samples: [Float], at time: Date) async {
        if let start = pendingStart {
            // A gap in what arrived (the engine restarted): start counting again from here.
            let expected = start.addingTimeInterval(Double(pending.count) / 16_000)
            if abs(time.timeIntervalSince(expected)) > 0.5 {
                pending = []
                pendingStart = time
            }
        } else {
            pendingStart = time
        }
        pending += samples
        while pending.count >= Self.chunk, let start = pendingStart {
            let chunk = Array(pending.prefix(Self.chunk))
            pending.removeFirst(Self.chunk)
            pendingStart = start.addingTimeInterval(Self.chunkSeconds)
            await process(chunk, start: start)
        }
    }

    /// Moments on (with their timings) or off.
    func useMoments(_ settings: MomentDetector.Settings?) {
        moments = settings.map { MomentDetector(settings: $0) }
        clip = []
        clipStart = nil
    }

    /// What became of a moment. One said on its own whose conversation was set aside when it was handed on (`alone`):
    /// kept, that conversation goes, as the moment holds its words (`.absorbed`); not kept, its words come back, with `why`
    /// on its timeline: into the conversation open now, or open again on their own, as they'd have been without the moment
    /// (`takeBack`), or, when they can't (listening stopped or wrapped up since, three minutes of quiet), it's let go as
    /// the too-short conversation it was (`.dropped`). Otherwise the conversation keeps the words, as it always did, and
    /// `why` it wasn't a moment, when there's a reason worth saying, goes on that conversation's timeline while it's open.
    ///
    /// True for a kept moment still said on its own: set aside when it was handed on, and nothing said in the three
    /// minutes before it that no kept moment holds, a moment not kept just before it included. One just before it still
    /// being written down counts against it, as it may not be kept.
    ///
    /// `joins` (lane Y2): a moment kept in Auto in the conversation open now, which it goes with: that conversation is
    /// kept however short, for its vouch.
    @discardableResult
    func settleMoment(_ id: UUID, kept: Bool, why: String? = nil, in conversation: UUID? = nil, joins: UUID? = nil) -> Bool {
        if kept, let joins, open?.record.id == joins { open?.holdsMoment = true }
        if var aside = setAside.removeValue(forKey: id) {
            if kept {
                report(.absorbed(aside.record.id))
                let start = aside.heard.start
                let before = setAside.values.contains { $0.heard.end <= start && start - $0.heard.end < splitter.settings.silenceToClose }
                return !before && !heardLoose(before: start)
            }
            loosen(aside.heard.end)
            if takeBack(aside, why: why) { return false }
            if let why { aside.record.note(CaptureStep.notAMoment, why) }
            aside.record.markTooShort(at: aside.record.ended)
            report(.dropped(aside.record))
            return false
        }
        guard !kept, let why, let conversation, open?.record.id == conversation else { return false }
        open?.record.note(CaptureStep.notAMoment, why)
        if let record = open?.record { CaptureFiles.write(record) }
        return false
    }

    /// Speech no kept moment holds ended within `silenceToClose` before `start`.
    private func heardLoose(before start: TimeInterval) -> Bool {
        looseEnds.contains { $0 <= start + 0.001 && start - $0 < splitter.settings.silenceToClose }
    }

    private func loosen(_ end: TimeInterval) {
        let quiet = splitter.settings.silenceToClose
        looseEnds = looseEnds.filter { max(heardUntil, end) - $0 < 2 * quiet } + [end]
    }

    /// Wrap up now: the conversation being heard closes at once, to be written down, kept from `minimum` seconds of
    /// speech (a few, unless the Mac would call anything that short small talk). Listening carries on.
    func wrapUp(keepingFrom minimum: TimeInterval = wrapUpMinimum) {
        closing = "wrapped up"
        listening += 1
        for event in splitter.wrapUp(keepingFrom: minimum) { handle(event) }
        closing = nil
        moments?.reset()
        clip = []
        flushReport()
    }

    /// Why what's closing now closes, when it isn't the quiet: for its timeline.
    private var closing: String?

    // MARK: Lane Y2

    /// Said to yourself's mode now: stamped on a conversation as it opens, and lowered on the open one (Suggest, Add at
    /// Once, Auto; off lowest), never raised, so the record saved at close, and one read after a crash, carry it.
    func useMode(_ mode: String?) {
        self.mode = mode
        guard var current = open else { return }
        if Self.rank(mode) < Self.rank(current.record.mode) {
            current.record.mode = mode
            CaptureFiles.write(current.record)
        }
        open = current
    }

    private static func rank(_ mode: String?) -> Int { mode.map { MomentMode(stored: $0).rank } ?? -1 }

    /// The watchdog's tick heard other audio playing, or saw a call up: it counts for the open conversation only when it
    /// wrote audio since the tick before (SoloRule.whileSpeaking), so a podcast resumed after your last word doesn't.
    func heard(otherAudio: Bool, call: Bool, previousTick: Date) {
        guard otherAudio || call, var current = open,
              SoloRule.whileSpeaking(writtenUntil: current.writtenUntil == .distantPast ? nil : current.writtenUntil, previousTick: previousTick)
        else { return }
        if otherAudio { current.record.otherAudio = true }
        if call { current.record.call = true }
        CaptureFiles.write(current.record)
        open = current
    }

    static let wrapUpMinimum: TimeInterval = 3
    /// The timeline's line for a conversation kept for a moment said in it (lane Y2).
    static let keptForMomentNote = "after 3 minutes of quiet, kept for what you said in it"

    /// Capture stopped, was muted or interrupted: whatever is open closes, and the next speech starts afresh.
    func finish() {
        closing = "listening stopped"
        listening += 1
        for event in splitter.finish() { handle(event) }
        closing = nil
        moments?.reset()
        clip = []
        pending = []
        pendingStart = nil
        recent = []
        detectorState = nil
        // Listening again, the first chunk says which heard it.
        toldVoice = nil
        flushReport()
    }

    private func process(_ chunk: [Float], start: Date) async {
        var speech: Bool
        let byVoice: Bool
        if let detector, let result = try? await detector.processStreamingChunk(chunk, state: detectorState ?? VadStreamState.initial()) {
            detectorState = result.state
            detectorFailures = 0
            speech = result.state.triggered
            byVoice = true
        } else {
            if detector != nil {
                detectorFailures += 1
                // Failing for good (iOS keeping it from the hardware, say): loudness for now, and it's tried again later.
                if detectorFailures >= 40 {
                    detector = nil
                    detectorState = nil
                    detectorFailures = 0
                }
            }
            speech = gate.isSpeech(chunk, duration: Self.chunkSeconds)
            byVoice = false
        }
        // From the first chunk loudness takes, not after forty of them: the screen says so, and stops once Silero reads one.
        if detectorHanded, byVoice != toldVoice {
            toldVoice = byVoice
            report(.voiceDetector(byVoice))
        }
        // Exact zeros are a muted or dead input, never speech.
        if speech, !chunk.contains(where: { $0 != 0 }) { speech = false }
        if ignoring {
            speech = false
            open?.tail = 0
        }

        heardUntil = start.timeIntervalSince1970 + Self.chunkSeconds
        let events = keepsConversations ? splitter.add(speech: speech, at: start.timeIntervalSince1970, duration: Self.chunkSeconds) : []
        for event in events { handle(event) }

        if var current = open {
            if speech {
                // Back to speech after a pause: the second before it first, as far as it wasn't written already.
                for earlier in recent where earlier.start >= current.writtenUntil.addingTimeInterval(-0.01) {
                    write(earlier.samples, at: earlier.start, to: &current)
                }
                write(chunk, at: start, to: &current)
                current.tail = Self.padding
            } else if current.tail > 0, !ignoring {
                write(chunk, at: start, to: &current)
                current.tail -= Self.chunkSeconds
            }
            if Date().timeIntervalSince(current.savedAt) > 15 {
                CaptureFiles.write(current.record)
                current.savedAt = Date()
            }
            open = current
        }

        if moments != nil { hearMoment(speech: speech, chunk: chunk, start: start) }

        // Dictation never becomes the second before someone's first word.
        if ignoring { recent.removeAll() } else { recent.append((chunk, start)) }
        while recent.count > Int((Self.padding / Self.chunkSeconds).rounded(.up)) { recent.removeFirst() }
        if speech { speechToReport += Self.chunkSeconds }
        if speechToReport >= 10 { flushReport() }
    }

    /// The moment detector beside the splitter: the clip is gathered while something short is said, and handed on once
    /// nobody answered it; or, said in a conversation, handed on to be checked for the wake word.
    private func hearMoment(speech: Bool, chunk: [Float], start: Date) {
        guard var detector = moments else { return }
        let decision = detector.add(speech: speech, at: start.timeIntervalSince1970, duration: Self.chunkSeconds)
        moments = detector
        switch decision {
        case .none:
            break
        case .collect:
            gather(chunk, start: start)
        case .forget:
            clip = []
            clipStart = nil
            momentsLetGo += 1
        case .moment(let burst):
            clip += chunk
            hand(burst, checkingFirst: nil)
        case .wakeCheck(let burst):
            clip += chunk
            hand(burst, checkingFirst: detector.settings.wakeCheckLength)
        }
        // The stretch that ended one (an answer to it) already began the next: it's heard from its first word.
        if decision != .collect, decision != .none, detector.isHearing { gather(chunk, start: start) }
    }

    /// The clip so far, and this stretch. The second before the first word comes first, as a conversation keeps it.
    private func gather(_ chunk: [Float], start: Date) {
        if clip.isEmpty {
            clip = recent.flatMap(\.samples)
            clipStart = recent.first?.start ?? start
        }
        clip += chunk
        let most = 20 * 16_000
        if clip.count > most {
            clipStart = clipStart?.addingTimeInterval(Double(clip.count - most) / 16_000)
            clip.removeFirst(clip.count - most)
        }
    }

    /// The clip, up to half a second after the last word, to MomentCenter; with `checkingFirst` seconds from the first
    /// word to check for the wake word when it was said in a conversation.
    private func hand(_ burst: MomentDetector.Burst, checkingFirst: TimeInterval?) {
        defer {
            clip = []
            clipStart = nil
        }
        guard var from = clipStart?.timeIntervalSince1970 else { return }
        let keep = Int(max(0, burst.end + 0.5 - from) * 16_000)
        if keep < clip.count { clip = Array(clip.prefix(keep)) }
        if checkingFirst != nil {
            // Said in a conversation, after maybe only a second of quiet: half a second before the first word is enough,
            // and leaves out the end of what was said before it, which would come before "Binders".
            let lead = Int(max(0, burst.start - 0.5 - from) * 16_000)
            if lead > 0, lead < clip.count {
                clip.removeFirst(lead)
                from += Double(lead) / 16_000
            }
        }
        let head = checkingFirst.map { min(clip.count, Int(max(0, burst.start + $0 - from) * 16_000)) }
        let id = UUID()
        let conversation = open?.record.id
        // Said on its own, in the conversation that opened at its first word, with nothing else said in it: that
        // conversation is set aside now, before the clip is written down, so what's said a few seconds later opens one of
        // its own and can't undo this. Anything said before it keeps it in its conversation, a moment not kept included.
        let alone = checkingFirst == nil && setAsideConversation(for: burst, moment: id)
        report(.moment(MomentClip(id: id, started: Date(timeIntervalSince1970: burst.start), ended: Date(timeIntervalSince1970: burst.end),
                                  speech: burst.speech, samples: clip, conversation: conversation, checkFirst: head, alone: alone)))
    }

    /// Sets the open conversation aside for the moment `id`, when it began at the burst's first word, holds its speech and
    /// nothing else, and nothing no kept moment holds was said in the three minutes before it: the splitter lets it go, its
    /// two files are deleted, and its record and audio wait in `setAside` for the moment to be settled. True when it was.
    private func setAsideConversation(for burst: MomentDetector.Burst, moment id: UUID) -> Bool {
        guard let current = open, let samples = current.early, let heard = splitter.current, heard.start == burst.start,
              abs(heard.speech - burst.speech) < 0.001, !heardLoose(before: burst.start) else {
            return false
        }
        splitter.discard()
        open = nil
        try? FileManager.default.removeItem(at: CaptureFiles.audioURL(current.record.id))
        try? FileManager.default.removeItem(at: CaptureFiles.recordURL(current.record.id))
        var record = current.record
        record.started = Date(timeIntervalSince1970: heard.start)
        record.ended = Date(timeIntervalSince1970: heard.end)
        record.speech = heard.speech
        setAside[id] = SetAside(record: record, heard: heard, samples: samples, listening: listening)
        return true
    }

    /// The conversation set aside for a moment that wasn't kept comes back, as it would have been without the moment:
    /// into the conversation open now, in the order things were said, which keeps its id and holds both from here on
    /// (`.absorbed` for the one set aside); or, with nothing open, open again on its own (`.opened` once more), to close
    /// after three minutes of quiet as any conversation does. False when it can't: listening stopped or was wrapped up
    /// since, three minutes of quiet have passed, the one open now is longer than `keptInMemory`, or its file can't be
    /// written.
    private func takeBack(_ aside: SetAside, why: String?) -> Bool {
        let quiet = splitter.settings.silenceToClose
        guard keepsConversations, aside.listening == listening, heardUntil - aside.heard.end < quiet else { return false }
        var record: CapturedConversation
        var pieces = aside.record.spans.pieces(of: aside.samples)
        var tail: TimeInterval = 0
        if let current = open {
            guard let now = splitter.current, now.start - aside.heard.end < quiet, let early = current.early else { return false }
            record = current.record
            record.started = min(record.started, aside.record.started)
            pieces += current.record.spans.pieces(of: early)
            tail = current.tail
        } else {
            guard splitter.current == nil else { return false }
            record = aside.record
        }
        if let why { record.note(CaptureStep.notAMoment, why) }
        record.spans = CaptureSpans()
        // Written to a new file first, so the one open now is let go only once its audio is safe in the other.
        let draft = CaptureFiles.audioURL(UUID())
        guard let file = Self.newFile(at: draft) else { return false }
        var merged = Open(record: record, file: file, writtenUntil: .distantPast, tail: tail, savedAt: Date())
        for piece in pieces.sorted(by: { $0.wallStart < $1.wallStart }) { write(piece.samples, at: piece.wallStart, to: &merged) }
        let id = record.id
        let reopened = open == nil
        // Letting go of the file open now closes it; the new one takes its place, under its id.
        open = nil
        do {
            // A rename in the same folder: the new file stays open for writing under its new name.
            try? FileManager.default.removeItem(at: CaptureFiles.audioURL(id))
            try FileManager.default.moveItem(at: draft, to: CaptureFiles.audioURL(id))
        } catch {
            report(.unsaved("Some of what was heard couldn't be saved: \(error.localizedDescription)"))
        }
        splitter.takeBack(aside.heard)
        if let heard = splitter.current {
            merged.record.started = Date(timeIntervalSince1970: heard.start)
            merged.record.speech = heard.speech
        }
        open = merged
        CaptureFiles.write(merged.record)
        if reopened {
            report(.opened(merged.record))
        } else {
            try? FileManager.default.removeItem(at: CaptureFiles.recordURL(aside.record.id))
            report(.absorbed(aside.record.id))
        }
        return true
    }

    /// A conversation's audio file: 16 kHz mono, written as 16-bit PCM from float samples.
    private static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]

    private static func newFile(at url: URL) -> AVAudioFile? {
        try? AVAudioFile(forWriting: url, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private func handle(_ event: ConversationSplitter.Event) {
        switch event {
        case .opened(let time):
            let id = UUID()
            let started = Date(timeIntervalSince1970: time)
            let record = CapturedConversation(id: id, started: started, ended: started, speech: 0, state: .recording, spans: CaptureSpans())
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forWriting: CaptureFiles.audioURL(id), settings: Self.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                report(.unsaved("What was heard couldn't be saved: \(error.localizedDescription)"))
                return
            }
            unsavedSaid = false
            var current = Open(record: record, file: file, writtenUntil: .distantPast, tail: Self.padding, savedAt: Date())
            current.record.note(CaptureStep.heard, at: started)
            current.record.mode = mode
            // Opened within the quiet after a cut: it carries on the one cut (lane Y2).
            if let cut = lastCut, ConversationSplitter.continues(lastEnd: cut.end, lastCut: cut.at, start: started, settings: splitter.settings) {
                current.record.continues = cut.id
            }
            lastCut = nil
            // The second before the first word.
            for earlier in recent { write(earlier.samples, at: earlier.start, to: &current) }
            CaptureFiles.write(current.record)
            open = current
            report(.opened(current.record))
        case .closed(let conversation):
            loosen(conversation.end)
            guard open != nil else { return }
            var record: CapturedConversation
            do {
                // Letting go of the file closes it, before anyone reads it.
                record = open!.record
                open = nil
            }
            record.started = Date(timeIntervalSince1970: conversation.start)
            record.ended = Date(timeIntervalSince1970: conversation.end)
            record.speech = conversation.speech
            record.state = .recorded
            if closing == "wrapped up" { record.wrappedUp = true }
            let long = conversation.end - conversation.start >= splitter.settings.maxLength - Self.chunkSeconds * 4
            record.note(CaptureStep.closed, closing ?? (long ? "split at \(Int(splitter.settings.maxLength / 60)) minutes"
                                                            : "after \(Int(splitter.settings.silenceToClose / 60)) minutes of quiet"),
                        at: record.ended)
            // A cut (the split, or listening stopped), not quiet or a Wrap Up: the next one may carry it on.
            lastCut = closing == "listening stopped" || (closing == nil && long) ? (record.id, record.ended, record.ended) : nil
            CaptureFiles.write(record)
            report(.closed(record))
        case .dropped(let conversation):
            loosen(conversation.end)
            guard let current = open else { return }
            if current.holdsMoment {
                // Kept for a moment said in it, in Auto: written down and its voices told apart for its vouch, and none of
                // its words sent (lane Y2).
                open = nil
                var record = current.record
                record.started = Date(timeIntervalSince1970: conversation.start)
                record.ended = Date(timeIntervalSince1970: conversation.end)
                record.speech = conversation.speech
                record.state = .recorded
                record.keptForMoment = true
                record.note(CaptureStep.closed, Self.keptForMomentNote, at: record.ended)
                lastCut = nil
                CaptureFiles.write(record)
                report(.closed(record))
                return
            }
            open = nil
            let id = current.record.id
            try? FileManager.default.removeItem(at: CaptureFiles.audioURL(id))
            try? FileManager.default.removeItem(at: CaptureFiles.recordURL(id))
            var record = current.record
            record.started = Date(timeIntervalSince1970: conversation.start)
            record.ended = Date(timeIntervalSince1970: conversation.end)
            record.speech = conversation.speech
            record.markTooShort(at: record.ended)
            report(.dropped(record))
        }
    }

    private func write(_ samples: [Float], at start: Date, to current: inout Open) {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: SixteenKilohertz.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        do {
            try current.file.write(from: buffer)
        } catch {
            if !unsavedSaid {
                unsavedSaid = true
                report(.unsaved("Some of what was heard couldn't be saved: \(error.localizedDescription)"))
            }
            return
        }
        let seconds = Double(samples.count) / 16_000
        current.record.spans.append(wallStart: start, duration: seconds)
        current.writtenUntil = start.addingTimeInterval(seconds)
        if let early = current.early {
            current.early = early.count + samples.count <= Int(Self.keptInMemory * 16_000) ? early + samples : nil
        }
    }

    private func flushReport() {
        guard speechToReport > 0 else { return }
        report(.heard(speech: speechToReport))
        speechToReport = 0
    }
}
