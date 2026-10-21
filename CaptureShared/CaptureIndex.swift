import BindersKit
import Foundation

/// What a capture's row, the launch and the tidy go by: the same in its full record and in its line of the index, so
/// both answer alike.
protocol CaptureFacts {
    var id: UUID { get }
    var started: Date { get }
    var ended: Date { get }
    /// Seconds of speech in it.
    var speech: TimeInterval { get }
    var state: CapturedConversation.State { get }
    var audioDeleted: Bool { get }
    var keepAudioUntil: Date? { get }
    var failures: Int? { get }
    var appOnly: Bool? { get }
    var notKept: String? { get }
}

extension CaptureFacts {
    var duration: TimeInterval { max(0, ended.timeIntervalSince(started)) }
    /// Not with the Mac yet: it can be deleted before it goes.
    var isUnsent: Bool { state != .sent }
    /// Failed, with tries left and its audio still here, within its three days.
    var canRetry: Bool { canRetry(at: Date()) }

    func canRetry(at now: Date) -> Bool {
        state == .failed && notKept == nil && !audioDeleted && (failures ?? 1) < CapturedConversation.maxFailures
            && ended > now.addingTimeInterval(-CapturedConversation.failedAudioKept)
    }

    /// Failed with no tries left, so its audio is no use any more and goes now: after its last try, or three days after it
    /// was heard (a record from before tries were counted included). Audio kept for the developer setting waits its day.
    func failedAudioDue(at now: Date) -> Bool {
        state == .failed && !audioDeleted && keepAudioUntil == nil && !canRetry(at: now)
    }
}

/// One capture's line in the index: what its row, Today and the launch go by, without its transcript, timeline or spans.
/// Made afresh from the full record each time that's saved, so it never says what the record doesn't.
struct CaptureEntry: Codable, Identifiable, Equatable, CaptureFacts {
    let id: UUID
    var started: Date
    var ended: Date
    var speech: TimeInterval
    var state: CapturedConversation.State
    var engine: String?
    var words: Int?
    var error: String?
    var sharedAt: Date?
    var sharedVia: String?
    var audioDeleted: Bool
    var keepAudioUntil: Date?
    var failures: Int?
    var appOnly: Bool?
    var wrappedUp: Bool?
    /// What the Mac made of it, and the state word with it.
    var outcome: String?
    var outcomeState: String?
    var notKept: String?
    /// Why it waits, from the last line of its timeline.
    var waitingBecause: String?
    /// The first line of its transcript, cut short, for its row.
    var firstLine: String?
    /// Lines in the transcript as it went to the Mac (nil: none yet), and in the one written down before the voices were
    /// told apart.
    var transcriptCount: Int?
    var segmentCount: Int?
    /// When its record's file was last written, as the folder says. A record written since (by an older build, or by
    /// capture while it listens) is read again at launch; nil, as after a write that failed, always is.
    var written: Date?

    /// Its transcript is written, voices and all.
    var hasTranscript: Bool { transcriptCount != nil }
    /// Written down, and waiting for its voices to be told apart.
    var hasSegments: Bool { (segmentCount ?? 0) > 0 }

    /// More of the first line than a row shows.
    static let firstLineLength = 200

    init(_ record: CapturedConversation, written: Date?) {
        id = record.id
        started = record.started
        ended = record.ended
        speech = record.speech
        state = record.state
        engine = record.engine
        words = record.words
        error = record.error
        sharedAt = record.sharedAt
        sharedVia = record.sharedVia
        audioDeleted = record.audioDeleted
        keepAudioUntil = record.keepAudioUntil
        failures = record.failures
        appOnly = record.appOnly
        wrappedUp = record.wrappedUp
        outcome = record.outcome
        outcomeState = record.outcomeState
        notKept = record.notKept
        waitingBecause = record.waitingBecause
        firstLine = record.transcript?.first.map { line in
            line.text.count > Self.firstLineLength ? String(line.text.prefix(Self.firstLineLength)) + "…" : line.text
        }
        transcriptCount = record.transcript?.count
        segmentCount = record.segments?.count
        self.written = written
    }
}

/// A small file beside the capture records with one line per capture (`CaptureEntry`), so the iPhone's launch and its
/// lists read it instead of decoding every record. It's a cache, never the source of truth: written whole, atomically,
/// as each record is saved; checked at launch against the folder's listing (which records there are, and when each was
/// written), so a record missing from it, written since its line (by an older build, by capture while it listens, or
/// just before a quit) or gone is read again or dropped without opening the rest; and made again from the records when
/// it's missing, unreadable or another version's. The records stay as they were, so a build without the index reads
/// them as ever, and its name isn't a record's, so such a build never reads it.
enum CaptureIndex {
    static let version = 1
    static let fileName = "captures.index"

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    /// What a launch found.
    struct Loaded {
        /// Every capture's line, newest first.
        var entries: [CaptureEntry]
        /// Records decoded in full: none when the index was up to date.
        var read: Int
        /// The index was missing, unreadable or another version's, so it was made again from the records.
        var rebuilt: Bool
        /// It didn't match the folder, so it was written again.
        var rewrote: Bool
    }

    /// The line of every record in `folder`: from the index where it's up to date, from the record where it isn't. The
    /// index is written back when that changed it.
    static func load(from folder: URL) -> Loaded {
        let files = recordFiles(in: folder)
        let stored = entries(in: folder)
        var lines: [UUID: CaptureEntry] = [:]
        for line in stored ?? [] { lines[line.id] = line }
        var entries: [CaptureEntry] = []
        var read = 0
        for (id, written) in files {
            if let line = lines[id], let written, let then = line.written, abs(then.timeIntervalSince(written)) < 0.000_001 {
                entries.append(line)
                continue
            }
            read += 1
            // One that can't be read (a newer build's, say) is left out, as it always was.
            if let record = CaptureFiles.read(id, in: folder) { entries.append(CaptureEntry(record, written: written)) }
        }
        entries.sort(by: newestFirst)
        let rewrote = stored == nil || entries.count != lines.count || entries.contains { lines[$0.id] != $0 }
        if rewrote { write(entries, to: folder) }
        return Loaded(entries: entries, read: read, rebuilt: stored == nil, rewrote: rewrote)
    }

    /// Writes the index whole, replacing the last at once; false when it couldn't be, which the next launch mends.
    @discardableResult
    static func write(_ entries: [CaptureEntry], to folder: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(File(version: version, entries: entries)) else { return false }
        #if os(macOS)
        return (try? data.write(to: url(in: folder), options: .atomic)) != nil
        #else
        return (try? data.write(to: url(in: folder), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
        #endif
    }

    /// Saves a record, and returns its line for the index with when its file was written: nil when the write failed, so
    /// the record is read again at the next launch rather than taken from a line it doesn't match.
    static func save(_ record: CapturedConversation, in folder: URL) -> CaptureEntry {
        let saved = CaptureFiles.write(record, in: folder)
        return CaptureEntry(record, written: saved ? written(CaptureFiles.recordURL(record.id, in: folder)) : nil)
    }

    /// The records in a folder and when each file was last written, from the folder's listing alone: none is opened.
    static func recordFiles(in folder: URL) -> [UUID: Date?] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var files: [UUID: Date?] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            files.updateValue(try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, forKey: id)
        }
        return files
    }

    /// When a file was last written, as the folder tells it (the same reading the listing gives).
    static func written(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The index's lines, as written; nil when it's missing, can't be read, or is another version's. A line this build
    /// can't read (a newer build's state, say) is left out, so its record is read instead, and the rest stand.
    static func entries(in folder: URL) -> [CaptureEntry]? {
        guard let data = try? Data(contentsOf: url(in: folder)),
              let file = try? JSONDecoder().decode(StoredFile.self, from: data), file.version == version else { return nil }
        return file.entries.compactMap(\.entry)
    }

    /// Newest first, as the lists show them; the same order every time.
    static func newestFirst(_ a: CaptureEntry, _ b: CaptureEntry) -> Bool {
        a.started != b.started ? a.started > b.started : a.id.uuidString > b.id.uuidString
    }

    private struct File: Encodable {
        let version: Int
        let entries: [CaptureEntry]
    }

    private struct StoredFile: Decodable {
        let version: Int
        let entries: [Line]
    }

    /// One line as read, or nothing when it can't be.
    private struct Line: Decodable {
        let entry: CaptureEntry?

        init(from decoder: Decoder) throws {
            entry = try? CaptureEntry(from: decoder)
        }
    }
}

// MARK: Timing the launch

extension CaptureIndex {
    /// How long a launch takes to read made-up captures, before the index and with it, for the DEBUG log line.
    struct Timing: Sendable {
        var records: Int
        /// Every record decoded, as the launch did before the index.
        var everyRecord: TimeInterval
        /// The first launch with the index: every record decoded once more, to build it.
        var building: TimeInterval
        /// Every launch after: the index and the folder's listing, no record.
        var withIndex: TimeInterval
        /// Records the launch with the index decoded: none.
        var read: Int

        var line: String {
            func ms(_ seconds: TimeInterval) -> String { String(format: "%.1f ms", seconds * 1_000) }
            return "Capture launch on \(records) made-up records: before, every record decoded, \(ms(everyRecord)); "
                + "with the index, \(ms(withIndex)) (\(read) records decoded); the first launch, which builds it, \(ms(building))."
        }
    }

    /// Times the launch on `count` made-up captures, the middle of three runs each, in a temporary folder of their own
    /// that's deleted after: no real capture is read or touched. Nil when the folder couldn't be written.
    static func timeLaunch(records count: Int = 200) -> Timing? {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("capture-index-timing-\(UUID().uuidString)", isDirectory: true)
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? manager.removeItem(at: folder) }
        guard madeUp(count).allSatisfy({ CaptureFiles.write($0, in: folder) }) else { return nil }
        func seconds(_ run: () -> Void) -> TimeInterval {
            let began = ProcessInfo.processInfo.systemUptime
            run()
            return ProcessInfo.processInfo.systemUptime - began
        }
        func middle(_ times: [TimeInterval]) -> TimeInterval { times.sorted()[times.count / 2] }
        let everyRecord = middle((0..<3).map { _ in seconds { _ = CaptureFiles.all(in: folder) } })
        let building = middle((0..<3).map { _ in
            try? manager.removeItem(at: url(in: folder))
            return seconds { _ = load(from: folder) }
        })
        var read = 0
        let withIndex = middle((0..<3).map { _ in seconds { read = load(from: folder).read } })
        return Timing(records: count, everyRecord: everyRecord, building: building, withIndex: withIndex, read: read)
    }

    /// Made-up captures shaped like a few weeks of real ones: a transcript of 30 to 120 lines, a timeline and spans; most
    /// sent and filed, some waiting for the Mac or to be written down, failed, or not kept.
    static func madeUp(_ count: Int, now: Date = Date()) -> [CapturedConversation] {
        let words = ("so the booth plan for Thursday needs two more chairs and a screen and Sam said the dentist can call back "
            + "after lunch about the Ignite slides and the budget review next week").split(separator: " ").map(String.init)
        return (0..<count).map { n in
            let started = now.addingTimeInterval(-Double(n) * 3 * 3_600 - 600)
            let seconds = 240 + Double((n * 37) % 1_200)
            var spans = CaptureSpans()
            spans.append(wallStart: started, duration: seconds / 2)
            spans.append(wallStart: started.addingTimeInterval(seconds / 2 + 60), duration: seconds / 2 - 60)
            let lines = 30 + (n * 13) % 91
            let transcript = (0..<lines).map { line in
                TranscriptSegment(channel: .microphone, start: Double(line) * 8, end: Double(line) * 8 + 7.5,
                                  text: (0..<22).map { words[(n + line * 7 + $0 * 3) % words.count] }.joined(separator: " "),
                                  speaker: "Speaker \(1 + line % 3)")
            }
            var record = CapturedConversation(id: UUID(), started: started, ended: started.addingTimeInterval(seconds),
                                              speech: seconds * 0.7, state: .sent, spans: spans)
            record.engine = "parakeet-v3"
            record.words = lines * 22
            record.transcript = transcript
            record.speakers = ["Speaker 1": TranscriptSegment.you]
            record.audioDeleted = true
            record.note(CaptureStep.heard, at: started)
            record.note(CaptureStep.closed, "after 3 minutes of quiet", at: record.ended)
            record.note(CaptureStep.transcribing, "with Binders open", at: record.ended.addingTimeInterval(5))
            record.note(CaptureStep.transcribed, "\(lines * 22) words · parakeet-v3 · 12 s", at: record.ended.addingTimeInterval(20))
            record.note(CaptureStep.labelled, "3 voices, you among them", at: record.ended.addingTimeInterval(40))
            record.note(CaptureStep.queued, at: record.ended.addingTimeInterval(41))
            switch n % 10 {
            case 0:
                record.state = .queued
            case 1:
                record.state = .failed
                record.transcript = nil
                record.speakers = nil
                record.audioDeleted = false
                record.failures = 1
                record.error = "Writing it down kept stopping Binders."
                record.note(CaptureStep.failed, record.error, at: record.ended.addingTimeInterval(60))
            case 2:
                record.markNotKept(CapturedConversation.nothingToWriteDown, at: record.ended.addingTimeInterval(30))
            case 3:
                record.state = .recorded
                record.transcript = nil
                record.speakers = nil
                record.audioDeleted = false
                record.note(CaptureStep.waiting, "writing down while locked is off, so with Binders open or while charging")
            default:
                record.note(CaptureStep.sent, "the Mac", at: record.ended.addingTimeInterval(45))
                record.outcome = "Filed in Events: Ignite booth plan · 2 to-dos"
                record.outcomeState = CaptureOutcome.States.filed
                record.note(CaptureStep.filed, "in Events · 2 to-dos", at: record.ended.addingTimeInterval(90))
            }
            return record
        }
    }
}
