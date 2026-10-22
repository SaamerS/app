import Foundation
import SQLite3
import BindersKit

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// What teammates' Macs made of the items they shared (lane DB4), kept beside the outbox (`knowledge.sqlite`) as the feed
/// brings it: each chunk's vector under the key of exactly what its model read, the people and topics found in each item
/// and how they relate, with the hash of the chunks they were made for. This Mac's knowledge index takes from it instead
/// of embedding and reading those items again. Also what this Mac published of its own items, so a pass sends only what
/// changed.
actor TeamKnowledgeCache {
    private let db: OpaquePointer?

    init(url: URL) {
        var handle: OpaquePointer?
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open(url.path, &handle) != SQLITE_OK {
            Log.app.error("Couldn't open the team's knowledge at \(url.path, privacy: .public)")
            handle = nil
        }
        db = handle
        sqlite3_exec(handle, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS chunks(row_id TEXT PRIMARY KEY, binder TEXT NOT NULL, source TEXT NOT NULL, chunks_hash TEXT NOT NULL,
                                              key TEXT, vector BLOB);
            CREATE INDEX IF NOT EXISTS chunks_key ON chunks(key);
            CREATE INDEX IF NOT EXISTS chunks_source ON chunks(source);
            CREATE TABLE IF NOT EXISTS entities(row_id TEXT PRIMARY KEY, binder TEXT NOT NULL, source TEXT NOT NULL, chunks_hash TEXT NOT NULL,
                                                name TEXT NOT NULL, kind TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS entities_source ON entities(source);
            CREATE TABLE IF NOT EXISTS relations(row_id TEXT PRIMARY KEY, binder TEXT NOT NULL, source TEXT NOT NULL, chunks_hash TEXT NOT NULL,
                                                 subject TEXT NOT NULL, predicate TEXT NOT NULL, object TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS relations_source ON relations(source);
            CREATE TABLE IF NOT EXISTS published(document TEXT PRIMARY KEY, binder TEXT NOT NULL, print TEXT NOT NULL, marker TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            """, nil, nil, nil)
    }

    /// A knowledge row's item as this Mac's index names it: "meeting:<ID>", "conversation:<ID>", "note:<ID>".
    static func document(kind: String?, source: String?) -> String? {
        guard let kind, let id = source.flatMap(UUID.init(uuidString:)) else { return nil }
        return "\(kind):\(id.uuidString)"
    }

    // MARK: From the feed

    /// Rows of one knowledge table as they are now: kept, or let go when taken away. `mine`: this member's own, which this
    /// Mac's index already has.
    func take(_ rows: [TeamRow], table: TeamTable, me: UUID?) {
        guard !rows.isEmpty else { return }
        run("BEGIN")
        for row in rows {
            guard let id = row.rowID?.uuidString.lowercased() else { continue }
            remove(rowID: id, table: table)
            guard row.deletedAt == nil, me == nil || row["created_by"]?.uuid != me,
                  let binder = row["binder_id"]?.uuid?.uuidString.lowercased(),
                  let source = Self.document(kind: row["source_kind"]?.string, source: row["source_id"]?.string) else { continue }
            let hash = row["chunks_hash"]?.string ?? ""
            switch table {
            case .knowledgeChunks:
                let vector = TeamEmbedding.vector(row["embedding"])
                let model = row["embedding_model"]?.string
                let key = vector != nil && model != nil
                    ? TeamEmbedding.key(model: model ?? "", title: row["title"]?.string ?? "", text: row["text"]?.string ?? "") : nil
                let blob = vector.map { VectorMath.normalized($0).withUnsafeBufferPointer { Data(buffer: $0) } }
                run("INSERT OR REPLACE INTO chunks(row_id, binder, source, chunks_hash, key, vector) VALUES(?,?,?,?,?,?)",
                    [id, binder, source, hash, key, blob])
            case .entities:
                run("INSERT OR REPLACE INTO entities(row_id, binder, source, chunks_hash, name, kind) VALUES(?,?,?,?,?,?)",
                    [id, binder, source, hash, row["name"]?.string ?? "", row["kind"]?.string ?? ""])
            case .relations:
                run("INSERT OR REPLACE INTO relations(row_id, binder, source, chunks_hash, subject, predicate, object) VALUES(?,?,?,?,?,?,?)",
                    [id, binder, source, hash, row["subject"]?.string ?? "", row["predicate"]?.string ?? "", row["object"]?.string ?? ""])
            default:
                continue
            }
        }
        run("COMMIT")
    }

    /// Rows gone for good, or no longer in a binder this member sees.
    func remove(_ ids: [UUID], table: TeamTable) {
        guard !ids.isEmpty else { return }
        run("BEGIN")
        for id in ids { remove(rowID: id.uuidString.lowercased(), table: table) }
        run("COMMIT")
    }

    private func remove(rowID: String, table: TeamTable) {
        switch table {
        case .knowledgeChunks: run("DELETE FROM chunks WHERE row_id = ?", [rowID])
        case .entities: run("DELETE FROM entities WHERE row_id = ?", [rowID])
        case .relations: run("DELETE FROM relations WHERE row_id = ?", [rowID])
        default: break
        }
    }

    /// Everything of a binder: for a binder the team lost, or one read whole.
    func forget(binder: UUID) {
        let key = binder.uuidString.lowercased()
        run("BEGIN")
        for table in ["chunks", "entities", "relations"] { run("DELETE FROM \(table) WHERE binder = ?", [key]) }
        run("COMMIT")
    }

    // MARK: For this Mac's index

    /// Vectors kept under these keys.
    func vectors(for keys: Set<String>) -> [String: [Float]] {
        guard !keys.isEmpty else { return [:] }
        var found: [String: [Float]] = [:]
        let list = Array(keys)
        for start in stride(from: 0, to: list.count, by: 200) {
            let part = Array(list[start..<min(start + 200, list.count)])
            let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
            select("SELECT key, vector FROM chunks WHERE vector IS NOT NULL AND key IN (\(marks))", part.map { $0 as Any? }) { row in
                guard let key = Self.text(row, 0), found[key] == nil else { return }
                let count = Int(sqlite3_column_bytes(row, 1)) / MemoryLayout<Float>.size
                guard count > 0, let bytes = sqlite3_column_blob(row, 1) else { return }
                var values = [Float](repeating: 0, count: count)
                values.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, bytes, count * MemoryLayout<Float>.size) }
                found[key] = values
            }
        }
        return found
    }

    /// The hashes of the chunks the team has for an item, and whether any of them has a vector.
    func published(source: String) -> (hashes: Set<String>, vectors: Bool)? {
        var hashes = Set<String>()
        var vectors = false
        select("SELECT chunks_hash, vector IS NOT NULL FROM chunks WHERE source = ?", [source]) { row in
            hashes.insert(Self.text(row, 0) ?? "")
            if sqlite3_column_int(row, 1) != 0 { vectors = true }
        }
        return hashes.isEmpty ? nil : (hashes, vectors)
    }

    /// The people and topics the team found in an item for exactly these chunks, and how they relate; nil when it has
    /// none for them.
    func extraction(source: String, chunksHash: String) -> ExtractionResult? {
        var entities: [ExtractedEntity] = []
        select("SELECT name, kind FROM entities WHERE source = ? AND chunks_hash = ? ORDER BY name", [source, chunksHash]) { row in
            entities.append(ExtractedEntity(name: Self.text(row, 0) ?? "", type: Self.text(row, 1) ?? "topic"))
        }
        guard !entities.isEmpty else { return nil }
        var relations: [ExtractedRelation] = []
        select("SELECT subject, predicate, object FROM relations WHERE source = ? AND chunks_hash = ?", [source, chunksHash]) { row in
            relations.append(ExtractedRelation(from: Self.text(row, 0) ?? "", to: Self.text(row, 2) ?? "", label: Self.text(row, 1) ?? ""))
        }
        return ExtractionResult(entities: entities, relations: relations)
    }

    /// How many vectors it keeps: for the self-tests and the log.
    func vectorCount() -> Int {
        var count = 0
        select("SELECT COUNT(*) FROM chunks WHERE vector IS NOT NULL") { count = Int(sqlite3_column_int64($0, 0)) }
        return count
    }

    // MARK: What this Mac published

    struct Published: Sendable, Equatable {
        var binder: UUID
        /// The item as published (TeamKnowledgeItem.fingerprint, hashed).
        var print: String
        /// What it was made from here: the index's hash of it, whether its people and topics were found, the team's
        /// epoch, the binder, whether vectors went and with which model.
        var marker: String
    }

    func published(_ document: String) -> Published? {
        var found: Published?
        select("SELECT binder, print, marker FROM published WHERE document = ?", [document]) { row in
            if let binder = Self.text(row, 0).flatMap(UUID.init(uuidString:)) {
                found = Published(binder: binder, print: Self.text(row, 1) ?? "", marker: Self.text(row, 2) ?? "")
            }
        }
        return found
    }

    func allPublished() -> [String: Published] {
        var found: [String: Published] = [:]
        select("SELECT document, binder, print, marker FROM published") { row in
            if let document = Self.text(row, 0), let binder = Self.text(row, 1).flatMap(UUID.init(uuidString:)) {
                found[document] = Published(binder: binder, print: Self.text(row, 2) ?? "", marker: Self.text(row, 3) ?? "")
            }
        }
        return found
    }

    func setPublished(_ document: String, _ published: Published) {
        run("INSERT OR REPLACE INTO published(document, binder, print, marker) VALUES(?,?,?,?)",
            [document, published.binder.uuidString.lowercased(), published.print, published.marker])
    }

    func forgetPublished(_ document: String) {
        run("DELETE FROM published WHERE document = ?", [document])
    }

    /// A new pin: every item is published again.
    func forgetAllPublished() {
        run("DELETE FROM published")
    }

    func meta(_ key: String) -> String? {
        var value: String?
        select("SELECT value FROM meta WHERE key = ?", [key]) { value = Self.text($0, 0) }
        return value
    }

    func setMeta(_ key: String, _ value: String?) {
        if let value { run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [key, value]) } else { run("DELETE FROM meta WHERE key = ?", [key]) }
    }

    // MARK: SQLite

    private func select(_ sql: String, _ bindings: [Any?] = [], row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            Log.app.error("Team knowledge query failed: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return
        }
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, bindings)
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    @discardableResult
    private func run(_ sql: String, _ bindings: [Any?] = []) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            Log.app.error("Team knowledge statement failed: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return false
        }
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, bindings)
        let result = sqlite3_step(statement)
        return result == SQLITE_DONE || result == SQLITE_ROW
    }

    private static func bind(_ statement: OpaquePointer, _ bindings: [Any?]) {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            guard let value else {
                sqlite3_bind_null(statement, index)
                continue
            }
            switch value {
            case let string as String: sqlite3_bind_text(statement, index, string, -1, transient)
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            case let data as Data:
                data.withUnsafeBytes { bytes in _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient) }
            default: sqlite3_bind_null(statement, index)
            }
        }
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }
}
