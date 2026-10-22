import Foundation
import SwiftData
import PostgresNIO
import BindersKit

extension TeamDBTestBed {
    /// Waits until a condition that reads the database holds, or `timeout` passes.
    func until(_ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

extension SelfTest {
    /// Captures and the team database: one goes only when you put it in a shared binder yourself, or choose Share It on
    /// it there; never one in your own binders, never its audio; the rule holds through edits, moves and a restart; a new
    /// capture never lands in a shared binder by itself, and the router never files one there.
    @MainActor
    static func captureChecks(_ bed: TeamDBTestBed, mac: TeamMac, alex: TeamDatabase, root: TeamDatabaseLink) async throws {
        let store = Store.shared
        var content: TeamContent { mac.team.content }
        func captures() async throws -> [TeamRow] {
            try await root.json("SELECT coalesce(json_agg(to_jsonb(c)), '[]')::text FROM binders.captures c").array?.compactMap(\.object) ?? []
        }
        func lines(of id: UUID) async throws -> [TeamRow] {
            try await root.json("SELECT coalesce(json_agg(to_jsonb(s)), '[]')::text FROM binders.capture_segments s WHERE capture_id = $1::uuid",
                                [id.uuidString.lowercased()]).array?.compactMap(\.object) ?? []
        }
        /// A capture the iPhone heard, written up and filed, with its recording kept on this Mac.
        func capture(_ title: String, in binder: UUID, said: [String]) -> MeetingRecord {
            let record = MeetingRecord(title: title, appName: "iPhone", templateID: MeetingTemplate.conversation.id)
            record.kind = MeetingRecord.conversationKind
            record.binderID = binder
            record.status = "ready"
            record.summary = "Notes on \(title.lowercased())."
            record.duration = Double(said.count * 4)
            record.speakerNames = ["Speaker 2": "Robin"]
            record.micAudioFile = "capture-\(UUID().uuidString).m4a"
            record.soloJSON = ""
            store.insert(record)
            store.replaceSegments(for: record.id, with: said.enumerated().map { index, text in
                TranscriptSegment(channel: .microphone, start: Double(index * 4), end: Double(index * 4) + 3, text: text,
                                  speaker: index % 2 == 0 ? "You" : "Speaker 2")
            })
            return record
        }
        func settle() async {
            try? await Task.sleep(for: .milliseconds(500))
            _ = await mac.drained()
        }
        let own = BinderRecord(name: "Own captures", colorIndex: 5)
        store.insert(own)
        guard let shared = store.binder(bed.shared) else { return bed.check(false, "the shared binder is here") }

        // MARK: In your own binder: never leaves.
        let dentist = capture("Coffee with the dentist", in: own.id, said: ["The cleaning is on Tuesday.", "Bring the old x-rays."])
        await settle()
        bed.check(try await captures().isEmpty, "a capture in your own binder never leaves this Mac")

        // MARK: In the shared binder already (filed there before it was shared): kept on this Mac until Share It.
        let hallway = capture("Hallway chat about the booth", in: bed.shared, said: ["The booth is in hall B.", "Stand 12, near the café.",
                                                                                     "Badges come on Monday."])
        await settle()
        bed.check(try await captures().isEmpty && content.isKeptHere(hallway), "one that was in the shared binder before stays on this Mac, with Share It")
        content.share(hallway)
        let shown = await bed.eventually(5) { content.state.captures[hallway.id]?.digest != nil }
        _ = await mac.drained()
        var row = try await alex.rows(.captures, ids: [hallway.id]).first
        bed.check(shown && row?["owner_id"]?.uuid == bed.samID && row?["kept"]?.bool == true && row?["title"]?.string == "Hallway chat about the booth"
                  && row?["summary"]?.string == "Notes on hallway chat about the booth." && row?["speaker_names"]?["Speaker 2"]?.string == "Robin",
                  "Share It: Alex sees it, yours, kept, with its notes and who spoke")
        var said = try await alex.rows(.captureSegments, binder: bed.shared).filter { $0["capture_id"]?.uuid == hallway.id }
        bed.check(said.count == 3, "and its transcript: \(said.count) lines")
        let wire = TeamJSON.array([.object(row ?? [:])] + said.map { .object($0) }).text
        bed.check(!wire.contains(".m4a") && !wire.contains(hallway.micAudioFile ?? "?"), "never its recording: no file of it in any row")

        // MARK: Moved in by you: it goes.
        store.move(dentist, to: shared)
        let movedIn = await bed.eventually(5) { content.state.captures[dentist.id]?.digest != nil }
        _ = await mac.drained()
        let movedRows = try await alex.rows(.captures, ids: [dentist.id]).count
        bed.check(movedIn && movedRows == 1, "a capture you move into the shared binder goes")

        // MARK: Edits: a shared one's go, a private one's never.
        let insurance = capture("Phone call about insurance", in: own.id, said: ["The claim number is on the letter."])
        insurance.summary = "Edited here, still mine."
        hallway.summary = "The booth is in hall B, stand 12."
        store.save()
        _ = await bed.until(5) { (try? await alex.rows(.captures, ids: [hallway.id]).first?["summary"]?.string) == "The booth is in hall B, stand 12." }
        await settle()
        row = try await alex.rows(.captures, ids: [hallway.id]).first
        bed.check(row?["summary"]?.string == "The booth is in hall B, stand 12.", "an edit to a shared capture goes")
        bed.check(try await captures().count == 2, "an edit to one in your own binder doesn't: still 2 in the team database")

        // MARK: Hidden as small talk: not kept.
        dentist.status = "trivial"
        store.save()
        let hidden = await bed.until(5) { (try? await alex.rows(.captures, ids: [dentist.id]).first?["kept"]?.bool) == false }
        bed.check(hidden, "one Binders hides as small talk says so: not kept")

        // MARK: A restart: the rule holds, and nothing goes twice.
        let before = try await root.json("SELECT json_agg(json_build_object('id', id, 'at', updated_at) ORDER BY id)::text FROM binders.captures").text
        let lineCount = try await root.value("SELECT count(*) FROM binders.capture_segments", as: Int64.self) ?? -1
        await mac.team.stop()
        mac.team.run(bed.sam)
        let back = await bed.eventually(30) { mac.team.isConnected && mac.team.directory.myName == "Sam" }
        try await Task.sleep(for: .seconds(1))
        _ = await mac.drained()
        let after = try await root.json("SELECT json_agg(json_build_object('id', id, 'at', updated_at) ORDER BY id)::text FROM binders.captures").text
        let lineCountAfter = try await root.value("SELECT count(*) FROM binders.capture_segments", as: Int64.self) ?? -2
        bed.check(back && after == before && lineCountAfter == lineCount,
                  "after a restart: the same 2 captures, untouched, and the same \(lineCount) lines; nothing sent again")
        bed.check(content.isShared(hallway) && content.isShared(dentist) && !content.isShared(insurance), "and the same ones shared")
        insurance.summary = "Edited again after the restart."
        store.save()
        await settle()
        bed.check(try await captures().count == 2, "one in your own binder still never leaves")

        // MARK: Moved out: off the team, its words erased; back in by you, it's shared again.
        store.move(hallway, to: own)
        let out = await bed.eventually(5) { content.state.captures[hallway.id]?.withdrawn == true }
        _ = await mac.drained()
        let tomb = try await root.json("SELECT to_jsonb(c)::text FROM binders.captures c WHERE id = $1::uuid", [hallway.id.uuidString.lowercased()])
        let words = try await lines(of: hallway.id).filter { ($0["text"]?.string ?? "") != "" }
        bed.check(out && tomb["deleted_at"]?.isNull == false && tomb["title"]?.string == "" && tomb["summary"]?.string == "" && words.isEmpty
                  && !content.state.shared.contains(hallway.id), "moved to your own binder: off the team, its words and transcript erased there")
        let gone = try await alex.rows(.captures, ids: [hallway.id]).first?.deletedAt != nil
        bed.check(gone, "and Alex's Mac learns it's gone")
        store.move(hallway, to: shared)
        let again = await bed.eventually(5) { content.state.captures[hallway.id]?.withdrawn == false && content.state.captures[hallway.id]?.digest != nil }
        _ = await mac.drained()
        row = try await alex.rows(.captures, ids: [hallway.id]).first
        said = try await alex.rows(.captureSegments, binder: bed.shared)
            .filter { $0["capture_id"]?.uuid == hallway.id && $0["revision"]?.int == row?["transcript_revision"]?.int }
        bed.check(again && row?.deletedAt == nil && row?["title"]?.string == "Hallway chat about the booth" && said.count == 3,
                  "moved back in by you: shared again, with its transcript")

        // MARK: New captures never land in a shared binder by themselves, and the router never files one there.
        let conversations = mac.controller.conversations
        conversations.model = { nil }
        AppSettings.shared.currentBinderID = bed.shared
        let heard = ConversationPayload(started: Date().addingTimeInterval(-120), ended: Date(), segments: [
            TranscriptSegment(channel: .microphone, start: 0, end: 3, text: "Let's move the launch review to Thursday.", speaker: "You")],
                                        device: "iPhone", engine: "self-test")
        _ = conversations.receive(heard)
        let landed = content.meeting(heard.id)
        bed.check(landed != nil && landed?.binderID != bed.shared, "a capture that arrives while the shared binder is open lands in one of yours")
        AppSettings.shared.currentBinderID = nil
        let booth = capture("Talk about the booth stand", in: own.id, said: ["The stand needs a second screen."])
        conversations.model = { StandInModel(reply: "BINDER: Shared\nREASON: It's about the booth.") }
        await conversations.route(booth)
        bed.check(booth.binderID == own.id, "the router never files a capture into a shared binder")
        conversations.model = { nil }
        await settle()
        bed.check(try await captures().count == 2, "neither reaches the team")

        // MARK: A teammate's capture: theirs here, read-only; for a tool, only with captures and teammates' items allowed.
        let theirs = UUID()
        let values = TeamMeetingValues(id: theirs, binder: bed.shared, title: "Supplier call", started: Date(), duration: 180, app: "iPhone",
                                       summary: "The supplier ships on the 4th.", status: "ready")
        _ = try await alex.call(.putItem(values.row(capture: true), in: .captures))
        _ = try await alex.call(.put(rows: TeamTranscript.rows([TranscriptSegment(channel: .microphone, start: 0, end: 4, text: "We ship on the 4th.",
                                                                                  speaker: "Speaker 2")],
                                                               item: theirs, binder: bed.shared, revision: 0, after: 0, capture: true), in: .captureSegments))
        let copied = await bed.eventually(5) { content.meeting(theirs).map { $0.isTeamCopy && $0.isConversation } == true && !store.segments(for: theirs).isEmpty }
        bed.check(copied && content.meeting(theirs)?.teamAuthorName == "Alex", "Alex's shared capture shows here as Alex's, read-only")
        func call(_ arguments: [String: Any], reads: MCPServer.Reads) async -> (ok: Bool, text: String) {
            do {
                return (true, try await MCPServer.call("list_meetings", arguments, knowledge: mac.controller.knowledge,
                                                       write: MCPServer.writeInApp(controller: mac.controller),
                                                       actor: BoardActor(name: "Claude Code", kind: .agent), reads: reads, host: "Claude Code"))
            } catch {
                return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription)
            }
        }
        let noCaptures = await call(["kind": "capture"], reads: MCPServer.Reads(captures: false, transcripts: false, team: true))
        bed.check(!noCaptures.ok && noCaptures.text.contains("Captures"), "list_meetings refuses captures to a tool that may not read them")
        let noTeam = TeamMac.list((await call(["kind": "capture"], reads: MCPServer.Reads(captures: true, transcripts: false, team: false))).text)
        bed.check(!noTeam.contains { $0["id"] as? String == theirs.uuidString }, "and leaves Alex's out for one that may not read teammates' items")
        let both = TeamMac.list((await call(["kind": "capture"], reads: .everything)).text)
        bed.check(both.first { $0["id"] as? String == theirs.uuidString }?["author"] as? String == "Alex", "with both allowed, it's there, Alex's")
        _ = try await alex.call(.putItem(["id": TeamJSON(theirs), "kept": false, "status": "trivial"], in: .captures))
        let notKept = await bed.eventually(5) { content.meeting(theirs)?.status == "trivial" }
        bed.check(notKept, "Alex hides it as small talk: hidden here too")
    }
}
