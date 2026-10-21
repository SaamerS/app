import Foundation
import BindersKit

extension SelfTest {
    /// The iPhone's capture index (CaptureIndex, shared with the iPhone): its launch reads the index and no record, and
    /// the index stays a cache of the records. A record written, added or removed without it is read again or dropped, an
    /// index that's missing, broken or another version's is made again from the records, and a build without it still
    /// reads every record. Also times the launch on 200 made-up records, before the index and with it. Works in a
    /// temporary folder of its own, deleted after.
    static func captureIndexSelfTest() -> Int32 {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("binders-capture-index-\(UUID().uuidString)", isDirectory: true)
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            print("FAIL: a temporary folder for the records")
            return 1
        }
        defer { try? manager.removeItem(at: folder) }
        let indexURL = CaptureIndex.url(in: folder)
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

        // 200 records as the iPhone keeps them, written as a build before the index wrote them: no index yet.
        let records = CaptureIndex.madeUp(200)
        check(records.allSatisfy { CaptureFiles.write($0, in: folder) }, "200 made-up records written")
        let first = CaptureIndex.load(from: folder)
        check(first.entries.count == 200 && first.read == 200 && first.rebuilt && first.rewrote,
              "the first launch with the index reads each record once and makes the index: \(first.read) read")
        check(manager.fileExists(atPath: indexURL.path), "and writes it beside the records")
        check(URL(fileURLWithPath: CaptureIndex.fileName).pathExtension != "json", "under a name a build without it never takes for a record")
        let second = CaptureIndex.load(from: folder)
        check(second.read == 0 && !second.rewrote && second.entries == first.entries,
              "the next launch reads only the index: \(second.read) records decoded, nothing written")
        check(second.entries.map(\.started) == records.map(\.started).sorted(by: >), "its lines come newest first")
        let recordBytes = records.reduce(0) { $0 + size(CaptureFiles.recordURL($1.id, in: folder)) }
        check(size(indexURL) * 10 < recordBytes, "the index is a small part of what the records hold: \(size(indexURL) / 1_024) KB against \(recordBytes / 1_024) KB")

        // Each line says what its record does, for the row, Today, the tidy and the retries.
        let now = Date()
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let alike = second.entries.allSatisfy { entry in
            guard let record = byID[entry.id] else { return false }
            return entry.state == record.state && entry.started == record.started && entry.ended == record.ended
                && entry.speech == record.speech && entry.duration == record.duration && entry.engine == record.engine
                && entry.words == record.words && entry.error == record.error && entry.outcome == record.outcome
                && entry.outcomeState == record.outcomeState && entry.notKept == record.notKept
                && entry.audioDeleted == record.audioDeleted && entry.failures == record.failures
                && entry.waitingBecause == record.waitingBecause && entry.firstLine == record.transcript?.first?.text
                && entry.hasTranscript == (record.transcript != nil) && entry.transcriptCount == record.transcript?.count
                && entry.canRetry(at: now) == record.canRetry(at: now) && entry.failedAudioDue(at: now) == record.failedAudioDue(at: now)
                && entry.isUnsent == record.isUnsent
        }
        check(alike, "each line says what its record does: state, times, outcome, first line, counts, tries left")
        check(Set(second.entries.map(\.state)) == [.sent, .queued, .failed, .recorded] && second.entries.contains { $0.notKept != nil }
              && second.entries.contains { $0.waitingBecause != nil } && second.entries.contains { $0.canRetry(at: now) },
              "among them sent, waiting, failed with tries left, and not kept")
        var long = records[4]
        long.transcript?[0].text = String(repeating: "booth plan ", count: 60)
        let cut = CaptureEntry(long, written: nil)
        check(cut.firstLine?.count == CaptureEntry.firstLineLength + 1 && cut.firstLine?.hasSuffix("…") == true,
              "a long first line is cut short in the index")
        var labelling = records[3]
        labelling.state = .labelling
        labelling.segments = [TranscriptSegment(channel: .microphone, start: 0, end: 4, text: "the booth plan", speaker: CaptureTranscript.unlabelled)]
        check(CaptureEntry(labelling, written: nil).hasSegments, "one written down and waiting for its voices says so")
        labelling.segments = []
        check(!CaptureEntry(labelling, written: nil).hasSegments, "and one written down to nothing doesn't")

        // A save as the iPhone makes one: the record, then its line with when the file was written, then the index.
        var saved = records[15]
        saved.outcome = "Filed in Personal: the dentist · 1 to-do"
        let line = CaptureIndex.save(saved, in: folder)
        check(line.written != nil, "a save notes when its record was written")
        let lines = second.entries.map { $0.id == saved.id ? line : $0 }
        check(CaptureIndex.write(lines, to: folder), "and writes the index whole")
        let afterSave = CaptureIndex.load(from: folder)
        check(afterSave.read == 0 && afterSave.entries.first { $0.id == saved.id }?.outcome == saved.outcome,
              "a save's line holds at the next launch, no record read: \(afterSave.read)")

        // A record written without the index, as an older build, or capture while it listens, would: read again, alone.
        Thread.sleep(forTimeInterval: 0.01)
        var changed = records[25]
        changed.outcome = "Not kept: small talk"
        changed.outcomeState = CaptureOutcome.States.notKept
        CaptureFiles.write(changed, in: folder)
        let afterChange = CaptureIndex.load(from: folder)
        check(afterChange.read == 1 && afterChange.rewrote && afterChange.entries.first { $0.id == changed.id }?.outcome == changed.outcome,
              "a record written without the index is read again, and only it: \(afterChange.read)")
        check(CaptureIndex.load(from: folder).read == 0, "and the index has it from then on")

        // One added without it: capture opened it, and Binders stopped before the list had it.
        var added = CapturedConversation(id: UUID(), started: now, ended: now, speech: 0, state: .recording, spans: CaptureSpans())
        added.note(CaptureStep.heard, at: now)
        CaptureFiles.write(added, in: folder)
        let afterAdd = CaptureIndex.load(from: folder)
        check(afterAdd.read == 1 && afterAdd.entries.count == 201 && afterAdd.entries.first?.id == added.id,
              "a record the index doesn't have is read, and listed first")

        // One removed without it: capture let it go as too short.
        try? manager.removeItem(at: CaptureFiles.recordURL(added.id, in: folder))
        let afterRemove = CaptureIndex.load(from: folder)
        check(afterRemove.read == 0 && afterRemove.rewrote && afterRemove.entries.count == 200 && !afterRemove.entries.contains { $0.id == added.id },
              "a record that's gone leaves the index, with nothing read")

        // An index that's missing, can't be read, or is another version's: made again from the records.
        try? manager.removeItem(at: indexURL)
        let missing = CaptureIndex.load(from: folder)
        check(missing.rebuilt && missing.read == 200 && missing.entries == afterRemove.entries, "a missing index is made again from the records")
        try? Data("not an index".utf8).write(to: indexURL)
        let broken = CaptureIndex.load(from: folder)
        check(broken.rebuilt && broken.read == 200 && broken.entries == afterRemove.entries, "so is one that can't be read")
        try? Data(#"{"version":99,"entries":[]}"#.utf8).write(to: indexURL)
        let other = CaptureIndex.load(from: folder)
        check(other.rebuilt && other.read == 200 && other.entries.count == 200, "and another version's")

        // Lines this build can't read (a newer build's state, or not a line at all): their records are read, the rest stand.
        if let data = try? Data(contentsOf: indexURL), var file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var entries = file["entries"] as? [[String: Any]] {
            entries[0]["state"] = "archived"
            file["entries"] = entries + [["id": 42]]
            try? JSONSerialization.data(withJSONObject: file).write(to: indexURL)
        }
        let lossy = CaptureIndex.load(from: folder)
        check(!lossy.rebuilt && lossy.read == 1 && lossy.entries.map(\.id) == afterRemove.entries.map(\.id),
              "a line it can't read has its record read instead, and the rest stand: \(lossy.read) read")

        // A record from iPhone 2.0 (9), before tries, outcomes or timelines; a record that can't be read; and files that
        // aren't records, beside them.
        let oldID = UUID()
        let oldRecord = #"""
        {"id":"\#(oldID.uuidString)","started":782300000,"ended":782300600,"speech":312,"state":"sent",
         "spans":{"spans":[{"fileStart":0,"wallStart":782300000,"duration":600}]},"engine":"parakeet-v2","words":640,
         "speakers":{"Speaker 1":"You"},"audioDeleted":true}
        """#
        try? Data(oldRecord.utf8).write(to: CaptureFiles.recordURL(oldID, in: folder))
        try? Data("{".utf8).write(to: CaptureFiles.recordURL(UUID(), in: folder))
        try? Data("[]".utf8).write(to: folder.appendingPathComponent("suggestions.json"))
        let mixed = CaptureIndex.load(from: folder)
        let oldLine = mixed.entries.first { $0.id == oldID }
        check(mixed.read == 2 && mixed.entries.count == 201, "an old record is indexed, and one that can't be read is left out as before: \(mixed.read) read")
        check(oldLine?.state == .sent && oldLine?.words == 640 && oldLine?.failures == nil && oldLine?.outcome == nil && oldLine?.hasTranscript == false,
              "the old record's line says what it does")

        // The records stay the source: a build without the index reads every one, as written.
        let all = CaptureFiles.all(in: folder)
        check(all.count == 201 && all.map(\.id) == mixed.entries.map(\.id), "a build without the index still reads every record")
        check(all.first { $0.id == changed.id } == changed && all.first { $0.id == records[100].id } == records[100],
              "and the records are as written: the index never changes them")

        // The launch, timed on 200 made-up records in a folder of their own: before the index, and with it.
        if let timing = CaptureIndex.timeLaunch(records: 200) {
            print(timing.line)
            check(timing.read == 0 && timing.withIndex < timing.everyRecord,
                  "the launch with the index decodes no record, and takes less time than decoding every one")
        } else {
            check(false, "the launch could be timed")
        }

        print(failures == 0 ? "CAPTURE_INDEX_OK" : "CAPTURE_INDEX_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
