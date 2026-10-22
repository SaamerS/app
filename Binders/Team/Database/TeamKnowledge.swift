import Foundation
import SwiftData
import BindersKit

/// Knowledge a team database shares (lane DB4), as the knowledge index asks for it while it embeds and reads: vectors and
/// people and topics a teammate's Mac already made of the same items, the items whose index is still coming, and, after
/// each pass, this Mac's own items published.
@MainActor
protocol KnowledgeSharing: AnyObject {
    /// Documents (index ids, "meeting:<ID>") whose vectors a teammate's Mac is still making: the index waits for them a while.
    func waitingDocuments() async -> Set<String>
    /// Vectors the team has for these passages from the same model as `model` (any precision), by chunk id.
    func vectors(for chunks: [(id: Int64, text: String, title: String)], model: String) async -> [Int64: [Float]]
    /// Documents whose people and topics a teammate's Mac is still finding.
    func waitingForEntities() async -> Set<String>
    /// The people and topics a teammate's Mac found in the same item, for exactly these chunks; nil when it has none.
    func entities(for job: EntityJob) async -> ExtractionResult?
    /// Teammates' items whose people and topics this Mac hasn't found or taken since they last changed.
    func teamDocumentsToRead() async -> [String]
    /// A knowledge pass ended: what changed of this Mac's shared items is published.
    func indexed() async
}

/// This Mac's half of the team's knowledge: publishes its own items' index (chunks with their vectors, people and topics,
/// how they relate, corrections), one `replace_knowledge` per item that changed (TeamKnowledgePublish.swift); keeps what
/// teammates' Macs published (TeamKnowledgeCache) for its own index to take; keeps teammates' corrections
/// (corrections.json) for Ask and search; and notices when the team pins another embedding model, says so, and publishes
/// again.
@MainActor
final class TeamKnowledge: KnowledgeSharing {
    unowned let content: TeamContent
    private(set) var cache: TeamKnowledgeCache?
    /// Teammates' corrections, newest first.
    private(set) var teamCorrections: [TeamCorrection] = []
    /// When each teammate's item was first found waiting for its maker's index.
    private var waitingSince: [String: Date] = [:]
    /// How long a teammate's item waits for its maker's vectors and people and topics before this Mac makes its own.
    var grace: TimeInterval = 600
    var publishing = false
    var publishAgain = false
    var waitingForOutbox = false
    /// The team's pin as last read: its model, its length, its epoch.
    private(set) var pin: (model: String, dimension: Int, epoch: Int)?
    /// The team pinned another model since this Mac last published everything: it's being sent again.
    var resending = false
    /// What was published since the app started, for the self-tests and the log: items, vectors, and passages embedded
    /// for the team (the maker's own lines, as the team reads them).
    var publishedItems = 0
    var publishedVectors = 0
    var embeddedForTeam = 0

    init(content: TeamContent) {
        self.content = content
    }

    var knowledge: KnowledgeService? { content.team.controller?.knowledge }
    private var folder: URL? { content.team.folder }

    func start() {
        if cache == nil, let folder { cache = TeamKnowledgeCache(url: folder.appendingPathComponent("knowledge.sqlite")) }
        teamCorrections = Self.read(folder)
        knowledge?.sharing = self
        knowledge?.correctionsChanged()
    }

    func stop() {
        if knowledge?.sharing === self { knowledge?.sharing = nil }
        knowledge?.correctionsChanged()
    }

    /// Connected: the team's pin read again, then this Mac's items published.
    func cameOnline() async {
        if let team = content.database?.team { await notice(team: team) }
        await indexed()
    }

    // MARK: The team's pin

    /// The team's settings: a pin newer than the one this Mac last published with means every item goes again, said once.
    func notice(team row: TeamRow) async {
        guard let model = row["embedding_model"]?.string, let dimension = row["embedding_dimension"]?.int, let epoch = row["embedding_epoch"]?.int,
              let cache else { return }
        pin = (model, dimension, epoch)
        let known = await cache.meta("epoch").flatMap(Int.init)
        guard known != epoch else { return }
        await cache.setMeta("epoch", String(epoch))
        guard known != nil else { return }
        await cache.forgetAllPublished()
        resending = true
        let line = "The team's embedding model is now \(model). Binders is sending the meanings of your shared items again."
        content.team.controller?.flowBar.toast(line, symbol: "arrow.triangle.2.circlepath", duration: 6)
        Log.app.notice("Team knowledge: the team pinned \(model, privacy: .public) (epoch \(epoch)); publishing again")
        knowledge?.scheduleIndex(after: 1)
    }

    /// What Settings → Team says of the team's knowledge; nil before the team's pin is known.
    var line: String? {
        guard let pin else { return nil }
        guard let local = knowledge?.passageModel else {
            return "Choose an embedding model in Settings → Knowledge. The team's is \(pin.model)."
        }
        if !TeamEmbedding.isPin(local, pin: pin.model) {
            return "This Mac embeds with \(local) and the team with \(pin.model), so it makes the meanings of teammates' items itself and doesn't send its own."
        }
        if resending { return "The team's embedding model is now \(pin.model). Binders is sending the meanings of your shared items again." }
        return "The meanings of your shared items go to the team, made with \(pin.model), and teammates' come here, so no Mac makes them twice."
    }

    // MARK: From the feed

    /// An update's knowledge rows, corrections and team settings.
    func apply(_ update: TeamUpdate) async {
        guard let cache else { return }
        let me = content.directory.me
        var touched = false
        for table in [TeamTable.knowledgeChunks, .entities, .relations] {
            let rows = update.rows[table] ?? []
            if !rows.isEmpty {
                await cache.take(rows, table: table, me: me)
                touched = true
            }
            let gone = update.gone.filter { $0.table == table }.map(\.id)
            if !gone.isEmpty {
                await cache.remove(gone, table: table)
                touched = true
            }
        }
        let corrections = update.rows[.corrections] ?? []
        let goneCorrections = Set(update.gone.filter { $0.table == .corrections }.map(\.id))
        if !corrections.isEmpty || !goneCorrections.isEmpty {
            take(corrections: corrections, gone: goneCorrections)
        }
        if let team = update.rows[.teamSettings]?.first { await notice(team: team) }
        if touched { knowledge?.scheduleIndex(after: 1) }
    }

    /// A binder read whole: its knowledge as the database has it now.
    func readWhole(_ binder: UUID, rows: [TeamTable: [TeamRow]]) async {
        guard let cache else { return }
        await cache.forget(binder: binder)
        let me = content.directory.me
        for table in [TeamTable.knowledgeChunks, .entities, .relations] { await cache.take(rows[table] ?? [], table: table, me: me) }
        teamCorrections.removeAll { $0.binder == binder }
        take(corrections: rows[.corrections] ?? [], gone: [])
        knowledge?.scheduleIndex(after: 1)
    }

    /// The team lost a binder for this Mac: what its teammates made of it goes.
    func binderGone(_ binder: UUID) {
        let cache = cache
        Task { await cache?.forget(binder: binder) }
        let before = teamCorrections.count
        teamCorrections.removeAll { $0.binder == binder }
        if teamCorrections.count != before { saveCorrections() }
    }

    /// Teammates' corrections: kept, or let go when taken away. This member's own are its notes here.
    private func take(corrections rows: [TeamRow], gone: Set<UUID>) {
        let me = content.directory.me
        var list = teamCorrections.filter { !gone.contains($0.id) }
        for row in rows {
            guard let id = row.rowID else { continue }
            list.removeAll { $0.id == id }
            guard me == nil || row["created_by"]?.uuid != me else { continue }
            let author = content.directory.memberName(row["created_by"]?.uuid) ?? "A teammate"
            if let correction = TeamCorrection(row: row, author: author) { list.append(correction) }
        }
        teamCorrections = list.sorted { $0.date > $1.date }
        saveCorrections()
    }

    private func saveCorrections() {
        guard let url = folder?.appendingPathComponent("corrections.json") else { return }
        if let data = try? JSONEncoder().encode(teamCorrections) { try? data.write(to: url, options: .atomic) }
        knowledge?.correctionsChanged()
    }

    private static func read(_ folder: URL?) -> [TeamCorrection] {
        guard let url = folder?.appendingPathComponent("corrections.json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TeamCorrection].self, from: data)) ?? []
    }

    /// Teammates' corrections, wherever the knowledge index runs: the app's, kept as they come, or, in `Binders --mcp`,
    /// which runs no team database of its own, what the app last kept.
    static func corrections() -> [TeamCorrection] {
        if let current = TeamContent.current { return current.knowledge.teamCorrections }
        guard let server = TeamBoard.savedServer() else { return [] }
        return read(TeamDatabaseFiles.folder(for: server))
    }

    // MARK: For this Mac's index (KnowledgeSharing)

    /// Teammates' meetings and captures in the shared binders, written up: what the index might wait for.
    private func teamCopies() -> [MeetingRecord] {
        let shared = content.team.sharedBinders
        guard !shared.isEmpty else { return [] }
        let copies = (try? content.store.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate {
            $0.isTeamCopy && ($0.status == "ready" || $0.status == "failed")
        }))) ?? []
        return copies.filter { $0.binderID.map(shared.contains) == true }
    }

    static func document(_ record: MeetingRecord) -> String {
        "\(record.isConversation ? KnowledgeKind.conversation.rawValue : KnowledgeKind.meeting.rawValue):\(record.id.uuidString)"
    }

    /// Teammates' meetings and captures whose chunks here aren't the ones their maker published (not yet, or not since
    /// they changed), within the grace since this Mac first found them so: their vectors are still coming.
    func waitingDocuments() async -> Set<String> {
        guard let cache, let knowledge else { return [] }
        let unembedded = await knowledge.store.documentsNeedingEmbedding()
        var waiting = Set<String>()
        for copy in teamCopies() {
            let document = Self.document(copy)
            guard unembedded.contains(document) else { continue }
            let texts = await knowledge.store.passageTexts(of: document)
            guard !texts.isEmpty else { continue }
            let hash = TeamEmbedding.chunksHash(title: copy.title, texts: texts)
            if let published = await cache.published(source: document), published.hashes.contains(hash) {
                // Published for these chunks: its vectors are in the cache, or its maker had none and this Mac makes them.
                waitingSince[document] = nil
                continue
            }
            if stillWaiting(document) { waiting.insert(document) }
        }
        return waiting
    }

    /// The same for people and topics: teammates' items whose maker's haven't come for their chunks here.
    func waitingForEntities() async -> Set<String> {
        guard let cache, let knowledge else { return [] }
        let unread = Set(await teamDocumentsToRead())
        var waiting = Set<String>()
        for copy in teamCopies() {
            let document = Self.document(copy)
            guard unread.contains(document) else { continue }
            let texts = await knowledge.store.passageTexts(of: document)
            guard !texts.isEmpty else { continue }
            let key = "entities " + document
            if await cache.extraction(source: document, chunksHash: TeamEmbedding.chunksHash(title: copy.title, texts: texts)) != nil {
                waitingSince[key] = nil
                continue
            }
            if stillWaiting(key) { waiting.insert(document) }
        }
        return waiting
    }

    /// Whether something first found waiting at some point is still within the grace.
    private func stillWaiting(_ key: String) -> Bool {
        let now = Date()
        let since = waitingSince[key] ?? now
        waitingSince[key] = since
        return now.timeIntervalSince(since) < grace
    }

    func teamDocumentsToRead() async -> [String] {
        guard let knowledge else { return [] }
        let states = await knowledge.store.documentStates()
        return teamCopies().map(Self.document).filter { states[$0].map { !$0.extracted } == true }
    }

    func vectors(for chunks: [(id: Int64, text: String, title: String)], model: String) async -> [Int64: [Float]] {
        guard let cache, !chunks.isEmpty else { return [:] }
        let keys = chunks.map { TeamEmbedding.key(model: model, title: $0.title, text: $0.text) }
        let found = await cache.vectors(for: Set(keys))
        var vectors: [Int64: [Float]] = [:]
        for (chunk, key) in zip(chunks, keys) { if let vector = found[key] { vectors[chunk.id] = vector } }
        return vectors
    }

    func entities(for job: EntityJob) async -> ExtractionResult? {
        guard let cache else { return nil }
        return await cache.extraction(source: job.documentID, chunksHash: TeamEmbedding.chunksHash(title: job.title, texts: job.chunks.map(\.text)))
    }
}
