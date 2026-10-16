import BindersKit
import Foundation

/// One conversation All-day capture heard, on the iPhone or the Mac, from the moment it opened to the moment its text is
/// with the Mac. Kept as a small file next to its audio, so a quit, a crash or a restart never loses track of it.
struct CapturedConversation: Codable, Identifiable, Equatable {
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

    static let maxFailures = 3

    var duration: TimeInterval { max(0, ended.timeIntervalSince(started)) }
    /// Not with the Mac yet: it can be deleted before it goes.
    var isUnsent: Bool { state != .sent }
    /// Failed, with tries left and its audio still here.
    var canRetry: Bool { state == .failed && !audioDeleted && (failures ?? 1) < Self.maxFailures }

    /// What goes to the Mac, once the transcript is written.
    func payload(device: String) -> ConversationPayload? {
        guard let transcript, !transcript.isEmpty else { return nil }
        return ConversationPayload(id: id, started: started, ended: ended, segments: transcript, speakers: speakers ?? [:],
                                   device: device, engine: engine ?? "")
    }
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
    static func recordURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    static func write(_ conversation: CapturedConversation) {
        guard let data = try? JSONEncoder().encode(conversation) else { return }
        #if os(macOS)
        try? data.write(to: recordURL(conversation.id), options: .atomic)
        #else
        try? data.write(to: recordURL(conversation.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }

    /// Every record, newest first. Dates keep their fractions: a span's start, to the millisecond, lines a transcript
    /// up with the day.
    static func all() -> [CapturedConversation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(CapturedConversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: audioURL(id))
        try? FileManager.default.removeItem(at: recordURL(id))
    }
}
