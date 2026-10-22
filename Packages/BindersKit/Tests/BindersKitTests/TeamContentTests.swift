import XCTest
@testable import BindersKit

/// Lane DB4's pure parts: meetings', captures' and to-dos' rows, transcripts in revisions, which vectors a Mac may take,
/// an item's index, and how far a teammate's correction reaches. The Mac's `--selftest-teamdb-meetings`, `-knowledge` and
/// `-todos` run them against a real Postgres.
final class TeamContentTests: XCTestCase {
    private let binder = UUID(uuidString: "6F1D0C8E-2B3A-4C5D-9E8F-0A1B2C3D4E5F")!
    private let started = Date(timeIntervalSince1970: 1_790_000_000.25)

    // MARK: Migration 7

    func testMigrationSevenIsListedAndAddsNoTable() {
        let sql = TeamSchema.migration7.sql
        XCTAssertEqual(TeamSchema.migrations.first { $0.version == 7 }?.sql, sql, "listed as number 7, before migration 8")
        XCTAssertFalse(sql.contains("CREATE TABLE"), "columns and functions only, so it merges after lane DB3's migration")
        for function in ["put_item", "move_item", "withdraw_item", "replace_knowledge"] {
            XCTAssertTrue(sql.contains("CREATE FUNCTION binders.\(function)(p_op uuid"), "\(function) takes an operation id first")
        }
        // No column for audio, in any table.
        let allSQL = TeamSchema.migrations.map(\.sql).joined(separator: "\n").lowercased()
        XCTAssertNil(allSQL.range(of: #"(add column|\n\s+)[a-z_]*(audio|mic_|wav)[a-z_]* "#, options: .regularExpression))
    }

    // MARK: Meetings and captures

    func testAMeetingsRowCarriesWhatItShowsAndReadsBackTheSame() throws {
        let meeting = TeamMeetingValues(id: UUID(), binder: binder, title: "Pricing review", started: started, ended: started.addingTimeInterval(1800),
                                        duration: 1800, app: "Zoom", attendees: ["Sam", "Alex"], templateID: "general", summary: "- [ ] You: send the deck",
                                        notes: "Ask about Q3", speakerNames: ["Speaker 1": "Alex"], status: "recording", revision: 2)
        let row = meeting.row(capture: false)
        XCTAssertEqual(Set(row.keys), ["id", "binder_id", "folder_id", "title", "started_at", "ended_at", "duration", "app_name", "summary", "notes", "speaker_names",
                                       "status", "transcript_revision", "attendees", "template_id", "live"])
        XCTAssertEqual(row["live"], .bool(true), "live while it's recorded")
        XCTAssertNil(row["author_id"], "who made it is the database's to say")
        var stored = row
        stored["author_id"] = TeamJSON(UUID())
        stored["updated_at"] = TeamJSON(started)
        let back = try XCTUnwrap(TeamMeetingValues(row: stored, capture: false))
        XCTAssertEqual(back.title, meeting.title)
        XCTAssertEqual(back.attendees, meeting.attendees)
        XCTAssertEqual(back.speakerNames, meeting.speakerNames)
        XCTAssertEqual(back.revision, 2)
        XCTAssertTrue(back.isLive)
        XCTAssertEqual(back.started.timeIntervalSince1970, started.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(back.fingerprint(capture: false), meeting.fingerprint(capture: false), "read back, it's what was sent")
    }

    func testACapturesRowSaysWhetherItWasKeptAndNeverCarriesAudio() throws {
        var capture = TeamMeetingValues(id: UUID(), binder: binder, title: "Hallway chat", started: started, duration: 240, app: "iPhone",
                                        summary: "Talked about the booth.", speakerNames: ["You": "", "Speaker 2": "Dana"], status: "ready")
        var row = capture.row(capture: true)
        XCTAssertEqual(row["kept"], .bool(true))
        XCTAssertNil(row["attendees"])
        XCTAssertNil(row["live"])
        let text = TeamJSON.object(row).text.lowercased()
        for audio in [".wav", ".m4a", "audio", "mic"] { XCTAssertFalse(text.contains(audio), "no \(audio) in a capture's row") }
        capture.status = "trivial"
        row = capture.row(capture: true)
        XCTAssertEqual(row["kept"], .bool(false), "hidden as small talk: not kept")
        let back = try XCTUnwrap(TeamMeetingValues(row: row, capture: true))
        XCTAssertEqual(back.status, "trivial")
        XCTAssertFalse(back.kept)
    }

    func testARowFromBeforeMigrationSevenStillReads() throws {
        // As migration 3 made the tables: no status, no revision, no capture duration or speakers.
        let id = UUID(), author = UUID()
        let old: TeamRow = ["id": TeamJSON(id), "binder_id": TeamJSON(binder), "author_id": TeamJSON(author), "title": "Standup",
                            "started_at": TeamJSON(started), "duration": 600, "attendees": ["Sam"], "summary": "", "notes": "",
                            "speaker_names": [:], "live": false, "created_at": TeamJSON(started), "updated_at": TeamJSON(started)]
        let meeting = try XCTUnwrap(TeamMeetingValues(row: old, capture: false))
        XCTAssertEqual(meeting.status, "ready")
        XCTAssertEqual(meeting.revision, 0)
        XCTAssertEqual(meeting.maker, author)
        let capture = try XCTUnwrap(TeamMeetingValues(row: ["id": TeamJSON(UUID()), "binder_id": TeamJSON(binder), "owner_id": TeamJSON(author),
                                                            "title": "", "summary": "", "kept": true], capture: true))
        XCTAssertEqual(capture.duration, 0)
        XCTAssertEqual(capture.speakerNames, [:])
        XCTAssertEqual(capture.maker, author)
        let unknown = try XCTUnwrap(TeamMeetingValues(row: ["id": TeamJSON(UUID()), "binder_id": TeamJSON(binder), "status": "archived"], capture: false))
        XCTAssertEqual(unknown.status, "ready", "a status a later Binders writes reads as written up")
        XCTAssertNil(TeamMeetingValues(row: ["title": "no id"], capture: false))
    }

    func testAMakersYouIsTheMakerOnAnotherMac() {
        XCTAssertEqual(TeamSpeakers.shown(["Speaker 1": "Dana"], maker: "Sam"), ["Speaker 1": "Dana", "You": "Sam"])
        XCTAssertEqual(TeamSpeakers.shown(["You": " "], maker: "Sam"), ["You": "Sam"])
        XCTAssertEqual(TeamSpeakers.shown(["You": "Samuel"], maker: "Sam"), ["You": "Samuel"], "a name they gave themselves stays")
    }

    // MARK: Transcripts

    private func line(_ start: Double, _ text: String, speaker: String = "You", channel: AudioChannel = .microphone) -> TranscriptSegment {
        TranscriptSegment(channel: channel, start: start, end: start + 2, text: text, speaker: speaker)
    }

    func testATranscriptStreamsByAddingAndANewPassGoesAsARevision() {
        let first = [line(0, "Morning."), line(3, "Hi all.", speaker: "Others", channel: .system)]
        XCTAssertEqual(TeamTranscript.plan(local: [], sent: nil, sentDigest: nil), .nothing)
        XCTAssertEqual(TeamTranscript.plan(local: first, sent: nil, sentDigest: nil), .append(first), "nothing sent yet: all of it joins")
        var sent = Dictionary(uniqueKeysWithValues: first.map { ($0.id, TeamTranscript.fingerprint($0)) })
        let digest = TeamTranscript.digest(first)
        XCTAssertEqual(TeamTranscript.plan(local: first.reversed(), sent: sent, sentDigest: digest), .nothing, "in any order, the same")
        // A line written later, earlier in time (the other channel caught up): only it goes.
        let late = line(1.5, "Can you hear me?", speaker: "Others", channel: .system)
        XCTAssertEqual(TeamTranscript.plan(local: first + [late], sent: sent, sentDigest: digest), .append([late]))
        sent[late.id] = TeamTranscript.fingerprint(late)
        let all = first + [late]
        // Written up: a line changed (who said it), one dropped: a new revision, all of it, in time order.
        var changed = all
        changed[1].speaker = "Dana"
        changed.removeLast()
        guard case .revise(let revised) = TeamTranscript.plan(local: changed, sent: sent, sentDigest: TeamTranscript.digest(all)) else {
            return XCTFail("a changed line makes a new revision")
        }
        XCTAssertEqual(revised.map(\.text), ["Morning.", "Hi all."])
        // After a restart this Mac no longer knows each line it sent: the same transcript sends nothing, another a revision.
        XCTAssertEqual(TeamTranscript.plan(local: all, sent: nil, sentDigest: TeamTranscript.digest(all)), .nothing)
        let more = all + [line(9, "Bye.")]
        guard case .revise(let again) = TeamTranscript.plan(local: more, sent: nil, sentDigest: TeamTranscript.digest(all)) else {
            return XCTFail("after a restart, a changed transcript goes again whole")
        }
        XCTAssertEqual(again.map(\.text), ["Morning.", "Can you hear me?", "Hi all.", "Bye."], "in time order")
        XCTAssertEqual(TeamTranscript.plan(local: [], sent: sent, sentDigest: TeamTranscript.digest(all)), .revise([]), "emptied: an empty revision")
    }

    func testLinesTakePositionsByRevisionAndReadBack() throws {
        let item = UUID()
        let lines = [line(0, "One."), line(2, "Two.", speaker: "Speaker 1", channel: .system)]
        let rows = TeamTranscript.rows(lines, item: item, binder: binder, revision: 0, after: 5, capture: false)
        XCTAssertEqual(rows.map { $0["position"]?.int }, [5, 6])
        XCTAssertEqual(rows.first?.rowID, lines.first?.id, "revision 0 keeps the line's own id")
        let again = TeamTranscript.rows(lines, item: item, binder: binder, revision: 3, after: 0, capture: true)
        XCTAssertEqual(again.map { $0["position"]?.int }, [3_000_000, 3_000_001])
        XCTAssertNotEqual(again.first?.rowID, lines.first?.id, "a later revision's row is a new row")
        XCTAssertEqual(again.first?.rowID, TeamTranscript.rowID(item: item, revision: 3, segment: lines[0].id), "made the same way every time")
        XCTAssertEqual(again.first?["capture_id"]?.uuid, item)
        let read = try XCTUnwrap(TeamTranscript.line(again[1], capture: true))
        XCTAssertEqual(read.item, item)
        XCTAssertEqual(read.revision, 3)
        XCTAssertEqual(read.segment.text, "Two.")
        XCTAssertEqual(read.segment.speaker, "Speaker 1")
        XCTAssertEqual(read.segment.channel, .system)
        var gone = again[0]
        gone["deleted_at"] = TeamJSON(started)
        XCTAssertNil(TeamTranscript.line(gone, capture: true), "a line taken off the team isn't read")
    }

    // MARK: Knowledge

    func testEmbeddingGemmaFromOllamaOrMLXIsTheTeamsPin() {
        for name in ["embeddinggemma", "embeddinggemma:latest", "EmbeddingGemma:300m", "mlx-community/embeddinggemma-300m-4bit",
                     "mlx-community/embeddinggemma-300m-bf16"] {
            XCTAssertEqual(TeamEmbedding.canonical(name), "embeddinggemma", name)
            XCTAssertTrue(TeamEmbedding.isPin(name, pin: TeamEmbeddingPin.default.model), name)
        }
        XCTAssertEqual(TeamEmbedding.canonical("nomic-embed-text:latest"), "nomic-embed-text")
        XCTAssertFalse(TeamEmbedding.isPin("nomic-embed-text", pin: "embeddinggemma"))
        XCTAssertFalse(TeamEmbedding.isPin("", pin: "embeddinggemma"))
        XCTAssertEqual(TeamEmbedding.key(model: "embeddinggemma:latest", title: "T", text: "x"),
                       TeamEmbedding.key(model: "mlx-community/embeddinggemma-300m-4bit", title: "T", text: "x"))
        XCTAssertNotEqual(TeamEmbedding.key(model: "embeddinggemma", title: "T", text: "x"), TeamEmbedding.key(model: "embeddinggemma", title: "U", text: "x"),
                          "the title is part of what the model read")
        XCTAssertEqual(TeamEmbedding.input(title: "Standup", text: "We ship Friday."), "title: Standup | text: We ship Friday.")
    }

    func testVectorsReadFromTheColumnAndGoWithSixDigits() {
        XCTAssertEqual(TeamEmbedding.vector(.string("[0.5,-0.25,3e-05]")), [0.5, -0.25, 0.00003])
        XCTAssertEqual(TeamEmbedding.vector([1, 2]), [1, 2])
        XCTAssertNil(TeamEmbedding.vector(.string("[0.5,x]")))
        XCTAssertNil(TeamEmbedding.vector(.string("not a vector")))
        XCTAssertNil(TeamEmbedding.vector(nil))
        let sent = TeamEmbedding.json([0.123456789, -0.000012345678])
        XCTAssertEqual(sent.text, "[0.123457,-1.23457e-05]")
    }

    func testAnItemsIndexSaysWhatTheModelReadAndChangesWhenItDoes() {
        let note = UUID()
        var item = TeamKnowledgeItem(binder: binder, kind: "note", source: note, title: "Launch",
                                     chunks: [.init(text: "We launch Thursday.", vector: [1, 0]), .init(text: "Booth in hall B.")], model: "embeddinggemma",
                                     entities: [ExtractedEntity(name: "Hall B", type: "place"), ExtractedEntity(name: "hall b", type: "place"),
                                                ExtractedEntity(name: " ", type: "topic")],
                                     relations: [ExtractedRelation(from: "Booth", to: "Hall B", label: "in"), ExtractedRelation(from: "Booth", to: "Hall B", label: "in")],
                                     corrections: ["Wrong: launch is Friday\nRight: launch is Thursday\n#correction"])
        XCTAssertEqual(item.sourceKey, note.uuidString.lowercased())
        let chunks = item.chunkRows
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0]["embedding_model"], .string("embeddinggemma"))
        XCTAssertNotNil(chunks[0]["embedding"]?.array)
        XCTAssertNil(chunks[1]["embedding"], "no vector, no model: the column stays empty")
        XCTAssertEqual(chunks[1]["title"], .string("Launch"))
        XCTAssertEqual(chunks[0]["chunks_hash"]?.string, TeamEmbedding.chunksHash(title: "Launch", texts: ["We launch Thursday.", "Booth in hall B."]))
        XCTAssertEqual(item.entityRows.count, 1, "the same name and kind once, a blank one left out")
        XCTAssertEqual(item.relationRows.count, 1)
        let call = TeamCall.replaceKnowledge(item)
        XCTAssertEqual(call.function, "replace_knowledge")
        XCTAssertEqual(call.argument("p_source_kind"), "note")
        XCTAssertTrue(call.argument("p_corrections")?.contains("#correction") == true)
        XCTAssertNotNil(call.statement)
        let before = item.fingerprint
        item.chunks[1].vector = [0, 1]
        XCTAssertNotEqual(item.fingerprint, before, "a vector made since: published again")
        item.corrections = nil
        XCTAssertNil(TeamCall.replaceKnowledge(item).argument("p_corrections"), "a meeting's index leaves corrections alone")
    }

    func testATeammatesCorrectionReachesItsOwnBinderAndNeverAnAgents() throws {
        let note = UUID(), id = UUID()
        let text = KnowledgeCorrection(wrong: "the launch is on Friday", right: "the launch is on Thursday").markdown
        var row: TeamRow = ["id": TeamJSON(id), "binder_id": TeamJSON(binder), "source_kind": "note", "source_id": .string(note.uuidString.lowercased()),
                            "text": .string(text), "created_at": TeamJSON(started)]
        let correction = try XCTUnwrap(TeamCorrection(row: row, author: "Dana"))
        XCTAssertEqual(correction.note, note)
        XCTAssertEqual(correction.correction?.right, "the launch is on Thursday")
        XCTAssertTrue(correction.reaches(binder: binder.uuidString))
        XCTAssertFalse(correction.reaches(binder: UUID().uuidString), "a passage from another binder isn't steered")
        XCTAssertFalse(correction.reaches(binder: nil), "nor a dictation, which has none")
        row["created_by_agent"] = TeamJSON(UUID())
        let agents = try XCTUnwrap(TeamCorrection(row: row, author: "Dana"))
        XCTAssertFalse(agents.reaches(binder: binder.uuidString), "an agent's words count for nothing")
        row["source_kind"] = "meeting"
        XCTAssertNil(TeamCorrection(row: row, author: "Dana"))
        var gone = row
        gone["source_kind"] = "note"
        gone["deleted_at"] = TeamJSON(started)
        XCTAssertNil(TeamCorrection(row: gone, author: "Dana"))
        let data = try JSONEncoder().encode(correction)
        XCTAssertEqual(try JSONDecoder().decode(TeamCorrection.self, from: data), correction)
    }

    // MARK: To-dos

    func testATodosRowCarriesWhoseAndWhereButNeverTheMessage() throws {
        let card = UUID()
        let todo = TeamTodoValues(id: UUID(), binder: binder, text: "Send the deck", kind: "promise",
                                  owner: TeamTodoValues.owner(sending: "You", maker: "Sam"), to: "Dana", due: started, dueText: "by Friday",
                                  status: "open", origin: nil, madeBy: nil, source: "Promised to Dana in Mail", card: card)
        let row = todo.row()
        XCTAssertEqual(row["owner"], .string("Sam"), "your promise goes as yours, by name")
        XCTAssertNil(row["quote"])
        XCTAssertFalse(row.keys.contains { $0.contains("writing") || $0.contains("quote") })
        var stored = row
        stored["created_by"] = TeamJSON(UUID())
        let back = try XCTUnwrap(TeamTodoValues(row: stored))
        XCTAssertTrue(back.same(as: todo))
        XCTAssertEqual(back.card, card)
        XCTAssertEqual(Set(todo.statusRow().keys), ["id", "status", "done_at"], "a tick sends only where it stands")
        XCTAssertEqual(TeamTodoValues.owner(received: "Sam", me: "sam", maker: "Sam"), "You")
        XCTAssertEqual(TeamTodoValues.owner(received: "Dana", me: "Sam", maker: "Dana"), "Dana")
        XCTAssertEqual(TeamTodoValues.owner(received: nil, me: "Sam", maker: "Dana"), "Dana", "no owner: its maker's")
        XCTAssertEqual(TeamTodoValues.owner(sending: "Robin", maker: "Sam"), "Robin", "an ask keeps the name it was asked of")
        XCTAssertEqual(TeamTodoValues.source("Added by voice", maker: "Dana"), "From Dana: Added by voice")
        XCTAssertEqual(TeamTodoValues.source("", maker: "Dana"), "From Dana")
        let old = try XCTUnwrap(TeamTodoValues(row: ["id": TeamJSON(UUID()), "binder_id": TeamJSON(binder), "text": "Call Sam", "status": "open"]))
        XCTAssertEqual(old.kind, "todo", "a row from before migration 7 reads as a to-do")
        XCTAssertEqual(old.source, "")
    }

    // MARK: Calls

    func testMigrationSevenCallsSayWhichItemTheyreAbout() throws {
        let meeting = UUID()
        let put = TeamCall.putItem(TeamMeetingValues(id: meeting, binder: binder, title: "M", started: started).row(capture: false), in: .meetings)
        XCTAssertEqual(put.item?.table, .meetings)
        XCTAssertEqual(put.item?.id, meeting)
        let lines = TeamCall.put(rows: TeamTranscript.rows([line(0, "Hi.")], item: meeting, binder: binder, revision: 0, after: 0, capture: false),
                                 in: .meetingSegments)
        XCTAssertEqual(lines.item?.table, .meetingSegments)
        XCTAssertEqual(lines.item?.id, meeting, "a transcript's lines: the meeting they're in")
        XCTAssertEqual(TeamCall.withdrawItem(meeting, from: .captures).item?.id, meeting)
        XCTAssertEqual(TeamCall.moveItem(meeting, in: .meetings, to: UUID()).item?.table, .meetings)
        XCTAssertNil(TeamCall.claimCard(UUID()).item)
        for call in [put, lines, TeamCall.withdrawItem(meeting, from: .todos), TeamCall.moveItem(meeting, in: .captures, to: binder)] {
            let statement = try XCTUnwrap(call.statement)
            XCTAssertTrue(statement.sql.hasPrefix("SELECT binders.\(call.function)(p_op => $1::uuid"))
        }
    }
}

