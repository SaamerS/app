import XCTest
@testable import BindersKit

/// How agents report back: the report halves in agents.json, the MCP entries, status addresses, the states, and what a
/// Claude Code run's hooks put on its card.
final class AgentReportTests: XCTestCase {
    private let card = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let binders = "/Applications/Binders.app/Contents/MacOS/Binders"

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func report(_ json: String) throws -> AgentProfile.Report {
        try XCTUnwrap(JSONDecoder().decode([AgentProfile.Report].self, from: Data("[\(json)]".utf8)).first)
    }

    private func written(_ report: AgentProfile.Report) throws -> Any {
        let data = try JSONEncoder().encode([report])
        return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [Any])?.first)
    }

    // MARK: The report half in agents.json

    func testEachWayOfReportingReadsLikeWhatItIs() throws {
        XCTAssertEqual(try written(.mcp) as? String, "mcp", "as the word it always was")
        XCTAssertEqual(try written(.manual) as? String, "manual")
        XCTAssertEqual(try written(.ssh(host: "sam@studio.local")) as? NSDictionary, ["ssh": ["host": "sam@studio.local"]] as NSDictionary)
        XCTAssertEqual(try written(.status(url: "https://agent.example.test/status")) as? NSDictionary,
                       ["status": ["url": "https://agent.example.test/status"]] as NSDictionary)
        XCTAssertEqual([AgentProfile.Report.mcp, .ssh(host: "h"), .status(url: "u"), .manual].map(\.kind), ["mcp", "ssh", "status", "manual"])
        XCTAssertEqual([AgentProfile.Report.mcp, .ssh(host: "h"), .status(url: "u"), .manual].map(\.usesTools), [true, true, false, false])
        for each in [AgentProfile.Report.mcp, .manual, .ssh(host: "sam@studio.local"), .status(url: "https://agent.example.test/status")] {
            XCTAssertEqual(try JSONDecoder().decode([AgentProfile.Report].self, from: JSONEncoder().encode([each])), [each])
        }
    }

    func testAWayOfReportingThisVersionDoesntKnowReadsAsMCP() throws {
        XCTAssertEqual(try report(#"{"pigeon": {"loft": 3}}"#), .mcp)
        XCTAssertEqual(try report(#"{"ssh": {"port": 22}}"#), .mcp, "ssh with no host")
        XCTAssertEqual(try report(#"{"ssh": {"host": "a"}, "status": {"url": "b"}}"#), .mcp, "two ways at once")
        XCTAssertEqual(try report(#""ssh""#), .mcp, "a word for a way that has fields")
        XCTAssertEqual(try report(#"{}"#), .mcp)
        XCTAssertEqual(try report("null"), .mcp)
        XCTAssertEqual(try report(#"{"status": {"url": "https://x.test", "every": 5}}"#), .status(url: "https://x.test"), "extra fields are left alone")
    }

    func testHowAnAgentReportsInPractice() {
        let claude = AgentProfile.Wake.claudeCode(ClaudeCodeWake(repository: "/r"))
        XCTAssertEqual(AgentProfile(name: "C", wake: claude, report: .manual).reporting, .mcp, "Claude Code reports with the tools and its hooks")
        XCTAssertEqual(AgentProfile(name: "C", wake: claude, report: .status(url: "https://x.test")).reporting, .mcp)
        XCTAssertEqual(AgentProfile(name: "B", wake: .board, report: .status(url: "https://x.test")).reporting, .mcp, "checking the board takes the tools")
        XCTAssertEqual(AgentProfile(name: "B", wake: .board, report: .manual).reporting, .mcp)
        XCTAssertEqual(AgentProfile(name: "B", wake: .board, report: .ssh(host: "h")).reporting, .ssh(host: "h"))
        XCTAssertEqual(AgentProfile(name: "W", wake: .webhook(url: "https://x.test"), report: .status(url: "https://x.test/s")).reporting,
                       .status(url: "https://x.test/s"))
        XCTAssertEqual(AgentProfile(name: "S", wake: .shortcut(name: "File"), report: .manual).reporting, .manual)
    }

    /// An agent saved by 0.8.0 reads and saves byte for byte the same, so its fingerprint in the Keychain still matches and
    /// it doesn't show as changed outside Binders.
    func testAnAgentFromBeforeSavesTheSame() throws {
        let file = AgentFile(agents: [
            AgentProfile(id: card, name: "Echo", wake: .command(command: "echo hi")),
            AgentProfile(id: UUID(uuidString: "16FD2706-8BAF-433B-82EB-8C7FADA847DA")!, name: "Filer", wake: .shortcut(name: "File card"), report: .manual),
        ])
        let data = try file.encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""report" : "mcp""#) && text.contains(#""report" : "manual""#), text)
        XCTAssertEqual(try AgentFile.decode(data).file.encoded(), data)
        let before = #"{"agents":[{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","isEnabled":true,"name":"Echo","report":"mcp","wake":{"command":{"command":"echo hi"}}}],"paused":false}"#
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(try AgentFile.decode(Data(before.utf8)).file), as: UTF8.self), before)
    }

    // MARK: MCP entries

    func testTheEntryOnThisMacIsTheBoardsToolsAsTheAgent() {
        XCTAssertEqual(AgentMCPEntry.json(AgentMCPEntry.local(binders: binders, agent: "Pennant")),
                       #"{"args":["--mcp"],"command":"/Applications/Binders.app/Contents/MacOS/Binders","env":{"BINDERS_AGENT":"Pennant","BINDERS_TOOLS":"board"}}"#)
    }

    func testTheEntryForAnotherMachineRunsTheSameServerHereOverSSH() throws {
        let entry = AgentMCPEntry.ssh(binders: binders, agent: "Pennant", host: " sam@studio.local ")
        XCTAssertEqual(entry["command"] as? String, "ssh")
        XCTAssertEqual(entry["args"] as? [String], ["-T", "-o", "BatchMode=yes", "sam@studio.local",
                                                    "env BINDERS_AGENT='Pennant' BINDERS_TOOLS=board '/Applications/Binders.app/Contents/MacOS/Binders' --mcp"])
        XCTAssertNil(entry["env"], "the variables go with the command, to this Mac")
        // A name with quotes, spaces and $ is the agent's name on this Mac's shell, never anything it runs.
        XCTAssertEqual(AgentMCPEntry.remoteCommand(binders: "/Users/sam/My Apps/Binders.app/Contents/MacOS/Binders", agent: "Sam's $(bot) `x`"),
                       #"env BINDERS_AGENT='Sam'\''s $(bot) `x`' BINDERS_TOOLS=board '/Users/sam/My Apps/Binders.app/Contents/MacOS/Binders' --mcp"#)
        let json = AgentMCPEntry.json(entry)
        XCTAssertTrue(json.hasPrefix(#"{"args":["-T","-o","BatchMode=yes","sam@studio.local","env BINDERS_AGENT="#), json)
        XCTAssertEqual(try object(Data(json.utf8))["command"] as? String, "ssh")
    }

    func testOnlyAHostGoesToSSH() {
        for host in ["studio.local", "sam@studio.local", "studio", "100.101.102.103", "sam@mac-mini.tail1234.ts.net", "[fe80::1%en0]", "fe80::1", "ünïcode.local"] {
            XCTAssertTrue(AgentMCPEntry.isHost(host), host)
        }
        for host in ["", " ", "-oProxyCommand=touch pwned", "sam@-oProxyCommand=x", "studio local", "studio;rm", "$(whoami).local", "'studio'",
                     "sam@", "@studio", "a@b@c", "studio\nlocal", "studio/22", String(repeating: "a", count: 256)] {
            XCTAssertFalse(AgentMCPEntry.isHost(host), host)
        }
        XCTAssertEqual(AgentMCPEntry.quoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(AgentMCPEntry.quoted(""), "''")
    }

    // MARK: States

    func testEachColumnHasItsState() {
        XCTAssertEqual(TaskState(column: .ready, questionWaiting: false), .submitted)
        XCTAssertEqual(TaskState(column: .inProgress, questionWaiting: false), .working)
        XCTAssertEqual(TaskState(column: .blocked, questionWaiting: true), .inputRequired)
        XCTAssertEqual(TaskState(column: .blocked, questionWaiting: false), .failed, "blocked with a reason")
        XCTAssertEqual(TaskState(column: .review, questionWaiting: false), .completed)
        XCTAssertEqual(TaskState(column: .done, questionWaiting: false), .completed)
        XCTAssertEqual(TaskState(column: .backlog, questionWaiting: false), .canceled)
        XCTAssertEqual(TaskState(column: .inProgress, questionWaiting: true), .working, "a question counts only in Blocked")
        XCTAssertEqual(TaskState.allCases.map(\.rawValue), ["submitted", "working", "input_required", "completed", "failed", "canceled"])
    }

    func testBlockedIsAQuestionOnlyWhileOneWaits() {
        let asked: [(kind: String, to: String)] = [("created", "ready"), ("claimed", "in_progress"), ("question", "blocked")]
        XCTAssertEqual(TaskState(column: .blocked, timeline: asked), .inputRequired)
        let stopped: [(kind: String, to: String)] = [("created", "ready"), ("claimed", "in_progress"), ("moved", "blocked")]
        XCTAssertEqual(TaskState(column: .blocked, timeline: stopped), .failed, "a run that stopped, with its reason")
        let answeredThenBlocked = asked + [("answer", "in_progress"), ("moved", "blocked")]
        XCTAssertEqual(TaskState(column: .blocked, timeline: answeredThenBlocked), .failed, "an answered question isn't asking again")
        XCTAssertEqual(TaskState(column: .inProgress, timeline: asked + [("answer", "in_progress")]), .working)
    }

    func testAStatusIsReadLeniently() {
        let read: [String: TaskState] = ["working": .working, "WORKING": .working, "input-required": .inputRequired, "input_required": .inputRequired,
                                         "Input Required": .inputRequired, "auth-required": .inputRequired, "submitted": .submitted,
                                         "completed": .completed, "failed": .failed, "rejected": .failed, "canceled": .canceled, "cancelled": .canceled]
        for (word, state) in read { XCTAssertEqual(TaskState(loose: word), state, word) }
        for word in ["", "done", "unknown", "in progress", "ready", "paused"] { XCTAssertNil(TaskState(loose: word), word) }
    }

    // MARK: Status addresses

    func testWhatAStatusAddressAnswers() {
        XCTAssertEqual(AgentStatusReply(Data(#"{"state": "working", "note": "  Drafted the intro.  "}"#.utf8)),
                       AgentStatusReply(state: .working, note: "Drafted the intro."))
        XCTAssertEqual(AgentStatusReply(Data(#"{"state": "input-required", "note": "Which logo?", "progress": 40}"#.utf8))?.state, .inputRequired)
        XCTAssertEqual(AgentStatusReply(Data(#"{"state": "completed"}"#.utf8)), AgentStatusReply(state: .completed))
        XCTAssertEqual(AgentStatusReply(Data(#"{"status": {"state": "failed", "message": "The build broke."}}"#.utf8)),
                       AgentStatusReply(state: .failed, note: "The build broke."), "A2A's shape")
        XCTAssertEqual(AgentStatusReply(Data(#"{"state": "working", "message": "Halfway."}"#.utf8))?.note, "Halfway.")
        for text in ["", "working", "[]", #"{"state": "napping"}"#, #"{"note": "no state"}"#, #"{"state": 3}"#, "<html>"] {
            XCTAssertNil(AgentStatusReply(Data(text.utf8)), text)
        }
        let long = AgentStatusReply(state: .completed, note: String(repeating: "a", count: 5_000))
        XCTAssertEqual(long.note.count, AgentStatusReply.noteLimit)
        XCTAssertTrue(long.note.hasSuffix("…"))
    }

    func testAskingAboutACard() throws {
        let request = try XCTUnwrap(AgentStatusReply.request("https://agent.example.test/status?team=7&card=old", card: card, token: " s3cret "))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://agent.example.test/status?team=7&card=3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer s3cret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.httpBody)
        let plain = try XCTUnwrap(AgentStatusReply.request("http://127.0.0.1:8123/", card: card, token: nil))
        XCTAssertEqual(plain.url?.query, "card=3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertNil(plain.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(AgentStatusReply.request("http://127.0.0.1/", card: card, token: "  ")?.value(forHTTPHeaderField: "Authorization"))
        for address in ["", "ftp://agent.example.test/", "file:///etc/hosts", "agent.example.test/status", "https://", "javascript:alert(1)"] {
            XCTAssertNil(AgentStatusReply.request(address, card: card, token: nil), address)
            XCTAssertFalse(AgentStatusReply.isAddress(address), address)
        }
        XCTAssertTrue(AgentStatusReply.isAddress("https://agent.example.test/status"))
    }

    // MARK: A Claude Code run's hooks

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func assistant(_ id: String, _ blocks: [[String: Any]], sidechain: Bool = false) -> String {
        line(["type": "assistant", "isSidechain": sidechain, "message": ["id": id, "role": "assistant", "content": blocks]])
    }

    func testStopSaysWhatTheRunSaidLast() throws {
        let input = Data(line(["session_id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8", "hook_event_name": "Stop", "stop_hook_active": false,
                               "transcript_path": "/never/read", "last_assistant_message": "  Fixed the typo and committed it on binders-3f2504e0.  "]).utf8)
        let report = try XCTUnwrap(AgentRunReport.make(.stop, input: input) { _ in XCTFail("the message came with the hook"); return nil })
        XCTAssertEqual(report.session, "6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        XCTAssertEqual(report.text, "Fixed the typo and committed it on binders-3f2504e0.")
    }

    func testWithoutTheMessageStopReadsTheTranscript() throws {
        let transcript = [
            #"{"type":"user","message":{"role":"user","content":"Binders woke you for one card."}}"#,
            assistant("msg_1", [["type": "text", "text": "Reading the card."], ["type": "tool_use", "name": "get_task", "input": [:] as [String: Any]]]),
            line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "…"]]]]),
            assistant("msg_2", [["type": "thinking", "thinking": "Hmm."]]),
            assistant("msg_2", [["type": "text", "text": "I couldn't find the file the card names."]]),
            assistant("msg_2", [["type": "text", "text": "I asked on the card which one it is."]]),
            assistant("msg_3", [["type": "text", "text": "A subagent's last word."]], sidechain: true),
            assistant("msg_4", [["type": "tool_use", "name": "ask_on_task", "input": [:] as [String: Any]]]),
            #"{"type":"summary","summary":"Card work"}"#,
            #"{"type":"assist"#,
        ].joined(separator: "\n")
        XCTAssertEqual(AgentRunReport.lastAssistantText(in: Data(transcript.utf8)), "I couldn't find the file the card names.\n\nI asked on the card which one it is.")
        let input = Data(line(["session_id": "abc", "transcript_path": "~/.claude/projects/x/abc.jsonl"]).utf8)
        var asked: String?
        let report = AgentRunReport.make(.stop, input: input) { path in asked = path; return Data(transcript.utf8) }
        XCTAssertEqual(asked, "~/.claude/projects/x/abc.jsonl")
        XCTAssertEqual(report?.text, "I couldn't find the file the card names.\n\nI asked on the card which one it is.")
        // Read from the middle of a file: the cut first line is passed over.
        let tail = String(transcript.dropFirst(30))
        XCTAssertEqual(AgentRunReport.lastAssistantText(in: Data(tail.utf8)), "I couldn't find the file the card names.\n\nI asked on the card which one it is.")
        XCTAssertNil(AgentRunReport.lastAssistantText(in: Data(#"{"type":"user","message":{"content":"hi"}}"#.utf8)))
        XCTAssertEqual(AgentRunReport.lastAssistantText(in: Data(#"{"type":"assistant","message":{"content":"Plain words."}}"#.utf8)), "Plain words.")
    }

    func testNothingToSayIsNoReport() {
        XCTAssertNil(AgentRunReport.make(.stop, input: Data(#"{"session_id":"a","last_assistant_message":"  "}"#.utf8)) { _ in nil })
        XCTAssertNil(AgentRunReport.make(.stop, input: Data(#"{"session_id":"a","transcript_path":"/gone"}"#.utf8)) { _ in nil })
        XCTAssertNil(AgentRunReport.make(.stop, input: Data()) { _ in nil })
        XCTAssertNil(AgentRunReport.make(.sessionEnd, input: Data("not json".utf8)) { _ in nil }, "not a hook's JSON")
    }

    func testSessionEndSaysWhy() {
        XCTAssertEqual(AgentRunReport.make(.sessionEnd, input: Data(#"{"session_id":"s","hook_event_name":"SessionEnd","reason":"other"}"#.utf8)) { _ in nil }?.text,
                       "Session ended (other)")
        XCTAssertEqual(AgentRunReport.make(.sessionEnd, input: Data(#"{"session_id":"s","reason":"prompt_input_exit"}"#.utf8)) { _ in nil }?.text,
                       "Session ended (prompt_input_exit)")
        let plain = AgentRunReport.make(.sessionEnd, input: Data("{}".utf8)) { _ in nil }
        XCTAssertEqual(plain?.text, "Session ended (other)")
        XCTAssertEqual(plain?.session, "")
        XCTAssertEqual(AgentRunReport.Hook.allCases.map(\.rawValue), ["stop", "session-end"])
    }

    func testALongMessageIsCutAtAWord() {
        let words = Array(repeating: "lorem", count: 200).joined(separator: " ")
        let cut = AgentRunReport.trimmed(words)
        XCTAssertLessThanOrEqual(cut.count, AgentRunReport.limit + 1)
        XCTAssertGreaterThan(cut.count, AgentRunReport.limit - 10)
        XCTAssertTrue(cut.hasSuffix("lorem…"), String(cut.suffix(12)))
        let unbroken = String(repeating: "x", count: 900)
        XCTAssertEqual(AgentRunReport.trimmed(unbroken), String(repeating: "x", count: 600) + "…", "no word to cut at")
        XCTAssertEqual(AgentRunReport.trimmed("  short  "), "short")
        XCTAssertEqual(AgentRunReport.trimmed("one two three", limit: 9), "one two…")
    }

    func testTheRunHasItsHooksAndItsCardInItsEnvironment() throws {
        let launch = ClaudeCodeLaunch.make(card: card, reason: .ready, boardName: "Claude Code · app", wake: ClaudeCodeWake(repository: "/r"),
                                           binders: "/Users/sam/My Apps/Binders.app/Contents/MacOS/Binders", dataFolder: "/d", home: "/Users/sam",
                                           worktreeExists: false, session: UUID())
        XCTAssertEqual(launch.environment, ["BINDERS_CARD": card.uuidString, "BINDERS_AGENT": "Claude Code · app"])
        let index = try XCTUnwrap(launch.arguments.firstIndex(of: "--settings")) + 1
        let hooks = try XCTUnwrap(try object(Data(launch.arguments[index].utf8))["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["Stop", "SessionEnd"])
        func command(_ event: String) throws -> [String: Any] {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(groups.count, 1)
            XCTAssertNil(groups[0]["matcher"])
            return try XCTUnwrap((groups[0]["hooks"] as? [[String: Any]])?.first)
        }
        let stop = try command("Stop"), end = try command("SessionEnd")
        XCTAssertEqual(stop["type"] as? String, "command")
        XCTAssertEqual(stop["command"] as? String, "'/Users/sam/My Apps/Binders.app/Contents/MacOS/Binders' --agent-hook stop")
        XCTAssertEqual(end["command"] as? String, "'/Users/sam/My Apps/Binders.app/Contents/MacOS/Binders' --agent-hook session-end")
        XCTAssertEqual(stop["timeout"] as? Int, 30)
        XCTAssertEqual(end["timeout"] as? Int, 15)
        // Nothing from the card in a hook's command: the card comes from the environment.
        XCTAssertFalse(launch.arguments[index].contains("Claude Code · app"))
    }
}
