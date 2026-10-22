import Foundation
import BindersKit

extension SelfTest {
    /// The knowledge vectors: the column takes the pinned model's dimension (EmbeddingGemma's 768), takes only that
    /// model's vectors of that length, finds the nearest by meaning within what a member may see, and a new pin empties
    /// them, retypes the column and tells every Mac.
    @MainActor
    static func teamDatabaseVectorChecks(_ bed: TeamDBTestBed) async throws {
        let check = bed.check
        let root = try await bed.root()
        let samLink = try await bed.link(bed.sam)
        let alexLink = try await bed.link(bed.alex)
        let pin = TeamEmbeddingPin.default

        let column = try await root.json("""
            SELECT json_build_object('type', format_type(a.atttypid, a.atttypmod),
                'index', (SELECT indexdef FROM pg_indexes WHERE schemaname = 'binders' AND indexname = 'knowledge_chunks_embedding'),
                'team', (SELECT to_jsonb(t) FROM binders.team_settings t))::text
            FROM pg_attribute a WHERE a.attrelid = 'binders.knowledge_chunks'::regclass AND a.attname = 'embedding'
            """)
        check(column["type"]?.string == "vector(\(pin.dimension))", "the vector column has the pinned dimension: \(column["type"]?.string ?? "none")")
        check(column["index"]?.string?.contains("hnsw") == true && column["index"]?.string?.contains("vector_cosine_ops") == true,
              "with an HNSW index by cosine distance")
        check(column["team"]?["embedding_model"]?.string == pin.model && column["team"]?["embedding_dimension"]?.int == pin.dimension
                && column["team"]?["embedding_epoch"]?.int == 1, "the team pinned \(pin.model), \(pin.dimension) numbers, epoch 1")

        // Three chunks of a note in the shared binder, and one in Sam's own, each pointing a different way.
        func vector(_ axis: Int, of dimension: Int = 768) -> TeamJSON {
            .array((0..<dimension).map { .number($0 == axis ? 1 : ($0 == (axis + 1) % dimension ? 0.1 : 0)) })
        }
        let note = UUID(), mine = UUID()
        let chunks: [TeamRow] = (0..<3).map { index in
            ["id": TeamJSON(UUID()), "chunk_index": .number(Double(index)), "text": ["the auth flow uses passkeys", "deploys run on Fridays",
                                                                                     "the booth is in the north hall"][index],
             "embedding": vector(index * 10), "embedding_model": .string(pin.model)]
        }
        let replaced = try await samLink.call(.replace(chunks, in: .knowledgeChunks, binder: bed.shared, sourceKind: "note", sourceID: note.uuidString))
        check(replaced.ok && replaced.body["kept"]?.int == 3, "a Mac writes an item's chunks with their vectors")
        try await bed.expectOK(samLink, .replace([["id": TeamJSON(UUID()), "text": "my own plan", "embedding": vector(20),
                                                   "embedding_model": .string(pin.model)]],
                                                 in: .knowledgeChunks, binder: bed.personal, sourceKind: "note", sourceID: mine.uuidString))
        let short = try await samLink.call(.put(["id": TeamJSON(UUID()), "binder_id": TeamJSON(bed.shared), "source_kind": "note",
                                                 "source_id": .string(note.uuidString), "text": "short", "embedding": [1, 2, 3],
                                                 "embedding_model": .string(pin.model)], in: .knowledgeChunks))
        check(short.refusal?.code == "embedding_dimension", "a vector of another length is refused: \(short.refusal?.message ?? "taken")")
        let otherModel = try await samLink.call(.put(["id": TeamJSON(UUID()), "binder_id": TeamJSON(bed.shared), "source_kind": "note",
                                                      "source_id": .string(note.uuidString), "text": "other", "embedding": vector(1),
                                                      "embedding_model": "another-embedder"], in: .knowledgeChunks))
        check(otherModel.refusal?.code == "embedding_model", "and one from another model: \(otherModel.refusal?.message ?? "taken")")

        // By meaning, as Alex: the chunk pointing the query's way, and nothing from Sam's own binder.
        let near = try await alexLink.json("SELECT binders.search_knowledge(NULL, $1::jsonb)::text", [vector(10).text]).array ?? []
        check(near.first?["text"]?.string == "deploys run on Fridays" && (near.first?["score"]?.double ?? 0) > 0.99,
              "the nearest chunk by meaning is the one pointing the same way (\(near.first?["score"]?.double ?? 0))")
        check(!near.contains { $0["text"]?.string == "my own plan" } && near.count == 3, "and a member finds none from a binder not shared with them")
        let words = try await alexLink.json("SELECT binders.search_knowledge('passkeys')::text").array ?? []
        check(words.first?["text"]?.string == "the auth flow uses passkeys", "by words, through the tsvector")
        let direct = try await alexLink.value("""
            SELECT text FROM binders.knowledge_chunks ORDER BY embedding <=> $1::text::vector LIMIT 1
            """, [vector(20).text], as: String.self)
        check(direct != "my own plan", "a headless agent's own SQL meets the same row-level security")

        // Re-embedding again replaces an item's chunks: those not sent again are deleted.
        let again = try await samLink.call(.replace(Array(chunks.prefix(1)), in: .knowledgeChunks, binder: bed.shared, sourceKind: "note",
                                                    sourceID: note.uuidString))
        check(again.body["kept"]?.int == 1 && again.body["deleted"]?.int == 2, "an item indexed again keeps its new chunks and deletes the rest")

        // A new pin: an admin (every person is one) chooses another model; the vectors go, the column takes its length,
        // and every Mac hears of it from the feed.
        let samClient = bed.client(bed.sam)
        try await bed.waitConnected(samClient)
        var updates: [TeamUpdate] = []
        let collector = Task { @MainActor in
            for await update in samClient.updates {
                updates.append(update)
                samClient.acknowledge(update)
            }
        }
        defer { collector.cancel() }
        let repinned = try await alexLink.call(.pinEmbeddingModel(TeamEmbeddingPin(model: "test-embedder", dimension: 4)))
        check(repinned.ok && repinned.body["epoch"]?.int == 2, "an admin pins another model, and the epoch grows")
        let heard = await bed.eventually(5) { updates.contains { $0.changes.contains { $0.table == .teamSettings } } }
        let settings = updates.lazy.compactMap { $0.rows[.teamSettings]?.first }.first
        check(heard && settings?["embedding_model"]?.string == "test-embedder" && settings?["embedding_dimension"]?.int == 4,
              "every Mac hears of the new pin through the feed")
        let after = try await root.json("""
            SELECT json_build_object('type', (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
                                              WHERE attrelid = 'binders.knowledge_chunks'::regclass AND attname = 'embedding'),
                                     'vectors', (SELECT count(*) FROM binders.knowledge_chunks WHERE embedding IS NOT NULL),
                                     'chunks', (SELECT count(*) FROM binders.knowledge_chunks WHERE deleted_at IS NULL))::text
            """)
        check(after["type"]?.string == "vector(4)" && after["vectors"]?.int == 0 && (after["chunks"]?.int ?? 0) > 0,
              "the column takes 4 numbers now, the old vectors are gone and the chunks stay, for their text")
        let four = try await samLink.call(.put(["id": TeamJSON(UUID()), "binder_id": TeamJSON(bed.shared), "source_kind": "note",
                                                "source_id": .string(note.uuidString), "text": "four", "embedding": [0.5, 0.5, 0.5, 0.5],
                                                "embedding_model": "test-embedder"], in: .knowledgeChunks))
        check(four.ok, "the new model's vectors go in")
        let old = try await samLink.call(.put(["id": TeamJSON(UUID()), "binder_id": TeamJSON(bed.shared), "source_kind": "note",
                                               "source_id": .string(note.uuidString), "text": "old", "embedding": vector(1),
                                               "embedding_model": .string(pin.model)], in: .knowledgeChunks))
        check(old.refusal != nil, "and the old one's don't")
        await samClient.stop()
    }
}
