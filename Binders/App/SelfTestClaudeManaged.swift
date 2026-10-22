import Foundation
import BindersKit

extension SelfTest {
    /// A Claude Code that an organization manages, with a stand-in for claude (a script given as the agent's program), in
    /// a throwaway folder (BINDERS_DATA_DIR); the real claude never runs, and Claude Code's real folder of managed settings
    /// is never touched: the one looked at is under the throwaway folder. Where a run limited to Binders' tools is refused,
    /// it starts again once without the limit, the card saying why in one line, and later runs start without it; where the
    /// organization's managed-mcp.json is, runs start without it at once; where the organization's settings keep Binders'
    /// tools out of a run (the stand-in prints Claude Code's "exclusive control" warning and starts without Binders'
    /// server), the card says so and what to do, after one start again at most. A run without the limit carries the hook
    /// that keeps every other MCP tool out of it, and that hook (this Binders, `--agent-hook pre-tool`) lets through only
    /// Binders' board tools. Settings → Agents says what Binders does about it.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-claude-managed -notesShowMarkdown NO
    @MainActor
    static func claudeManagedSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards, an agent and a stand-in claude")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let folder = AppPaths.support
        let manager = FileManager.default
        let managed = URL(fileURLWithPath: AgentDispatcher.managedFolder, isDirectory: true)
        check(AgentDispatcher.managedFolder.hasPrefix(AgentPlaces.root.path) && AgentDispatcher.managedFolder.hasSuffix(ClaudeCodeManaged.folder),
              "the managed folder looked at is under the throwaway folder: \(AgentDispatcher.managedFolder)")
        try? manager.createDirectory(at: managed, withIntermediateDirectories: true)

        // The stand-in: it notes each run (its card, whether limited to Binders' tools, whether the guard hook came), and
        // does as its mode says: "refuse", a managed Claude Code that refuses the limit; "managed", one that also leaves
        // Binders' server out ("exclusive control"); "allow", an ordinary one.
        let repository = folder.appendingPathComponent("fake-repo")
        try? manager.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let bin = folder.appendingPathComponent("bin")
        try? manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try? #"""
            #!/bin/sh
            here="$(cd "$(dirname "$0")/.." && pwd)"
            cat > /dev/null
            mode="$(cat "$here/claude-mode.txt" 2>/dev/null)"
            strict=loose
            for a in "$@"; do [ "$a" = "--strict-mcp-config" ] && strict=strict; done
            hook=nohook
            case "$*" in *PreToolUse*) hook=guard;; esac
            printf 'RUN %s %s %s\n' "$BINDERS_CARD" "$strict" "$hook" >> "$here/claude-runs.txt"
            if [ "$strict" = strict ] && [ "$mode" != allow ]; then
              echo "Error: You cannot use --strict-mcp-config when an enterprise MCP config is present" >&2
              exit 1
            fi
            if [ "$mode" = managed ]; then
              echo "Warning: an enterprise MCP config (managed-mcp.json) is present and has exclusive control over MCP servers; ignoring 1 MCP server supplied via --mcp-config: binders" >&2
              echo '{"type":"system","subtype":"init","session_id":"s","mcp_servers":[]}'
            else
              echo '{"type":"system","subtype":"init","session_id":"s","mcp_servers":[{"name":"binders","status":"connected"}]}'
            fi
            echo '{"type":"result","subtype":"success","result":"Done with the card.","total_cost_usd":0.01,"num_turns":1}'
            exit 0
            """#.write(to: fake, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        func mode(_ value: String) { try? value.write(to: folder.appendingPathComponent("claude-mode.txt"), atomically: true, encoding: .utf8) }
        func runs(_ id: UUID) -> [String] {
            ((try? String(contentsOf: folder.appendingPathComponent("claude-runs.txt"), encoding: .utf8)) ?? "").split(separator: "\n")
                .filter { $0.hasPrefix("RUN \(id.uuidString) ") }.map { String($0.dropFirst("RUN \(id.uuidString) ".count)) }
        }
        func until(seconds: Double = 12, _ done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        }

        let controller = DictationController()
        let board = controller.board
        let dispatcher = controller.agents
        let registry = AgentRegistry.shared
        let launch = BinderRecord(name: "Launch", colorIndex: 2)
        Store.shared.insert(launch)
        let agent = AgentProfile(name: "Claude Code · fake", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "plan", executable: fake.path)),
                                 preset: "claude-code", wakesPerHour: 60)
        check(registry.upsert(agent) == nil, "a Claude Code agent with the stand-in is saved: \(registry.problem(with: agent) ?? "")")
        /// A card given to the agent, as Give to does it: woken at once.
        func give(_ title: String) -> UUID {
            let card = board.create(title: title, binderID: launch.id, by: .you)
            _ = board.give(card, to: agent.name, by: .you)
            return card.id
        }
        func lines(_ id: UUID) -> [String] { board.timeline(id).map(\.text) }
        func receipts(_ id: UUID) -> [String] { board.timeline(id).filter { $0.kind == .woke }.map(\.text) }
        func settled(_ id: UUID, runs count: Int) async {
            await until { runs(id).count >= count && !dispatcher.isWorking(on: id) }
            try? await Task.sleep(for: .milliseconds(300))
        }
        AppDefaults.store.removeObject(forKey: AgentDispatcher.refusedOnlyBindersKey)

        // a) An ordinary Claude Code: limited to Binders' tools, as always; nothing to say.
        mode("allow")
        check(AgentDispatcher.asksOnlyBinders && !AgentDispatcher.claudeCodeIsManaged, "an unmanaged Claude Code: runs ask for only Binders' tools")
        let plain = give("Fix the footer link")
        await settled(plain, runs: 1)
        check(runs(plain) == ["strict nohook"], "one run, limited to Binders' tools, with no guard hook: \(runs(plain))")
        check(!lines(plain).contains(ClaudeCodeManaged.keptOutLine) && !receipts(plain).contains { $0.hasPrefix(ClaudeCodeManaged.startedAgainLine) },
              "and nothing on the card about an organization")

        // b) Managed in a way that refuses the limit (settings from a device profile, say, with no file to see): refused, it
        // starts again once without it, and the card says why in one line.
        mode("refuse")
        let refused = give("Tidy the footer copy")
        await settled(refused, runs: 2)
        check(runs(refused) == ["strict nohook", "loose guard"], "refused, it started again once, without the limit and with the guard hook: \(runs(refused))")
        let again = receipts(refused).last ?? ""
        check(receipts(refused).count == 2 && again.hasPrefix(ClaudeCodeManaged.startedAgainLine) && again.contains("Started Claude Code in"),
              "the card says why, in one line, before the second start's receipt: \(again)")
        check(!lines(refused).contains(ClaudeCodeManaged.keptOutLine), "Binders' tools were there for that run: nothing more to say")
        check(AppDefaults.store.object(forKey: AgentDispatcher.refusedOnlyBindersKey) is Date && !AgentDispatcher.asksOnlyBinders && AgentDispatcher.claudeCodeIsManaged,
              "the refusal is remembered")
        let later = give("Check the footer on mobile")
        await settled(later, runs: 1)
        try? await Task.sleep(for: .milliseconds(500))
        check(runs(later) == ["loose guard"], "the next run starts without the limit at once: \(runs(later))")

        // c) The organization's managed-mcp.json is here: runs start without the limit at once, and when it keeps Binders'
        // server out, the card says so and what to do.
        AppDefaults.store.removeObject(forKey: AgentDispatcher.refusedOnlyBindersKey)
        try? Data("{\"mcpServers\":{}}".utf8).write(to: managed.appendingPathComponent(ClaudeCodeManaged.mcpFile))
        mode("managed")
        check(!AgentDispatcher.asksOnlyBinders && AgentDispatcher.claudeCodeIsManaged, "with managed-mcp.json here, runs don't ask for only Binders' tools")
        let keptOut = give("Update the pricing table")
        await settled(keptOut, runs: 1)
        try? await Task.sleep(for: .milliseconds(500))
        check(runs(keptOut) == ["loose guard"], "one run, without the limit: \(runs(keptOut))")
        let said = board.timeline(keptOut).filter { $0.text == ClaudeCodeManaged.keptOutLine }
        check(said.count == 1 && said.first?.author == BoardService.binders.name,
              "the card says the organization's settings keep Binders' tools out, and what to do, once, by Binders")

        // d) Managed, with no file to see, and Binders' server kept out: one refusal, one start again, then that line. Never
        // a loop.
        try? manager.removeItem(at: managed.appendingPathComponent(ClaudeCodeManaged.mcpFile))
        AppDefaults.store.removeObject(forKey: AgentDispatcher.refusedOnlyBindersKey)
        let both = give("Write the release notes")
        await settled(both, runs: 2)
        try? await Task.sleep(for: .milliseconds(1_500))
        check(runs(both) == ["strict nohook", "loose guard"], "refused once, started again once, and no more: \(runs(both))")
        check(lines(both).filter { $0 == ClaudeCodeManaged.keptOutLine }.count == 1 && receipts(both).last?.hasPrefix(ClaudeCodeManaged.startedAgainLine) == true,
              "the card says why it started again, then that Binders' tools were kept out")

        // e) Settings → Agents' line, where the organization's settings are.
        AppDefaults.store.removeObject(forKey: AgentDispatcher.refusedOnlyBindersKey)
        check(AgentDispatcher.asksOnlyBinders && !AgentDispatcher.claudeCodeIsManaged, "with nothing managed here, Settings says nothing")
        try? Data("{}".utf8).write(to: managed.appendingPathComponent(ClaudeCodeManaged.settingsFile))
        check(AgentDispatcher.claudeCodeIsManaged && AgentDispatcher.asksOnlyBinders,
              "managed settings alone: Settings says what Binders does, and runs still ask for only Binders' tools, which they allow")
        try? manager.removeItem(at: managed.appendingPathComponent(ClaudeCodeManaged.settingsFile))

        // f) The guard hook, as a run without the limit calls it: this Binders, `--agent-hook pre-tool`.
        func guarded(_ tool: String) -> (status: Int32, said: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: MCPHost.executable)
            process.arguments = ["--agent-hook", ClaudeCodeToolGuard.hook]
            let input = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            input.fileHandleForWriting.write(Data(#"{"hook_event_name":"PreToolUse","tool_name":"\#(tool)","tool_input":{}}"#.utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        check(guarded("mcp__binders__get_task").status == 0, "the guard lets Binders' board tools through")
        let github = guarded("mcp__github__create_issue")
        check(github.status == 2 && github.said.contains("only Binders' board tools") && github.said.contains("mcp__github__create_issue"),
              "and refuses anyone else's, saying why, so Claude Code doesn't run it: \(github.status) \(github.said.prefix(80))")
        check(guarded("mcp__binders__search_knowledge").status == 2, "and Binders' own tools that read your binders, from a server of that name the run didn't bring")

        registry.remove(agent.id)
        print(failures == 0 ? "CLAUDE_MANAGED_OK" : "CLAUDE_MANAGED_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
