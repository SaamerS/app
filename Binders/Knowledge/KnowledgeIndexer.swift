import Foundation
import SwiftData
import BindersKit

/// What was saved to the library since the knowledge index last read it, noted during each save the store's contexts
/// make. A pass reads what was saved and what's new; what's gone it finds by comparing ids, as a bulk delete doesn't say
/// what it deleted.
final class IndexChangeLog: @unchecked Sendable {
    struct Changes: Sendable {
        /// Notes, meetings, captured writing and dictations saved, with each one's id when the saving context still held it
        /// (nil when it didn't: a pass reads that kind whole to find it).
        var saved: [PersistentIdentifier: UUID?] = [:]
        /// Meetings whose transcript lines were saved.
        var transcripts: Set<UUID> = []
        /// A save that said every id it knew is out of date: everything is read again.
        var everything = false
    }

    private let lock = NSLock()
    private var changes = Changes()
    private var observer: NSObjectProtocol?

    init(container: ModelContainer) {
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] notification in
            // On the thread that saved, during its save, while its context still holds what it saved.
            guard let self, let context = notification.object as? ModelContext, context.container === container else { return }
            self.note(notification.userInfo, from: context)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// What was saved since the last call.
    func take() -> Changes {
        lock.lock()
        defer { lock.unlock() }
        let taken = changes
        changes = Changes()
        return taken
    }

    private func note(_ userInfo: [AnyHashable: Any]?, from context: ModelContext) {
        func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] { userInfo?[key.rawValue] as? [PersistentIdentifier] ?? [] }
        var saved: [PersistentIdentifier: UUID?] = [:]
        var transcripts = Set<UUID>()
        for id in ids(.insertedIdentifiers) + ids(.updatedIdentifiers) {
            switch id.entityName {
            case "NoteItem": saved[id] = (context.registeredModel(for: id) as NoteItem?)?.id
            case "MeetingRecord": saved[id] = (context.registeredModel(for: id) as MeetingRecord?)?.id
            case "WritingRecord": saved[id] = (context.registeredModel(for: id) as WritingRecord?)?.id
            case "TranscriptRecord": saved[id] = (context.registeredModel(for: id) as TranscriptRecord?)?.id
            case "MeetingSegmentRecord":
                // Lines the store adds also bump its transcript revisions, which a pass compares too.
                if let meeting = (context.registeredModel(for: id) as MeetingSegmentRecord?)?.meetingID { transcripts.insert(meeting) }
            default: continue
            }
        }
        let everything = userInfo?[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] != nil
        guard !saved.isEmpty || !transcripts.isEmpty || everything else { return }
        lock.lock()
        defer { lock.unlock() }
        // An id found once stays found.
        changes.saved.merge(saved) { old, new in new ?? old }
        changes.transcripts.formUnion(transcripts)
        changes.everything = changes.everything || everything
    }
}

/// Keeps the knowledge index up to date with the library, off the main thread: each pass reads on a context of its own,
/// and reads only what's new or was saved since the last pass (all of it the first time after launch). What it reads it
/// splits into passages and hashes as 0.8.0 did, and it writes only what changed, so an update writes nothing again.
actor KnowledgeIndexer {
    struct Report: Sendable {
        var read = 0
        var written = 0
        var removed = 0
        /// The first notes due a digest, the one edited longest ago first, and how many are due in all.
        var digestsDue: [UUID] = []
        var digestsDueCount = 0
        /// Items saved by a context that no longer held them, found by reading their kind whole.
        var lookedUp = 0
    }

    /// An item the last pass read, and the document it made, if any, with that document's hash.
    private struct Entry {
        var uuid: UUID
        var document: String?
        var hash: String?
    }

    /// The kinds of item the index reads, one model each.
    private enum Source: CaseIterable {
        case meetings, notes, writing, dictations

        var entityName: String {
            switch self {
            case .meetings: "MeetingRecord"
            case .notes: "NoteItem"
            case .writing: "WritingRecord"
            case .dictations: "TranscriptRecord"
            }
        }

        /// Whether a document id is one this kind makes.
        func makes(_ documentID: String) -> Bool {
            let kinds: [KnowledgeKind] = switch self {
            case .meetings: [.meeting, .conversation]
            case .notes: [.note]
            case .writing: [.writing]
            case .dictations: [.dictation, .command]
            }
            return kinds.contains { documentID.hasPrefix($0.rawValue + ":") }
        }
    }

    /// Past this many items to read, a pass reads the whole kind in one go rather than asking for them by id.
    private static let wholeKindAbove = 300

    private let container: ModelContainer
    private let store: KnowledgeStore
    private var known: [Source: [PersistentIdentifier: Entry]] = [:]
    private var transcriptRevisions: [UUID: Int] = [:]
    private var digests = DigestQueue<UUID>()
    /// Bumped by `forget()`, so a pass running meanwhile doesn't keep what it read.
    private var generation = 0

    init(container: ModelContainer, store: KnowledgeStore) {
        self.container = container
        self.store = store
    }

    /// The next pass reads everything again: for when the index was emptied.
    func forget() {
        known = [:]
        transcriptRevisions = [:]
        digests = DigestQueue()
        generation += 1
    }

    /// One pass: `changes` is what was saved since the last, `revisions` each meeting's transcript revision now.
    func pass(_ changes: IndexChangeLog.Changes, transcriptRevisions revisions: [UUID: Int]) async -> Report {
        let generation = self.generation
        var known = self.known
        var digests = self.digests
        var report = Report()
        // What's in the index now: a document a pass wrote and that isn't there as written is written again.
        let stored = await store.documentHashes()
        var removals = Set<String>()
        var scanned = Set<Source>()

        var transcripts = changes.transcripts
        for (meeting, revision) in revisions where transcriptRevisions[meeting] != revision { transcripts.insert(meeting) }

        for source in Source.allCases {
            // A context per kind, so what one kind read is let go before the next.
            let context = ModelContext(container)
            context.autosaveEnabled = false
            var entries = known[source] ?? [:]
            let found: [(KnowledgeDocument, [KnowledgeChunk])]?
            switch source {
            case .meetings:
                found = read(MeetingRecord.self, source, in: context, entries: &entries, changes: changes, transcripts: transcripts,
                             stored: stored, report: &report, removals: &removals) { meeting in
                    KnowledgeService.document(for: meeting, segments: Self.segments(of: meeting.id, in: context))
                }
            case .notes:
                found = read(NoteItem.self, source, in: context, entries: &entries, changes: changes, transcripts: [],
                             stored: stored, report: &report, removals: &removals, gone: { digests.remove($0) }) { note in
                    digests.update(note.id, stale: note.digestHash != KnowledgeService.noteContentHash(note.text),
                                   words: note.text.wordCount, edited: note.updatedAt)
                    return KnowledgeService.document(for: note)
                }
            case .writing:
                found = read(WritingRecord.self, source, in: context, entries: &entries, changes: changes, transcripts: [],
                             stored: stored, report: &report, removals: &removals) { KnowledgeService.document(for: $0) }
            case .dictations:
                found = read(TranscriptRecord.self, source, in: context, entries: &entries, changes: changes, transcripts: [],
                             stored: stored, report: &report, removals: &removals) { KnowledgeService.document(for: $0) }
            }
            // A kind that couldn't be read is read whole next time, and nothing of it is removed now.
            guard let found else {
                known[source] = nil
                continue
            }
            scanned.insert(source)
            known[source] = entries
            for (document, chunks) in found {
                await store.upsert(document, chunks: chunks)
                report.written += 1
            }
        }

        // Documents no item makes any more: deleted while Binders was closed, or left by an older build.
        let expected = Set(known.values.flatMap { $0.values.compactMap(\.document) })
        for id in stored.keys where !expected.contains(id) && scanned.contains(where: { $0.makes(id) }) { removals.insert(id) }
        removals.subtract(expected)
        if !removals.isEmpty {
            await store.remove(documentIDs: Array(removals))
            report.removed = removals.count
        }

        let due = digests.due()
        report.digestsDue = Array(due.prefix(8))
        report.digestsDueCount = due.count
        // Forgotten meanwhile: the next pass reads everything, as asked.
        guard generation == self.generation else { return report }
        self.known = known
        self.digests = digests
        if scanned.contains(.meetings) { transcriptRevisions = revisions }
        return report
    }

    /// Reads the items of one kind that are new, were saved since, or whose document isn't in the index as last written,
    /// and drops the ones gone. Returns the documents to write, or nil, having changed nothing, when the kind couldn't be
    /// read.
    private func read<Model: IndexedModel>(
        _ type: Model.Type, _ source: Source, in context: ModelContext, entries: inout [PersistentIdentifier: Entry],
        changes: IndexChangeLog.Changes, transcripts: Set<UUID>, stored: [String: String], report: inout Report,
        removals: inout Set<String>, gone: (UUID) -> Void = { _ in },
        document: (Model) -> (KnowledgeDocument, [KnowledgeChunk])?
    ) -> [(KnowledgeDocument, [KnowledgeChunk])]? {
        let live: Set<PersistentIdentifier>
        do {
            live = try Set(context.fetchIdentifiers(Model.indexable))
        } catch {
            Log.app.error("Knowledge pass couldn't list \(source.entityName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let firstSight = entries.isEmpty
        var saved = changes.everything ? live : Set(changes.saved.keys.filter { $0.entityName == source.entityName })
        for (id, entry) in entries {
            if transcripts.contains(entry.uuid) { saved.insert(id) }
            if let documentID = entry.document, stored[documentID] != entry.hash { saved.insert(id) }
        }
        let delta = IndexDelta(live: live, known: Set(entries.keys), saved: saved)

        // A few, asked for by id; many, or one saved where its id wasn't known, by reading the kind whole. In one read:
        // reading in batches kept the app's own reads no quicker (at most 7 ms either way, on 17,000 items) and made a
        // whole read a fifth slower.
        var ids: [UUID] = []
        var unknown = 0
        for id in delta.read {
            if let uuid = changes.saved[id].flatMap({ $0 }) ?? entries[id]?.uuid { ids.append(uuid) } else { unknown += 1 }
        }
        var models: [Model] = []
        do {
            if unknown > 0 || delta.read.count > Self.wholeKindAbove {
                models = try context.fetch(Model.indexable)
                if !firstSight, delta.read.count <= Self.wholeKindAbove { report.lookedUp += unknown }
            } else {
                for start in stride(from: 0, to: ids.count, by: 200) {
                    models += try context.fetch(Model.withIDs(Array(ids[start..<min(start + 200, ids.count)])))
                }
            }
        } catch {
            Log.app.error("Knowledge pass couldn't read \(source.entityName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        for id in delta.gone {
            if let entry = entries.removeValue(forKey: id) {
                if let documentID = entry.document { removals.insert(documentID) }
                gone(entry.uuid)
            }
        }
        var writes: [(KnowledgeDocument, [KnowledgeChunk])] = []
        for model in models {
            let id = model.persistentModelID
            guard delta.read.contains(id) else { continue }
            let made = document(model)
            let previous = entries[id]?.document
            if let (document, chunks) = made, stored[document.id] != document.contentHash { writes.append((document, chunks)) }
            // A meeting that became a capture, or a dictation that became a command, has a new document id; a note
            // emptied has none.
            if let previous, previous != made?.0.id { removals.insert(previous) }
            entries[id] = Entry(uuid: model.id, document: made?.0.id, hash: made?.0.contentHash)
            report.read += 1
        }
        return writes
    }

    private static func segments(of meetingID: UUID, in context: ModelContext) -> [TranscriptSegment] {
        let descriptor = FetchDescriptor<MeetingSegmentRecord>(predicate: #Predicate { $0.meetingID == meetingID },
                                                               sortBy: [SortDescriptor(\.start)])
        return ((try? context.fetch(descriptor)) ?? []).map(\.segment)
    }
}

/// A model the index reads: which of its items can be indexed at all, and how to fetch some of them by id.
private protocol IndexedModel: PersistentModel {
    var id: UUID { get }
    static var indexable: FetchDescriptor<Self> { get }
    static func withIDs(_ ids: [UUID]) -> FetchDescriptor<Self>
}

extension MeetingRecord: IndexedModel {
    /// Meetings and captures once they're done, whether their notes were written or not.
    fileprivate static var indexable: FetchDescriptor<MeetingRecord> {
        FetchDescriptor(predicate: #Predicate { $0.status == "ready" || $0.status == "failed" })
    }

    fileprivate static func withIDs(_ ids: [UUID]) -> FetchDescriptor<MeetingRecord> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }
}

extension NoteItem: IndexedModel {
    fileprivate static var indexable: FetchDescriptor<NoteItem> { FetchDescriptor() }

    fileprivate static func withIDs(_ ids: [UUID]) -> FetchDescriptor<NoteItem> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }
}

extension WritingRecord: IndexedModel {
    fileprivate static var indexable: FetchDescriptor<WritingRecord> { FetchDescriptor() }

    fileprivate static func withIDs(_ ids: [UUID]) -> FetchDescriptor<WritingRecord> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }
}

extension TranscriptRecord: IndexedModel {
    /// Dictations and commands that were typed into an app.
    fileprivate static var indexable: FetchDescriptor<TranscriptRecord> {
        FetchDescriptor(predicate: #Predicate { $0.status == "inserted" })
    }

    fileprivate static func withIDs(_ ids: [UUID]) -> FetchDescriptor<TranscriptRecord> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }
}
