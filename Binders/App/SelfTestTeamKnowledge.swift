import Foundation
import SwiftData
import PostgresNIO
import BindersKit

/// Stand-ins for the knowledge self-test: an embedding model that remembers what it was given and puts each passage on
/// the axes of its words, and a model that remembers what it was asked and always says the same.
final class RecordingEmbedder: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [String] = []
    let model: String
    let dimension: Int

    init(model: String, dimension: Int) {
        self.model = model
        self.dimension = dimension
    }

    var embedded: [String] { lock.withLock { inputs } }
    func forget() { lock.withLock { inputs = [] } }

    func embed(_ texts: [String]) -> [[Float]] {
        lock.withLock { inputs += texts }
        return texts.map { Self.vector($0, dimension: dimension) }
    }

    /// Each word of three letters or more on an axis of its own (FNV-1a of the word), so passages that share words point
    /// the same way.
    static func vector(_ text: String, dimension: Int = 768) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where word.count > 2 {
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in word.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            vector[Int(hash % UInt64(dimension))] += 1
        }
        if vector.allSatisfy({ $0 == 0 }) { vector[0] = 1 }
        return vector
    }
}

final class RecordingModel: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []
    let reply: String
    var model: String { "stand-in" }

    init(reply: String) {
        self.reply = reply
    }

    var asked: [String] { lock.withLock { prompts } }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        lock.withLock { prompts.append(user) }
        return reply
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout)
    }

    func listModels() async throws -> [String] { [model] }
    func warmUp() async {}
}

extension SelfTest {
    // MARK: Knowledge

    @MainActor
    static func teamKnowledgeChecks(_ bed: TeamDBTestBed) async throws {
        AppSettings.shared.noteDigests = false
        AppSettings.shared.knowledgeGraph = true
        let mac = try await TeamMac.start(bed)
        let content = mac.team.content
        content.editDelay = .milliseconds(150)
        let knowledge = mac.controller.knowledge
        let embedder = RecordingEmbedder(model: "mlx-community/embeddinggemma-300m-4bit", dimension: 768)
        knowledge.documentEmbedder = (embedder.model, { texts in embedder.embed(texts) })
        knowledge.queryEmbedder = { text in RecordingEmbedder.vector(text) }
        let finder = RecordingModel(reply: #"{"entities":[{"name":"Robin","type":"person"},{"name":"Hall B","type":"place"}],"relations":[{"from":"Robin","to":"Hall B","label":"books"}]}"#)
        knowledge.entityModel = finder
        let alex = try await bed.teammate()
        let root = try await bed.root()
        let store = Store.shared
        _ = await bed.eventually(10) { content.knowledge.pin != nil }
        bed.check(content.knowledge.pin?.model == "embeddinggemma" && content.knowledge.pin?.dimension == 768, "this Mac knows the team's pin: embeddinggemma, 768")
        bed.check(content.knowledge.line?.contains("go to the team") == true,
                  "MLX's EmbeddingGemma counts as the team's: \(content.knowledge.line ?? "-")")

        // MARK: This Mac's meeting: indexed here, published once as the team will index it.
        let meeting = MeetingRecord(title: "Booth review", appName: "Zoom", templateID: "general")
        meeting.binderID = bed.shared
        meeting.status = "ready"
        meeting.summary = "Robin books Hall B for the booth, stand 12."
        meeting.speakerNames = ["Speaker 1": "Robin"]
        store.insert(meeting)
        store.replaceSegments(for: meeting.id, with: [
            TranscriptSegment(channel: .microphone, start: 0, end: 3, text: "Can we get the stand near the café?", speaker: "You"),
            TranscriptSegment(channel: .system, start: 4, end: 7, text: "I booked Hall B, stand 12, near the café.", speaker: "Speaker 1"),
            TranscriptSegment(channel: .microphone, start: 30, end: 33, text: "Great, I'll order the banners.", speaker: "You")])
        _ = await bed.eventually(5) { content.state.meetings[meeting.id]?.digest != nil }
        _ = await mac.drained()
        await knowledge.indexNow()
        let document = "meeting:\(meeting.id.uuidString)"
        let published = await bed.until(10) {
            ((try? await alex.rows(.knowledgeChunks, binder: bed.shared)) ?? []).contains { $0["source_id"]?.uuid == meeting.id }
        }
        let chunks = try await alex.rows(.knowledgeChunks, binder: bed.shared).filter { $0["source_id"]?.uuid == meeting.id }
            .sorted { ($0["chunk_index"]?.int ?? 0) < ($1["chunk_index"]?.int ?? 0) }
        let view = TeamKnowledge.teamView(of: meeting, maker: "Sam")
        bed.check(published && chunks.map { $0["text"]?.string ?? "" } == view?.chunks.map(\.text),
                  "its chunks reach the team as a teammate's Mac will index them (\(chunks.count))")
        bed.check(chunks.contains { ($0["text"]?.string ?? "").contains("Sam:") } && !chunks.contains { ($0["text"]?.string ?? "").contains("You:") },
                  "in them, your \"You\" is Sam")
        bed.check(chunks.allSatisfy { $0["embedding_model"]?.string == "embeddinggemma" && TeamEmbedding.vector($0["embedding"])?.count == 768
                                      && $0["title"]?.string == "Booth review" && !($0["chunks_hash"]?.string ?? "").isEmpty },
                  "each with its vector (EmbeddingGemma's 768 numbers), the title it was made with and the item's hash")
        let local = await knowledge.store.passages(of: document)
        let summary = chunks.first { ($0["text"]?.string ?? "").contains("Robin books Hall B") }
        let localSummary = local.first { $0.text.contains("Robin books Hall B") }?.vector
        let sameVector = zip(TeamEmbedding.vector(summary?["embedding"]) ?? [], localSummary ?? []).allSatisfy { abs($0 - $1) < 0.0001 }
        bed.check(sameVector && localSummary != nil, "a passage the same as this Mac's own goes with this Mac's vector")
        bed.check(content.knowledge.embeddedForTeam > 0 && content.knowledge.embeddedForTeam < chunks.count,
                  "only the passages that read differently for the team were embedded again: \(content.knowledge.embeddedForTeam) of \(chunks.count)")
        let entities = try await alex.rows(.entities, binder: bed.shared).filter { $0["source_id"]?.uuid == meeting.id }
        let relations = try await alex.rows(.relations, binder: bed.shared).filter { $0["source_id"]?.uuid == meeting.id }
        bed.check(Set(entities.compactMap { $0["name"]?.string }) == ["Robin", "Hall B"] && relations.count == 1
                  && relations.first?["predicate"]?.string == "books", "with its people and topics and how they relate")
        let print = await content.knowledge.cache?.published(document)
        await knowledge.indexNow()
        let again = await content.knowledge.cache?.published(document)
        bed.check(print != nil && print == again && content.knowledge.publishedItems == 1, "indexed again unchanged: nothing sent again")

        // MARK: A note of this Mac's from the team folder days, which carries this member's own name there (lane DB6).
        let fromFolder = NoteItem(text: "# Stand checklist\n\nThe stand needs two chairs and a lamp.")
        fromFolder.binderID = bed.shared
        fromFolder.teamAuthorID = "folder-sam"
        fromFolder.teamAuthorName = "Sam"
        store.insert(fromFolder)
        _ = await bed.eventually(10) { mac.team.notes.shares(fromFolder.id) }
        _ = await mac.drained()
        await knowledge.indexNow()
        let folderNote = await bed.until(10) {
            ((try? await alex.rows(.knowledgeChunks, binder: bed.shared)) ?? []).contains { $0["source_id"]?.uuid == fromFolder.id }
        }
        bed.check(folderNote, "a note of yours from the team folder days, with your name on it there, reaches the team's knowledge too")

        // MARK: RLS: an item in a binder that isn't shared with the teammate stays out of their reads and SQL.
        let privateMeeting = MeetingRecord(title: "Salary review", appName: "Zoom", templateID: "general")
        privateMeeting.binderID = bed.personal
        privateMeeting.status = "ready"
        privateMeeting.summary = "The raise for the booth crew is confidential."
        store.insert(privateMeeting)
        _ = await bed.eventually(5) { content.state.meetings[privateMeeting.id]?.fingerprint.isEmpty == false }
        _ = await mac.drained()
        await knowledge.indexNow()
        let inDatabase = await bed.until(10) {
            ((try? await root.value("SELECT count(*) FROM binders.knowledge_chunks WHERE source_id = $1",
                                    [privateMeeting.id.uuidString.lowercased()], as: Int64.self)) ?? 0) > 0
        }
        let alexReads = try await alex.rows(.knowledgeChunks, binder: bed.personal)
        let alexLink = try await bed.link(bed.alex)
        let alexSQL = try await alexLink.value("SELECT count(*) FROM binders.knowledge_chunks WHERE text LIKE '%confidential%'", as: Int64.self) ?? -1
        let alexSearch = try await alexLink.json("SELECT binders.search_knowledge('confidential')::text").array ?? []
        bed.check(inDatabase && alexReads.isEmpty && alexSQL == 0 && alexSearch.isEmpty,
                  "a meeting in a binder not shared with Alex: its chunks are in the database, and Alex's reads, SQL and search see none")

        // MARK: Alex's meeting reaches this Mac with its index: taken without embedding it again; search finds it.
        let theirs = UUID()
        let theirLines = [TranscriptSegment(channel: .microphone, start: 0, end: 4, text: "The printer said the banners arrive on Monday.", speaker: "You"),
                          TranscriptSegment(channel: .system, start: 5, end: 9, text: "Then we hang them on Tuesday morning.", speaker: "Speaker 1")]
        _ = try await alex.call(.putItem(TeamMeetingValues(id: theirs, binder: bed.shared, title: "Banner logistics", started: Date(), duration: 9,
                                                           summary: "The banners arrive on Monday; Robin hangs them on Tuesday.",
                                                           speakerNames: ["Speaker 1": "Robin"], status: "ready").row(capture: false), in: .meetings))
        _ = try await alex.call(.put(rows: TeamTranscript.rows(theirLines, item: theirs, binder: bed.shared, revision: 0, after: 0, capture: false),
                                     in: .meetingSegments))
        _ = await bed.eventually(5) { store.segments(for: theirs).count == 2 }
        guard let copy = content.meeting(theirs), let theirView = KnowledgeService.document(for: copy, segments: store.segments(for: theirs)) else {
            return bed.check(false, "Alex's meeting is here")
        }
        // As Alex's Mac publishes it: its team view, with vectors from the same model in another precision (Ollama's).
        let theirItem = TeamKnowledgeItem(binder: bed.shared, kind: "meeting", source: theirs, title: theirView.0.title,
                                          chunks: theirView.1.map { .init(text: $0.text, startTime: $0.startTime, speaker: $0.speaker,
                                                                         vector: RecordingEmbedder.vector(TeamEmbedding.input(title: theirView.0.title, text: $0.text))) },
                                          model: "embeddinggemma", entities: [ExtractedEntity(name: "Robin", type: "person"),
                                                                              ExtractedEntity(name: "Banner printer", type: "company")],
                                          relations: [ExtractedRelation(from: "Robin", to: "Banner printer", label: "works with")])
        embedder.forget()
        let findsBefore = finder.asked.count
        let sent = try await alex.call(.replaceKnowledge(theirItem))
        bed.check(sent.ok, "Alex's Mac publishes its meeting's index: \(sent.refusal?.message ?? "taken")")
        _ = await bed.until(5) { await content.knowledge.cache?.vectorCount() ?? 0 >= theirItem.chunks.count }
        await knowledge.indexNow()
        let theirDocument = "meeting:\(theirs.uuidString)"
        let taken = await knowledge.store.passages(of: theirDocument)
        let embeddedHere = embedder.embedded.filter { input in theirItem.chunks.contains { input.hasSuffix($0.text) } }
        bed.check(!taken.isEmpty && taken.allSatisfy { $0.vector != nil } && embeddedHere.isEmpty,
                  "this Mac's index has every passage of Alex's meeting with a vector, none embedded here (\(taken.count) passages)")
        let found = await knowledge.store.extraction(of: theirDocument)
        bed.check(Set(found?.entities.map(\.name) ?? []) == ["Robin", "Banner printer"] && finder.asked.count == findsBefore,
                  "and its people and topics, taken as Alex's Mac found them, the model not asked")
        let query = TeamEmbedding.input(title: theirView.0.title, text: theirView.1[0].text)
        let byMeaning = await knowledge.store.semanticSearch(RecordingEmbedder.vector(query), limit: 3, minScore: 0.9, kinds: nil)
        bed.check(byMeaning.first?.sourceID == theirs.uuidString && byMeaning.first?.author == "Alex",
                  "search by meaning finds Alex's passage here, Alex's (\(byMeaning.first.map { String(format: "%.3f", $0.score) } ?? "none"))")
        let hits = await knowledge.search("banners Monday printer")
        bed.check(hits.contains { $0.sourceID == theirs.uuidString && $0.author == "Alex" }, "and search finds it by its words too")

        // MARK: An item whose maker's index hasn't come waits a while, then this Mac makes its own.
        let late = UUID()
        _ = try await alex.call(.putItem(TeamMeetingValues(id: late, binder: bed.shared, title: "Catering call", started: Date(),
                                                           summary: "Sandwiches for forty on day one.", status: "ready").row(capture: false), in: .meetings))
        _ = await bed.eventually(5) { content.meeting(late) != nil }
        embedder.forget()
        await knowledge.indexNow()
        let lateDocument = "meeting:\(late.uuidString)"
        let waited = await knowledge.store.passages(of: lateDocument)
        bed.check(!waited.isEmpty && waited.allSatisfy { $0.vector == nil } && !embedder.embedded.contains { $0.contains("Sandwiches") },
                  "a teammate's meeting whose index hasn't come yet isn't embedded here at once")
        content.knowledge.grace = 0
        await knowledge.indexNow()
        let made = await knowledge.store.passages(of: lateDocument)
        bed.check(made.allSatisfy { $0.vector != nil } && embedder.embedded.contains { $0.contains("Sandwiches") },
                  "after the wait, this Mac makes its own")
        content.knowledge.grace = 600

        // MARK: Corrections.
        try await correctionChecks(bed, mac: mac, alex: alex, banner: theirs)

        // MARK: SQL for a headless agent.
        let sql = try await alexLink.json(TeamKnowledge.headlessExample, ["banners"])
        bed.check((sql.array ?? []).contains { ($0["item"]?.string ?? "") == "Banner logistics" }, "the SQL example for headless agents finds it: \(sql.text.prefix(120))")

        // MARK: A new pin: every Mac says so and sends its items again; this one without vectors until it embeds with it.
        let repinned = try await alexLink.call(.pinEmbeddingModel(TeamEmbeddingPin(model: "test-embedder", dimension: 4)))
        bed.check(repinned.ok, "an admin pins another model")
        let noticed = await bed.eventually(10) { content.knowledge.pin?.epoch == 2 }
        bed.check(noticed && content.knowledge.line?.contains("test-embedder") == true, "this Mac notices and says so: \(content.knowledge.line ?? "-")")
        await knowledge.indexNow()
        let republished = await bed.until(10) {
            let rows = (try? await alex.rows(.knowledgeChunks, binder: bed.shared))?.filter { $0["source_id"]?.uuid == meeting.id } ?? []
            return !rows.isEmpty && rows.allSatisfy { $0["embedding"]?.isNull != false }
        }
        bed.check(republished, "published again without vectors, as this Mac doesn't embed with the new model")
        let fourDims = RecordingEmbedder(model: "test-embedder", dimension: 4)
        knowledge.documentEmbedder = (fourDims.model, { texts in fourDims.embed(texts) })
        await knowledge.indexNow()
        let withNew = await bed.until(10) {
            let rows = (try? await alex.rows(.knowledgeChunks, binder: bed.shared))?.filter { $0["source_id"]?.uuid == meeting.id } ?? []
            return !rows.isEmpty && rows.allSatisfy { TeamEmbedding.vector($0["embedding"])?.count == 4 && $0["embedding_model"]?.string == "test-embedder" }
        }
        bed.check(withNew && !fourDims.embedded.isEmpty, "choosing the new model here: this Mac embeds again and sends its vectors with it")
        await mac.stop()
    }

    /// A teammate's correction steers answers drawn from its binder, named; an agent's counts for nothing; and this Mac's
    /// own corrections in a shared binder go to the team.
    @MainActor
    private static func correctionChecks(_ bed: TeamDBTestBed, mac: TeamMac, alex: TeamDatabase, banner: UUID) async throws {
        let knowledge = mac.controller.knowledge
        let store = Store.shared
        let wrong = "the banners arrive on Monday"
        let correction = KnowledgeCorrection(wrong: wrong, right: "the banners arrive on Wednesday", reason: "The printer moved it.")
        let note = UUID()
        _ = try await alex.call(.put(["id": TeamJSON(UUID()), "binder_id": TeamJSON(bed.shared), "source_kind": "note",
                                      "source_id": .string(note.uuidString.lowercased()), "text": .string(correction.markdown)], in: .corrections))
        let agents = KnowledgeCorrection(wrong: "robin hangs them on tuesday", right: "nobody hangs them")
        _ = try await alex.call(.put(["id": TeamJSON(UUID()), "binder_id": TeamJSON(bed.shared), "source_kind": "note",
                                      "source_id": .string(UUID().uuidString.lowercased()), "text": .string(agents.markdown)],
                                     in: .corrections, agent: bed.agentC))
        let arrived = await bed.eventually(5) { mac.team.content.knowledge.teamCorrections.count == 2 }
        bed.check(arrived, "Alex's corrections reach this Mac")
        // A passage in a binder of this Mac's own says the same wrong thing: a teammate's correction doesn't reach it.
        let own = BinderRecord(name: "Own notes", colorIndex: 6)
        store.insert(own)
        let mine = NoteItem(text: "# Supplier notes\n\nI heard the banners arrive on Monday, from someone else.")
        mine.binderID = own.id
        store.insert(mine)
        await knowledge.indexNow()
        let all = knowledge.corrections()
        let theirs = all.first { $0.correction.wrong == wrong }
        bed.check(theirs?.author == "Alex" && theirs?.scoped == true && !all.contains { $0.correction.right == "nobody hangs them" },
                  "a teammate's correction counts, named and kept to its binder; one their agent wrote doesn't")
        let hits = await knowledge.search("banners arrive Monday")
        let inShared = hits.first { $0.sourceID == banner.uuidString }
        let inOwn = hits.first { $0.sourceID == mine.id.uuidString }
        bed.check(inShared.flatMap { knowledge.correction(for: $0, in: all) }?.author == "Alex", "it marks the passage from its binder")
        bed.check(inOwn != nil && inOwn.flatMap { knowledge.correction(for: $0, in: all) } == nil, "and not the same words in a binder of your own")
        let answers = RecordingModel(reply: "On Wednesday [1].")
        knowledge.answerModel = answers
        _ = await knowledge.ask("When do the banners arrive?")
        let prompt = answers.asked.last ?? ""
        bed.check(prompt.contains("CORRECTION by Alex") && prompt.contains("Right: the banners arrive on Wednesday"),
                  "Ask answers from Alex's correction, named")
        bed.check(!prompt.contains("nobody hangs them"), "and never from their agent's")
        let searched = TeamMac.list((await mac.mcp("search_knowledge", ["query": "banners arrive Monday"], as: BoardActor(name: "Claude Code", kind: .agent))).text)
        bed.check((searched.first { $0["source_id"] as? String == banner.uuidString }?["corrected"] as? [String: Any])?["by"] as? String == "Alex",
                  "search_knowledge marks it corrected, by Alex")
        let mcpSearch = TeamMac.list((try? await MCPServer.call("search_knowledge", ["query": "banners arrive Monday"], knowledge: knowledge,
                                                                write: MCPServer.writeInApp(controller: mac.controller),
                                                                actor: BoardActor(name: "Claude Code", kind: .agent),
                                                                reads: MCPServer.Reads(captures: false, transcripts: false, team: false),
                                                                host: "Claude Code")) ?? "[]")
        bed.check(mcpSearch.contains { $0["source_id"] as? String == mine.id.uuidString } && !mcpSearch.contains { ($0["author"] as? String) == "Alex" },
                  "search_knowledge, for a tool that may not read teammates' items: your passage, none of Alex's")
        // The iPhone is you: it reads what this Mac shows, Alex's passage and correction included.
        let phone = TeamMac.list((try? await MCPServer.call("search_knowledge", ["query": "banners arrive Monday"], knowledge: knowledge,
                                                             write: MCPServer.writeInApp(controller: mac.controller), actor: .you)) ?? "[]")
        bed.check((phone.first { $0["source_id"] as? String == banner.uuidString }?["corrected"] as? [String: Any])?["by"] as? String == "Alex",
                  "the iPhone, through this Mac, finds Alex's passage, corrected by Alex")
        let mcpAnswers = RecordingModel(reply: "Monday.")
        knowledge.answerModel = mcpAnswers
        _ = try? await MCPServer.call("ask_knowledge", ["question": "When do the banners arrive?"], knowledge: knowledge,
                                      write: MCPServer.writeInApp(controller: mac.controller), actor: BoardActor(name: "Claude Code", kind: .agent),
                                      reads: MCPServer.Reads(captures: false, transcripts: false, team: false), host: "Claude Code")
        bed.check(!(mcpAnswers.asked.last ?? "").contains("CORRECTION by Alex") && !(mcpAnswers.asked.last ?? "").contains("Banner logistics"),
                  "for a tool that may not read teammates' items: neither Alex's meeting nor Alex's correction")
        // This Mac's own correction in the shared binder goes to the team; one an agent wrote here doesn't.
        let fix = NoteItem(text: KnowledgeCorrection(wrong: "the stand is number 14", right: "the stand is number 12").markdown)
        fix.binderID = bed.shared
        store.insert(fix)
        let agentsFix = NoteItem(text: KnowledgeCorrection(wrong: "the café opens at nine", right: "the café opens at ten").markdown)
        agentsFix.binderID = bed.shared
        agentsFix.madeBy = "Claude Code"
        store.insert(agentsFix)
        await knowledge.indexNow()
        let sent = await bed.until(10) {
            ((try? await alex.rows(.corrections, binder: bed.shared)) ?? []).contains { $0["source_id"]?.uuid == fix.id }
        }
        let rows = try await alex.rows(.corrections, binder: bed.shared)
        bed.check(sent && rows.first { $0["source_id"]?.uuid == fix.id }?["created_by"]?.uuid == bed.samID,
                  "your correction in the shared binder reaches the team, as yours")
        bed.check(!rows.contains { $0["source_id"]?.uuid == agentsFix.id }, "one an agent wrote doesn't")
    }
}

extension TeamKnowledge {
    /// The SQL a headless agent runs to search the team's knowledge by its words, with the item each passage is from
    /// (LANE-NOTES has it for the founder); $1 is the query.
    static let headlessExample = """
        SELECT coalesce(json_agg(hit), '[]')::text FROM (
          SELECT k.text, coalesce(m.title, c.title, k.title) AS item, k.source_kind AS kind, b.name AS binder,
                 ts_rank(k.tsv, websearch_to_tsquery('simple', $1)) AS score
          FROM binders.knowledge_chunks k
          JOIN binders.binders b ON b.id = k.binder_id
          LEFT JOIN binders.meetings m ON k.source_kind = 'meeting' AND m.id::text = k.source_id
          LEFT JOIN binders.captures c ON k.source_kind = 'conversation' AND c.id::text = k.source_id
          WHERE k.deleted_at IS NULL AND k.tsv @@ websearch_to_tsquery('simple', $1)
          ORDER BY score DESC LIMIT 10) hit
        """
}
