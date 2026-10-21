import AppKit
import Darwin
import SwiftUI
import BindersKit

extension SelfTest {
    /// Waking a Claude Code agent in the session you have open ("Post to the Claude Code session open in this repository"):
    /// a card you give it goes, as one message, into a stand-in for a session's inbox socket that this test makes in its
    /// throwaway folder, named by a session file in a fake agent home there, for a session with Binders' tools (Binders'
    /// MCP server, this very Binders, runs as its child). The session takes the card as "Claude Code", as your Binders
    /// entry has it, so your answer on it posts nothing and starts nothing; a card the agent itself holds from a run goes
    /// back to a run, Wake Now included. With the option off, with no session open, with only a closed one, one without
    /// Binders' tools, or only Binders' own runs and other checkouts open, the run starts as before; a post that fails says
    /// why and starts nothing; a paused agent, an agent's suggestion and the wake limit post nothing; and each time the card
    /// says what happened. An agent saved before the option keeps its fingerprint, and one turned on in agents.json by
    /// anything else is held. BINDERS_AGENT_HOME is set to the throwaway folder before anything is read, so no session of
    /// yours is ever read or posted to. In a throwaway folder (BINDERS_DATA_DIR) only. A folder, when given, gets a drawing
    /// of the agent's settings with the option on (agent-sessions-settings.png).
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-agent-sessions [folder] -notesShowMarkdown NO
    @MainActor
    static func agentSessionsSelfTest(drawingTo directory: URL? = nil) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards, agents and a fake Claude Code home")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let folder = AppPaths.support
        let manager = FileManager.default
        // The agent home, in the throwaway folder whatever the environment said: no real session is read.
        let home = folder.appendingPathComponent("agent-home")
        let sessionFiles = home.appendingPathComponent(".claude/sessions")
        try? manager.createDirectory(at: sessionFiles, withIntermediateDirectories: true)
        setenv("BINDERS_AGENT_HOME", home.path, 1)
        defer { unsetenv("BINDERS_AGENT_HOME") }

        // Binders' MCP server, this very Binders on the throwaway folder, as this test's own child, as a session's Binders
        // server is the session's child: the stand-in sessions below that go by this process have Binders' tools. It ends
        // when its input closes.
        let server = Process()
        server.executableURL = URL(fileURLWithPath: MCPHost.executable)
        server.arguments = ["--mcp"]
        let serverInput = Pipe()
        server.standardInput = serverInput
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        // And a process with no Binders among its own: a session without Binders' tools.
        let bare = Process()
        bare.executableURL = URL(fileURLWithPath: "/bin/cat")
        let bareInput = Pipe()
        bare.standardInput = bareInput
        bare.standardOutput = FileHandle.nullDevice
        defer {
            try? serverInput.fileHandleForWriting.close()
            try? bareInput.fileHandleForWriting.close()
            if server.isRunning { server.terminate() }
            if bare.isRunning { bare.terminate() }
        }
        do {
            try server.run()
            try bare.run()
        } catch {
            check(false, "the stand-in processes couldn't start: \(error.localizedDescription)")
            return 1
        }

        let controller = DictationController()
        let board = controller.board
        let dispatcher = controller.agents
        let registry = AgentRegistry.shared
        let write = MCPServer.writeInApp(controller: controller)
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func made(_ text: String) -> UUID {
            ((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        }
        func receipts(_ id: UUID) -> [String] { board.timeline(id).filter { $0.kind == .woke }.map(\.text) }
        func until(seconds: Double = 8, _ done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        }
        Store.shared.insert(BinderRecord(name: "Launch", colorIndex: 2))

        // The repository, and a stand-in for claude that notes each run started for a card, and stops.
        let repository = folder.appendingPathComponent("fake-repo")
        try? manager.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let bin = folder.appendingPathComponent("bin")
        try? manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try? """
            #!/bin/sh
            here="$(cd "$(dirname "$0")/.." && pwd)"
            cat > /dev/null
            printf 'RUN %s\\n' "$BINDERS_CARD" >> "$here/claude-runs.txt"
            """.write(to: fake, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        func runs() -> [String] {
            ((try? String(contentsOf: folder.appendingPathComponent("claude-runs.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func runCount(_ id: UUID) -> Int { runs().filter { $0 == "RUN \(id.uuidString)" }.count }

        // A stand-in for a session's inbox socket, and the session files that say which sessions are open where.
        let inbox = StandInInbox(path: folder.appendingPathComponent("inbox.sock").path)
        guard inbox.start() else {
            check(false, "the stand-in inbox couldn't listen at \(inbox.path)")
            return 1
        }
        defer { inbox.stop() }
        var nextFile = 900_000
        func openSession(name: String, in place: URL = repository, socket: String? = nil, pid: Int32 = getpid(), entrypoint: String = "cli") {
            nextFile += 1
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let fields: [String: Any] = ["pid": Int(pid), "sessionId": UUID().uuidString.lowercased(), "cwd": place.path, "messagingSocketPath": socket ?? inbox.path,
                                         "name": name, "nameSource": "user", "status": "idle", "entrypoint": entrypoint, "kind": "interactive",
                                         "startedAt": now, "updatedAt": now, "version": "2.1.300", "peerProtocol": 1]
            try? JSONSerialization.data(withJSONObject: fields).write(to: sessionFiles.appendingPathComponent("\(nextFile).json"))
        }
        func closeSessions() {
            for file in (try? manager.contentsOfDirectory(atPath: sessionFiles.path)) ?? [] where file.hasSuffix(".json") {
                try? manager.removeItem(at: sessionFiles.appendingPathComponent(file))
            }
        }
        // A key file beside them, as Claude Code keeps: never read, and never mistaken for a session.
        try? Data("not for Binders".utf8).write(to: sessionFiles.appendingPathComponent("\(getpid()).0a1b2c3d.key"))

        // Which stand-ins have Binders' tools: only one with Binders' MCP server among its own processes.
        await until { ClaudeSessionInbox.hasBindersTools(ClaudeSession(pid: getpid(), folder: repository.path, socket: inbox.path)) }
        check(ClaudeSessionInbox.hasBindersTools(ClaudeSession(pid: getpid(), folder: repository.path, socket: inbox.path)),
              "a session whose own Binders MCP server runs as its child has Binders' tools")
        check(!ClaudeSessionInbox.hasBindersTools(ClaudeSession(pid: bare.processIdentifier, folder: repository.path, socket: inbox.path)),
              "one with no Binders among its processes doesn't")

        var options = ClaudeCodeWake(repository: repository.path, permissionMode: "plan", executable: fake.path, postToOpenSession: true)
        var claude = AgentProfile(name: "Claude Code · fake", wake: .claudeCode(options), preset: "claude-code", wakesPerHour: 30)
        check(registry.upsert(claude) == nil, "a Claude Code agent that posts to your open session is saved: \(registry.problem(with: claude) ?? "")")
        let listed = ((try? JSONSerialization.jsonObject(with: Data(await call("list_agents", [:], as: .you).text.utf8)) as? [String: Any])?["agents"] as? [[String: Any]]) ?? []
        let entry = listed.first { $0["name"] as? String == claude.name }
        var off = claude
        off.wake = .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "plan", executable: fake.path))
        check(entry?["open_session"] as? Bool == true && entry?["fingerprint"] as? String != AgentRegistry.consentFingerprint(off, reads: AgentBriefing.reads(for: off.name)),
              "your iPhone hears that its cards go to your open session, and asks again before the first one")
        check(entry?["sends_to"] as? String == "Anthropic, or the Claude Code session you have open in its repository",
              "and where its cards go names the session, for an iPhone that shows only that: \(entry?["sends_to"] as? String ?? "")")
        let agent = BoardActor(name: claude.name, kind: .agent)
        /// A card given to the agent, as Give to does it: woken at once.
        func give(_ title: String, details: String = "", to name: String? = nil) async -> UUID {
            let id = made(await call("create_task", ["title": title, "details": details, "binder": "Launch", "column": "backlog"], as: .you).text)
            if let card = board.card(id) { board.give(card, to: name ?? claude.name, by: .you) }
            return id
        }

        // a) A session with Binders' tools is open in the repository: the card goes to it, as one message, and no run starts.
        openSession(name: "launch-work")
        check(ClaudeSessionInbox.sessions(in: repository.path).ready.count == 1, "the session open there is found, with Binders' tools")
        let first = await give("Fix the footer link", details: "The wifi password is lighthouse.")
        await until { inbox.received.count >= 1 && receipts(first).contains { $0.hasPrefix("Posted") } }
        let text = String(decoding: inbox.received.first ?? Data(), as: UTF8.self)
        check(inbox.received.count == 1, "the session's inbox got one message: \(inbox.received.count)")
        check(text.hasSuffix("\n") && text.filter { $0 == "\n" }.count == 1, "one line, ended by a newline, with no auth line before it")
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        let message = object?["message"] as? [String: Any]
        let content = message?["content"] as? String ?? ""
        check(object?["type"] as? String == "user" && message?["role"] as? String == "user" && Set(object?.keys.map { $0 } ?? []) == ["type", "message"],
              "a user message, as Claude Code's own messages read: \(text.prefix(80))")
        check(content.hasPrefix(AgentWake.promptMarker) && content.contains("“Fix the footer link”") && content.contains("binders://card/\(first.uuidString)")
              && content.contains("get_task") && content.contains(claude.name), "with the card's title, id and link, and the board tools that have it")
        check(content.contains("answers, approvals and comments on the card don't reach this session"),
              "and that your answers and comments on the card don't reach it, so it waits for you there")
        check(!content.contains("lighthouse") && !content.contains("Launch"), "and nothing else from your binders: not its description, not its binder")
        let posted = receipts(first).last ?? ""
        check(posted.hasPrefix("Posted the card to the Claude Code session open in") && posted.contains("fake-repo") && posted.contains("“launch-work”")
              && posted.contains("instead of starting a run"), "the card says where it was posted: \(posted)")
        check(posted.contains("can't see whether it took it") && posted.contains("drops it after a few minutes") && posted.contains("Wake Now on the card posts it again")
              && !posted.contains("waits there for your OK"), "what a session may do with it, and what to do if nothing happens")
        check(runs().isEmpty && !dispatcher.isWorking(on: first), "and no run started")

        // b) The session takes the card as itself, "Claude Code", as your Binders entry has it: its question and your answer
        // are on the card, and your answer posts nothing and starts nothing, since the card isn't the agent's own.
        let yourSession = BoardActor(name: MCPHost.claudeCode.name, kind: .agent)
        if let card = board.card(first) { try? board.claim(card, by: yourSession) }
        let asked = await call("ask_on_task", ["id": first.uuidString, "question": "Which footer?"], as: yourSession)
        _ = await call("comment_task", ["id": first.uuidString, "text": "The one on the pricing page."], as: .you)
        try? await Task.sleep(for: .milliseconds(2600))
        check(asked.ok && board.card(first)?.assignee == yourSession.name && board.card(first)?.column == .inProgress,
              "your session holds the card as Claude Code, and your answer sends it back to work: \(asked.text.prefix(80))")
        check(inbox.received.count == 1 && runs().isEmpty && receipts(first).count == 1, "your answer to a card your session took posts nothing and starts nothing")

        // c) A card the agent itself holds, as a run of it does once it has claimed it: your answer goes to a run, which can
        // go on with it, never to your session, which can't take it over.
        let fromRun = await give("Tidy the footer copy")
        await until { receipts(fromRun).contains { $0.hasPrefix("Posted") } }
        if let card = board.card(fromRun) { try? board.claim(card, by: agent) }
        _ = await call("ask_on_task", ["id": fromRun.uuidString, "question": "Shorter or friendlier?"], as: agent)
        let beforeAnswer = inbox.received.count
        _ = await call("comment_task", ["id": fromRun.uuidString, "text": "Shorter."], as: .you)
        await until { runCount(fromRun) == 1 }
        let answeredRun = receipts(fromRun).last ?? ""
        check(runCount(fromRun) == 1 && inbox.received.count == beforeAnswer && answeredRun.hasPrefix("\(claude.name) has this card from an earlier run")
              && answeredRun.contains("Started Claude Code in") && answeredRun.contains("you answered"),
              "your answer to the agent's own card starts a run, posts nothing, and the card says why: \(answeredRun)")
        // That run ended before it finished: the card waits in Blocked, still the agent's, and Wake Now starts a run again.
        await until { board.card(fromRun)?.column == .blocked && !dispatcher.isWorking(on: fromRun) }
        check(board.card(fromRun)?.column == .blocked && board.card(fromRun)?.assignee == claude.name, "the run ended, and the card waits in Blocked, still the agent's")
        check(board.card(fromRun).map { dispatcher.wakeNow($0) == nil } == true, "Wake Now on it goes")
        await until { runCount(fromRun) == 2 }
        check(runCount(fromRun) == 2 && inbox.received.count == beforeAnswer && receipts(fromRun).last?.contains("Wake Now") == true,
              "as a run, not a post, so a card a stopped run left in Blocked goes on: \(receipts(fromRun).last ?? "")")
        // Finished by the agent and sent back from Review, it goes to a run too.
        await until { !dispatcher.isWorking(on: fromRun) }
        if let card = board.card(fromRun) { try? board.complete(card, summary: "Shortened it.", by: agent) }
        if let card = board.card(fromRun), card.column == .review { try? board.move(card, to: .inProgress, by: .you) }
        await until { runCount(fromRun) == 3 }
        check(runCount(fromRun) == 3 && inbox.received.count == beforeAnswer && receipts(fromRun).last?.contains("you sent it back") == true
              && receipts(fromRun).last?.hasPrefix("\(claude.name) has this card from an earlier run") == true,
              "and sent back from Review, the agent's own card goes to a run, not your session: \(receipts(fromRun).last ?? "")")
        // And your comment while it works on its own card: a run too, with the comment's reason, never a post to your session.
        await until { !dispatcher.isWorking(on: fromRun) && board.card(fromRun)?.column == .blocked }
        _ = await call("update_task", ["id": fromRun.uuidString, "progress": "Back on it.", "column": "in_progress"], as: agent)
        _ = await call("comment_task", ["id": fromRun.uuidString, "text": "And keep it under ten words."], as: .you)
        await until { runCount(fromRun) == 4 }
        check(runCount(fromRun) == 4 && inbox.received.count == beforeAnswer && receipts(fromRun).last?.contains("you commented") == true
              && receipts(fromRun).last?.hasPrefix("\(claude.name) has this card from an earlier run") == true,
              "and your comment on it while it works goes to a run, not your session: \(receipts(fromRun).last ?? "")")

        // d) Paused, nothing is posted and no run starts.
        let postedSoFar = inbox.received.count
        let runsSoFar = runs().count
        registry.setPaused(true)
        let whilePaused = await give("Rename the build step")
        try? await Task.sleep(for: .milliseconds(2600))
        check(inbox.received.count == postedSoFar && runs().count == runsSoFar && receipts(whilePaused).isEmpty, "paused, nothing is posted and nothing starts")
        check(board.card(whilePaused).flatMap { dispatcher.wakeNow($0) }?.contains("paused") == true, "and Wake Now says why")
        registry.setPaused(false)

        // e) An agent's suggestion posts nothing.
        let suggested = made(await call("create_task", ["title": "Find a caterer", "binder": "Launch", "column": "ready", "for": claude.name],
                                        as: BoardActor(name: "Helper", kind: .agent)).text)
        try? await Task.sleep(for: .milliseconds(2600))
        check(inbox.received.count == postedSoFar && receipts(suggested).isEmpty, "a card an agent meant for it posts nothing")

        // f) With the option off, the run starts as before, the session open or not.
        options.postToOpenSession = nil
        claude.wake = .claudeCode(options)
        registry.upsert(claude)
        let offCard = await give("Update the changelog")
        await until { runs().contains("RUN \(offCard.uuidString)") }
        check(runs().contains("RUN \(offCard.uuidString)") && inbox.received.count == postedSoFar, "with the option off, the run starts and nothing is posted")
        check(receipts(offCard).last?.hasPrefix("Started Claude Code in") == true, "and the card says so, as before: \(receipts(offCard).last ?? "")")
        options.postToOpenSession = true
        claude.wake = .claudeCode(options)
        registry.upsert(claude)

        /// A card given while only `sessions` are open: a run should start for it, with the card saying why (`note`).
        @discardableResult
        func runsInstead(_ title: String, _ label: String, saying note: String = "No Claude Code session was open in", sessions open: () -> Void) async -> String {
            closeSessions()
            open()
            let before = inbox.received.count
            let id = await give(title)
            await until { runs().contains("RUN \(id.uuidString)") }
            let said = receipts(id).last ?? ""
            check(runs().contains("RUN \(id.uuidString)") && inbox.received.count == before
                  && said.hasPrefix(note) && said.contains("Started Claude Code in"), "\(label): \(said)")
            return said
        }
        // g) No session open: the run starts, and the card says why.
        await runsInstead("Tidy the scripts", "with no session open, the run starts and the card says why") {}
        // h) A session whose process has ended is closed.
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? ended.run()
        ended.waitUntilExit()
        await runsInstead("Sort the screenshots", "a session whose process has ended is closed") {
            openSession(name: "gone", pid: ended.processIdentifier)
        }
        // i) A session whose inbox nothing listens at any more is closed too, found out when Binders posts.
        let stale = folder.appendingPathComponent("stale.sock").path
        let staleListening = StandInInbox(path: stale)
        _ = staleListening.start()
        staleListening.stop(keepingFile: true)
        await runsInstead("Check the links", "a session whose inbox nothing listens at is closed, and the run starts") {
            openSession(name: "stale", socket: stale)
        }
        // j) Binders' own runs, a worktree, another repository and a script's run aren't the session you have open.
        let worktree = repository.appendingPathComponent(".claude/worktrees/binders-0a1b2c3d")
        let elsewhere = folder.appendingPathComponent("other-repo")
        try? manager.createDirectory(at: worktree, withIntermediateDirectories: true)
        try? manager.createDirectory(at: elsewhere.appendingPathComponent(".git"), withIntermediateDirectories: true)
        await runsInstead("Bump the version", "Binders' own runs, worktrees, other repositories and scripts' runs are left alone") {
            openSession(name: ClaudeSessions.runNamePrefix + "0a1b2c3d")
            openSession(name: "feature", in: worktree)
            openSession(name: "elsewhere", in: elsewhere)
            openSession(name: "script", entrypoint: "sdk-cli")
        }
        // k) A session open there without Binders' tools couldn't read the card: nothing is posted, the run starts, and the
        // card says why and what to do; Check in Settings says the same.
        let withoutTools = await runsInstead("Sort the issues", "a session without Binders' tools gets nothing, and the run starts",
                                             saying: "The Claude Code session open in") {
            openSession(name: "no-tools", pid: bare.processIdentifier)
        }
        check(withoutTools.contains("doesn't have Binders' tools") && withoutTools.contains("Settings → MCP"), "the card says it hasn't Binders' tools, and where to add them")
        let split = ClaudeSessionInbox.sessions(in: repository.path)
        check(split.ready.isEmpty && split.withoutTools.map(\.name) == ["no-tools"], "and Check sees it the same way")

        // l) A post that fails says why, and starts nothing.
        closeSessions()
        let notASocket = folder.appendingPathComponent("not-a-socket")
        try? Data().write(to: notASocket)
        openSession(name: "odd", socket: notASocket.path)
        let failed = await give("Merge the docs")
        await until { receipts(failed).contains { $0.hasPrefix("Couldn't post") } }
        let failure = receipts(failed).last ?? ""
        check(failure.hasPrefix("Couldn't post the card to the Claude Code session open in") && failure.contains("isn't a socket")
              && failure.contains("Nothing was started"), "an inbox that isn't a socket is left alone, and the card says why: \(failure)")
        check(!runs().contains("RUN \(failed.uuidString)") && dispatcher.outcomes[failed]?.ok == false, "and no run starts")
        closeSessions()
        openSession(name: "busy")
        inbox.reply(Data(#"{"type": "error", "message": "Too many messages to this session just now"}"#.utf8 + Data("\n".utf8)))
        let refused = await give("Write the release notes")
        await until { receipts(refused).contains { $0.hasPrefix("Couldn't post") } }
        check(receipts(refused).last?.contains("it said “Too many messages to this session just now”") == true && !runs().contains("RUN \(refused.uuidString)"),
              "a session that says no is quoted, and nothing starts: \(receipts(refused).last ?? "")")
        inbox.reply(nil)

        // m) The wake limit holds for a post as for a run, and Wake Now goes past it.
        let capped = AgentProfile(name: "Claude Code · capped", wake: .claudeCode(options), preset: "claude-code", wakesPerHour: 1)
        check(registry.upsert(capped) == nil, "another agent, woken once an hour at most, is saved")
        let once = await give("Order the stickers", to: capped.name)
        await until { receipts(once).contains { $0.hasPrefix("Posted") } }
        let afterOnce = inbox.received.count
        let twice = await give("Order the banners", to: capped.name)
        try? await Task.sleep(for: .milliseconds(1500))
        check(inbox.received.count == afterOnce && receipts(twice).isEmpty && dispatcher.outcomes[twice]?.message.contains("in the last hour") == true,
              "a second wake in the hour posts nothing, and says why: \(dispatcher.outcomes[twice]?.message ?? "")")
        check(board.card(twice).map { dispatcher.wakeNow($0) == nil } == true, "Wake Now goes past it")
        await until { receipts(twice).contains { $0.hasPrefix("Posted") } }
        check(inbox.received.count == afterOnce + 1, "and posts it")

        // n) An agent saved by Binders 0.8.0, before the option, keeps the fingerprint the Keychain holds for it (worked out
        // with 0.8.0's own code), so the update doesn't hold it as changed outside Binders. Turned on in agents.json by
        // anything but Settings, an agent is held until you save it there, and a card for it posts nothing.
        let fromBefore = """
            {
              "agents" : [
                {
                  "id" : "6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
                  "isEnabled" : true,
                  "name" : "Claude Code · app",
                  "preset" : "claude-code",
                  "report" : "mcp",
                  "wake" : {
                    "claudeCode" : {
                      "allowedDomains" : [
                        "github.com"
                      ],
                      "model" : "sonnet",
                      "permissionMode" : "plan",
                      "repository" : "/Users/sam/Code/app"
                    }
                  },
                  "wakesPerHour" : 6
                }
              ],
              "paused" : false
            }
            """
        let old = (try? AgentFile.decode(Data(fromBefore.utf8)))?.file.agents.first
        check(old.map(AgentRegistry.fingerprint) == "e2733304f1d5665176142d466175fdd3f4d93314cacbb877e9e66c672f93e343",
              "an agent saved before the option keeps its fingerprint: \(old.map(AgentRegistry.fingerprint) ?? "none read")")
        let outside = AgentProfile(name: "Claude Code · outside", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "plan", executable: fake.path)),
                                   preset: "claude-code")
        check(registry.upsert(outside) == nil, "an agent with the option off is saved")
        let agentsFile = folder.appendingPathComponent("agents.json")
        if var saved = (try? Data(contentsOf: agentsFile)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
           var agents = saved["agents"] as? [[String: Any]] {
            for index in agents.indices where agents[index]["id"] as? String == outside.id.uuidString {
                var wake = agents[index]["wake"] as? [String: [String: Any]] ?? [:]
                wake["claudeCode"]?["postToOpenSession"] = true
                agents[index]["wake"] = wake
            }
            saved["agents"] = agents
            try? JSONSerialization.data(withJSONObject: saved).write(to: agentsFile)
        }
        registry.load()
        check(registry.changedOutside.contains(outside.id) && !registry.changedOutside.contains(claude.id) && !registry.changedOutside.contains(capped.id),
              "turned on in agents.json by anything but Settings, it's held until you save it there, and the others aren't")
        closeSessions()
        openSession(name: "launch-work")
        let beforeHeld = inbox.received.count
        let forHeld = await give("Check the held agent", to: outside.name)
        try? await Task.sleep(for: .milliseconds(1500))
        check(inbox.received.count == beforeHeld && receipts(forHeld).isEmpty && !runs().contains("RUN \(forHeld.uuidString)"), "and a card for it posts nothing and starts nothing")
        registry.remove(outside.id)

        // Drawn: the agent's settings, with the option on and what it means.
        if let directory {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 660), styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let hosting = NSHostingView(rootView: AgentEditor(agent: claude, isNew: false).modelContainer(Store.shared.container))
            hosting.wantsLayer = true
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1500))
            capture(hosting, name: "agent-sessions-settings", directory: directory)
            window.close()
            check(manager.fileExists(atPath: directory.appendingPathComponent("agent-sessions-settings.png").path), "draws agent-sessions-settings.png")
        }

        closeSessions()
        check(ClaudeSessionInbox.open().isEmpty && manager.fileExists(atPath: sessionFiles.appendingPathComponent("\(getpid()).0a1b2c3d.key").path),
              "a key file beside the session files is never taken for a session")
        registry.remove(claude.id)
        registry.remove(capped.id)
        print(failures == 0 ? "AGENT_SESSIONS_OK" : "AGENT_SESSIONS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

/// A stand-in for a Claude Code session's inbox socket, in the throwaway folder: it takes each connection, keeps what came
/// in until the other end finished sending, and says `reply` back when there is one.
private final class StandInInbox: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var kept: [Data] = []
    private var answer: Data?
    private var running = false
    private var listener: Int32 = -1

    init(path: String) { self.path = path }

    /// What each connection sent, in order.
    var received: [Data] { lock.withLock { kept } }

    func reply(_ data: Data?) { lock.withLock { answer = data } }

    func start() -> Bool {
        unlink(path)
        guard let address = ClaudeSessionInbox.address(path) else { return false }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        let bound = address.withUnsafeBytes { bind(socket, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t($0.count)) }
        guard bound == 0, listen(socket, 8) == 0 else {
            close(socket)
            return false
        }
        lock.withLock {
            listener = socket
            running = true
        }
        Thread { [self] in serve(socket) }.start()
        return true
    }

    /// Stops listening; `keepingFile` leaves the socket's file there, as a session that ended without tidying up does.
    func stop(keepingFile: Bool = false) {
        let socket: Int32 = lock.withLock {
            running = false
            defer { listener = -1 }
            return listener
        }
        if socket >= 0 { close(socket) }
        if !keepingFile { unlink(path) }
    }

    private func serve(_ socket: Int32) {
        while lock.withLock({ running }) {
            var waiting = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 200) > 0, lock.withLock({ running }) else { continue }
            let connection = accept(socket, nil, nil)
            guard connection >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            let capacity = buffer.count
            while true {
                let count = read(connection, &buffer, capacity)
                if count > 0 {
                    data.append(contentsOf: buffer[0..<count])
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            // Kept before it answers, so whoever posted finds it here once the answer is in.
            let answer: Data? = lock.withLock {
                kept.append(data)
                return self.answer
            }
            answer?.withUnsafeBytes { _ = Darwin.write(connection, $0.baseAddress!, $0.count) }
            close(connection)
        }
    }
}
