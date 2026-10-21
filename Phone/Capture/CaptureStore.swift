import BindersKit
import Foundation
import Observation
#if DEBUG
import os
#endif

/// The iPhone's All-day capture records, as the screens show them. The launch and the lists read only the index
/// (`CaptureIndex`): one line per capture. A full record is read from its file when it's opened or written down, and the
/// last few read are kept. The files themselves are `CaptureFiles`.
@MainActor
@Observable
final class CaptureStore {
    static let shared = CaptureStore()

    /// Every capture's line in the index, newest first.
    private(set) var conversations: [CaptureEntry] = []
    /// Moves on with every save: a page showing a whole record follows a change its line doesn't show.
    private var revision = 0
    /// Whole records read or saved lately, the latest last: the pages open and the captures being written down.
    @ObservationIgnored private var records: [UUID: CapturedConversation] = [:]
    @ObservationIgnored private var recent: [UUID] = []
    private static let recordsKept = 12
    /// While tidying, the index is written once at the end rather than at every save.
    @ObservationIgnored private var holdingIndex = false
    @ObservationIgnored private var indexChanged = false

    private init() {
        reload()
    }

    func reload() {
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        #endif
        let loaded = CaptureIndex.load(from: CaptureFiles.folder)
        conversations = loaded.entries
        records = [:]
        recent = []
        #if DEBUG
        let ms = String(format: "%.1f ms", (ProcessInfo.processInfo.systemUptime - began) * 1_000)
        Self.log("Capture launch: \(loaded.entries.count) captures from the index in \(ms), \(loaded.read) records decoded"
                 + (loaded.rebuilt ? ", the index made again from the records." : "."))
        #endif
    }

    #if DEBUG
    /// The DEBUG log line for the launch: in Xcode's console, and in Console on a Mac with the iPhone attached.
    static func log(_ line: String) {
        Logger(subsystem: "io.binders.app", category: "capture").notice("\(line, privacy: .public)")
    }
    #endif

    /// A capture's line, as the lists show it.
    func entry(_ id: UUID) -> CaptureEntry? { conversations.first { $0.id == id } }

    /// A capture's whole record: its transcript, timeline and spans, read from its file the first time it's asked for.
    func conversation(_ id: UUID) -> CapturedConversation? {
        _ = revision
        guard entry(id) != nil else { return nil }
        if let record = records[id] { return record }
        guard let record = CaptureFiles.read(id) else { return nil }
        keep(record)
        return record
    }

    /// Saves a conversation's record, adding it if it's new, and its line in the index.
    func save(_ conversation: CapturedConversation) {
        let entry = CaptureIndex.save(conversation, in: CaptureFiles.folder)
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = entry
        } else {
            conversations.insert(entry, at: 0)
            conversations.sort(by: CaptureIndex.newestFirst)
        }
        keep(conversation)
        revision += 1
        writeIndex()
    }

    func update(_ id: UUID, _ change: (inout CapturedConversation) -> Void) {
        guard let before = conversation(id) else { return }
        var conversation = before
        change(&conversation)
        // Nothing changed (the same wait noted again, say): nothing to write.
        guard conversation != before else { return }
        save(conversation)
    }

    /// The audio goes; the record and its transcript stay, to read here and to share again.
    func deleteAudio(_ id: UUID) {
        try? FileManager.default.removeItem(at: CaptureFiles.audioURL(id))
        update(id) {
            $0.audioDeleted = true
            $0.keepAudioUntil = nil
        }
    }

    /// Gone from this iPhone: its audio, its record and its transcript, and its line in the index.
    func delete(_ id: UUID) {
        CaptureFiles.remove(id)
        conversations.removeAll { $0.id == id }
        records[id] = nil
        recent.removeAll { $0 == id }
        revision += 1
        writeIndex()
    }

    /// Lets go of audio kept for the developer setting once its day is up; of audio still here once its text is in the
    /// outbox (Binders stopped before it could go); of a failed conversation's audio once it has no tries left, after its
    /// last or three days after it was heard (one from before tries were counted too); of one still waiting to be written
    /// down three days after it was heard (no speech model, no Wi-Fi, never opened in front), which then fails, as the
    /// privacy notes promise; and of records more than 30 days old once they were sent, or failed (or weren't kept) and lost
    /// their audio. Runs at launch, whenever the app comes to the front, and as conversations close and background runs
    /// start. `working` is the one being written down now. It goes by the index's lines: only the records it changes are
    /// read, and the index is written once, at the end.
    func tidy(now: Date = Date(), working: UUID? = nil) {
        holdingIndex = true
        defer { releaseIndex() }
        let month = now.addingTimeInterval(-30 * 86_400)
        for conversation in conversations {
            if let until = conversation.keepAudioUntil, until < now { deleteAudio(conversation.id) }
            if [.queued, .sent].contains(conversation.state), !conversation.audioDeleted, conversation.keepAudioUntil == nil,
               conversation.hasTranscript {
                deleteAudio(conversation.id)
            }
            if conversation.id != working, conversation.failedAudioDue(at: now) {
                deleteAudio(conversation.id)
            }
            if [.recorded, .transcribing, .labelling].contains(conversation.state), !conversation.audioDeleted,
               conversation.id != working, conversation.keepAudioUntil == nil,
               conversation.ended < now.addingTimeInterval(-CapturedConversation.failedAudioKept) {
                if conversation.state == .labelling, conversation.hasSegments {
                    // Its words are written down: they still go to your Mac, as one voice, without the audio.
                    update(conversation.id) { $0.failures = CapturedConversation.maxFailures }
                } else {
                    update(conversation.id) {
                        $0.state = .failed
                        $0.failures = CapturedConversation.maxFailures
                        $0.error = "It wasn't written down within three days, so its audio was deleted."
                    }
                }
                deleteAudio(conversation.id)
            }
            if conversation.state == .sent, conversation.started < month { delete(conversation.id) }
            if conversation.state == .failed, conversation.audioDeleted, conversation.started < month { delete(conversation.id) }
        }
    }

    /// Today's conversations, newest first.
    func today(calendar: Calendar = .current) -> [CaptureEntry] {
        conversations.filter { calendar.isDateInToday($0.started) }
    }

    /// Conversations from before today, newest first, grouped by day.
    func earlier(calendar: Calendar = .current) -> [(day: Date, conversations: [CaptureEntry])] {
        let older = conversations.filter { !calendar.isDateInToday($0.started) }
        let days = Dictionary(grouping: older) { calendar.startOfDay(for: $0.started) }
        return days.keys.sorted(by: >).map { ($0, days[$0]!.sorted { $0.started > $1.started }) }
    }

    #if DEBUG
    /// For screenshots and the UI tests, in Debug builds only (`-sampleCaptures YES`): a dozen made-up captures today
    /// (three filed, one waiting for the Mac, the rest not kept) and a few on each of the five days before. They take the
    /// same ids every time, so a launch replaces the last launch's; no other capture is touched.
    func fillSamples(now: Date = Date(), calendar: Calendar = .current) {
        let prefix = "5A3D0000-0000-0000-0000-"
        for entry in conversations where entry.id.uuidString.hasPrefix(prefix) { delete(entry.id) }
        func id(_ n: Int) -> UUID { UUID(uuidString: prefix + String(format: "%012d", n))! }
        enum Kind { case filed(String), waiting, tooShort, nothing, macNotKept }
        func make(_ n: Int, _ started: Date, minutes: Double, _ kind: Kind) -> CapturedConversation {
            var record = CapturedConversation(id: id(n), started: started, ended: started.addingTimeInterval(minutes * 60),
                                              speech: minutes * 40, state: .sent, spans: CaptureSpans())
            let lines = ["So the plan for Thursday is two more chairs and a screen.", "And Sam said the dentist can call back after lunch."]
            record.transcript = lines.enumerated().map { index, text in
                TranscriptSegment(channel: .microphone, start: Double(index) * 8, end: Double(index) * 8 + 7, text: text,
                                  speaker: "Speaker \(1 + index % 2)")
            }
            record.speakers = ["Speaker 1": TranscriptSegment.you]
            record.words = 240
            record.audioDeleted = true
            record.note(CaptureStep.heard, at: started)
            switch kind {
            case .filed(let line):
                record.outcome = line
                record.outcomeState = CaptureOutcome.States.filed
            case .waiting:
                record.state = .queued
            case .tooShort:
                record.markTooShort(at: record.ended)
            case .nothing:
                record.markNotKept(CapturedConversation.nothingToWriteDown, at: record.ended)
            case .macNotKept:
                record.outcome = "Not kept: small talk"
                record.outcomeState = CaptureOutcome.States.notKept
            }
            return record
        }
        let filed = ["Filed in Studio: Pricing page review and the onboarding checklist · 2 to-dos",
                     "Filed in Events: Ignite booth plan, with the screen, the chairs and who stands there on Thursday · 1 to-do",
                     "Filed in Personal: Dentist and the school run"]
        let todayKinds: [(Kind, Double)] = [(.tooShort, 1), (.filed(filed[0]), 16), (.tooShort, 1), (.nothing, 3), (.waiting, 6),
                                            (.tooShort, 2), (.filed(filed[1]), 22), (.macNotKept, 4), (.tooShort, 1),
                                            (.nothing, 2), (.filed(filed[2]), 9), (.tooShort, 1)]
        let morning = calendar.startOfDay(for: now)
        let step = min(25 * 60, now.timeIntervalSince(morning) / Double(todayKinds.count + 1))
        var n = 0
        for (index, (kind, minutes)) in todayKinds.enumerated() {
            save(make(n, now.addingTimeInterval(-Double(index + 1) * step), minutes: minutes, kind))
            n += 1
        }
        for back in 1...5 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: morning) else { continue }
            let kinds: [(Kind, Double)] = [(.filed(filed[back % 3]), 12), (.tooShort, 1), (.nothing, 3), (.filed(filed[(back + 1) % 3]), 8),
                                           (.tooShort, 2)].prefix(2 + back % 4).map { $0 }
            for (index, (kind, minutes)) in kinds.enumerated() {
                save(make(n, day.addingTimeInterval(Double(17 - index * 2) * 3_600), minutes: minutes, kind))
                n += 1
            }
        }
    }
    #endif

    // MARK: Kept here

    /// Keeps a whole record at hand, letting the one least lately used go past a dozen.
    private func keep(_ record: CapturedConversation) {
        records[record.id] = record
        recent.removeAll { $0 == record.id }
        recent.append(record.id)
        while recent.count > Self.recordsKept { records[recent.removeFirst()] = nil }
    }

    private func writeIndex() {
        guard !holdingIndex else { return indexChanged = true }
        CaptureIndex.write(conversations, to: CaptureFiles.folder)
    }

    private func releaseIndex() {
        holdingIndex = false
        guard indexChanged else { return }
        indexChanged = false
        writeIndex()
    }
}
