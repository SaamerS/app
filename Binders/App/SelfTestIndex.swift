import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// The knowledge index on a store the size of a heavy user's (about 2,000 notes, with meetings, captured writing and
    /// dictations): how long a pass takes and how long it holds the main thread; that a pass after a few edits reads only
    /// what they touched; that edits, new notes, deletions (one by one and in bulk), a replaced transcript and a moved note
    /// are searchable after the next pass; and that the index keeps the content hashes 0.8.0 wrote, so an update indexes
    /// nothing again. A throwaway store (BINDERS_DATA_DIR); `--notes` sets how many notes.
    @MainActor
    static func indexSelfTest(noteCount: Int) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes thousands of notes there")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let store = Store.shared
        let context = store.context
        let knowledge = KnowledgeService()
        knowledge.modelWork = false

        // Items with fixed ids, dates and words: 0.8.0 wrote these content hashes for them.
        let fixtures = IndexFixtures.insert(into: store)
        var expected = fixtures.documents
        // And the bulk of a heavy user's library.
        var random = SeededGenerator(seed: 2_026)
        let binders = ["Harbor launch", "Garden", "Hiring", "Ops"].enumerated().map { index, name in
            let binder = BinderRecord(name: name, colorIndex: index + 1)
            context.insert(binder)
            return binder
        }
        let seeded = Date()
        var notes: [NoteItem] = []
        for index in 0..<noteCount {
            let long = random.next(upTo: 10) == 0
            let note = NoteItem(text: IndexFixtures.noteText(index: index, paragraphs: long ? 10 + random.next(upTo: 10) : 1 + random.next(upTo: 6), using: &random))
            note.binderID = binders[index % binders.count].id
            note.createdAt = Date().addingTimeInterval(-Double(index) * 4_000 - 600)
            note.updatedAt = note.createdAt
            context.insert(note)
            notes.append(note)
        }
        var meetings: [MeetingRecord] = []
        for index in 0..<40 {
            let meeting = MeetingRecord(title: "Weekly sync \(index + 1)", appName: "Zoom", templateID: "general")
            meeting.status = "ready"
            meeting.kind = index % 10 == 9 ? MeetingRecord.conversationKind : "meeting"
            meeting.binderID = binders[index % binders.count].id
            meeting.createdAt = Date().addingTimeInterval(-Double(index) * 86_400)
            meeting.summary = "## Decisions\n" + (0..<8).map { _ in "- " + IndexFixtures.sentence(using: &random) }.joined(separator: "\n")
            if index % 3 == 0 { meeting.userNotes = IndexFixtures.sentence(using: &random) + " mt\(index)x" }
            meeting.speakerNames = ["Others": "Sam"]
            context.insert(meeting)
            meetings.append(meeting)
        }
        for index in 0..<400 {
            let writing = WritingRecord(text: (0..<1 + random.next(upTo: 5)).map { _ in IndexFixtures.sentence(using: &random) }.joined(separator: " ") + " wr\(index)x")
            writing.appName = ["Mail", "Slack", "Microsoft Teams", "Outlook"][index % 4]
            writing.source = ["mail", "slack", "teams", "outlook"][index % 4]
            writing.recipients = index % 2 == 0 ? "Sam" : "the venue team"
            writing.subject = index < 20 ? "Batch" : (index % 3 == 0 ? "Venue" : nil)
            writing.binderID = binders[index % binders.count].id
            writing.createdAt = Date().addingTimeInterval(-Double(index) * 9_000)
            context.insert(writing)
        }
        var dictations: [TranscriptRecord] = []
        for index in 0..<1_560 {
            let isCommand = index % 26 == 25
            let text = (0..<1 + random.next(upTo: 3)).map { _ in IndexFixtures.sentence(using: &random) }.joined(separator: " ") + " dc\(index)x"
            let record = TranscriptRecord(createdAt: Date().addingTimeInterval(-Double(index) * 1_800), mode: isCommand ? "command" : "dictation",
                                          rawText: isCommand ? "make this shorter" : text, finalText: text, appName: ["Slack", "Mail", "Notes"][index % 3],
                                          bundleID: nil, category: nil, duration: 8, asrMillis: 90, llmMillis: 400, engine: "parakeetV3",
                                          llmModel: nil, usedLLM: false, fallbackReason: nil, audioFileName: nil, status: "inserted")
            context.insert(record)
            dictations.append(record)
        }
        store.save()
        for (index, meeting) in meetings.enumerated() {
            var segments: [TranscriptSegment] = []
            for segment in 0..<60 {
                let start = Double(segment * 12)
                let text = IndexFixtures.sentence(using: &random) + (segment == 0 ? " tr\(index)x" : "")
                segments.append(TranscriptSegment(channel: segment % 2 == 0 ? .microphone : .system, start: start, end: start + 10, text: text))
            }
            store.replaceSegments(for: meeting.id, with: segments)
        }
        expected += noteCount + meetings.count + 400 + dictations.count
        print("SEEDED: \(noteCount) notes, \(meetings.count) meetings, 400 messages, \(dictations.count) dictations in \(ms(since: seeded)) ms")

        func pass(_ name: String, by service: KnowledgeService? = nil) async -> (report: KnowledgeService.PassReport, stall: Int) {
            let service = service ?? knowledge
            let watch = MainThreadWatch()
            watch.start()
            let started = Date()
            await service.indexNow()
            let stall = watch.stop()
            let report = service.lastPass
            print("INDEX_PASS \(name): \(report) · longest main-thread stall \(stall) ms · \(ms(since: started)) ms in all")
            return (report, stall)
        }
        func found(_ word: String, binder: UUID? = nil) async -> [KnowledgeHit] {
            await knowledge.store.keywordSearch(word, limit: 5, kinds: nil, binder: binder?.uuidString)
        }

        // The first pass after launch: everything.
        let first = await pass("first")
        let documents = await knowledge.store.stats().documents
        check(documents == expected, "every item is indexed: \(documents) of \(expected)")
        let hashes = await knowledge.store.documentHashes()
        if IndexFixtures.golden.isEmpty {
            for id in fixtures.ids { print("GOLDEN: \(id) \(hashes[id] ?? "none")") }
        }
        for (id, hash) in IndexFixtures.golden.sorted(by: { $0.key < $1.key }) {
            check(hashes[id] == hash, "\(id) has the content hash 0.8.0 wrote")
        }
        check(first.stall < 100, "the first pass leaves the main thread free (longest stall \(first.stall) ms)")

        // A few edits, as a morning brings: notes changed, added and deleted, messages pruned in bulk, a meeting's summary
        // and transcript changed, a note moved, a dictation deleted.
        for index in [3, 501, 1_402] where index < notes.count {
            notes[index].text += "\n\nAdded later: zephyrine\(index) for the booth."
            notes[index].updatedAt = Date()
        }
        let added = ["# Quillfeather plan\n\nThe quillfeather banner goes up first.", "# Second new note\n\nSam brings the cables. newnotetwo"]
            .map { text -> NoteItem in
                let note = NoteItem(text: text)
                note.binderID = binders[0].id
                context.insert(note)
                return note
            }
        let deleted = notes[7]
        context.delete(deleted)
        try? context.delete(model: WritingRecord.self, where: #Predicate { $0.subject == "Batch" })
        meetings[3].summary += "\n- Marmalade for the volunteers."
        let moved = notes[11]
        moved.binderID = binders[2].id
        context.delete(dictations[5])
        // A note left alone, long enough for a digest and waiting for one.
        let candidate = notes.enumerated().first { index, note in
            note.text.wordCount >= NoteDigest.minimumWords && ![3, 7, 11, 501, 1_402].contains(index)
        }?.element
        store.save()
        store.replaceSegments(for: meetings[4].id, with: [
            TranscriptSegment(channel: .microphone, start: 3, end: 9, text: "The lighthouse tier stays at nine dollars."),
        ])
        let changed = 3 + added.count + 1 + 20 + 1 + 1 + 1 + 1
        let edited = await pass("after edits")
        check(edited.report.read <= changed, "it reads only what changed: \(edited.report.read) items for \(changed) changes")
        check(edited.report.written == 3 + added.count + 3, "and writes only those: \(edited.report.written)")
        check(edited.report.removed == 1 + 20 + 1, "and removes what was deleted, one by one or in bulk: \(edited.report.removed)")
        check(edited.report.lookedUp == 0, "knowing what was saved as it was saved, without reading every item of a kind: \(edited.report.lookedUp) looked up")
        check(edited.stall < 50, "with the main thread free (longest stall \(edited.stall) ms)")
        // Which items a word is found in, with no model: the words each item alone has ("nt12x").
        var sources: [String: [String]] = [:]
        for word in ["zephyrine501", "quillfeather", "newnotetwo", "nt7x", "nt8x", "wr3x", "wr19x", "wr20x", "marmalade", "lighthouse",
                     "tr4x", "dc5x", "dc6x"] {
            sources[word] = await found(word).map(\.sourceID)
        }
        let movedTo = await found("nt11x", binder: binders[2].id).map(\.sourceID)
        let movedFrom = await found("nt11x", binder: binders[3].id).map(\.sourceID)
        func hits(_ word: String) -> [String] { sources[word] ?? [] }
        check(hits("zephyrine501").first == notes[501].id.uuidString, "an edited note is found by its new words")
        check(hits("quillfeather").first == added[0].id.uuidString && !hits("newnotetwo").isEmpty, "new notes are found")
        check(hits("nt7x").isEmpty && !hits("nt8x").isEmpty, "a deleted note is gone, its neighbour isn't")
        check(hits("wr3x").isEmpty && hits("wr19x").isEmpty && !hits("wr20x").isEmpty, "messages deleted in bulk are gone, the rest aren't")
        check(hits("marmalade").first == meetings[3].id.uuidString, "a meeting's new summary is found")
        check(hits("lighthouse").first == meetings[4].id.uuidString && hits("tr4x").isEmpty, "a replaced transcript is found, and its old words are gone")
        check(movedTo.first == moved.id.uuidString && movedFrom.isEmpty, "a moved note is found in its new binder only")
        check(hits("dc5x").isEmpty && !hits("dc6x").isEmpty, "a deleted dictation is gone")
        let after = await knowledge.store.stats().documents
        check(after == expected + added.count - 1 - 20 - 1, "the index holds what the library holds: \(after)")

        // Nothing changed: an idle pass (the five-minute timer) reads nothing.
        let idle = await pass("idle")
        check(idle.report.read == 0 && idle.report.written == 0 && idle.report.removed == 0, "an idle pass reads and writes nothing")
        check(idle.stall < 50, "and leaves the main thread free (longest stall \(idle.stall) ms)")

        // A note that waits for a digest, then has one.
        if let candidate {
            candidate.digest = "# Booth\n\n## Summary\nWhat the booth needs."
            candidate.digestHash = KnowledgeService.noteContentHash(candidate.text)
            store.save()
            let digested = await pass("after a digest")
            check(digested.report.digestCandidates == idle.report.digestCandidates - 1,
                  "a note with an up-to-date digest stops waiting for one: \(idle.report.digestCandidates) then \(digested.report.digestCandidates)")
            check(digested.report.read == 1 && digested.report.written == 1, "and only that note is read again and written with its digest")
        }

        // A note saved where nothing held on to it, so the save can't say which note it was: still read, and only it.
        context.insert(NoteItem(text: "# Gull watch\n\nThe cormorant count is on Saturday."))
        store.save()
        let unheld = await pass("after a save of an item nothing held")
        check(unheld.report.read == 1 && unheld.report.written == 1,
              "a note saved where its id wasn't known is read, and only it: \(unheld.report.read) read, \(unheld.report.lookedUp) looked up")
        check(await found("cormorant").count == 1, "and found")

        // Binders opened again over the same index, as after an update: everything read once, nothing written again.
        let indexed = await knowledge.store.stats().documents
        let relaunched = KnowledgeService()
        relaunched.modelWork = false
        let again = await pass("after a relaunch", by: relaunched)
        check(again.report.read == indexed, "the first pass after a relaunch reads everything: \(again.report.read) of \(indexed)")
        check(again.report.written == 0 && again.report.removed == 0,
              "and writes nothing again: \(again.report.written) written, \(again.report.removed) removed")
        check(again.stall < 100, "with the main thread free (longest stall \(again.stall) ms)")

        // The app reading the store while a pass reads everything, as Home does at launch: its reads share the store with
        // the pass's, and wait for them.
        final class Reads: @unchecked Sendable {
            var running = true
            var count = 0
            var longest: TimeInterval = 0
        }
        let reads = Reads()
        let reader = Task { @MainActor in
            var recent = FetchDescriptor<NoteItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            recent.fetchLimit = 20
            while reads.running {
                let started = Date()
                _ = try? context.fetch(recent)
                reads.longest = max(reads.longest, Date().timeIntervalSince(started))
                reads.count += 1
                try? await Task.sleep(for: .milliseconds(4))
            }
        }
        let readingRelaunch = KnowledgeService()
        readingRelaunch.modelWork = false
        let read = await pass("after a relaunch, with the app reading", by: readingRelaunch)
        reads.running = false
        await reader.value
        let longestRead = Int(reads.longest * 1000)
        print("APP_READS: \(reads.count) reads of the 20 latest notes during the pass, the longest \(longestRead) ms")
        check(read.report.written == 0 && longestRead < 100, "the app's own reads aren't held up by it: longest \(longestRead) ms")

        // Digests: a pass finds the notes due one, writes the four waiting longest (with a stand-in for the model) and
        // indexes them in the same pass.
        knowledge.digestModel = StandInModel(reply: "# Stand-in digest\n\n## Summary\nWhat the note says, in brief: pelican.")
        let waiting = knowledge.lastPass.digestCandidates
        let digesting = await pass("with digests written")
        knowledge.digestModel = nil
        check(digesting.report.written == 4 && digesting.report.digestCandidates == waiting - 4,
              "a pass writes digests for the four notes waiting longest and indexes them in the same pass: \(digesting.report.written) written, \(waiting) then \(digesting.report.digestCandidates) waiting")
        check(await found("pelican").count == 4, "and their digests are found")
        print(failures == 0 ? "INDEX_OK" : "INDEX_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

/// Items with fixed ids, dates and words, one of every kind the index holds, and the content hashes 0.8.0 wrote for them.
@MainActor
enum IndexFixtures {
    /// Printed by this test on the 0.8.0 index (7ed4ef1); empty, the test prints them instead of checking them.
    static let golden: [String: String] = [
        "note:0A0A0A0A-0000-4000-8000-000000000101": "ab80a6de29bdbfb0da4eb14cab6099de8a1c0af9a257d2d2b090f28c92246f0d",
        "note:0A0A0A0A-0000-4000-8000-000000000102": "95c65c80647acfb2e93f171daeaa097e619bcd43d14719888538b03584737143",
        "note:0A0A0A0A-0000-4000-8000-000000000103": "cf7129fe15a6f3091fcc1c2809214b3cc3bc7c87a7d66da0e96f55006fa4de37",
        "meeting:0A0A0A0A-0000-4000-8000-000000000201": "7a9e7d010239be61872123b68c8ba3e7fdb71f90ed2aed2d319d724319ece4a2",
        "conversation:0A0A0A0A-0000-4000-8000-000000000202": "27910a751b1f5284e19abb90325d84d0e7f7e1deb3d27240b48574923204d014",
        "writing:0A0A0A0A-0000-4000-8000-000000000301": "68884cf0fd69c90f1f3062a206a9cbc9eaf45dfc50566247c32d9f5728f7fec4",
        "dictation:0A0A0A0A-0000-4000-8000-000000000401": "a65336dc3689942a3240bf54f213e872feb974d73c1e3b681e9c23c4dd9dfb7d",
        "command:0A0A0A0A-0000-4000-8000-000000000402": "26cb3ed6f6b20e8a0dba7b344d5d0a1b88234fad27c838f5330c0809da34c30c",
    ]

    static func uuid(_ last: Int) -> UUID { UUID(uuidString: String(format: "0A0A0A0A-0000-4000-8000-%012d", last))! }

    /// Inserts them and returns their document ids and how many documents they make.
    static func insert(into store: Store) -> (ids: [String], documents: Int) {
        let context = store.context
        let day = Date(timeIntervalSince1970: 1_767_600_000)
        let binder = BinderRecord(name: "Index fixtures", colorIndex: 3)
        binder.id = uuid(1)
        context.insert(binder)

        let plain = NoteItem(text: "# Ignite booth\n\nThe booth needs two monitors and a banner. Sam books the van on Tuesday.")
        plain.id = uuid(101)
        let digested = NoteItem(text: "# Booth budget\n\n" + String(repeating: "The banner costs more than planned, so the van is shared with the venue team. ", count: 4)
                                + "\n\n- [ ] Ask the dentist to move the appointment")
        digested.id = uuid(102)
        digested.digest = "# Booth budget\n\n## Summary\nThe banner costs more; the van is shared.\n\n## To-dos\n- [ ] Ask the dentist to move the appointment"
        let shared = NoteItem(text: "# Venue notes\n\nThe venue holds two hundred people. Parking is round the back.")
        shared.id = uuid(103)
        shared.isTeamCopy = true
        shared.teamAuthorName = "Alex"
        for note in [plain, digested, shared] {
            note.binderID = binder.id
            note.createdAt = day
            note.updatedAt = day
            context.insert(note)
        }

        let meeting = MeetingRecord(title: "Venue walkthrough", appName: "Zoom", templateID: "general")
        meeting.id = uuid(201)
        meeting.summary = "## Decisions\n- The venue holds 200.\n- Catering arrives by noon."
        meeting.userNotes = "Ask about parking."
        meeting.speakerNames = ["Others": "Sam"]
        let conversation = MeetingRecord(title: "Hallway chat", appName: "iPhone", templateID: "conversation")
        conversation.id = uuid(202)
        conversation.kind = MeetingRecord.conversationKind
        conversation.summary = "## Summary\nA chat about the quayside venue."
        for record in [meeting, conversation] {
            record.status = "ready"
            record.binderID = binder.id
            record.createdAt = day
            context.insert(record)
        }

        let writing = WritingRecord(text: "Thanks for the update on the venue. I'll confirm the catering order by Friday.")
        writing.id = uuid(301)
        writing.appName = "Mail"
        writing.source = "mail"
        writing.recipients = "Sam"
        writing.subject = "Venue"
        writing.binderID = binder.id
        writing.createdAt = day
        context.insert(writing)

        let dictation = TranscriptRecord(id: uuid(401), createdAt: day, mode: "dictation", rawText: "remind the team the booth opens at nine",
                                         finalText: "Remind the team that the booth opens at nine on Thursday.", appName: "Slack",
                                         bundleID: nil, category: nil, duration: 4, asrMillis: 80, llmMillis: 300, engine: "parakeetV3",
                                         llmModel: nil, usedLLM: true, fallbackReason: nil, audioFileName: nil, status: "inserted")
        let command = TranscriptRecord(id: uuid(402), createdAt: day, mode: "command", rawText: "make this shorter",
                                       finalText: "The booth opens at nine on Thursday.", appName: "Notes", bundleID: nil, category: nil,
                                       duration: 2, asrMillis: 70, llmMillis: 500, engine: "parakeetV3", llmModel: nil, usedLLM: true,
                                       fallbackReason: nil, audioFileName: nil, status: "inserted")
        context.insert(dictation)
        context.insert(command)
        store.save()
        store.replaceSegments(for: meeting.id, with: [
            TranscriptSegment(channel: .microphone, start: 2, end: 7, text: "Can the venue take two hundred?"),
            TranscriptSegment(channel: .system, start: 8, end: 14, text: "Yes, and catering can be here by noon."),
            TranscriptSegment(channel: .microphone, start: 15, end: 19, text: "Good. I'll ask about parking."),
        ])
        store.replaceSegments(for: conversation.id, with: [
            TranscriptSegment(channel: .microphone, start: 1, end: 5, text: "Is the quayside venue still free on Friday?"),
        ])
        let ids = ["note:\(plain.id)", "note:\(digested.id)", "note:\(shared.id)", "meeting:\(meeting.id)", "conversation:\(conversation.id)",
                   "writing:\(writing.id)", "dictation:\(dictation.id)", "command:\(command.id)"]
        return (ids, ids.count)
    }

    private static let words = """
        booth banner venue catering parking van monitors cables schedule budget launch pricing plan review support import beta \
        roadmap annual monthly customers onboarding emails checklist design hiring candidate interview garden tomatoes beds \
        water compost seeds volunteers rota inbox friday monday tuesday thursday morning afternoon evening week month quarter \
        ticket invoice order delivery supplier contract draft copy page table chart slide deck numbers forecast target team \
        meeting call notes question answer idea follow up decision owner deadline priority risk blocker update status release \
        build test staging server data report summary agenda minutes travel train hotel booking dinner lunch coffee printer \
        signage lanyards badges stand floor plan power socket wifi password laptop charger backup storage folder spreadsheet \
        the a to of and in on for with at by from that this is was will can should could would need needs want wants make \
        takes brings sends books moves keeps checks asks tells calls writes reads shares opens closes starts finishes
        """.split(whereSeparator: \.isWhitespace).map(String.init)

    static func sentence(using random: inout SeededGenerator) -> String {
        let count = 6 + random.next(upTo: 13)
        let text = (0..<count).map { _ in words[random.next(upTo: words.count)] }.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    /// A note with a title, paragraphs, now and then a to-do list, and a word only it has ("nt12x").
    static func noteText(index: Int, paragraphs: Int, using random: inout SeededGenerator) -> String {
        var parts = ["# " + sentence(using: &random).dropLast()]
        for paragraph in 0..<paragraphs {
            if paragraph == 1, random.next(upTo: 4) == 0 {
                parts.append((0..<3).map { _ in "- [ ] " + sentence(using: &random) }.joined(separator: "\n"))
            } else {
                parts.append((0..<1 + random.next(upTo: 5)).map { _ in sentence(using: &random) }.joined(separator: " "))
            }
        }
        parts.append("nt\(index)x")
        return parts.joined(separator: "\n\n")
    }
}

/// Answers everything with the same words: what's done with a model's reply, checked without a model.
struct StandInModel: LLMClient {
    let reply: String
    var model: String { "stand-in" }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String { reply }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String { reply }

    func listModels() async throws -> [String] { [model] }

    func warmUp() async {}
}

/// The same numbers every run, so timings before and after a change compare like with like.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(upTo bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

/// How long the main thread goes without answering: a background thread asks it to run an empty block every few
/// milliseconds and keeps the longest wait.
final class MainThreadWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var longest: TimeInterval = 0
    private var running = false

    func start() {
        lock.withLock {
            running = true
            longest = 0
        }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let waited = Date().timeIntervalSince(sent)
                lock.withLock { longest = max(longest, waited) }
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
    }

    /// Stops watching; the longest wait, in milliseconds.
    func stop() -> Int {
        lock.withLock {
            running = false
            return Int(longest * 1000)
        }
    }
}
