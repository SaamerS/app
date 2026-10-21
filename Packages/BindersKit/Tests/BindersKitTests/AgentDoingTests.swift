import XCTest
@testable import BindersKit

final class AgentDoingTests: XCTestCase {
    private let session = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

    // Fixtures in the shapes Claude Code writes them, with made-up values.

    /// `~/.claude/tasks/<session>/2.json`, as TaskCreate and TaskUpdate leave it.
    private let taskInProgress = #"""
        {"id":"2","subject":"Fix the footer link","description":"The privacy link points at the old page.","activeForm":"Fixing the footer link","status":"in_progress","blocks":[],"blockedBy":["1"]}
        """#
    /// One with an owner and metadata, and no activeForm.
    private let taskPending = #"""
        {"id":"3","subject":"Run the tests","description":"","owner":"tester","status":"pending","blocks":[],"blockedBy":["2"],"metadata":{"source":"plan"}}
        """#

    private func task(_ json: String) -> AgentDoing.ClaudeTask? { AgentDoing.ClaudeTask(json: Data(json.utf8)) }

    func testATaskAsClaudeCodeWritesIt() throws {
        let fixing = try XCTUnwrap(task(taskInProgress))
        XCTAssertEqual(fixing, AgentDoing.ClaudeTask(id: "2", subject: "Fix the footer link", activeForm: "Fixing the footer link", status: "in_progress"))
        XCTAssertTrue(fixing.inProgress)
        let tests = try XCTUnwrap(task(taskPending))
        XCTAssertNil(tests.activeForm)
        XCTAssertFalse(tests.inProgress)
        XCTAssertNil(task("3"), "the list's .highwatermark isn't a task")
        XCTAssertNil(task(#"{"id":"4","subject":"Half"#), "nor is a file half written")
        XCTAssertNil(task(#"{"id":"5","status":"pending"}"#), "nor one without its subject")
    }

    func testTheLineIsTheTaskInProgressAsItsSaidWhileDoingIt() throws {
        let tasks = [try XCTUnwrap(task(taskPending)), try XCTUnwrap(task(taskInProgress))]
        XCTAssertEqual(AgentDoing.claudeLine(tasks: tasks), "Fixing the footer link")
        let plain = [AgentDoing.ClaudeTask(id: "7", subject: "Update the changelog", status: "in_progress")]
        XCTAssertEqual(AgentDoing.claudeLine(tasks: plain), "Update the changelog", "its subject without an activeForm")
        XCTAssertEqual(AgentDoing.claudeLine(tasks: [AgentDoing.ClaudeTask(id: "1", subject: "Check it", activeForm: " \n ", status: "in_progress")]),
                       "Check it", "a blank activeForm falls back to the subject")
        // Ids are numbers: "2" was made before "10".
        let two = [AgentDoing.ClaudeTask(id: "10", subject: "Later", activeForm: "Doing the later one", status: "in_progress"),
                   AgentDoing.ClaudeTask(id: "2", subject: "Earlier", activeForm: "Doing the earlier one", status: "in_progress")]
        XCTAssertEqual(AgentDoing.current(two)?.id, "2")
        XCTAssertNil(AgentDoing.current([AgentDoing.ClaudeTask(id: "1", subject: "Done", status: "completed")]))
    }

    /// Only the task list says it: with no task in progress there's no line, as nothing else of Claude Code's is read (its
    /// session's title is only the name Binders gave the run, and finding its record means reading every session's).
    func testWithNoTaskInProgressThereIsNoLine() throws {
        XCTAssertNil(AgentDoing.claudeLine(tasks: [AgentDoing.ClaudeTask(id: "1", subject: "Read the card", activeForm: "Reading the card", status: "completed"),
                                                   try XCTUnwrap(task(taskPending))]))
        XCTAssertNil(AgentDoing.claudeLine(tasks: []), "nothing to say is nothing")
        XCTAssertNil(AgentDoing.claudeLine(tasks: [AgentDoing.ClaudeTask(id: "1", subject: " ", activeForm: "\u{200B}", status: "in_progress")]),
                     "nor a task with no words")
    }

    func testTheLineIsOnePlainShortLine() {
        XCTAssertEqual(AgentDoing.clean("Running   the\ttests\nfor the [footer](https://evil.example/x) and ![logo](a.png)"),
                       "Running the tests for the footer and logo")
        XCTAssertEqual(AgentDoing.clean("Reading [the docs][1] at <https://example.test/docs>"), "Reading the docs at")
        XCTAssertEqual(AgentDoing.clean("Fixing\u{202E}txt.exe\u{202C} and \u{200B}spacing\u{0007}"), "Fixingtxt.exe and spacing")
        XCTAssertEqual(AgentDoing.clean("One\u{2028}line"), "One line")
        XCTAssertNil(AgentDoing.clean(" \n\t "))
        XCTAssertNil(AgentDoing.clean("\u{200B}\u{FEFF}"))
        let long = AgentDoing.clean(String(repeating: "Refactoring the payment module ", count: 8))
        XCTAssertEqual(long?.count, AgentDoing.limit)
        XCTAssertEqual(long?.hasSuffix("…"), true)
        XCTAssertEqual(AgentDoing.clean(String(repeating: "a", count: AgentDoing.limit)), String(repeating: "a", count: AgentDoing.limit), "120 is kept whole")
        XCTAssertEqual(AgentDoing.clean("Running" + String(repeating: " ", count: 2_000) + "the tests"), "Running the tests", "a run of spaces is one")
    }

    /// A character with marks piled on it counts as one, and draws over the lines around it: it keeps a few.
    func testMarksDontPileUpOnACharacter() throws {
        let piled = try XCTUnwrap(AgentDoing.clean(String(repeating: "e" + String(repeating: "\u{0301}", count: 2_000), count: 40)))
        XCTAssertEqual(piled.count, 40)
        XCTAssertEqual(piled.unicodeScalars.count, 40 * (1 + AgentDoing.markLimit), "the accented e, and three more marks on each")
        XCTAssertTrue(piled.allSatisfy { $0.unicodeScalars.count <= 1 + AgentDoing.markLimit })
        // Strings that look the same compare equal, so these compare what's in them.
        func scalars(_ text: String?) -> [UInt32] { text?.unicodeScalars.map(\.value) ?? [] }
        XCTAssertEqual(scalars(AgentDoing.clean("a" + String(repeating: "\u{0300}", count: 10_000) + " done")), scalars("\u{00E0}\u{0300}\u{0300}\u{0300} done"))
        // Real text keeps its marks: accents written apart are joined to their letter, and a stack of three stays whole.
        XCTAssertEqual(scalars(AgentDoing.clean("Đang kie\u{0302}\u{0309}m tra")), scalars("Đang ki\u{1EC3}m tra"))
        let stacked = "\u{0F56}\u{0F66}\u{0F92}\u{0FB2}\u{0F74}\u{0F56}\u{0F66}"
        XCTAssertEqual(scalars(AgentDoing.clean(stacked)), scalars(stacked))
        // However many go into one character, the line is never more than a line's worth of characters and their marks.
        let joined = try XCTUnwrap(AgentDoing.clean(String(repeating: "\u{1100}", count: 5_000)))
        XCTAssertLessThanOrEqual(joined.unicodeScalars.count, AgentDoing.limit * (1 + AgentDoing.markLimit) + 1)
        XCTAssertTrue(joined.hasSuffix("…"), "cut, and it says so")
        XCTAssertLessThanOrEqual(joined.count, AgentDoing.limit)
    }

    func testALineThatOnlySaysTheCardsTitleAgainIsLeftOut() {
        XCTAssertNil(AgentDoing.line("Fix the footer link.", for: "Fix the footer link"))
        XCTAssertEqual(AgentDoing.line("Fixing the footer link", for: "Fix the footer link"), "Fixing the footer link")
        XCTAssertNil(AgentDoing.line(nil, for: "Anything"))
    }

    func testTheReceiptNamesTheSession() {
        let receipt = "Started Claude Code in /Users/sam/code/app/.claude/worktrees/binders-3f2504e0 (acceptEdits, made ready for it). To look in: claude --resume \(session) there."
        XCTAssertEqual(AgentDoing.session(inReceipt: receipt), session)
        XCTAssertEqual(AgentDoing.session(inReceipt: receipt.uppercased().replacingOccurrences(of: "CLAUDE --RESUME", with: "claude --resume")), session,
                       "in lowercase")
        let folder = "Started Claude Code in /tmp/claude --resume 00000000-0000-0000-0000-000000000000 x (plan, Wake Now). To look in: claude --resume \(session) there."
        XCTAssertEqual(AgentDoing.session(inReceipt: folder), session, "the last one, after the folder")
        XCTAssertNil(AgentDoing.session(inReceipt: "Woke Pennant with its command (made ready for it)."))
        XCTAssertNil(AgentDoing.session(inReceipt: "To look in: claude --resume not-a-session there."))
    }

    func testOnlyTheRunBindersStartedForTheAgentHoldingTheCard() {
        let receipt = AgentDoing.Entry(kind: "woke", author: "Claude Code · app", byAgent: true,
                                       text: "Started Claude Code in /r/.claude/worktrees/binders-3f2504e0 (plan, made ready for it). To look in: claude --resume \(session) there.")
        let claimed = AgentDoing.Entry(kind: "claimed", author: "Claude Code · app", byAgent: true, from: "ready", to: "in_progress")
        let started = [AgentDoing.Entry(kind: "created", author: "You", byAgent: false, to: "ready"), receipt, claimed]
        XCTAssertEqual(AgentDoing.runSession(timeline: started, holder: "Claude Code · app", column: .inProgress), session)
        XCTAssertNil(AgentDoing.runSession(timeline: started, holder: "Claude Code · app", column: .review), "only while it's in progress")
        XCTAssertNil(AgentDoing.runSession(timeline: started, holder: "Pennant", column: .inProgress), "only for the agent it woke")
        XCTAssertNil(AgentDoing.runSession(timeline: [started[0], claimed], holder: "Claude Code · app", column: .inProgress),
                     "a card Binders woke no run for has none")
        let progress = AgentDoing.Entry(kind: "progress", author: "Claude Code · app", byAgent: true, text: "claude --resume 11111111-2222-3333-4444-555555555555")
        let comment = AgentDoing.Entry(kind: "comment", author: "You", byAgent: false, text: "Keep it small.")
        XCTAssertEqual(AgentDoing.runSession(timeline: started + [progress, comment], holder: "Claude Code · app", column: .inProgress), session,
                       "an agent's words and your comment change nothing")
        let commandWake = AgentDoing.Entry(kind: "woke", author: "Claude Code · app", byAgent: true, text: "Woke Claude Code · app with its command (Wake Now).")
        XCTAssertNil(AgentDoing.runSession(timeline: started + [commandWake], holder: "Claude Code · app", column: .inProgress),
                     "a later wake that names no session leaves none")
        // You answered or sent it back: that wakes a newer run, which has a receipt of its own.
        let answered = AgentDoing.Entry(kind: "answer", author: "You", byAgent: false, text: "Tuesday.", from: "blocked", to: "in_progress")
        XCTAssertNil(AgentDoing.runSession(timeline: started + [answered], holder: "Claude Code · app", column: .inProgress))
        let sentBack = AgentDoing.Entry(kind: "moved", author: "You", byAgent: false, text: "Sent back to Claude Code · app.", from: "review", to: "in_progress")
        XCTAssertNil(AgentDoing.runSession(timeline: started + [sentBack], holder: "Claude Code · app", column: .inProgress))
        // You took it over, which stops its run, or it went quiet until the card lapsed: that run is over.
        let takenOver = AgentDoing.Entry(kind: "claimed", author: "You", byAgent: false, text: "Took it over from Claude Code · app.",
                                         from: "in_progress", to: "in_progress")
        XCTAssertNil(AgentDoing.runSession(timeline: started + [takenOver, claimed], holder: "Claude Code · app", column: .inProgress),
                     "given back after you took it over, the stopped run's words don't come back")
        let lapsed = AgentDoing.Entry(kind: "lapsed", author: "Claude Code · app", byAgent: true, from: "in_progress", to: "ready")
        XCTAssertNil(AgentDoing.runSession(timeline: started + [lapsed, claimed], holder: "Claude Code · app", column: .inProgress))
        XCTAssertTrue(Set(AgentDoing.runKinds).isSuperset(of: Set(started.map(\.kind) + [takenOver, lapsed, answered, sentBack].map(\.kind))))
        let newer = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let again = AgentDoing.Entry(kind: "woke", author: "Claude Code · app", byAgent: true,
                                     text: "Started Claude Code in /r/.claude/worktrees/binders-3f2504e0 (plan, you answered). To look in: claude --resume \(newer) there.")
        XCTAssertEqual(AgentDoing.runSession(timeline: started + [answered, again], holder: "Claude Code · app", column: .inProgress), newer)
    }

    /// "Claude Code" is the name your own Claude Code session goes by on the boards; the agent Binders starts runs for is
    /// "Claude Code · app". Holding the card after the run let it go, your session isn't saying what the run said.
    func testAShorterNameIsSomeoneElse() {
        let receipt = AgentDoing.Entry(kind: "woke", author: "Claude Code · app", byAgent: true,
                                       text: "Started Claude Code in /r/.claude/worktrees/binders-3f2504e0 (plan, made ready for it). To look in: claude --resume \(session) there.")
        let created = AgentDoing.Entry(kind: "created", author: "You", byAgent: false, to: "ready")
        let claimed = AgentDoing.Entry(kind: "claimed", author: "Claude Code · app", byAgent: true, from: "ready", to: "in_progress")
        let started = [created, receipt, claimed]
        XCTAssertEqual(AgentDoing.runSession(timeline: started, holder: " claude code · APP", column: .inProgress), session, "the same name, whatever its case")
        let released = AgentDoing.Entry(kind: "released", author: "Claude Code · app", byAgent: true, from: "in_progress", to: "ready")
        let yours = AgentDoing.Entry(kind: "claimed", author: "Claude Code", byAgent: true, from: "ready", to: "in_progress")
        XCTAssertNil(AgentDoing.runSession(timeline: started + [released, yours], holder: "Claude Code", column: .inProgress))
        XCTAssertNil(AgentDoing.runSession(timeline: started, holder: "Claude Code · app · laptop", column: .inProgress), "nor is a longer one")
        // Given back to the agent with no wake, the card isn't that run's any more: another agent had it meanwhile.
        let yoursReleased = AgentDoing.Entry(kind: "released", author: "Claude Code", byAgent: true, from: "in_progress", to: "ready")
        XCTAssertNil(AgentDoing.runSession(timeline: started + [released, yours, yoursReleased, claimed], holder: "Claude Code · app", column: .inProgress))
        // Its own letting go and taking it again leave it the run's.
        XCTAssertEqual(AgentDoing.runSession(timeline: started + [released, claimed], holder: "Claude Code · app", column: .inProgress), session)
    }

    /// What a run says goes only to a phone that keeps it out of its saved copy of work_streams: this build, not an older one.
    func testOnlyThisPhoneIsSentWhatARunSays() {
        XCTAssertTrue(LinkFeatures.thisPhone.contains(LinkFeatures.workStreamsDoing))
        XCTAssertFalse(LinkFeatures.phone(nil).contains(LinkFeatures.workStreamsDoing), "iPhone 2.0 lists nothing")
        XCTAssertFalse(LinkFeatures.phone(LinkFeatures.thisPhone.filter { $0 != LinkFeatures.workStreamsDoing }).contains(LinkFeatures.workStreamsDoing))
    }
}

final class WorkStreamsDoingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ title: String, _ who: String, doing: String? = nil, minutesAgo: Double = 10) -> WorkStreams.Card {
        WorkStreams.Card(title: title, binder: "Harbor launch", column: .inProgress, assignee: who, assigneeIsAgent: who != "You",
                         updated: now.addingTimeInterval(-minutesAgo * 60), doing: doing)
    }

    func testTheDigestSaysWhatARunIsDoingAsItsWords() {
        let digest = WorkStreams.digest([
            card("Fix the footer link", "Claude Code", doing: "Running the tests", minutesAgo: 1),
            card("Draft the changelog post", "Codex", minutesAgo: 2),
            card("Update the pricing table", "Codex", doing: "Checking the annual plans", minutesAgo: 3),
            card("Rewrite the status page", "You"),
        ], now: now)
        XCTAssertEqual(digest.streams.first { $0.who == "Claude Code" }?.doing, [WorkStreams.Doing(card: "Fix the footer link", line: "Running the tests")])
        XCTAssertEqual(digest.streams.first { $0.who == "Codex" }?.doing, [WorkStreams.Doing(card: "Update the pricing table", line: "Checking the annual plans")])
        XCTAssertEqual(digest.streams.first { $0.who == "You" }?.doing, [])
        let summary = digest.summary
        XCTAssertTrue(summary.contains("Claude Code is working on “Fix the footer link” and says: Running the tests."), summary)
        XCTAssertTrue(summary.contains("Codex is working on 2 cards: “Draft the changelog post” and “Update the pricing table”. On “Update the pricing table”, it says: Checking the annual plans."), summary)
        XCTAssertTrue(summary.contains("You are working on “Rewrite the status page”."), summary)
        XCTAssertFalse(digest.headline.contains("Running the tests") || digest.headline.contains("annual plans"), "the headline never carries an agent's words: \(digest.headline)")
        let quiet = WorkStreams.digest([card("Fix the footer link", "Claude Code", minutesAgo: 1)], now: now)
        let saying = WorkStreams.digest([card("Fix the footer link", "Claude Code", doing: "Running the tests", minutesAgo: 1)], now: now)
        XCTAssertNotEqual(quiet, saying, "a new line is a new digest, so the pages showing it draw it")
        XCTAssertEqual(quiet.headline, saying.headline)
        XCTAssertEqual(quiet.summary, "Claude Code is working on “Fix the footer link”.")
        XCTAssertTrue(WorkStreams.digest([card("Ship it", "Claude Code", doing: "Is it done?")], now: now).summary.hasSuffix("and says: Is it done?"))
    }

    func testWithoutWhatRunsSaidTheDigestIsTheSameOtherwise() {
        let saying = WorkStreams.digest([card("Fix the footer link", "Claude Code", doing: "Running the tests", minutesAgo: 1), card("Book the venue", "You")], now: now)
        XCTAssertTrue(saying.saysWhatRunsAreDoing)
        let quiet = saying.withoutDoing
        XCTAssertFalse(quiet.saysWhatRunsAreDoing)
        XCTAssertEqual(quiet, WorkStreams.digest([card("Fix the footer link", "Claude Code", minutesAgo: 1), card("Book the venue", "You")], now: now))
        XCTAssertEqual(quiet.headline, saying.headline)
        XCTAssertFalse(quiet.summary.contains("Running the tests"), quiet.summary)
    }

    func testTheIPhoneReadsAStreamFromAnOldMacAndANewOne() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // A Mac before 0.8.1 says nothing of doing.
        let old = try decoder.decode([WorkStreams.Working].self, from: Data(#"[{"who":"Claude Code","agent":true,"cards":["Fix the footer link"]}]"#.utf8))
        XCTAssertEqual(old, [WorkStreams.Working(who: "Claude Code", agent: true, cards: ["Fix the footer link"])])
        XCTAssertNil(old.first?.doing)
        let new = try decoder.decode([WorkStreams.Working].self, from: Data(#"""
            [{"who":"Claude Code","agent":true,"cards":["Fix the footer link"],"doing":[{"card":"Fix the footer link","line":"Running the tests"}],"later":1}]
            """#.utf8))
        XCTAssertEqual(new.first?.doing, [WorkStreams.Doing(card: "Fix the footer link", line: "Running the tests")], "and a key it doesn't know is left alone")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkStreams.Doing(card: "A", line: "B"))) as? [String: String]
        XCTAssertEqual(encoded, ["card": "A", "line": "B"])
    }

    func testTheIPhoneKeepsTheDigestWithoutWhatRunsSaid() throws {
        let reply = #"""
            {"headline":"Claude Code on 1 card.","summary":"Claude Code is working on “Fix the footer link” and says: Running the tests.","by_binder":[],
             "working":[{"who":"Claude Code","agent":true,"cards":["Fix the footer link"],"doing":[{"card":"Fix the footer link","line":"Running the tests"}]},
                        {"who":"You","agent":false,"cards":["Book the venue"]}],
             "questions":[],"reviews":[],"waiting_to_start":[],"done_today":[]}
            """#
        let kept = WorkStreams.keepable(reply)
        XCTAssertFalse(kept.contains("Running the tests") || kept.contains(#""doing""#) || kept.contains(#""summary""#), kept)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        struct Shown: Decodable { let headline: String; let working: [WorkStreams.Working]; let doneToday: [String] }
        let shown = try decoder.decode(Shown.self, from: Data(kept.utf8))
        XCTAssertEqual(shown.headline, "Claude Code on 1 card.")
        XCTAssertEqual(shown.working, [WorkStreams.Working(who: "Claude Code", agent: true, cards: ["Fix the footer link"]),
                                       WorkStreams.Working(who: "You", agent: false, cards: ["Book the venue"])])
        let quiet = #"{"headline":"You on 1 card.","summary":"You are working on “Book the venue”.","working":[{"who":"You","agent":false,"cards":["Book the venue"]}]}"#
        XCTAssertEqual(WorkStreams.keepable(quiet), quiet, "a reply with nothing a run said is kept as it came")
        XCTAssertEqual(WorkStreams.keepable("not json"), "not json")
    }
}

/// What a Codex, OpenCode or GitHub Copilot CLI run Binders started says it's doing: from its own output in Binders' log,
/// found through the card's receipt and its links.
final class AgentDoingCLITests: XCTestCase {
    private let card = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let logs = "/Users/sam/Library/Logs/Binders/Agents"

    func testEachToolsPlanIsItsLine() {
        let codex = #"{"type":"item.updated","item":{"id":"item_0","type":"todo_list","items":[{"text":"Read the card","completed":true},{"text":"Running   the\ttests","completed":false}]}}"#
        XCTAssertEqual(AgentDoing.cliLine(codex, tool: .codex), "Running the tests", "cleaned to one plain line")
        let opencode = #"{"type":"tool_use","sessionID":"ses_1","part":{"type":"tool","tool":"todowrite","state":{"status":"completed","input":{"todos":[{"content":"Fixing the [footer](https://x.example) link","status":"in_progress","priority":"high"}]}}}}"#
        XCTAssertEqual(AgentDoing.cliLine(opencode, tool: .opencode), "Fixing the footer link")
        let copilot = #"{"type":"tool.execution_start","data":{"toolName":"report_intent","arguments":{"intent":"Reading the card"}}}"#
        XCTAssertEqual(AgentDoing.cliLine(copilot, tool: .copilot), "Reading the card")
        XCTAssertNil(AgentDoing.cliLine("", tool: .codex))
        XCTAssertNil(AgentDoing.cliLine(copilot, tool: .codex), "each tool's own shape only")
    }

    func testTheRunsOwnLogAmongTheCardsLinks() {
        let mine = "file://\(logs)/3f2504e0-20261018T120000.jsonl", later = "file://\(logs)/3f2504e0-20261018T130000Z.jsonl"
        XCTAssertEqual(AgentDoing.runLog(links: [mine, "https://github.com/acme/app/pull/12", later], card: card, logs: logs),
                       "\(logs)/3f2504e0-20261018T130000Z.jsonl", "the last one")
        XCTAssertNil(AgentDoing.runLog(links: ["file://\(logs)/16fd2706-20261018T120000.jsonl"], card: card, logs: logs), "another card's")
        XCTAssertNil(AgentDoing.runLog(links: ["file:///Users/sam/elsewhere/3f2504e0-20261018T120000.jsonl"], card: card, logs: logs), "another folder's")
        XCTAssertNil(AgentDoing.runLog(links: ["file://\(logs)/../Agents/x/3f2504e0-1.jsonl"], card: card, logs: logs))
        XCTAssertNil(AgentDoing.runLog(links: ["https://example.test\(logs)/3f2504e0-20261018T120000.jsonl"], card: card, logs: logs), "not a file")
        XCTAssertNil(AgentDoing.runLog(links: ["file://\(logs)/3f2504e0-20261018T120000.log"], card: card, logs: logs), "a command's log")
        XCTAssertEqual(AgentDoing.runLog(links: ["file://\(logs)/3f2504e0-2026.jsonl", "file://\(logs)/3f2504e0-x;rm.jsonl"], card: card, logs: logs),
                       "\(logs)/3f2504e0-2026.jsonl")
    }

    func testTheReceiptSaysWhichToolStarted() {
        XCTAssertEqual(AgentDoing.cliRun(inReceipt: "Started Codex in ~/.binders/worktrees/app-1/binders-x-codex (workspace sandbox, no network; made ready for it)."), .codex)
        XCTAssertEqual(AgentDoing.cliRun(inReceipt: "Your note first. Started OpenCode in ~/.binders/worktrees/app-1/binders-x-opencode (…)."), .opencode)
        XCTAssertEqual(AgentDoing.cliRun(inReceipt: "Started GitHub Copilot CLI in ~/.binders/x (…)."), .copilot)
        XCTAssertNil(AgentDoing.cliRun(inReceipt: "Started Claude Code in /Users/sam/app/.claude/worktrees/binders-3f2504e0 (plan, made ready for it)."))
        XCTAssertNil(AgentDoing.cliRun(inReceipt: "Woke Echo with its command (made ready for it)."))
    }

    func testTheRunIsOnUntilSomethingEndsIt() {
        func entry(_ kind: String, _ author: String, agent: Bool, _ text: String = "", to: String? = nil) -> AgentDoing.Entry {
            AgentDoing.Entry(kind: kind, author: author, byAgent: agent, text: text, to: to)
        }
        let receipt = entry("woke", "Codex · app", agent: true, "Started Codex in ~/.binders/x (workspace sandbox, no network; made ready for it).")
        let timeline = [entry("created", "You", agent: false, to: "ready"), receipt, entry("claimed", "Codex · app", agent: true, to: "in_progress")]
        XCTAssertEqual(AgentDoing.runReceipt(timeline: timeline, holder: "Codex · app", column: .inProgress), receipt)
        XCTAssertNil(AgentDoing.runReceipt(timeline: timeline, holder: "Codex", column: .inProgress), "exactly its name")
        XCTAssertNil(AgentDoing.runReceipt(timeline: timeline, holder: "Codex · app", column: .blocked), "only while it's in progress")
        XCTAssertNil(AgentDoing.runReceipt(timeline: timeline + [entry("claimed", "You", agent: false)], holder: "Codex · app", column: .inProgress),
                     "you took it over")
        XCTAssertNil(AgentDoing.runSession(timeline: timeline, holder: "Codex · app", column: .inProgress), "no Claude session in it")
    }
}
