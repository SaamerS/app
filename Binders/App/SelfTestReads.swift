import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// What a tool connected over MCP may read: no captures, meeting transcripts or teammates' items until Settings → MCP
    /// allows them for it. In a throwaway folder (BINDERS_DATA_DIR) only.
    @MainActor
    static func mcpReadsSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes meetings and notes")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let store = Store.shared
        let binder = store.defaultBinder()

        let meeting = MeetingRecord(title: "Harbor pricing review", appName: "Zoom", templateID: "general")
        meeting.status = "ready"
        meeting.binderID = binder.id
        meeting.summary = "## Summary\nThe team agreed on the Harbor price list.\n\n- [ ] Send the price list"
        store.insert(meeting)
        store.replaceSegments(for: meeting.id, with: [
            TranscriptSegment(channel: .microphone, start: 12, end: 18, text: "The lighthouse tier stays at nine dollars.", speaker: "You"),
        ])
        let capture = MeetingRecord(title: "Hallway chat about the venue", appName: "iPhone", templateID: "conversation")
        capture.kind = MeetingRecord.conversationKind
        capture.status = "ready"
        capture.binderID = binder.id
        capture.summary = "## Summary\nA chat about the quayside venue.\n\n- [ ] Call the quayside venue"
        store.insert(capture)
        let shared = NoteItem(text: "# Teammate's budget\n\nThe marquee costs more than planned.")
        shared.binderID = binder.id
        shared.isTeamCopy = true
        shared.teamAuthorName = "Maya"
        store.insert(shared)
        let mine = NoteItem(text: "# My launch plan\n\nThe marquee goes up on Friday.")
        mine.binderID = binder.id
        store.insert(mine)
        store.save()
        let knowledge = KnowledgeService()
        await knowledge.indexNow()

        func call(_ tool: String, _ arguments: [String: Any], reads: MCPServer.Reads) async -> (ok: Bool, text: String) {
            do {
                let text = try await MCPServer.call(tool, arguments, knowledge: knowledge, write: { _, _ in "{}" },
                                                    actor: BoardActor(name: "Claude Code", kind: .agent), reads: reads, host: "Claude Code")
                return (true, text)
            } catch {
                return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription)
            }
        }
        let nothing = MCPServer.Reads(captures: false, transcripts: false, team: false)

        // Nothing allowed: the default for every tool.
        let refused = await call("list_meetings", ["kind": "capture"], reads: nothing)
        check(!refused.ok && refused.text.contains("Settings → MCP"), "captures can't be listed: \(refused.text)")
        let all = await call("list_meetings", ["kind": "all"], reads: nothing)
        check(all.text.contains("Harbor pricing review") && !all.text.contains("Hallway chat"), "all meetings leaves the capture out")
        check(!(await call("get_meeting", ["id": capture.id.uuidString], reads: nothing)).ok, "a capture can't be opened")
        let withTranscript = await call("get_meeting", ["id": meeting.id.uuidString, "include_transcript": true], reads: nothing)
        check(withTranscript.ok && !withTranscript.text.contains("lighthouse tier") && withTranscript.text.contains("transcript_note"),
              "a meeting comes with its notes and without its transcript, saying why")
        let notes = await call("list_notes", [:], reads: nothing)
        check(notes.text.contains("My launch plan") && !notes.text.contains("Teammate's budget"), "a teammate's note isn't listed")
        check(!(await call("get_note", ["id": shared.id.uuidString], reads: nothing)).ok, "and can't be opened")
        let todos = await call("list_todos", [:], reads: nothing)
        check(todos.text.contains("Send the price list") && !todos.text.contains("quayside"), "the capture's to-do isn't listed")
        let search = await call("search_knowledge", ["query": "marquee venue lighthouse quayside"], reads: nothing)
        check(search.ok && search.text.contains("My launch plan") && !search.text.contains("Teammate") && !search.text.contains("quayside")
              && !search.text.contains("lighthouse"), "search finds your note, and no capture, transcript or teammate's note")
        check(!(await call("search_knowledge", ["query": "venue", "kind": "capture"], reads: nothing)).ok, "searching captures is refused")

        // Allowed in Settings → MCP, for Claude Code, including a particular form of its name.
        let keys = [MCPServer.captureReaders, MCPServer.transcriptReaders, MCPServer.teamReaders]
        for key in keys { MCPServer.ReadGrants.set(["Claude Code"], key) }
        let allowed = MCPServer.reads(for: "Claude Code · binders-io/app")
        check(allowed == .everything && MCPServer.reads(for: "Cursor") == nothing, "allowances are per tool: \(allowed)")
        // Kept in the Keychain: what a script writes to the app's settings changes nothing.
        for key in keys { MCPServer.ReadGrants.set([], key); AppDefaults.store.set(["Cursor"], forKey: key) }
        check(MCPServer.reads(for: "Cursor") == nothing, "a script writing the app's settings can't widen what a tool reads")
        for key in keys { AppDefaults.store.removeObject(forKey: key) }
        check(MCPServer.reads(for: "Claude Code") == nothing, "and off again once unticked")
        check((await call("get_meeting", ["id": capture.id.uuidString], reads: allowed)).ok, "an allowed tool opens the capture")
        let transcript = await call("get_meeting", ["id": meeting.id.uuidString, "include_transcript": true], reads: allowed)
        check(transcript.text.contains("lighthouse tier"), "and reads the transcript")
        check((await call("list_notes", [:], reads: allowed)).text.contains("Teammate's budget"), "and sees teammates' notes")

        print(failures == 0 ? "MCP_READS_OK" : "MCP_READS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
