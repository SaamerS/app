import Foundation
import SwiftData
import PostgresNIO
import BindersKit

/// Lane DB4's self-tests, on TeamDBTestBed's throwaway Postgres, as DB2's: this Mac is Sam, the app itself (its
/// TeamBoard and TeamContent connected as Sam); a teammate is Alex, a second login acting through a TeamDatabase client of
/// its own and writing rows as Alex's Mac would (the kit's TeamContent rows).
///
///     Binders --selftest-teamdb-meetings    meetings stream to a teammate as they're written, then as a new revision;
///                                           a teammate can't edit them; captures go only when you put them in a shared
///                                           binder or share them, never audio, through moves, edits and a restart
///     Binders --selftest-teamdb-knowledge   a teammate's index taken without embedding it again, search finds it, RLS
///                                           hides an unshared binder's, a teammate's correction steers answers, a new pin
///     Binders --selftest-teamdb-todos       to-dos tick everywhere, a card's to-do follows it, MCP's reads and ticks
extension SelfTest {
    // MARK: Meetings and captures

    @MainActor
    static func teamMeetingChecks(_ bed: TeamDBTestBed) async throws {
        let mac = try await TeamMac.start(bed)
        let content = mac.team.content
        content.editDelay = .milliseconds(150)
        let alex = try await bed.teammate()
        let root = try await bed.root()
        let store = Store.shared
        func ms(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded())) ms" }

        // Alex's Mac hears the feed: when each row first reached it.
        var seen: [UUID: Date] = [:]
        let hearing = Task { @MainActor in
            for await update in alex.updates {
                for rows in update.rows.values { for row in rows { if let id = row.rowID, seen[id] == nil { seen[id] = Date() } } }
                alex.acknowledge(update)
            }
        }
        defer { hearing.cancel() }

        // MARK: A meeting being recorded streams to a teammate, line by line.
        let meeting = MeetingRecord(title: "Pricing review", appName: "Zoom", templateID: "general")
        meeting.binderID = bed.shared
        meeting.attendees = ["Sam", "Alex"]
        meeting.micAudioFile = "pricing-review-mic.wav"
        meeting.systemAudioFile = "pricing-review-system.wav"
        store.insert(meeting)
        let started = await bed.eventually(5) { seen[meeting.id] != nil }
        bed.check(started, "a meeting started in a shared binder reaches the team as it starts")
        var lags: [TimeInterval] = []
        var live: [TranscriptSegment] = []
        for n in 0..<6 {
            let line = TranscriptSegment(channel: n % 2 == 0 ? .microphone : .system, start: Double(n * 3), end: Double(n * 3) + 2.5,
                                         text: "Line \(n) of the pricing review.")
            live.append(line)
            let written = Date()
            store.appendSegment(line, to: meeting.id)
            _ = await bed.eventually(5) { seen[line.id] != nil }
            lags.append(seen[line.id].map { $0.timeIntervalSince(written) } ?? 99)
            try await Task.sleep(for: .milliseconds(250))
        }
        let slowest = lags.max() ?? 99
        bed.check(slowest < 1, "each line written while it's recorded reaches a teammate's Mac in \(lags.map(ms).joined(separator: ", ")) (slowest \(ms(slowest)))")
        var row = try await alex.rows(.meetings, ids: [meeting.id]).first
        bed.check(row?["live"]?.bool == true && row?["status"]?.string == "recording" && row?["author_id"]?.uuid == bed.samID
                  && row?["attendees"]?.strings == ["Sam", "Alex"], "Alex sees it live, recording, by Sam, with who's there")
        var lines = try await alex.rows(.meetingSegments, binder: bed.shared).filter { $0["meeting_id"]?.uuid == meeting.id }
        bed.check(lines.count == 6 && lines.allSatisfy { $0["revision"]?.int == 0 }, "its 6 lines, revision 0: \(lines.count)")
        let audioColumns = try await root.value("""
            SELECT count(*) FROM information_schema.columns WHERE table_schema = 'binders'
            AND (column_name LIKE '%audio%' OR column_name LIKE '%mic%' OR column_name LIKE '%wav%' OR column_name LIKE '%sound%')
            """, as: Int64.self) ?? -1
        bed.check(audioColumns == 0, "no table in the team database has a column for audio")
        bed.check(!(TeamJSON.object(row ?? [:]).text.contains(".wav")), "and the meeting's row names no recording")

        // MARK: Offline while it's recorded: the lines wait on this Mac, not in the outbox, and go once it's back, each once.
        await mac.team.database?.stop()
        var offline: [TranscriptSegment] = []
        for n in 6..<9 {
            let line = TranscriptSegment(channel: .microphone, start: Double(n * 3), end: Double(n * 3) + 2.5, text: "Line \(n), said while offline.")
            offline.append(line)
            store.appendSegment(line, to: meeting.id)
        }
        try await Task.sleep(for: .milliseconds(400))
        let queuedOffline = mac.team.database?.waiting ?? -1
        mac.team.database?.start()
        let caughtUp = await bed.eventually(20) { offline.allSatisfy { seen[$0.id] != nil } }
        _ = await mac.drained()
        lines = try await alex.rows(.meetingSegments, binder: bed.shared).filter { $0["meeting_id"]?.uuid == meeting.id }
        bed.check(caughtUp && queuedOffline == 0 && lines.count == 9 && Set(lines.compactMap(\.rowID)).count == 9,
                  "offline while it's recorded: 3 lines waited on this Mac (\(queuedOffline) in the outbox) and went once it was back, each once")

        // MARK: Written up: who said what, an echo dropped, its notes: a new revision, all of it; nothing sent is changed.
        let final = [TranscriptSegment(channel: .microphone, start: 0, end: 2.5, text: "Line 0 of the pricing review.", speaker: "You"),
                     TranscriptSegment(channel: .system, start: 3, end: 5.5, text: "Line 1 of the pricing review.", speaker: "Speaker 1"),
                     TranscriptSegment(channel: .microphone, start: 6, end: 8.5, text: "Line 2 of the pricing review.", speaker: "You"),
                     TranscriptSegment(channel: .system, start: 9, end: 11.5, text: "Line 3, said again, of the pricing review.", speaker: "Speaker 1"),
                     TranscriptSegment(channel: .microphone, start: 12, end: 14.5, text: "Line 4 of the pricing review.", speaker: "You")]
        meeting.speakerNames = ["Speaker 1": "Alex"]
        meeting.summary = "## Decisions\n- The price stays at 12 a seat.\n\n## To-dos\n- [ ] You: send the deck"
        meeting.userNotes = "Ask about the Q3 numbers."
        meeting.duration = 18
        meeting.endedAt = meeting.createdAt.addingTimeInterval(18)
        meeting.status = "ready"
        store.replaceSegments(for: meeting.id, with: final)
        let written = await bed.eventually(10) {
            seen.keys.contains(TeamTranscript.rowID(item: meeting.id, revision: 1, segment: final.last!.id))
        }
        _ = await mac.drained()
        row = try await alex.rows(.meetings, ids: [meeting.id]).first
        lines = try await alex.rows(.meetingSegments, binder: bed.shared).filter { $0["meeting_id"]?.uuid == meeting.id }
        let current = lines.filter { $0["revision"]?.int == row?["transcript_revision"]?.int }
        bed.check(written && row?["transcript_revision"]?.int == 1 && row?["status"]?.string == "ready" && row?["live"]?.bool == false,
                  "written up: the meeting says revision 1 is current, ready, no longer live")
        bed.check(current.count == 5 && Set(current.compactMap { $0["speaker"]?.string }) == ["You", "Speaker 1"],
                  "revision 1 has the 5 lines written up, with who said them: \(current.count)")
        bed.check(lines.filter { $0["revision"]?.int == 0 }.count == 9, "and the 9 lines heard live are still there, as they were (only ever added to)")
        bed.check(row?["summary"]?.string?.contains("12 a seat") == true && row?["notes"]?.string == "Ask about the Q3 numbers."
                  && row?["speaker_names"]?["Speaker 1"]?.string == "Alex", "its notes, your own notes and who spoke travel")

        // MARK: Only its author changes it.
        var refused = await bed.failure { _ = try await alex.call(.putItem(["id": TeamJSON(meeting.id), "title": "Alex's title"], in: .meetings)) }
        bed.check(refused == "42501", "a teammate can't change your meeting: \(refused ?? "taken")")
        let line = TeamTranscript.rows([TranscriptSegment(channel: .system, start: 30, end: 31, text: "Slipped in.")], item: meeting.id, binder: bed.shared,
                                       revision: 1, after: 9, capture: false)
        refused = await bed.failure { _ = try await alex.call(.put(rows: line, in: .meetingSegments)) }
        bed.check(refused == "42501", "nor add a line to its transcript: \(refused ?? "taken")")
        refused = await bed.failure { _ = try await alex.call(.withdrawItem(meeting.id, from: .meetings)) }
        bed.check(refused == "42501", "nor take it off the team: \(refused ?? "taken")")

        // MARK: A teammate's meeting, recorded on their Mac: here as it's written, read-only.
        let theirs = UUID()
        var values = TeamMeetingValues(id: theirs, binder: bed.shared, title: "Booth planning", started: Date(), app: "Meet", attendees: ["Alex", "Sam"],
                                       speakerNames: [:], status: "recording")
        let opened = try await alex.call(.putItem(values.row(capture: false), in: .meetings))
        bed.check(opened.ok, "Alex's Mac puts its meeting in the shared binder as it starts recording")
        var copy: MeetingRecord? { content.meeting(theirs) }
        let arrived = await bed.eventually(5) { copy != nil }
        bed.check(arrived && copy?.isTeamCopy == true && copy?.teamAuthorName == "Alex" && copy?.status == "recording",
                  "Alex's meeting shows here as it starts: Alex's, read-only, recording")
        var theirLags: [TimeInterval] = []
        var theirLines: [TranscriptSegment] = []
        for n in 0..<4 {
            let line = TranscriptSegment(channel: n % 2 == 0 ? .microphone : .system, start: Double(n * 4), end: Double(n * 4) + 3,
                                         text: "Booth line \(n).", speaker: n % 2 == 0 ? "You" : "Others")
            theirLines.append(line)
            let sent = Date()
            _ = try await alex.call(.put(rows: TeamTranscript.rows([line], item: theirs, binder: bed.shared, revision: 0, after: n, capture: false),
                                         in: .meetingSegments))
            _ = await bed.eventually(5) { store.segments(for: theirs).contains { $0.id == line.id } }
            theirLags.append(Date().timeIntervalSince(sent))
        }
        bed.check((theirLags.max() ?? 99) < 1, "each of Alex's lines shows here in \(theirLags.map(ms).joined(separator: ", "))")
        bed.check(copy?.speakerNames["You"] == "Alex" && TranscriptFormatter.displayName("You", names: copy?.speakerNames ?? [:]) == "Alex",
                  "Alex's \"You\" is Alex here")
        bed.check((copy?.duration ?? 0) >= 15, "its length grows with its lines while it's recorded: \(Int(copy?.duration ?? 0)) s")
        bed.check(TeamContent.teamKeysLive(copy), "and it reads as live")
        // Read-only here: a change made to the copy goes nowhere.
        copy?.summary = "Changed on Sam's Mac"
        store.save()
        try await Task.sleep(for: .milliseconds(600))
        bed.check(mac.team.database?.waiting == 0, "a change to a teammate's copy sends nothing")
        refused = await bed.failure { _ = try await mac.team.database?.call(.putItem(["id": TeamJSON(theirs), "summary": "Mine now"], in: .meetings)) }
        bed.check(refused == "42501", "and the database wouldn't take one from this Mac: \(refused ?? "taken")")
        // Written up on Alex's Mac: the copy follows, its lines the new revision's only.
        let theirFinal = theirLines.prefix(3).map { TranscriptSegment(channel: $0.channel, start: $0.start, end: $0.end, text: $0.text + " (clean)",
                                                                       speaker: $0.speaker == "You" ? "You" : "Speaker 1") }
        values.status = "ready"
        values.revision = 1
        values.duration = 15
        values.summary = "## Booth\n- Hall B, stand 12."
        values.speakerNames = ["Speaker 1": "Robin"]
        _ = try await alex.call(.putItem(values.row(capture: false), in: .meetings))
        _ = try await alex.call(.put(rows: TeamTranscript.rows(Array(theirFinal), item: theirs, binder: bed.shared, revision: 1, after: 0, capture: false),
                                     in: .meetingSegments))
        let followed = await bed.eventually(5) {
            copy?.status == "ready" && Set(store.segments(for: theirs).map(\.text)) == Set(theirFinal.map(\.text))
        }
        bed.check(followed && copy?.summary == "## Booth\n- Hall B, stand 12.", "written up there: here it's ready, with Alex's notes and only revision 1's 3 lines")

        // MARK: Moves: to a binder Alex isn't in, out of the shared binders (its words erased), and back.
        func alexSees(_ id: UUID) async throws -> Bool {
            let rows = try await alex.rows(.meetings, ids: [id])
            return !rows.isEmpty
        }
        if let personal = store.binder(bed.personal) {
            store.move(meeting, to: personal)
            _ = await bed.eventually(5) { (mac.team.database?.waiting ?? 1) == 0 && content.state.meetings[meeting.id]?.binder == bed.personal }
            _ = await mac.drained()
            let hidden = try await alexSees(meeting.id) == false
            let movedLines = try await root.value("SELECT count(*) FROM binders.meeting_segments WHERE meeting_id = $1::uuid AND binder_id = $2::uuid",
                                                  [meeting.id.uuidString.lowercased(), bed.personal.uuidString.lowercased()], as: Int64.self) ?? 0
            bed.check(hidden && movedLines == 14, "moved to a binder Alex isn't in: Alex doesn't see it, and its 14 lines went with it")
        }
        let own = BinderRecord(name: "Just mine", colorIndex: 4)
        store.insert(own)
        store.move(meeting, to: own)
        _ = await bed.eventually(5) { content.state.meetings[meeting.id]?.withdrawn == true }
        _ = await mac.drained()
        let erased = try await root.json("""
            SELECT json_build_object('deleted', (SELECT deleted_at IS NOT NULL FROM binders.meetings WHERE id = $1::uuid),
                'title', (SELECT title FROM binders.meetings WHERE id = $1::uuid),
                'summary', (SELECT summary FROM binders.meetings WHERE id = $1::uuid),
                'words', (SELECT count(*) FROM binders.meeting_segments WHERE meeting_id = $1::uuid AND text <> ''))::text
            """, [meeting.id.uuidString.lowercased()])
        bed.check(erased["deleted"]?.bool == true && erased["title"]?.string == "" && erased["summary"]?.string == "" && erased["words"]?.int == 0,
                  "moved to your own binder: off the team, its words erased in the database (\(erased.text))")
        if let shared = store.binder(bed.shared) {
            store.move(meeting, to: shared)
            _ = await bed.eventually(5) { content.state.meetings[meeting.id]?.withdrawn == false && content.state.meetings[meeting.id]?.digest != nil }
            _ = await mac.drained()
            row = try await alex.rows(.meetings, ids: [meeting.id]).first
            let back = try await alex.rows(.meetingSegments, binder: bed.shared)
                .filter { $0["meeting_id"]?.uuid == meeting.id && $0["revision"]?.int == row?["transcript_revision"]?.int && $0.deletedAt == nil }
            bed.check(row?.deletedAt == nil && row?["title"]?.string == "Pricing review" && back.count == 5 && (row?["transcript_revision"]?.int ?? 0) >= 2,
                      "moved back: Alex sees it again, its transcript as a new revision (\(row?["transcript_revision"]?.int ?? -1), \(back.count) lines)")
        }
        // Alex deletes theirs: it goes from here.
        _ = try await alex.call(.withdrawItem(theirs, from: .meetings))
        let dropped = await bed.eventually(5) { copy == nil && store.segments(for: theirs).isEmpty }
        bed.check(dropped, "Alex takes their meeting off the team: it goes from this Mac, its transcript with it")

        // MARK: MCP: a teammate's meeting for what may read teammates' items, its transcript for what may read transcripts.
        let theirsNow = UUID()
        _ = try await alex.call(.putItem(TeamMeetingValues(id: theirsNow, binder: bed.shared, title: "Standup", started: Date(), status: "ready")
            .row(capture: false), in: .meetings))
        _ = try await alex.call(.put(rows: TeamTranscript.rows([TranscriptSegment(channel: .microphone, start: 0, end: 2, text: "Shipping Friday.")],
                                                               item: theirsNow, binder: bed.shared, revision: 0, after: 0, capture: false), in: .meetingSegments))
        _ = await bed.eventually(5) { !store.segments(for: theirsNow).isEmpty }
        try await meetingReads(bed, mac: mac, teammates: theirsNow, mine: meeting.id)

        // MARK: Captures.
        try await captureChecks(bed, mac: mac, alex: alex, root: root)
        await mac.stop()
    }

    /// list_meetings and get_meeting as a tool sees them.
    @MainActor
    private static func meetingReads(_ bed: TeamDBTestBed, mac: TeamMac, teammates: UUID, mine: UUID) async throws {
        func call(_ tool: String, _ arguments: [String: Any], reads: MCPServer.Reads) async -> (ok: Bool, text: String) {
            do {
                return (true, try await MCPServer.call(tool, arguments, knowledge: mac.controller.knowledge, write: MCPServer.writeInApp(controller: mac.controller),
                                                       actor: BoardActor(name: "Claude Code", kind: .agent), reads: reads, host: "Claude Code"))
            } catch {
                return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription)
            }
        }
        let none = MCPServer.Reads(captures: false, transcripts: false, team: false)
        let team = MCPServer.Reads(captures: false, transcripts: false, team: true)
        let listedMine = TeamMac.list((await call("list_meetings", [:], reads: none)).text)
        bed.check(listedMine.contains { $0["id"] as? String == mine.uuidString } && !listedMine.contains { $0["id"] as? String == teammates.uuidString },
                  "list_meetings, for a tool that may not read teammates' items: yours, not Alex's")
        let listedTeam = TeamMac.list((await call("list_meetings", [:], reads: team)).text)
        bed.check(listedTeam.first { $0["id"] as? String == teammates.uuidString }?["author"] as? String == "Alex",
                  "for one that may: Alex's too, saying whose")
        let refused = await call("get_meeting", ["id": teammates.uuidString], reads: none)
        bed.check(!refused.ok && refused.text.contains("Teammates' items"), "get_meeting refuses Alex's to the first: \(refused.text.prefix(60))")
        let withheld = TeamMac.object((await call("get_meeting", ["id": teammates.uuidString, "include_transcript": true], reads: team)).text)
        bed.check(withheld["author"] as? String == "Alex" && (withheld["transcript"] as? String ?? "x").isEmpty && withheld["transcript_note"] != nil,
                  "and to the second without its transcript, which it may not read")
        let full = TeamMac.object((await call("get_meeting", ["id": teammates.uuidString, "include_transcript": true],
                                              reads: MCPServer.Reads(captures: false, transcripts: true, team: true))).text)
        bed.check((full["transcript"] as? String)?.contains("Shipping Friday.") == true, "with transcripts allowed, its transcript")
        // The iPhone is you, through this Mac: it lists Alex's meeting as this Mac shows it.
        let phone = TeamMac.list((try? await MCPServer.call("list_meetings", [:], knowledge: mac.controller.knowledge,
                                                             write: MCPServer.writeInApp(controller: mac.controller), actor: .you)) ?? "[]")
        bed.check(phone.first { $0["id"] as? String == teammates.uuidString }?["author"] as? String == "Alex", "the iPhone lists Alex's meeting, Alex's")
    }
}

extension TeamContent {
    /// For the self-tests: whether a meeting reads as live to a tool.
    static func teamKeysLive(_ meeting: MeetingRecord?) -> Bool {
        meeting.map { MCPServer.teamKeys($0, in: [:])["live"] as? Bool == true } ?? false
    }
}
