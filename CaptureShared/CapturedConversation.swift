import BindersKit
import Foundation

/// One conversation All-day capture heard, on the iPhone or the Mac, from the moment it opened to the moment its text is
/// with the Mac. Kept as a small file next to its audio, so a quit, a crash or a restart never loses track of it. On the
/// iPhone the lists read its line in the index (`CaptureEntry`), and this whole record only when it's opened or worked on.
struct CapturedConversation: Codable, Identifiable, Equatable, CaptureFacts {
    /// recording → recorded → transcribing → labelling → queued → sent. Each step is saved before the next begins, so a
    /// conversation picks up where it was.
    enum State: String, Codable {
        case recording, recorded, transcribing, labelling, queued, sent, failed
    }

    let id: UUID
    var started: Date
    var ended: Date
    /// Seconds of speech in it.
    var speech: TimeInterval
    var state: State
    /// Where each stretch of the audio file was heard in the day.
    var spans: CaptureSpans
    /// The speech engine that wrote the transcript.
    var engine: String?
    var words: Int?
    var error: String?
    /// The transcript as first written, with times in the audio file, so labelling can resume without transcribing again.
    var segments: [TranscriptSegment]?
    /// The transcript as it went to the Mac: speakers labelled, times on the clock since `started`. Kept to read on the
    /// iPhone and to share again.
    var transcript: [TranscriptSegment]?
    /// Speaker label → name ("Speaker 2" → "You").
    var speakers: [String: String]?
    /// Shared as a file (AirDrop, Files, Mail), and how.
    var sharedAt: Date?
    var sharedVia: String?
    /// The audio is gone; or, for the developer setting, when it goes.
    var audioDeleted = false
    var keepAudioUntil: Date?
    /// How many times writing it down failed with the app open. It's tried again the next times the app opens, up to
    /// `maxFailures`. Optional, so records from before it existed still read.
    var failures: Int?
    /// It stopped Binders once, or couldn't be written down well, in the background: from then on it's written down only
    /// with the app open. Optional, so older records still read.
    var appOnly: Bool?
    /// You wrapped it up yourself, so the Mac keeps it however short. Optional, as is everything below.
    var wrappedUp: Bool?
    /// What the Mac made of it once sent ("Filed in Events: Ignite booth plan · 2 to-dos"), and the state word with it
    /// (CaptureOutcome.States).
    var outcome: String?
    var outcomeState: String?
    /// What happened to it, step by step, for "What happened" on its page.
    var steps: [CaptureStep]?
    /// Not kept on this iPhone, and why ("nothing to write down"): it ends here, with nothing for the Mac and its audio
    /// gone, and its row stays until it expires like any other. Its state is `failed`, so an older build that doesn't know
    /// this field never tries it again. Optional, so older records still read.
    var notKept: String?
    /// Lane Y2, Optional and with no enum among them, so records written before read, and a newer record never stops an
    /// older build: whether the iPhone heard only you in it (its `hold` a word); Said to yourself's mode as it opened,
    /// lowered while open ("add", "auto"; nil while Said to yourself was off); other audio played, or a call was up, while
    /// it wrote speech; the capture it continues, cut by the 90-minute split or listening stopping; kept, though short,
    /// for a moment said in it; and when its one notification went.
    var solo: SoloRule.Verdict?
    var mode: String?
    var otherAudio: Bool?
    var call: Bool?
    var continues: UUID?
    var keptForMoment: Bool?
    var noticed: Date?
    /// From its outcome (lane Y2): what the Mac read from it, each with its own outcome under its id, and why it wasn't
    /// read when it wasn't.
    var found: [CaptureOutcome.Found]?
    var soloLine: String?

    static let maxFailures = 3
    /// How long a capture that couldn't be written down keeps its audio, from when it was heard, as the privacy notes say.
    static let failedAudioKept: TimeInterval = 3 * 86_400
    /// Written down to no words at all: noise, music, a language the speech model can't read.
    static let nothingToWriteDown = "nothing to write down"
    /// Too little speech to write down: under `ConversationSplitter.Settings.minSpeech`, or under a few seconds when you
    /// wrap it up yourself.
    static let tooShort = "too short"

    /// Adds a line to the timeline, unless it says just what the last one did. The last 40 are kept.
    mutating func note(_ step: String, _ note: String? = nil, at time: Date = Date()) {
        var steps = self.steps ?? []
        if let last = steps.last, last.step == step, last.note == note { return }
        steps.append(CaptureStep(at: time, step: step, note: note))
        self.steps = Array(steps.suffix(40))
    }

    /// The reason it waits, from the last time it was told to wait.
    var waitingBecause: String? {
        guard let last = steps?.last, last.step == CaptureStep.waiting else { return nil }
        return last.note
    }

    /// Not kept on this iPhone, for `reason`: nothing of it goes to the Mac, it isn't tried again, and its timeline says
    /// why. The audio is the caller's to delete.
    mutating func markNotKept(_ reason: String, at time: Date = Date()) {
        state = .failed
        notKept = reason
        failures = Self.maxFailures
        error = nil
        segments = nil
        transcript = nil
        speakers = nil
        note(CaptureStep.dropped, reason, at: time)
    }

    /// Too short to keep: not kept, the same way, with its audio already gone and nothing of it but its time and the
    /// fact (no spans, no words). Its row stays until it expires, as a not-kept one does.
    mutating func markTooShort(at time: Date = Date()) {
        markNotKept(Self.tooShort, at: time)
        spans = CaptureSpans()
        engine = nil
        words = nil
        audioDeleted = true
        keepAudioUntil = nil
    }

    /// What goes to the Mac, once the transcript is written.
    func payload(device: String) -> ConversationPayload? {
        guard let transcript, !transcript.isEmpty else { return nil }
        return ConversationPayload(id: id, started: started, ended: ended, segments: transcript, speakers: speakers ?? [:],
                                   device: device, engine: engine ?? "", wrappedUp: wrappedUp)
    }
}

/// One line of a capture's timeline: what happened to it and when, with a short note. Only counts, reasons and names,
/// never words from the capture, and it stays on the iPhone. The step is a String rather than an enum, so a newer build's
/// steps never stop an older build reading the record.
struct CaptureStep: Codable, Equatable {
    var at: Date
    var step: String
    var note: String?

    static let heard = "heard"
    static let closed = "closed"
    static let waiting = "waiting"
    static let transcribing = "transcribing"
    static let transcribed = "transcribed"
    static let labelled = "labelled"
    static let queued = "queued"
    static let sent = "sent"
    static let failed = "failed"
    static let retry = "retry"
    static let filed = "filed"
    static let notKept = "not-kept"
    /// Not kept on this iPhone (the note says why): nothing went to the Mac.
    static let dropped = "dropped"
    /// Something said in it, on its own, that wasn't a moment, and why (MomentGate): kinds only.
    static let notAMoment = "not-a-moment"
}

/// Where All-day capture keeps its files: one audio file and one record per conversation. On the iPhone they stay
/// readable while it's locked (after it's been unlocked once since it started), so capture keeps writing then, and they
/// stay out of iCloud backups: audio never leaves the iPhone.
enum CaptureFiles {
    static var folder: URL {
        #if os(macOS)
        let url = AppPaths.support.appendingPathComponent("Capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #else
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Capture", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        _ = keptOutOfBackups
        #endif
        return url
    }

    #if !os(macOS)
    /// Marks the folder, and so everything in it, as not for backup: once per launch, which also covers a folder an older
    /// version made.
    private static let keptOutOfBackups: Void = {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Capture", isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }()
    #endif

    static func audioURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).caf") }
    static func recordURL(_ id: UUID) -> URL { recordURL(id, in: folder) }
    static func recordURL(_ id: UUID, in folder: URL) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    /// Writes a record whole, replacing the last; false when it couldn't be (the disk full, say). `folder` is the capture
    /// folder unless a test or a timing run says otherwise.
    @discardableResult
    static func write(_ conversation: CapturedConversation, in folder: URL? = nil) -> Bool {
        guard let data = try? JSONEncoder().encode(conversation) else { return false }
        let url = recordURL(conversation.id, in: folder ?? Self.folder)
        #if os(macOS)
        return (try? data.write(to: url, options: .atomic)) != nil
        #else
        return (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
        #endif
    }

    /// One record, read from its file; nil when it's gone or can't be read.
    static func read(_ id: UUID, in folder: URL? = nil) -> CapturedConversation? {
        guard let data = try? Data(contentsOf: recordURL(id, in: folder ?? Self.folder)) else { return nil }
        return try? JSONDecoder().decode(CapturedConversation.self, from: EarlierSpellings.json(data))
    }

    /// Every record, newest first. Dates keep their fractions: a span's start, to the millisecond, lines a transcript
    /// up with the day. The iPhone reads its index (`CaptureIndex`) instead, at launch.
    static func all(in folder: URL? = nil) -> [CapturedConversation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder ?? Self.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(CapturedConversation.self, from: EarlierSpellings.json(Data(contentsOf: $0))) }
            .sorted { $0.started > $1.started }
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: audioURL(id))
        try? FileManager.default.removeItem(at: recordURL(id))
    }
}
