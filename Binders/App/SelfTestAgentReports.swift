import Foundation
import BindersKit

extension SelfTest {
    /// How agents report back, through the same tools agents and the phone use: each card's state in A2A / MCP Tasks words,
    /// the report halves (SSH, a status address, moving cards yourself), a Give to that wakes at once, and a Claude Code run
    /// (a stand-in for claude that the test writes) whose hooks report on its card once, and whose unfinished run leaves the
    /// card in Blocked with why. In a throwaway folder (BINDERS_DATA_DIR) only.
    @MainActor
    static func agentReportsSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards and agents")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        let board = controller.board
        let dispatcher = controller.agents
        let registry = AgentRegistry.shared
        let write = MCPServer.writeInApp(controller: controller)
        let folder = AppPaths.support
        let manager = FileManager.default
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func json(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
        func made(_ text: String) -> UUID { ((json(text) as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID() }
        func card(_ id: UUID) -> TaskCard? { board.card(id) }
        func events(_ id: UUID) -> [TaskEvent] { board.timeline(id) }
        func woke(_ id: UUID) -> Int { events(id).filter { $0.kind == .woke }.count }
        func lines(_ file: String) -> [String] {
            ((try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func state(_ id: UUID) async -> String {
            ((json(await call("get_task", ["id": id.uuidString], as: .you).text) as? [String: Any])?["state"] as? String) ?? "none"
        }
        Store.shared.insert(BinderRecord(name: "Launch", colorIndex: 2))
        let helper = BoardActor(name: "Helper", kind: .agent)

        // a) Each card's state, in A2A and MCP Tasks words, beside its column.
        let waiting = made(await call("create_task", ["title": "Order the banners", "binder": "Launch", "column": "ready"], as: .you).text)
        let later = made(await call("create_task", ["title": "Sketch the poster", "binder": "Launch", "column": "backlog"], as: .you).text)
        let submitted = await state(waiting), canceled = await state(later)
        check(submitted == "submitted" && canceled == "canceled", "Ready is submitted and Backlog canceled: \(submitted), \(canceled)")
        _ = await call("claim_task", ["id": waiting.uuidString], as: helper)
        check(await state(waiting) == "working", "In progress is working")
        _ = await call("ask_on_task", ["id": waiting.uuidString, "question": "Which size?"], as: helper)
        check(await state(waiting) == "input_required", "Blocked with a question is input_required")
        _ = await call("comment_task", ["id": waiting.uuidString, "text": "The big ones."], as: .you)
        _ = await call("update_task", ["id": waiting.uuidString, "column": "blocked", "progress": "The printer is out of ink."], as: helper)
        check(await state(waiting) == "failed", "Blocked with a reason is failed")
        _ = await call("complete_task", ["id": waiting.uuidString, "summary": "Ordered."], as: helper)
        check(await state(waiting) == "completed", "Review is completed")
        let listed = (json(await call("list_tasks", ["binder": "Launch"], as: .you).text) as? [[String: Any]]) ?? []
        let keys: Set = ["id", "title", "column", "assignee", "assignee_is_agent", "claim_expires", "binder", "due", "links", "updated", "preview",
                         "todo", "meant_for", "meant_for_confirmed", "state"]
        check(listed.count == 2 && listed.allSatisfy { Set($0.keys) == keys }, "list_tasks keeps its keys and adds state: \(listed.first.map { $0.keys.sorted() } ?? [])")
        check(listed.first { $0["id"] as? String == waiting.uuidString }?["column"] as? String == "review"
              && listed.first { $0["id"] as? String == waiting.uuidString }?["state"] as? String == "completed", "and column is as it was")

        // b) Reporting from another machine over SSH: a host ssh can take, and the same tools as the agent, run here.
        check(registry.upsert(AgentProfile(name: "Remote", wake: .board, report: .ssh(host: "-oProxyCommand=touch pwned"))) != nil,
              "a host that's an option for ssh isn't saved")
        let remote = AgentProfile(name: "Remote", wake: .board, report: .ssh(host: "sam@studio.local"))
        check(registry.upsert(remote) == nil, "an agent on another machine is saved")
        let file = (try? String(contentsOf: folder.appendingPathComponent("agents.json"), encoding: .utf8)) ?? ""
        check(file.contains("\"host\" : \"sam@studio.local\""), "agents.json says where it reports from")
        check(registry.upsert(AgentProfile(name: "Pinger", wake: .board, report: .status(url: "https://status.example.test"))) != nil,
              "one that checks the board itself reports with the tools, not a status address")
        check(registry.upsert(AgentProfile(name: "Pinger", wake: .command(command: "true"), report: .status(url: "ftp://status.example.test"))) != nil,
              "a status address is http or https")
        let entry = AgentMCPEntry.ssh(binders: MCPHost.executable, agent: "Remote", host: "sam@studio.local")
        check((entry["args"] as? [String])?.last == "env BINDERS_AGENT='Remote' BINDERS_TOOLS=board '\(MCPHost.executable)' --mcp",
              "its MCP entry runs this Binders over ssh, as the agent, with the board's tools")
        // What ssh hands this Mac's login shell sets the variables, whatever the name.
        let printer = folder.appendingPathComponent("print-env")
        try? "#!/bin/sh\nprintf '%s|%s|%s' \"$BINDERS_AGENT\" \"$BINDERS_TOOLS\" \"$1\"\n".write(to: printer, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: printer.path)
        let shell = try? await AutomationService.runProcess("/bin/zsh", ["-c", AgentMCPEntry.remoteCommand(binders: printer.path, agent: "Sam's $(bot) `x`")],
                                                           stdin: nil, environment: nil, timeout: 20)
        check(shell?.stdout == "Sam's $(bot) `x`|board|--mcp", "the shell on this Mac reads the name as words: \(shell?.stdout ?? "nothing")")
        registry.remove(remote.id)

        // c) Give to is a hand-off: the agent is woken at once, not after the moment an edit waits.
        func commandAgent(_ name: String, report: AgentProfile.Report, log file: String) -> AgentProfile {
            AgentProfile(name: name, wake: .command(command: "printf 'WAKE %s %s\\n' \"$BINDERS_EVENT\" \"$BINDERS_CARD\" >> \(file); cat > /dev/null",
                                                    folder: folder.path), report: report, wakesPerHour: 30)
        }
        let quick = commandAgent("Quick", report: .mcp, log: "quick.txt")
        check(registry.upsert(quick) == nil, "an agent is saved")
        let given = made(await call("create_task", ["title": "Check the venue", "binder": "Launch", "column": "backlog"], as: .you).text)
        if let target = card(given) { board.give(target, to: "Quick", by: .you) }
        check(card(given)?.column == .ready && woke(given) == 1, "Give to wakes it at once: \(dispatcher.outcomes[given]?.message ?? "not yet")")
        if let target = card(given) { board.give(target, to: "Quick", by: .you) }
        check(woke(given) == 1, "and giving it again changes nothing, so wakes nothing")
        let edited = made(await call("create_task", ["title": "Print the badges", "binder": "Launch", "column": "ready"], as: .you).text)
        if let target = card(edited) { board.assign(target, to: "Quick", by: .you) }
        check(woke(edited) == 0, "an edit, the For menu, waits a moment first")
        for _ in 0..<40 where woke(edited) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        check(woke(edited) == 1, "then wakes it")
        // The iPhone's Give to: who it's for, then Ready, each a call of its own.
        let fromPhone = made(await call("create_task", ["title": "Book the photographer", "binder": "Launch", "column": "backlog"], as: .you).text)
        _ = await call("update_task", ["id": fromPhone.uuidString, "for": "Quick"], as: .you)
        check(woke(fromPhone) == 0, "the iPhone's Give to leaves a Backlog card asleep until it's Ready")
        _ = await call("update_task", ["id": fromPhone.uuidString, "column": "ready"], as: .you)
        check(woke(fromPhone) == 1, "and wakes it at once when it is")
        let suggested = made(await call("create_task", ["title": "Find a caterer", "binder": "Launch", "column": "ready", "for": "Quick"], as: helper).text)
        check(woke(suggested) == 0, "an agent's suggestion wakes nothing")
        for _ in 0..<30 where !lines("quick.txt").contains("WAKE ready \(fromPhone.uuidString)") { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(2200))
        check(lines("quick.txt").filter { $0.hasPrefix("WAKE ") }.count == 3 && woke(suggested) == 0, "three wakes in all: \(lines("quick.txt"))")

        // d) A status address: Binders holds the card for the agent and moves it as the address says.
        final class Answers: @unchecked Sendable {
            let lock = NSLock()
            var body = #"{"state": "working"}"#, code = 200, requests: [URLRequest] = []
        }
        let answers = Answers()
        dispatcher.fetch = { request in
            answers.lock.withLock {
                answers.requests.append(request)
                return (Data(answers.body.utf8), HTTPURLResponse(url: request.url!, statusCode: answers.code, httpVersion: nil, headerFields: nil)!)
            }
        }
        func answer(_ body: String, code: Int = 200) { answers.lock.withLock { answers.body = body; answers.code = code } }
        let bot = commandAgent("Status Bot", report: .status(url: "https://status.example.test/cards?team=7"), log: "status-bot.txt")
        check(registry.upsert(bot, statusToken: "tok-123") == nil && registry.statusToken(for: bot.id) == "tok-123", "an agent with a status address and its token is saved")
        let tracked = made(await call("create_task", ["title": "Design the flyer", "binder": "Launch", "column": "ready", "for": "Status Bot"], as: .you).text)
        let holding = card(tracked)
        check(holding?.column == .inProgress && holding?.assignee == "Status Bot" && holding?.assigneeIsAgent == true && holding?.claimExpiresAt != nil,
              "once it's woken, Binders holds the card for it, in progress, with a lease")
        check(events(tracked).contains { $0.kind == .claimed && $0.text.contains("status address") }, "and says so on the card")
        await dispatcher.askStatuses(now: Date())
        check(answers.requests.isEmpty, "a card just handed over isn't asked about yet")
        var clock = Date()
        func ask() async {
            clock = clock.addingTimeInterval(AgentDispatcher.statusInterval + 1)
            await dispatcher.askStatuses(now: clock)
        }
        func has(_ kind: TaskEvent.Kind, _ text: String, to column: BoardColumn? = nil) -> Bool {
            events(tracked).contains { $0.kind == kind && $0.text == text && $0.author == "Status Bot" && (column == nil || $0.toColumn == column?.rawValue) }
        }
        answer(#"{"state": "working", "note": "Drafted the headline."}"#)
        await ask()
        let request = answers.requests.last
        check(request?.httpMethod == "GET" && request?.url?.absoluteString == "https://status.example.test/cards?team=7&card=\(tracked.uuidString)"
              && request?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123", "it's asked with the card's id and its token: \(request?.url?.absoluteString ?? "no request")")
        check(card(tracked)?.column == .inProgress && has(.progress, "Drafted the headline."), "working, with a note, is its progress")
        let lineCount = events(tracked).count
        await ask()
        check(events(tracked).count == lineCount && card(tracked)?.column == .inProgress, "the same again adds nothing")
        answer("Bad gateway", code: 502)
        await ask()
        check(card(tracked)?.column == .inProgress && events(tracked).count == lineCount && dispatcher.outcomes[tracked]?.message.contains("502") == true,
              "an address that fails changes nothing, and the card says why: \(dispatcher.outcomes[tracked]?.message ?? "")")
        answer(#"{"state": "napping"}"#)
        await ask()
        check(dispatcher.outcomes[tracked]?.message.contains("didn't give a state") == true && card(tracked)?.column == .inProgress, "nor does a state Binders doesn't know")
        answer(#"{"state": "input-required", "note": "Round logo or square?"}"#)
        await ask()
        let asking = await state(tracked)
        check(card(tracked)?.column == .blocked && asking == "input_required" && has(.question, "Round logo or square?"), "input_required asks you, in Blocked: \(asking)")
        _ = await call("comment_task", ["id": tracked.uuidString, "text": "Round."], as: .you)
        check(card(tracked)?.column == .inProgress, "your answer sends it back to work")
        for _ in 0..<40 where !lines("status-bot.txt").contains("WAKE answered \(tracked.uuidString)") { try? await Task.sleep(for: .milliseconds(100)) }
        check(lines("status-bot.txt").contains("WAKE answered \(tracked.uuidString)"), "and wakes it with the answer")
        await ask()
        check(card(tracked)?.column == .inProgress && events(tracked).filter { $0.kind == .question }.count == 1,
              "a question it hasn't updated since your answer doesn't ask again")
        answer(#"{"state": "completed", "note": "Swapped in the round logo."}"#)
        await ask()
        let completed = await state(tracked)
        check(card(tracked)?.column == .review && has(.completed, "Swapped in the round logo.") && completed == "completed",
              "completed puts it in Review, with its summary: \(completed)")
        _ = await call("update_task", ["id": tracked.uuidString, "column": "in_progress"], as: .you)
        await ask()
        check(card(tracked)?.column == .inProgress, "sent back, a completed it hasn't updated doesn't finish it again")
        answer(#"{"state": "failed", "note": "The printer is offline."}"#)
        await ask()
        let failed = await state(tracked)
        check(card(tracked)?.column == .blocked && has(.moved, "The printer is offline.", to: .blocked) && failed == "failed", "failed is Blocked with why: \(failed)")
        _ = await call("comment_task", ["id": tracked.uuidString, "text": "Use the other printer."], as: .you)
        answer(#"{"status": {"state": "canceled"}, "message": "Nothing to print after all."}"#)
        await ask()
        let gone = await state(tracked)
        check(card(tracked)?.column == .backlog && card(tracked)?.assignee == nil && has(.moved, "Nothing to print after all.", to: .backlog) && gone == "canceled",
              "canceled is back in Backlog: \(gone)")
        let asked = answers.requests.count
        await ask()
        check(answers.requests.count == asked, "and nothing is asked about a card that isn't in progress")
        // Paused, a card held for it waits where it is: its address isn't asked and its claim is kept, past the 30 minutes
        // it would otherwise lapse in; once you resume, what the address says is read again.
        answer(#"{"state": "working"}"#)
        let flyer = made(await call("create_task", ["title": "Print the flyer", "binder": "Launch", "column": "ready", "for": "Status Bot"], as: .you).text)
        check(card(flyer)?.column == .inProgress && card(flyer)?.assignee == "Status Bot", "another card is held for it")
        registry.setPaused(true)
        let beforePause = answers.requests.count
        var paused = Date()
        for _ in 0..<35 {
            paused = paused.addingTimeInterval(2 * 60)
            await dispatcher.askStatuses(now: paused)
            board.sweep(now: paused)
        }
        check(card(flyer)?.column == .inProgress && card(flyer)?.assignee == "Status Bot" && !events(flyer).contains { $0.kind == .lapsed }
              && answers.requests.count == beforePause, "paused for 70 minutes, it stays in progress, held for it, and its address isn't asked")
        registry.setPaused(false)
        answer(#"{"state": "completed", "note": "Printed 200 flyers."}"#)
        clock = max(clock, paused)
        await ask()
        check(card(flyer)?.column == .review && events(flyer).contains { $0.kind == .completed && $0.text == "Printed 200 flyers." },
              "resumed, its address is asked again, and its completed puts the card in Review")
        registry.remove(bot.id)
        check(registry.statusToken(for: bot.id) == nil, "removing it takes its token from the Keychain")

        // e) Moving its cards yourself: held for it with no time limit, so they never lapse.
        let filer = commandAgent("Filer", report: .manual, log: "filer.txt")
        check(registry.upsert(filer) == nil, "an agent whose cards you move is saved")
        let filed = made(await call("create_task", ["title": "File the receipts", "binder": "Launch", "column": "ready", "for": "Filer"], as: .you).text)
        check(card(filed)?.column == .inProgress && card(filed)?.assignee == "Filer" && card(filed)?.claimExpiresAt == nil,
              "it's held for it in progress, with no lease")
        board.sweep(now: Date().addingTimeInterval(6 * 3_600))
        check(card(filed)?.column == .inProgress && card(filed)?.assignee == "Filer", "and doesn't lapse, hours later")
        _ = await call("update_task", ["id": filed.uuidString, "column": "review"], as: .you)
        _ = await call("update_task", ["id": filed.uuidString, "column": "in_progress"], as: .you)
        check(card(filed)?.assignee == "Filer" && card(filed)?.claimExpiresAt == nil, "sent back, it still has no lease")
        registry.remove(filer.id)

        // f) A Claude Code run: a stand-in for claude in the throwaway folder, which runs the hooks Binders gave it.
        let repository = folder.appendingPathComponent("fake-repo")
        try? manager.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let bin = folder.appendingPathComponent("bin")
        try? manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        let script = #"""
            #!/bin/sh
            # A stand-in for claude: notes what it was given, says something, runs the hooks it was given as Claude Code would, and stops.
            here="$(cd "$(dirname "$0")/.." && pwd)"
            settings=""; session=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --settings) settings="$2"; shift ;;
                --session-id) session="$2"; shift ;;
              esac
              shift
            done
            cat > /dev/null
            printf '%s|%s|%s\n' "$BINDERS_CARD" "$BINDERS_AGENT" "$session" > "$here/claude-env.txt"
            mode="$(cat "$here/claude-mode.txt")"
            printf '%s\n' '{"type":"result","result":"I could not reach the build server.","total_cost_usd":0.02,"num_turns":3}'
            hook() { printf '%s' "$settings" | /usr/bin/plutil -extract "hooks.$1.0.hooks.0.command" raw -o - -; }
            if [ "$mode" = "hooks" ]; then
              printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Fixed the footer link. The tests need the build server."}' "$session" | /bin/sh -c "$(hook Stop)"
            fi
            if [ "$mode" = "hooks" ] || [ "$mode" = "end" ]; then
              printf '{"session_id":"%s","hook_event_name":"SessionEnd","reason":"other"}' "$session" | /bin/sh -c "$(hook SessionEnd)"
            fi
            sleep "$(cat "$here/claude-sleep.txt")"
            exit 3
            """#
        try? script.write(to: fake, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        func setting(_ name: String, _ value: String) { try? value.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let claude = AgentProfile(name: "Claude Code · fake", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "plan",
                                                                                               executable: fake.path)),
                                  preset: "claude-code", wakesPerHour: 30)
        check(registry.upsert(claude) == nil, "a Claude Code agent is saved: \(registry.problem(with: claude) ?? "")")
        let agent = BoardActor(name: claude.name, kind: .agent)
        /// Starts a run for a new card, takes the card as the run would, and waits for the run to end while answering the
        /// inbox as the app does. The card, and what the run's environment held.
        func run(_ title: String, mode: String, sleep seconds: Int = 1, stop: Bool = false) async -> (card: UUID, environment: [String]) {
            setting("claude-mode.txt", mode)
            setting("claude-sleep.txt", String(seconds))
            try? manager.removeItem(at: folder.appendingPathComponent("claude-env.txt"))
            let id = made(await call("create_task", ["title": title, "binder": "Launch", "column": "ready", "for": claude.name], as: .you).text)
            if let target = card(id) { try? board.claim(target, by: agent) }
            if stop {
                for _ in 0..<50 where lines("claude-env.txt").isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                dispatcher.stop(id)
            }
            await serveInbox(controller, seconds: 30) { !dispatcher.isWorking(on: id) }
            return (id, lines("claude-env.txt").first?.split(separator: "|", omittingEmptySubsequences: false).map(String.init) ?? [])
        }
        func lastMove(_ id: UUID) -> TaskEvent? { events(id).last { $0.kind == .moved } }
        let hooked = await run("Fix the footer link", mode: "hooks")
        check(hooked.environment.count == 3 && hooked.environment[0] == hooked.card.uuidString && hooked.environment[1] == claude.name
              && UUID(uuidString: hooked.environment[2]) != nil, "the run's environment names its card and agent, for its hooks: \(hooked.environment)")
        let said = events(hooked.card).filter { $0.kind == .progress && $0.author == claude.name }
        check(said.map(\.text) == ["Fixed the footer link. The tests need the build server."], "its Stop hook puts what it said last on the card: \(said.map(\.text))")
        check(!events(hooked.card).contains { $0.text.hasPrefix("Session ended") }, "its SessionEnd hook, after that, says nothing more")
        check(card(hooked.card)?.column == .blocked && card(hooked.card)?.assignee == claude.name && lastMove(hooked.card)?.toColumn == "blocked"
              && lastMove(hooked.card)?.text == "Its run stopped (exit 3) before it finished.",
              "a run that stopped unfinished leaves the card in Blocked with why, still its: \(lastMove(hooked.card)?.text ?? "")")
        check(await state(hooked.card) == "failed", "which reads as failed")

        let plain = await run("Update the changelog", mode: "none")
        check(lastMove(plain.card)?.text == "Its run stopped (exit 3) before it finished. It said: I could not reach the build server.",
              "with no hooks, its end says what it said last instead: \(lastMove(plain.card)?.text ?? "")")
        let ended = await run("Rename the build step", mode: "end")
        check(events(ended.card).filter { $0.kind == .progress && $0.text == "Session ended (other)" }.count == 1
              && lastMove(ended.card)?.text == "Its run stopped (exit 3) before it finished.", "a session that ends without a Stop says so, once")

        // A hook that comes after the run ended, or for another agent, adds nothing.
        func hook(_ kind: String, card id: UUID, agent name: String, input: String) async -> Bool {
            let environment = ProcessInfo.processInfo.environment.merging(["BINDERS_CARD": id.uuidString, "BINDERS_AGENT": name]) { _, new in new }
            let finished = Flag()
            Task {
                _ = try? await AutomationService.runProcess(MCPHost.executable, ["--agent-hook", kind], stdin: input, environment: environment, timeout: 30)
                finished.set()
            }
            await serveInbox(controller, seconds: 30) { finished.isSet }
            return finished.isSet
        }
        let before = events(plain.card).count
        let late = await hook("session-end", card: plain.card, agent: claude.name, input: #"{"session_id":"\#(plain.environment.last ?? "")","reason":"other"}"#)
        check(late && events(plain.card).count == before, "a hook after its run ended adds nothing")
        _ = await hook("stop", card: plain.card, agent: "Someone Else", input: #"{"session_id":"\#(UUID().uuidString)","last_assistant_message":"Mine now."}"#)
        check(events(plain.card).count == before, "nor one by an agent the card isn't meant for")
        _ = await hook("stop", card: plain.card, agent: claude.name, input: "")
        check(events(plain.card).count == before, "nor one with nothing on its input")

        let stopped = await run("Tidy the scripts", mode: "none", sleep: 8, stop: true)
        check(lastMove(stopped.card)?.text.hasPrefix("You stopped its run before it finished.") == true && card(stopped.card)?.column == .blocked,
              "a run you stopped says so: \(lastMove(stopped.card)?.text ?? "")")
        registry.remove(claude.id)
        registry.remove(quick.id)

        print(failures == 0 ? "AGENT_REPORTS_OK" : "AGENT_REPORTS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Takes the inbox's requests as the running app does (what `Binders --mcp` and the agent hooks write), for up to
    /// `seconds` or until `done` says so.
    @MainActor
    private static func serveInbox(_ controller: DictationController, seconds: Double, until done: () -> Bool) async {
        let inbox = InboxCommands.directory, suffix = Inbox.requestFile("")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? [] where file.hasSuffix(suffix) {
                await InboxCommands.apply(named: String(file.dropLast(suffix.count)), controller: controller)
            }
            if done() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Set once, from wherever a process ends.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
