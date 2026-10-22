import CryptoKit
import Foundation

// Meetings, captures, knowledge and to-dos on the team database (lane DB4): the calls migration 7 added, the rows a Mac
// sends and reads back, how a transcript goes in revisions, which vectors a Mac may take for its own index, and how far a
// teammate's correction reaches. Pure, so it's tested without a database; the Mac's TeamContent uses it.

// MARK: Calls (migration 7)

extension TeamCall {
    /// A meeting, capture or to-do of this member's. One taken off the team before (moved out of the shared binders, or
    /// deleted) comes back as given.
    public static func putItem(_ row: TeamRow, in table: TeamTable, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "put_item", arguments: [.text("p_table", table.rawValue), .json("p_row", .object(row)), .uuid("p_agent", agent)],
                 operation: operation)
    }

    /// A meeting or capture to another shared binder, with its transcript and its index.
    public static func moveItem(_ id: UUID, in table: TeamTable, to binder: UUID, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "move_item", arguments: [.text("p_table", table.rawValue), .uuid("p_id", id), .uuid("p_binder", binder),
                                                    .uuid("p_agent", agent)], operation: operation)
    }

    /// A meeting, capture or to-do off the team: a tombstone stays, its words erased, its index gone.
    public static func withdrawItem(_ id: UUID, from table: TeamTable, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "withdraw_item", arguments: [.text("p_table", table.rawValue), .uuid("p_id", id), .uuid("p_agent", agent)],
                 operation: operation)
    }

    /// An item's whole index at once.
    public static func replaceKnowledge(_ item: TeamKnowledgeItem, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "replace_knowledge",
                 arguments: [.uuid("p_binder", item.binder), .text("p_source_kind", item.kind), .text("p_source_id", item.sourceKey),
                             .json("p_chunks", .array(item.chunkRows)), .json("p_entities", .array(item.entityRows)),
                             .json("p_relations", .array(item.relationRows)), .json("p_corrections", item.corrections.map { .array($0.map { ["text": .string($0)] }) }),
                             .uuid("p_agent", agent)],
                 operation: operation)
    }

    /// The item a call of migration 7's is about, and its table: for telling which item an outbox answer was for.
    public var item: (table: TeamTable, id: UUID)? {
        guard let table = argument("p_table").flatMap(TeamTable.init(rawValue:)) else { return nil }
        switch function {
        case "put_item", "put_row":
            return argument("p_row").flatMap { TeamJSON(text: $0)?["id"]?.uuid }.map { (table, $0) }
        case "put_rows":
            // A transcript's lines: the meeting or capture they belong to.
            guard let first = argument("p_rows").flatMap({ TeamJSON(text: $0)?.array?.first }) else { return nil }
            let parent = table == .meetingSegments ? first["meeting_id"]?.uuid : table == .captureSegments ? first["capture_id"]?.uuid : first["id"]?.uuid
            return parent.map { (table, $0) }
        case "move_item", "withdraw_item":
            return argument("p_id").flatMap(UUID.init(uuidString:)).map { (table, $0) }
        default:
            return nil
        }
    }
}

// MARK: Meetings and captures

/// A meeting or a capture as the team database keeps it: what its maker's Mac sends (`row`), and what another Mac reads
/// back (`init(row:)`). A fixed list of fields, so nothing else of the record goes: never its audio, its chat, its
/// errors, its suggestions or what Binders read in it for its owner.
public struct TeamMeetingValues: Equatable, Sendable {
    public var id: UUID
    public var binder: UUID
    public var title: String
    public var started: Date
    public var ended: Date?
    public var duration: Double
    public var app: String?
    /// Meetings only.
    public var attendees: [String]
    public var templateID: String?
    public var summary: String
    /// The maker's own notes on it.
    public var notes: String
    public var speakerNames: [String: String]
    /// recording, processing, ready or failed, as its maker's Mac has it; a capture not kept reads `trivial`.
    public var status: String
    /// Which transcript revision is current.
    public var revision: Int
    /// Read back: who made it (a meeting's author, a capture's owner), when it last changed, and whether it was taken off
    /// the team.
    public var maker: UUID?
    public var updatedAt: Date?
    public var deleted: Bool
    /// The folder it's filed in, in its binder; nil at the top. The database keeps it only when it has that folder in the
    /// binder (else the top, as for notes).
    public var folder: UUID?

    public init(id: UUID, binder: UUID, title: String, started: Date, ended: Date? = nil, duration: Double = 0, app: String? = nil,
                attendees: [String] = [], templateID: String? = nil, summary: String = "", notes: String = "",
                speakerNames: [String: String] = [:], status: String = "ready", revision: Int = 0, maker: UUID? = nil,
                updatedAt: Date? = nil, deleted: Bool = false, folder: UUID? = nil) {
        self.id = id
        self.binder = binder
        self.title = title
        self.started = started
        self.ended = ended
        self.duration = duration
        self.app = app
        self.attendees = attendees
        self.templateID = templateID
        self.summary = summary
        self.notes = notes
        self.speakerNames = speakerNames
        self.status = status
        self.revision = revision
        self.maker = maker
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.folder = folder
    }

    /// Whether it's being recorded now: its lines arrive as they're written.
    public var isLive: Bool { status == "recording" }
    /// A capture its Mac kept (not hidden as small talk).
    public var kept: Bool { status != "trivial" }

    /// The row its maker's Mac sends: `capture` for the captures table. Who made it is the database's to say.
    public func row(capture: Bool) -> TeamRow {
        var row: TeamRow = ["id": TeamJSON(id), "binder_id": TeamJSON(binder), "folder_id": TeamJSON(folder), "title": .string(title),
                            "started_at": TeamJSON(started),
                            "ended_at": TeamJSON(ended), "duration": .number(duration), "app_name": TeamJSON(app), "summary": .string(summary),
                            "notes": .string(notes), "speaker_names": .object(speakerNames.mapValues { .string($0) }),
                            "status": .string(status), "transcript_revision": .number(Double(revision))]
        if capture {
            row["kept"] = .bool(kept)
        } else {
            row["attendees"] = TeamJSON(attendees)
            row["template_id"] = TeamJSON(templateID)
            row["live"] = .bool(isLive)
        }
        return row
    }

    /// A row read back; nil without an id, a binder or a start.
    public init?(row: TeamRow, capture: Bool) {
        guard let id = row.rowID, let binder = row["binder_id"]?.uuid else { return nil }
        let started = row["started_at"]?.date ?? row["created_at"]?.date ?? Date(timeIntervalSince1970: 0)
        var status = row["status"]?.string ?? "ready"
        // A capture its owner hid as small talk; a status this Binders doesn't know reads as written up.
        if capture, row["kept"]?.bool == false { status = "trivial" }
        if !["recording", "processing", "ready", "failed", "trivial"].contains(status) { status = "ready" }
        let names = (row["speaker_names"]?.object ?? [:]).compactMapValues(\.string)
        self.init(id: id, binder: binder, title: row["title"]?.string ?? "", started: started, ended: row["ended_at"]?.date,
                  duration: row["duration"]?.double ?? 0, app: row["app_name"]?.string, attendees: row["attendees"]?.strings ?? [],
                  templateID: row["template_id"]?.string, summary: row["summary"]?.string ?? "", notes: row["notes"]?.string ?? "",
                  speakerNames: names, status: status, revision: row["transcript_revision"]?.int ?? 0,
                  maker: row[capture ? "owner_id" : "author_id"]?.uuid, updatedAt: row["updated_at"]?.date, deleted: row.deletedAt != nil,
                  folder: row["folder_id"]?.uuid)
    }

    /// What's sent, as one text: the same values give the same text, so a Mac sends a row again only when it changed.
    public func fingerprint(capture: Bool) -> String { TeamJSON.object(row(capture: capture)).text }
}

/// Speaker names as another Mac shows them: the maker's "You" is the maker, by name, unless they named it already.
public enum TeamSpeakers {
    public static func shown(_ names: [String: String], maker: String) -> [String: String] {
        var shown = names
        if shown[TranscriptSegment.you]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            shown[TranscriptSegment.you] = maker
        }
        return shown
    }
}

// MARK: Transcripts

/// How a meeting's or capture's transcript goes to the team: its lines are only ever added to, in revisions. While it's
/// recorded, new lines join the current revision as they're written; when its Mac writes the transcript again (who said
/// what, a better pass), the whole new transcript goes as the next revision, and the item says which revision is current.
public enum TeamTranscript {
    /// Each revision's lines take positions from `revision × positionsPerRevision`, so (item, position) stays unique.
    public static let positionsPerRevision = 1_000_000

    /// What a Mac does with a transcript now.
    public enum Plan: Equatable, Sendable {
        /// The team has it as it is.
        case nothing
        /// These lines join the current revision (oldest first).
        case append([TranscriptSegment])
        /// The whole transcript goes as a new revision.
        case revise([TranscriptSegment])
    }

    /// One line's words, speaker, times and channel, as text: a line sent and then changed is told apart by it.
    public static func fingerprint(_ segment: TranscriptSegment) -> String {
        KnowledgeContentHash.of([segment.text, segment.speaker, String(segment.start), String(segment.end), segment.channel.rawValue])
    }

    /// The whole transcript, whatever order it's read in: each line's id and fingerprint.
    public static func digest(_ segments: [TranscriptSegment]) -> String {
        KnowledgeContentHash.of(segments.map { $0.id.uuidString + ":" + fingerprint($0) }.sorted())
    }

    /// `local`: the lines this Mac has now. `sent`: the lines sent in the current revision, by id, with their
    /// fingerprints, when this Mac still knows them (it forgets them at a restart); `sentDigest`: the digest of all the
    /// lines sent, nil when none were. Every line sent still here as it was: the new ones join; anything else: a new
    /// revision with all of them.
    public static func plan(local: [TranscriptSegment], sent: [UUID: String]?, sentDigest: String?) -> Plan {
        let ordered = local.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        // Nothing sent yet: every line joins the current revision.
        guard let sentDigest else { return ordered.isEmpty ? .nothing : .append(ordered) }
        if sentDigest == digest(local) { return .nothing }
        // Each line sent is still here as it was: only the new ones go.
        if let sent {
            let byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if sent.allSatisfy({ id, print in byID[id].map { fingerprint($0) == print } ?? false }) {
                let new = ordered.filter { sent[$0.id] == nil }
                return new.isEmpty ? .nothing : .append(new)
            }
        }
        return .revise(ordered)
    }

    /// A line's row id: in revision 0 the line's own id, later one made from it and the revision, so the same line sent
    /// again in a new revision is a new row.
    public static func rowID(item: UUID, revision: Int, segment: UUID) -> UUID {
        revision == 0 ? segment
            : TeamOperationID.derived("transcript \(item.uuidString.lowercased()) \(revision) \(segment.uuidString.lowercased())")
    }

    /// Lines as rows: the next positions in `revision` after `count` lines already sent in it.
    public static func rows(_ segments: [TranscriptSegment], item: UUID, binder: UUID, revision: Int, after count: Int,
                            capture: Bool) -> [TeamRow] {
        segments.enumerated().map { offset, segment in
            [capture ? "capture_id" : "meeting_id": TeamJSON(item), "id": TeamJSON(rowID(item: item, revision: revision, segment: segment.id)),
             "binder_id": TeamJSON(binder), "revision": .number(Double(revision)),
             "position": .number(Double(revision * positionsPerRevision + count + offset)), "speaker": .string(segment.speaker),
             "text": .string(segment.text), "start_time": .number(segment.start), "end_time": .number(segment.end),
             "channel": .string(segment.channel.rawValue)]
        }
    }

    /// A line read back: its revision and the item it belongs to, with the line as this Mac keeps it (the row's id as its
    /// own). Nil for a line taken off the team or one that isn't whole.
    public static func line(_ row: TeamRow, capture: Bool) -> (item: UUID, revision: Int, position: Int, segment: TranscriptSegment)? {
        guard row.deletedAt == nil, let id = row.rowID, let item = row[capture ? "capture_id" : "meeting_id"]?.uuid else { return nil }
        let channel = row["channel"]?.string.flatMap(AudioChannel.init(rawValue:)) ?? .system
        let start = row["start_time"]?.double ?? 0
        let segment = TranscriptSegment(id: id, channel: channel, start: start, end: row["end_time"]?.double ?? start,
                                        text: row["text"]?.string ?? "", speaker: row["speaker"]?.string ?? "")
        return (item, row["revision"]?.int ?? 0, row["position"]?.int ?? 0, segment)
    }
}

// MARK: Knowledge

/// Which vectors a Mac may take for its own index: only those of the model its own index uses, compared by the name the
/// team gives a model, and only for exactly the text that model reads for a passage.
public enum TeamEmbedding {
    /// The name a model's vectors go by in the team. Ollama's `embeddinggemma` (whatever its tag) and MLX's
    /// `mlx-community/embeddinggemma-300m-…` are the same model, EmbeddingGemma 300M, in other precisions (768 numbers
    /// each), so both are `embeddinggemma`, the team's pin by default. Any other model: its name, lower-cased, without an
    /// Ollama `:latest` tag.
    public static func canonical(_ model: String) -> String {
        var name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(":latest") { name.removeLast(":latest".count) }
        let base = name.split(separator: "/").last.map(String.init) ?? name
        if base.hasPrefix("embeddinggemma") { return "embeddinggemma" }
        return name
    }

    /// Whether vectors made with `model` are the team's pin.
    public static func isPin(_ model: String, pin: String) -> Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty && canonical(model) == canonical(pin)
    }

    /// What the embedding model reads for a passage, as the knowledge index gives it (KnowledgeService.embedPending).
    public static func input(title: String, text: String) -> String { "title: \(title) | text: \(text)" }

    /// The key a vector is kept under: the model, by its team name, and exactly what it read.
    public static func key(model: String, title: String, text: String) -> String {
        KnowledgeContentHash.of([canonical(model), input(title: title, text: text)])
    }

    /// A vector as the team database's column writes it in JSON ("[0.1,-0.2,…]"), as numbers; nil for anything else.
    public static func vector(_ json: TeamJSON?) -> [Float]? {
        if let numbers = json?.array { return numbers.compactMap(\.double).map(Float.init) }
        guard let text = json?.string?.trimmingCharacters(in: .whitespaces), text.hasPrefix("["), text.hasSuffix("]") else { return nil }
        let parts = text.dropFirst().dropLast().split(separator: ",")
        let values = parts.compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        return values.count == parts.count && !values.isEmpty ? values : nil
    }

    /// A vector to send: six significant digits a number, which is as much as the column keeps that matters for search.
    public static func json(_ vector: [Float]) -> TeamJSON {
        .array(vector.map { .number(Double(String(format: "%.6g", Double($0))) ?? Double($0)) })
    }

    /// A hash of an item's chunks as every Mac makes them (its title and each chunk's words, in order): what tells a Mac
    /// whether the team's index of an item is for the item as it has it.
    public static func chunksHash(title: String, texts: [String]) -> String {
        KnowledgeContentHash.of([title] + texts)
    }
}

/// One item's whole index, as replace_knowledge takes it: from the Mac whose member made the item.
public struct TeamKnowledgeItem: Equatable, Sendable {
    public struct Chunk: Equatable, Sendable {
        public var text: String
        public var startTime: Double?
        public var speaker: String?
        /// Its vector, from the team's model; nil when this Mac couldn't make one with it.
        public var vector: [Float]?

        public init(text: String, startTime: Double? = nil, speaker: String? = nil, vector: [Float]? = nil) {
            self.text = text
            self.startTime = startTime
            self.speaker = speaker
            self.vector = vector
        }
    }

    public var binder: UUID
    /// The knowledge kind: meeting, conversation (a capture) or note.
    public var kind: String
    public var source: UUID
    /// The item's title: what its vectors were made with.
    public var title: String
    public var chunks: [Chunk]
    /// The team's model by its pinned name, for the chunks that have vectors.
    public var model: String?
    public var entities: [ExtractedEntity]
    public var relations: [ExtractedRelation]
    /// A note's corrections, as each note keeps one (KnowledgeCorrection.markdown); nil for an item that isn't a note.
    public var corrections: [String]?

    public init(binder: UUID, kind: String, source: UUID, title: String, chunks: [Chunk], model: String? = nil,
                entities: [ExtractedEntity] = [], relations: [ExtractedRelation] = [], corrections: [String]? = nil) {
        self.binder = binder
        self.kind = kind
        self.source = source
        self.title = title
        self.chunks = chunks
        self.model = model
        self.entities = entities
        self.relations = relations
        self.corrections = corrections
    }

    /// The source id as the database keeps it.
    public var sourceKey: String { source.uuidString.lowercased() }

    public var chunksHash: String { TeamEmbedding.chunksHash(title: title, texts: chunks.map(\.text)) }

    public var chunkRows: [TeamJSON] {
        let hash = chunksHash
        return chunks.map { chunk in
            var row: TeamRow = ["text": .string(chunk.text), "title": .string(title), "chunks_hash": .string(hash),
                                "start_time": chunk.startTime.map { .number($0) } ?? .null, "speaker": TeamJSON(chunk.speaker)]
            if let vector = chunk.vector, let model {
                row["embedding"] = TeamEmbedding.json(vector)
                row["embedding_model"] = .string(model)
            }
            return .object(row)
        }
    }

    public var entityRows: [TeamJSON] {
        let hash = chunksHash
        var seen = Set<String>()
        return entities.compactMap { entity in
            let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased() + "|" + entity.type).inserted else { return nil }
            return .object(["name": .string(name), "kind": .string(entity.type), "chunks_hash": .string(hash)])
        }
    }

    public var relationRows: [TeamJSON] {
        let hash = chunksHash
        var seen = Set<String>()
        return relations.compactMap { relation in
            let subject = relation.from.trimmingCharacters(in: .whitespacesAndNewlines), object = relation.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty, !object.isEmpty, seen.insert("\(subject)|\(relation.label)|\(object)").inserted else { return nil }
            return .object(["subject": .string(subject), "predicate": .string(relation.label), "object": .string(object), "chunks_hash": .string(hash)])
        }
    }

    /// What tells two publishings of an item apart: the same index gives the same text, so an item is published again only
    /// when its index changed.
    public var fingerprint: String {
        TeamJSON.object(["binder": TeamJSON(binder), "kind": .string(kind), "source": .string(sourceKey), "chunks": .array(chunkRows),
                         "entities": .array(entityRows), "relations": .array(relationRows), "model": TeamJSON(model),
                         "corrections": corrections.map { TeamJSON($0) } ?? .null]).text
    }
}

/// A teammate's correction, as this Mac keeps it (corrections.json beside the outbox): it steers answers drawn from its
/// binder, named, unless an agent wrote it.
public struct TeamCorrection: Codable, Equatable, Sendable {
    /// The row's id.
    public var id: UUID
    /// The note that keeps it.
    public var note: UUID
    public var binder: UUID
    /// The correction as its note keeps it ("Wrong: … Right: …", #correction).
    public var text: String
    /// Who made it, by name.
    public var author: String
    public var byAgent: Bool
    public var date: Date

    public init(id: UUID, note: UUID, binder: UUID, text: String, author: String, byAgent: Bool = false, date: Date) {
        self.id = id
        self.note = note
        self.binder = binder
        self.text = text
        self.author = author
        self.byAgent = byAgent
        self.date = date
    }

    /// A `corrections` row; nil for one taken away, one that isn't a note's, or one that keeps no correction.
    public init?(row: TeamRow, author: String) {
        guard row.deletedAt == nil, let id = row.rowID, let binder = row["binder_id"]?.uuid, row["source_kind"]?.string == "note",
              let note = row["source_id"]?.uuid, let text = row["text"]?.string, KnowledgeCorrection.parse(text) != nil else { return nil }
        self.init(id: id, note: note, binder: binder, text: text, author: author, byAgent: row["created_by_agent"]?.uuid != nil,
                  date: row["updated_at"]?.date ?? row["created_at"]?.date ?? Date())
    }

    public var correction: KnowledgeCorrection? { KnowledgeCorrection.parse(text) }

    /// Whether it steers a passage from `binder` (a source's binder, by id string, as the index keeps it): only passages
    /// from its own binder, and never one an agent wrote.
    public func reaches(binder passage: String?) -> Bool {
        !byAgent && passage.flatMap(UUID.init(uuidString:)) == binder
    }
}

// MARK: To-dos

/// A to-do as the team database keeps it: its words, kind, whose promise it is, to whom, when it's due (and as said),
/// where it stands and since when, where it came from in its maker's words, its origin, who added it when that wasn't its
/// maker, and the card it's on. Never the message it was found in.
public struct TeamTodoValues: Equatable, Sendable {
    public var id: UUID
    public var binder: UUID
    public var text: String
    /// promise, ask or todo.
    public var kind: String
    /// Whose promise it is, by name ("You" goes out as its maker's name).
    public var owner: String?
    public var to: String?
    public var due: Date?
    public var dueText: String?
    /// open, done or dismissed.
    public var status: String
    public var doneAt: Date?
    public var origin: String?
    public var madeBy: String?
    /// Where it came from, in its maker's words ("Promised to Sam in Mail").
    public var source: String
    public var card: UUID?
    /// Read back: who made it, and whether it was taken off the team.
    public var maker: UUID?
    public var deleted: Bool

    public init(id: UUID, binder: UUID, text: String, kind: String = "todo", owner: String? = nil, to: String? = nil, due: Date? = nil,
                dueText: String? = nil, status: String = "open", doneAt: Date? = nil, origin: String? = nil, madeBy: String? = nil,
                source: String = "", card: UUID? = nil, maker: UUID? = nil, deleted: Bool = false) {
        self.id = id
        self.binder = binder
        self.text = text
        self.kind = kind
        self.owner = owner
        self.to = to
        self.due = due
        self.dueText = dueText
        self.status = status
        self.doneAt = doneAt
        self.origin = origin
        self.madeBy = madeBy
        self.source = source
        self.card = card
        self.maker = maker
        self.deleted = deleted
    }

    public func row() -> TeamRow {
        ["id": TeamJSON(id), "binder_id": TeamJSON(binder), "text": .string(text), "kind": .string(kind), "owner": TeamJSON(owner),
         "to_name": TeamJSON(to), "due_at": TeamJSON(due), "due_text": TeamJSON(dueText), "status": .string(status),
         "done_at": TeamJSON(doneAt), "origin": TeamJSON(origin), "made_by": TeamJSON(madeBy), "source_title": .string(source),
         "card_id": TeamJSON(card)]
    }

    /// Only where it stands: what a teammate's tick sends.
    public func statusRow() -> TeamRow {
        ["id": TeamJSON(id), "status": .string(status), "done_at": TeamJSON(doneAt)]
    }

    public init?(row: TeamRow) {
        guard let id = row.rowID, let binder = row["binder_id"]?.uuid else { return nil }
        let status = row["status"]?.string ?? "open"
        self.init(id: id, binder: binder, text: row["text"]?.string ?? "", kind: row["kind"]?.string ?? "todo", owner: row["owner"]?.string,
                  to: row["to_name"]?.string, due: row["due_at"]?.date, dueText: row["due_text"]?.string,
                  status: ["open", "done", "dismissed"].contains(status) ? status : "open", doneAt: row["done_at"]?.date,
                  origin: row["origin"]?.string, madeBy: row["made_by"]?.string, source: row["source_title"]?.string ?? "",
                  card: row["card_id"]?.uuid, maker: row["created_by"]?.uuid, deleted: row.deletedAt != nil)
    }

    /// The same, as the team keeps it: dates to the microsecond.
    public func same(as other: TeamTodoValues) -> Bool {
        TeamJSON.object(row()).text == TeamJSON.object(other.row()).text
    }

    /// Whose promise it is, going out: "You" is its maker, by name.
    public static func owner(sending owner: String, maker: String) -> String {
        BoardRules.isReserved(owner) ? maker : owner
    }

    /// And coming in: this Mac's member's name is "You" here; none is its maker's.
    public static func owner(received owner: String?, me: String?, maker: String) -> String {
        let trimmed = owner?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = trimmed.isEmpty ? maker : trimmed
        if let me, name.localizedCaseInsensitiveCompare(me) == .orderedSame { return BoardActor.you.name }
        return name
    }

    /// Where a teammate's to-do came from, as this Mac shows it: "From Dana: Added by voice".
    public static func source(_ source: String, maker: String) -> String {
        let source = source.trimmingCharacters(in: .whitespaces)
        return source.isEmpty ? "From \(maker)" : "From \(maker): \(source)"
    }
}
