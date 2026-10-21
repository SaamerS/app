import CryptoKit
import XCTest
@testable import BindersKit

final class AgentTests: XCTestCase {
    private let card = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let session = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
    private let home = "/Users/sam"
    private let dataFolder = "/Users/sam/Library/Application Support/Binders"
    private let binders = "/Applications/Binders.app/Contents/MacOS/Binders"

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The wake as agents.json holds it.
    private func written(_ wake: AgentProfile.Wake) throws -> NSDictionary {
        let file = try object(AgentFile(agents: [AgentProfile(name: "Echo", wake: wake)]).encoded())
        let agents = try XCTUnwrap(file["agents"] as? [[String: Any]])
        return try XCTUnwrap(agents.first?["wake"] as? NSDictionary)
    }

    private func wake(_ json: String) throws -> AgentProfile.Wake {
        try JSONDecoder().decode(AgentProfile.Wake.self, from: Data(json.utf8))
    }

    // MARK: agents.json

    func testEachWakeReadsLikeWhatItIs() throws {
        XCTAssertEqual(try written(.command(command: "cat >> ~/cards.log")), ["command": ["command": "cat >> ~/cards.log"]] as NSDictionary,
                       "no folder when there's none")
        XCTAssertEqual(try written(.command(command: "make agent", folder: "/Users/sam/app")),
                       ["command": ["command": "make agent", "folder": "/Users/sam/app"]] as NSDictionary)
        XCTAssertEqual(try written(.board), ["board": [String: Any]()] as NSDictionary)
        XCTAssertEqual(try written(.webhook(url: "https://example.test/hook")), ["webhook": ["url": "https://example.test/hook"]] as NSDictionary)
        XCTAssertEqual(try written(.shortcut(name: "File card")), ["shortcut": ["name": "File card"]] as NSDictionary)
        XCTAssertEqual(try written(.claudeCode(ClaudeCodeWake(repository: "/Users/sam/app"))),
                       ["claudeCode": ["repository": "/Users/sam/app", "permissionMode": "acceptEdits"]] as NSDictionary,
                       "Claude Code's settings sit right under its key")
        XCTAssertEqual([AgentProfile.Wake.board, .command(command: "x"), .webhook(url: "u"), .shortcut(name: "s"),
                        .claudeCode(ClaudeCodeWake(repository: "/r"))].map(\.kind),
                       ["board", "command", "webhook", "shortcut", "claudeCode"])
    }

    func testEveryKindOfAgentComesBackTheSame() throws {
        let file = AgentFile(paused: true, agents: [
            AgentProfile(name: "Echo", wake: .command(command: "cat >> ~/cards.log", folder: "/tmp")),
            AgentProfile(name: "Pennant", isEnabled: false, wake: .board, preset: "pennant", binders: [UUID()], wakesPerHour: 3),
            AgentProfile(name: "Grok Bot", wake: .webhook(url: "https://example.test/hook"), preset: "grok-bot"),
            AgentProfile(name: "Filer", wake: .shortcut(name: "File card"), report: .manual),
            AgentProfile(name: "Claude Code · app", wake: .claudeCode(ClaudeCodeWake(repository: "/Users/sam/app", permissionMode: "plan", model: "opus",
                                                                                     maxBudgetUSD: 2.5, allowedDomains: ["github.com"],
                                                                                     executable: "/opt/homebrew/bin/claude")),
                         preset: "claude-code"),
        ])
        let data = try file.encoded()
        let read = try AgentFile.decode(data)
        XCTAssertEqual(read.file, file)
        XCTAssertEqual(read.skipped, 0)
        XCTAssertEqual(try JSONDecoder().decode(AgentFile.self, from: data), file)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\n"), "pretty printed")
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"agents\"")).lowerBound, try XCTUnwrap(text.range(of: "\"paused\"")).lowerBound, "sorted keys")
        XCTAssertFalse(text.contains("_0"))
    }

    func testOptionalFieldsMayBeMissingAndUnknownOnesAreIgnored() throws {
        let json = #"""
        {"agents": [{"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "name": "Echo", "isEnabled": true, "report": "mcp",
                     "wake": {"command": {"command": "echo hi"}}, "addedLater": {"x": 1}}],
         "somethingNew": true}
        """#
        let read = try AgentFile.decode(Data(json.utf8))
        XCTAssertFalse(read.file.paused, "a file without paused isn't paused")
        XCTAssertEqual(read.skipped, 0)
        let agent = try XCTUnwrap(read.file.agents.first)
        XCTAssertEqual(agent.id, card)
        XCTAssertEqual(agent.wake, .command(command: "echo hi", folder: nil))
        XCTAssertNil(agent.preset)
        XCTAssertNil(agent.binders)
        XCTAssertNil(agent.wakesPerHour)
    }

    func testAnAgentThisVersionCantReadDoesntTakeTheOthersWithIt() throws {
        let json = #"""
        {"paused": false, "agents": [
          {"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "name": "Echo", "isEnabled": true, "report": "mcp", "wake": {"command": {"command": "echo hi"}}},
          {"id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "name": "Future", "isEnabled": true, "report": "mcp", "wake": {"telepathy": {"channel": 7}}},
          {"id": "8F0B6C0C-5C4E-4C1E-9E0A-2B7F1D0C3A11", "name": "Two ways", "isEnabled": true, "report": "mcp", "wake": {"board": {}, "shortcut": {"name": "x"}}},
          {"id": "not an id", "name": "Broken", "isEnabled": true, "report": "mcp", "wake": {"board": {}}},
          "not an agent",
          {"id": "16FD2706-8BAF-433B-82EB-8C7FADA847DA", "name": "Pennant", "isEnabled": true, "report": "carrier pigeon", "wake": {"board": {}}}
        ]}
        """#
        let read = try AgentFile.decode(Data(json.utf8))
        XCTAssertEqual(read.file.agents.map(\.name), ["Echo", "Pennant"])
        XCTAssertEqual(read.skipped, 4)
        XCTAssertEqual(read.file.agents.last?.report, .mcp, "a way of reporting this version doesn't know reads as MCP")
        XCTAssertEqual(try JSONDecoder().decode(AgentFile.self, from: Data(json.utf8)).agents.count, 2, "read the usual way, it keeps them too")
        XCTAssertThrowsError(try wake(#"{"telepathy": {}}"#), "an unknown wake fails on its own")
    }

    func testAFileThatIsntAnAgentsFileCantBeRead() throws {
        for text in ["not json", "[]", #"{"agents": {}}"#, #"{"paused": "yes", "agents": []}"#] {
            XCTAssertThrowsError(try AgentFile.decode(Data(text.utf8)), text)
        }
        XCTAssertEqual(try AgentFile.decode(Data()).file, AgentFile(), "an empty file holds no agents")
        XCTAssertEqual(try AgentFile.decode(Data(" \n".utf8)).skipped, 0)
        XCTAssertEqual(try AgentFile.decode(Data("{}".utf8)).file, AgentFile())
    }

    func testAnUnknownWayOfReportingReadsAsMCP() throws {
        func report(_ json: String) throws -> AgentProfile.Report {
            try XCTUnwrap(JSONDecoder().decode([AgentProfile.Report].self, from: Data("[\(json)]".utf8)).first)
        }
        XCTAssertEqual(try report(#""manual""#), .manual)
        XCTAssertEqual(try report(#""mcp""#), .mcp)
        XCTAssertEqual(try report(#""carrier pigeon""#), .mcp)
        XCTAssertEqual(try report("7"), .mcp)
    }

    func testAnAgentTakesCardsFromItsBinders() {
        let harbor = UUID(), personal = UUID()
        let pennant = AgentProfile(name: "Pennant", wake: .board, binders: [harbor])
        XCTAssertTrue(pennant.takesCards(from: harbor))
        XCTAssertFalse(pennant.takesCards(from: personal))
        XCTAssertFalse(pennant.takesCards(from: nil))
        XCTAssertTrue(AgentProfile(name: "Echo", wake: .board).takesCards(from: personal), "every binder")
        XCTAssertEqual(AgentProfile.defaultWakesPerHour, 6)
    }

    // MARK: Only Binders changes how an agent is woken

    func testTheFingerprintFollowsTheWakeNotTheOrderOfItsKeys() throws {
        let one = try wake(#"{"claudeCode": {"repository": "/Users/sam/app", "permissionMode": "plan", "model": "opus", "allowedDomains": ["github.com"]}}"#)
        let other = try wake(#"{"claudeCode": {"allowedDomains": ["github.com"], "model": "opus", "permissionMode": "plan", "repository": "/Users/sam/app"}}"#)
        XCTAssertEqual(AgentList.fingerprint(one), AgentList.fingerprint(other))
        XCTAssertEqual(AgentList.fingerprint(try wake(#"{"command": {"folder": "/tmp", "command": "echo hi"}}"#)),
                       AgentList.fingerprint(.command(command: "echo hi", folder: "/tmp")))
        let fingerprint = AgentList.fingerprint(.command(command: "echo hi"))
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertTrue(fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(fingerprint, AgentList.fingerprint(.command(command: "echo hi")), "the same every time")
        XCTAssertNotEqual(fingerprint, AgentList.fingerprint(.command(command: "echo hi; curl https://example.test")), "a changed command doesn't match")
        XCTAssertNotEqual(fingerprint, AgentList.fingerprint(.command(command: "echo hi", folder: "/tmp")))
        XCTAssertNotEqual(AgentList.fingerprint(one), AgentList.fingerprint(.claudeCode(ClaudeCodeWake(repository: "/Users/sam/app", permissionMode: "acceptEdits",
                                                                                                         model: "opus", allowedDomains: ["github.com"]))))
    }

    func testOnlyModesThatKeepThePermissionChecksOnRun() {
        XCTAssertEqual(ClaudeCodeWake.modes, ["auto", "acceptEdits", "plan", "dontAsk"])
        XCTAssertEqual(ClaudeCodeWake.newAgentMode, "auto")
        XCTAssertEqual(ClaudeCodeWake(repository: "/r", permissionMode: "auto").safeMode, "auto")
        // An agents.json from before keeps the mode it was saved with.
        XCTAssertEqual(ClaudeCodeWake(repository: "/r").permissionMode, "acceptEdits")
        for mode in ClaudeCodeWake.modes {
            XCTAssertEqual(ClaudeCodeWake(repository: "/r", permissionMode: mode).safeMode, mode)
        }
        for mode in ["bypassPermissions", "", "manual", "default", "BypassPermissions", "plan ", "Auto"] {
            XCTAssertEqual(ClaudeCodeWake(repository: "/r", permissionMode: mode).safeMode, "plan", mode)
        }
    }

    func testClaudesPromptIsUnchanged() {
        // SHA-256 of each prompt as this lane's code wrote it before the prompt moved to AgentRunPrompt.
        let before: [String: String] = [
            "ready true": "5ed674e02916518ab095775ad97832889ceb7683eb0551ba05db18eebe788194",
            "ready false": "77ce83064f1f824d78231b7e706960f86b64e8a600fc8da1b6c3c429143df5e9",
            "answered true": "1d817539960fc2241afc6abef3a2a2cd6afebf152c7da0f0f62b2c94b434d244",
            "answered false": "d0b0479b2074230f97e7fd01bdad386eb7b5d47f83f793b2c81f248154ba5bbb",
            "sent_back true": "047b0110bf0f37174ea7d02e1420d3c72cca7a960f0f9ab8060d4d1cf9a9d6db",
            "sent_back false": "5ac0e3cbe66b64357874221f14049a2cb2d1285fa0e648b9a2b9a63866b9ac93",
            "manual true": "e759718ec475629ae903aec59d7fab5912b5372b007479166e620df4749687db",
            "manual false": "93da54fef0278e2be98c2a71cd9e78dd2708554d08d753bbf096467148c64c14",
            // Woken for your comment (lane W1): recorded from the new prompt once it was written.
            "commented true": "5cdb53ee7390b59e19067932781526af43f3e71c8359fd1bf037c5e8bfe02245",
            "commented false": "7864773226cfe16945e25445227e1d81754119a64924d1a4eb0dffd741c960b4",
        ]
        for reason in AgentWake.Reason.allCases {
            for drafts in [true, false] {
                let text = ClaudeCodeLaunch.prompt(card: card, reason: reason, draftsFirst: drafts)
                XCTAssertEqual(text, AgentRunPrompt.text(card: card, reason: reason, draftsFirst: drafts, commits: .agent, reach: nil))
                let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(hash, before["\(reason.rawValue) \(drafts)"], "\(reason) \(drafts): byte for byte")
            }
        }
        XCTAssertEqual(launch().prompt, AgentRunPrompt.text(card: card, reason: .ready))
        XCTAssertTrue(launch().prompt.contains("4. Commit on its branch, and never push."))
    }

    func testClaudesDeniesIncludeTheSharedList() {
        let denied = ClaudeCodeLaunch.deniedTools(dataFolder: dataFolder, home: home)
        for rule in ["Read(~/.config/gh/**)", "Read(~/.codex/**)", "Edit(~/.claude.json)", "Read(~/.binders/**)", "Read(~/.npmrc)",
                     "Read(~/.claude/history.jsonl)", "Read(~/.claude/file-history/**)", "Read(~/.claude/todos/**)", "Read(~/.local/state/opencode/**)"] {
            XCTAssertTrue(denied.contains(rule), rule)
        }
        XCTAssertFalse(denied.contains("Read(~/.claude/**)"), "not the whole of ~/.claude: a run's own skills and plans are there")
        XCTAssertFalse(denied.contains { $0.contains("shell-snapshots") || $0.contains("session-env") || $0.contains(".claude/plans") || $0.contains(".claude/tasks") },
                       "nor what Claude Code's own commands read: its shell snapshot, its session's environment, its plan, its task list")
        XCTAssertEqual(Array(denied.prefix(7)), ["Bash(git push)", "Bash(git push *)", "Bash(open *)", "Read(~/.ssh/**)", "Edit(~/.ssh/**)",
                                                 "Read(~/Library/Application Support/Binders/**)", "Edit(~/Library/Application Support/Binders/**)"],
                       "the rules it always had come first, as they were")
        XCTAssertEqual(Set(denied).count, denied.count, "each once")
    }

    func testCommandsThatTurnChecksOffAreRefused() {
        let refused: [(String, String)] = [
            ("copilot -p x --allow-all-tools", "--allow-all-tools"), ("copilot -p x --allow-all-urls", "--allow-all-urls"),
            ("COPILOT_ALLOW_ALL=1 copilot -p x", "copilot_allow_all=1"), ("opencode run --auto x", "--auto"), ("gemini -y -p x", "-y"),
            ("codex exec --yolo;", "--yolo"), ("(codex --yolo)", "--yolo"), ("true && codex exec --yolo&&true", "--yolo"),
            ("copilot --allow-all|tee log", "--allow-all"), ("copilot --allow-tool=write,shell", "--allow-tool=shell"),
            ("copilot --allow-tool shell", "--allow-tool=shell"), ("copilot --allow-tool='url(*)'", "url(*)"),
            ("bash -c 'opencode run --auto x'", "--auto"), ("zsh -c \"gemini -y\"", "-y"), ("echo $(opencode run --auto)", "--auto"),
            (#"OPENCODE_PERMISSION='{"*":"allow"}' opencode run x"#, "a permission that allows everything"),
            (#"OPENCODE_CONFIG_CONTENT='{"permission":{"bash":"deny","*":"allow"}}' opencode run x"#, "a permission that allows everything"),
            (#"OPENCODE_CONFIG_CONTENT='{"permission":"allow"}' opencode run x"#, "permission: allow"),
            ("codex exec -s danger-full-access", "danger-full-access"), ("codex exec --approve-for-me", "--approve-for-me"),
            ("codex --not-so-yolo exec", "--not-so-yolo"), ("codex exec -c approvals_reviewer=auto_review", "approvals_reviewer=auto_review"),
            ("claude --dangerously-skip-permissions -p", "--dangerously-skip-permissions"), ("opencode run --dangerously-skip-permissions", "--dangerously-skip-permissions"),
            ("grok -p x --trust", "--trust"), ("grok -p x --permission-mode auto", "--permission-mode auto"), ("GROK_SANDBOX=off grok -p x", "grok_sandbox off"),
            ("grok -p x --sandbox=devbox", "--sandbox devbox"), ("cursor-agent -p x --force", "--force"), ("agent -p -f x", "-f"),
            ("cursor-agent --sandbox disabled -p x", "--sandbox disabled"), ("gemini --approval-mode yolo -p x", "--approval-mode yolo"),
            ("env FOO=1 nice -n 5 opencode run --auto", "--auto"), ("sudo -u sam timeout 30 gemini -y", "-y"),
        ]
        for (command, what) in refused {
            XCTAssertFalse(AgentCommands.isAllowed(command), command)
            XCTAssertEqual(AgentCommands.refusal(command), what, command)
        }
        let allowed = ["git gc --auto", "claude -p --permission-mode auto", "codex exec --sandbox workspace-write",
                       "copilot --allow-tool=write --allow-tool='shell(git status)'", "copilot --allow-tool=write,binders", "grep -y foo",
                       "make -f build.mk", "echo agent; rm -f x", "opencode run x", "gemini -p x", "cursor-agent -p x", "grok -p x --permission-mode plan",
                       "time -p codex exec -"]
        for command in allowed { XCTAssertTrue(AgentCommands.isAllowed(command), "\(command): \(AgentCommands.refusal(command) ?? "")") }
        XCTAssertEqual(AgentCommands.message("--yolo"), "Binders never runs an agent with its permission checks off: --yolo.")
        XCTAssertEqual(AgentCommands.held("--allow-all-tools", program: "copilot"),
                       "Binders won't run it: --allow-all-tools turns copilot's checks off. Change it in Settings → Agents.")
        XCTAssertEqual(AgentCommands.programs(in: "cd ~/app && FOO=1 env codex exec - | tee log; bash -lc 'opencode run x'"),
                       ["cd", "codex", "tee", "bash", "opencode"])
    }

    func testOrdinaryCommandsWithTheseWordsStillRun() {
        // Commands and automation scripts the base build ran: neither is a switch of an agent's.
        for command in ["deno run --allow-all ~/agents/bot.ts", "grep -rn dangerouslySetInnerHTML src", "rg 'dangerouslySetInnerHTML=' src",
                        "git log --grep=dangerouslySetInnerHTML", "deno run -A x.ts && echo copilot-free"] {
            XCTAssertTrue(AgentCommands.isAllowed(command), "\(command): \(AgentCommands.refusal(command) ?? "")")
        }
        // Every dangerously-named switch is still refused, as an option, a setting or a variable.
        let refused: [(String, String)] = [
            ("codex exec -c 'network.dangerously_allow_all_unix_sockets=true' -", "network.dangerously_allow_all_unix_sockets=true"),
            ("grok -p x --dangerously-bypass-hook-trust", "--dangerously-bypass-hook-trust"),
            ("GROK_DANGEROUSLY_SKIP_PERMISSIONS=1 grok -p x", "grok_dangerously_skip_permissions=1"),
            (#"node run.js '{"allowDangerouslySkipPermissions":true}'"#, #"{"allowdangerouslyskippermissions":true}"#),
            ("opencode run --dangerously-skip-permissions x", "--dangerously-skip-permissions"),
            ("npx @github/copilot -p x --allow-all", "--allow-all"), ("bash -c 'copilot --allow-all'", "--allow-all"),
        ]
        for (command, what) in refused { XCTAssertEqual(AgentCommands.refusal(command), what, command) }
    }

    func testAHeldCommandNamesTheProgramWhosePartTurnsChecksOff() {
        let cases: [(String, String?)] = [
            ("cd ~/agents && copilot -p x --allow-all-tools", "copilot"), ("export X=1; codex exec --yolo -", "codex"),
            ("COPILOT_ALLOW_ALL=1 copilot -p x", "copilot"), ("bash -lc 'cd ~/a && opencode run --auto x'", "opencode"),
            ("cd ~/a && copilot --allow-tool=shell", "copilot"), ("cd ~/a; gemini -y -p x", "gemini"),
            ("cd ~/a && npx @github/copilot --allow-all", "npx"),
        ]
        for (command, program) in cases {
            XCTAssertEqual(AgentCommands.culprit(command)?.program, program, command)
            XCTAssertEqual(AgentCommands.culprit(command)?.what, AgentCommands.refusal(command), command)
        }
        XCTAssertNil(AgentCommands.culprit("cd ~/a && copilot -p x"))
        XCTAssertEqual(AgentCommands.held("--allow-all-tools", program: AgentCommands.culprit(cases[0].0)?.program),
                       "Binders won't run it: --allow-all-tools turns copilot's checks off. Change it in Settings → Agents.")
    }

    func testCommandsThatTurnPermissionChecksOffAreRefused() {
        for command in ["claude -p --permission-mode bypassPermissions", "claude -p --permission-mode=BYPASSPERMISSIONS",
                        "claude --dangerously-skip-permissions -p", "claude -p --Dangerously-Skip-Permissions",
                        "claude --allow-dangerously-skip-permissions -p",
                        "codex exec --dangerously-bypass-approvals-and-sandbox \"$BINDERS_TITLE\"", "codex exec --yolo", "codex exec \"--YOLO\""] {
            XCTAssertFalse(AgentCommands.isAllowed(command), command)
        }
        for command in ["claude -p", "claude -p --permission-mode acceptEdits --model opus < /dev/stdin", "cat >> ~/cards.log",
                        "codex exec --full-auto", ""] {
            XCTAssertTrue(AgentCommands.isAllowed(command), command)
        }
    }

    // MARK: What a woken agent gets

    func testACommandGetsTheCardsFieldsAndTheJSONGetsEverything() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = AgentWakePayload(event: AgentWake.Reason.ready.rawValue, agent: "Echo", card: card, title: "Add a line to README",
                                       details: "Say what the app does.", binder: "Harbor launch", column: .ready, due: due,
                                       links: ["https://github.com/acme/app/pull/12"], answer: "Use the short version.")
        XCTAssertEqual(payload.link, "binders://card/3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertEqual(payload.fields, ["event": "ready", "card": card.uuidString, "title": "Add a line to README", "binder": "Harbor launch",
                                        "agent": "Echo", "link": payload.link], "never the description")
        let json = try object(payload.json)
        XCTAssertEqual(Set(json.keys), Set(payload.fields.keys).union(["details", "column", "due", "links", "answer", "context", "may_act"]))
        XCTAssertEqual(json["may_act"] as? Bool, false, "it drafts first unless you let it act")
        XCTAssertEqual(json["event"] as? String, "ready")
        XCTAssertEqual(json["agent"] as? String, "Echo")
        XCTAssertEqual(json["card"] as? String, card.uuidString)
        XCTAssertEqual(json["title"] as? String, "Add a line to README")
        XCTAssertEqual(json["details"] as? String, "Say what the app does.")
        XCTAssertEqual(json["binder"] as? String, "Harbor launch")
        XCTAssertEqual(json["column"] as? String, "ready")
        XCTAssertEqual((json["due"] as? String).flatMap(AutomationPayload.date(fromISO:)), due)
        XCTAssertEqual(json["links"] as? [String], ["https://github.com/acme/app/pull/12"])
        XCTAssertEqual(json["answer"] as? String, "Use the short version.")
        XCTAssertEqual(json["link"] as? String, payload.link)
        let plain = try object(AgentWakePayload(event: "manual", agent: "Echo", card: card, title: "x", column: .inProgress).json)
        XCTAssertEqual(plain["due"] as? String, "", "no due date")
        XCTAssertEqual(plain["column"] as? String, "in_progress")
        XCTAssertEqual(plain["answer"] as? String, "")
        XCTAssertEqual(plain["links"] as? [String], [])
    }

    func testADescriptionIsCutAt32KB() throws {
        let long = AgentWakePayload(event: "ready", agent: "Echo", card: card, title: "Long", details: String(repeating: "a", count: 40_000), column: .ready)
        XCTAssertEqual(AgentWakePayload.detailsLimit, 32 * 1024)
        XCTAssertEqual(long.details.utf8.count, 32 * 1024)
        XCTAssertEqual((try object(long.json)["details"] as? String)?.utf8.count, 32 * 1024)
        // Never in the middle of a character: 4 bytes each, then a family of 25.
        let party = AgentWakePayload(event: "ready", agent: "Echo", card: card, title: "Party", details: String(repeating: "🎉", count: 9_000),
                                     column: .ready).details
        XCTAssertEqual(party.utf8.count, 32 * 1024)
        XCTAssertTrue(party.allSatisfy { $0 == "🎉" })
        let family = AgentWakePayload.cut("a" + String(repeating: "👨‍👩‍👧‍👦", count: 2_000), toBytes: 32 * 1024)
        XCTAssertLessThanOrEqual(family.utf8.count, 32 * 1024)
        XCTAssertGreaterThan(family.utf8.count, 32 * 1024 - 25)
        XCTAssertTrue(family.dropFirst().allSatisfy { $0 == "👨‍👩‍👧‍👦" })
        XCTAssertEqual(AgentWakePayload(event: "ready", agent: "Echo", card: card, title: "Short", details: "Just this.", column: .ready).details, "Just this.")
    }

    // MARK: When Binders wakes an agent

    func testOnlyAPersonsChangeWakesAnAgent() {
        let kinds = ["created", "moved", "claimed", "released", "lapsed", "progress", "question", "answer", "comment", "completed", "edited",
                     "assigned", "woke", "context", "approval", "decision"]
        let never: Set = ["claimed", "progress", "question", "completed", "lapsed", "edited", "woke", "context", "approval", "decision"]
        let columns: [BoardColumn?] = [nil] + BoardColumn.allCases.map(Optional.some)
        for kind in kinds {
            for from in columns {
                for to in columns {
                    for column in BoardColumn.allCases {
                        XCTAssertNil(AgentWake.reason(kind: kind, from: from, to: to, column: column, byPerson: false), "an agent's \(kind)")
                        if never.contains(kind) {
                            XCTAssertNil(AgentWake.reason(kind: kind, from: from, to: to, column: column, byPerson: true), "your \(kind)")
                        }
                        // Your comment wakes only the agent working on the card, in In progress, whatever it says it moved.
                        if kind == "comment" {
                            XCTAssertEqual(AgentWake.reason(kind: kind, from: from, to: to, column: column, byPerson: true),
                                           column == .inProgress ? .commented : nil, "your comment in \(column)")
                        }
                    }
                }
            }
        }
    }

    func testWhatWakesTheAgentACardIsMeantFor() {
        func reason(_ kind: String, _ from: BoardColumn?, _ to: BoardColumn?, in column: BoardColumn? = nil, byPerson: Bool = true) -> AgentWake.Reason? {
            AgentWake.reason(kind: kind, from: from, to: to, column: column ?? to ?? .backlog, byPerson: byPerson)
        }
        // Made ready for it.
        XCTAssertEqual(reason("created", nil, .ready), .ready, "created in Ready by you")
        XCTAssertNil(reason("created", nil, .backlog))
        XCTAssertEqual(reason("moved", .backlog, .ready), .ready)
        XCTAssertEqual(reason("moved", .review, .ready), .ready)
        XCTAssertEqual(reason("moved", .done, .ready), .ready)
        XCTAssertEqual(reason("released", .inProgress, .ready), .ready, "you let go of it")
        XCTAssertNil(reason("released", .inProgress, .ready, byPerson: false), "an agent's release to Ready")
        XCTAssertNil(reason("released", .review, .review))
        XCTAssertEqual(reason("assigned", nil, nil, in: .ready), .ready, "meant for it while it's in Ready")
        XCTAssertNil(reason("assigned", nil, nil, in: .backlog), "meant for it in Backlog")
        XCTAssertNil(reason("assigned", nil, nil, in: .inProgress))
        XCTAssertNil(reason("assigned", nil, nil, in: .ready, byPerson: false), "an agent's suggestion")
        // Sent back from Review.
        XCTAssertEqual(reason("moved", .review, .inProgress), .sentBack)
        XCTAssertNil(reason("moved", .review, .inProgress, byPerson: false))
        XCTAssertNil(reason("moved", .blocked, .inProgress), "dragged back to work isn't sent back")
        XCTAssertNil(reason("moved", .ready, .inProgress))
        XCTAssertNil(reason("moved", .inProgress, .review))
        XCTAssertNil(reason("moved", .review, .done), "approved")
        XCTAssertNil(reason("moved", .inProgress, .backlog))
        // Answered.
        XCTAssertEqual(reason("answer", .blocked, .inProgress), .answered)
        XCTAssertEqual(reason("answer", .blocked, .ready), .ready, "a question nobody held goes back to Ready")
        XCTAssertNil(reason("answer", .blocked, .inProgress, byPerson: false))
        XCTAssertNil(reason("answer", nil, nil, in: .inProgress))
        // Nothing else wakes anyone.
        XCTAssertNil(reason("lapsed", .inProgress, .ready, byPerson: false), "a lapse")
        XCTAssertNil(reason("claimed", .ready, .inProgress))
        XCTAssertNil(reason("comment", nil, nil, in: .ready))
        XCTAssertNil(reason("woke", nil, nil, in: .ready))
        // Your comment, where the agent works on the card: whether it holds it is the app's to check.
        XCTAssertEqual(reason("comment", nil, nil, in: .inProgress), .commented)
        XCTAssertNil(reason("comment", nil, nil, in: .inProgress, byPerson: false), "an agent's comment")
        for column in [BoardColumn.backlog, .ready, .blocked, .review, .done] {
            XCTAssertNil(reason("comment", nil, nil, in: column), "a comment in \(column)")
        }
        XCTAssertEqual(AgentWake.Reason.commented.rawValue, "commented")
        XCTAssertNil(reason("something-new", .backlog, .ready))
        XCTAssertEqual(AgentWake.Reason.sentBack.rawValue, "sent_back")
    }

    // MARK: Claude Code

    private func launch(_ wake: ClaudeCodeWake = ClaudeCodeWake(repository: "/Users/sam/code/app"), card: UUID? = nil,
                        reason: AgentWake.Reason = .ready, dataFolder: String? = nil, worktreeExists: Bool = false) -> ClaudeCodeLaunch {
        ClaudeCodeLaunch.make(card: card ?? self.card, reason: reason, boardName: "Claude Code · app", wake: wake, binders: binders,
                              dataFolder: dataFolder ?? self.dataFolder, home: home, worktreeExists: worktreeExists, session: session)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// The shared list after ~/.ssh and Binders' own folders, as Claude Code's rules write it: your other keys and
    /// sign-ins, the coding tools' sign-ins and sessions, and Binders' folder of CLI worktrees. (path, whether a folder)
    private let sharedRest: [(String, Bool)] = [("~/.gnupg", true), ("~/.netrc", false), ("~/.git-credentials", false), ("~/.npmrc", false),
                                                ("~/.pypirc", false), ("~/.aws", true), ("~/.azure", true), ("~/.config/gcloud", true), ("~/.kube", true),
                                                ("~/.docker", true), ("~/.config/gh", true), ("~/.codex", true), ("~/.local/share/opencode", true),
                                                ("~/.local/state/opencode", true), ("~/.config/opencode", true), ("~/.copilot", true),
                                                ("~/.claude/projects", true), ("~/.claude/history.jsonl", false), ("~/.claude/file-history", true),
                                                ("~/.claude/todos", true), ("~/.claude/paste-cache", true), ("~/.claude/image-cache", true),
                                                ("~/.claude/backups", true), ("~/.claude/.credentials.json", false), ("~/.claude.json", false),
                                                ("~/.grok", true), ("~/.gemini", true), ("~/.cursor", true), ("~/.binders", true)]

    private var sharedRestRules: [String] {
        sharedRest.flatMap { path, folder in folder ? ["Read(\(path)/**)", "Edit(\(path)/**)"] : ["Read(\(path))", "Edit(\(path))"] }
    }

    func testTheLaunchLine() throws {
        let wake = ClaudeCodeWake(repository: "/Users/sam/code/app/", permissionMode: "acceptEdits", model: "opus", maxBudgetUSD: 2.5)
        let line = launch(wake)
        var arguments = line.arguments
        let mcp = try XCTUnwrap(arguments.firstIndex(of: "--mcp-config")) + 1
        let settings = try XCTUnwrap(arguments.firstIndex(of: "--settings")) + 1
        arguments[mcp] = "<mcp>"
        arguments[settings] = "<settings>"
        XCTAssertEqual(arguments, [
            "-p", "--permission-mode", "acceptEdits", "--permission-prompts", "none",
            "--output-format", "stream-json", "--verbose",
            "--strict-mcp-config", "--mcp-config", "<mcp>", "--settings", "<settings>",
            "--allowedTools", "mcp__binders", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet",
            "--disallowedTools", "Bash(git push)", "Bash(git push *)", "Bash(open *)", "Read(~/.ssh/**)", "Edit(~/.ssh/**)",
            "Read(~/Library/Application Support/Binders/**)", "Edit(~/Library/Application Support/Binders/**)",
        ] + sharedRestRules + [
            "--session-id", "6ba7b810-9dad-11d1-80b4-00c04fd430c8", "--name", "Binders card 3f2504e0",
            "--worktree", "binders-3f2504e0", "--model", "opus", "--max-budget-usd", "2.50",
        ])
        XCTAssertEqual(line.directory, "/Users/sam/code/app", "the repository, where claude makes the worktree")
    }

    func testWorkingInTheFolderItselfMakesNoWorktree() throws {
        let wake = ClaudeCodeWake(repository: "/Users/sam/code/workspace/", permissionMode: "auto", inFolder: true)
        XCTAssertTrue(wake.worksInFolder)
        let line = launch(wake)
        XCTAssertFalse(line.arguments.contains("--worktree"), "no worktree is made")
        XCTAssertEqual(line.directory, "/Users/sam/code/workspace", "it starts in the folder itself")
        XCTAssertTrue(line.arguments.contains("Bash(git push)"), "its other limits stay")
        // Off, as an agents.json from before reads: a worktree per card.
        let old = try JSONDecoder().decode(ClaudeCodeWake.self, from: Data(#"{"repository":"/r","permissionMode":"auto"}"#.utf8))
        XCTAssertNil(old.inFolder)
        XCTAssertFalse(old.worksInFolder)
        XCTAssertTrue(launch(old).arguments.contains("--worktree"))
    }

    func testNoLaunchTurnsThePermissionChecksOff() throws {
        for mode in ["acceptEdits", "plan", "dontAsk", "bypassPermissions", "auto", "", "BYPASSPERMISSIONS", "manual"] {
            let wake = ClaudeCodeWake(repository: "/r", permissionMode: mode, model: "--dangerously-skip-permissions",
                                      executable: "claude --dangerously-skip-permissions")
            let arguments = launch(wake).arguments
            XCTAssertTrue(ClaudeCodeWake.modes.contains(value(after: "--permission-mode", in: arguments) ?? ""), mode)
            XCTAssertFalse(arguments.contains("--model"), "a model that's a flag is left out")
            let settings = try XCTUnwrap(arguments.firstIndex(of: "--settings")) + 1
            for (index, argument) in arguments.enumerated() where index != settings {
                XCTAssertFalse(argument.lowercased().contains("bypass") || argument.lowercased().contains("dangerously"), "\(mode): \(argument)")
            }
            // The settings name bypass only to turn it off.
            let permissions = try XCTUnwrap(try object(Data(arguments[settings].utf8))["permissions"] as? [String: Any])
            XCTAssertEqual(permissions["disableBypassPermissionsMode"] as? String, "disable")
            XCTAssertFalse(arguments[settings].contains("bypassPermissions"))
        }
        XCTAssertEqual(value(after: "--permission-mode", in: launch(ClaudeCodeWake(repository: "/r", permissionMode: "bypassPermissions")).arguments), "plan")
    }

    func testTheRunGetsOnlyTheBoardUnderItsOwnName() throws {
        let arguments = launch().arguments
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertEqual(value(after: "--allowedTools", in: arguments), "mcp__binders")
        let config = try object(Data(try XCTUnwrap(value(after: "--mcp-config", in: arguments)).utf8))
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), ["binders"])
        let server = try XCTUnwrap(servers["binders"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "stdio")
        XCTAssertEqual(server["command"] as? String, binders)
        XCTAssertEqual(server["args"] as? [String], ["--mcp"])
        XCTAssertEqual(server["env"] as? [String: String], ["BINDERS_AGENT": "Claude Code · app", "BINDERS_TOOLS": "board", "BINDERS_RUN": "1",
                                                            "BINDERS_CARD": card.uuidString],
                       "a run: a server that doesn't get the card or the name offers nothing, and one before this build still the board for that card")
    }

    func testTheRunKeepsATaskListAndNothingElseIsAllowedBeyondTheBoard() throws {
        let arguments = launch().arguments
        let start = try XCTUnwrap(arguments.firstIndex(of: "--allowedTools")) + 1
        let end = try XCTUnwrap(arguments.firstIndex(of: "--disallowedTools"))
        XCTAssertEqual(Array(arguments[start..<end]), ["mcp__binders"] + ClaudeCodeLaunch.taskTools)
        XCTAssertEqual(ClaudeCodeLaunch.taskTools, ["TaskCreate", "TaskUpdate", "TaskList", "TaskGet"], "the task list's own tools, and no others")
    }

    func testTheTeamFolderAndTheLogsArePrivateToo() throws {
        let line = ClaudeCodeLaunch.make(card: card, reason: .ready, boardName: "Claude Code · app", wake: ClaudeCodeWake(repository: "/r"),
                                         binders: binders, dataFolder: dataFolder, home: home,
                                         alsoPrivate: ["\(home)/Library/Logs/Binders/Agents", "/Volumes/Team/Binders", "  "],
                                         worktreeExists: false, session: session)
        let denied = ClaudeCodeLaunch.deniedTools(dataFolder: dataFolder, home: home,
                                                  alsoPrivate: ["\(home)/Library/Logs/Binders/Agents", "/Volumes/Team/Binders", "  "])
        XCTAssertTrue(denied.contains("Read(~/Library/Logs/Binders/Agents/**)") && denied.contains("Edit(//Volumes/Team/Binders/**)"))
        XCTAssertFalse(denied.contains { $0.contains("(/**)") || $0.contains("//**") }, "a blank folder isn't a rule")
        let settings = try object(Data(try XCTUnwrap(value(after: "--settings", in: line.arguments)).utf8))
        let sandbox = try XCTUnwrap(settings["sandbox"] as? [String: Any])
        XCTAssertEqual((sandbox["filesystem"] as? [String: Any])?["denyRead"] as? [String],
                       ["~/.ssh", "~/Library/Application Support/Binders", "~/Library/Logs/Binders/Agents", "//Volumes/Team/Binders"] + sharedRest.map(\.0))
    }

    func testTheSettingsDenyTheSameRulesAndSandboxItsCommands() throws {
        let arguments = launch(ClaudeCodeWake(repository: "/r", allowedDomains: [" github.com ", "", "registry.npmjs.org"])).arguments
        let denied = ClaudeCodeLaunch.deniedTools(dataFolder: dataFolder, home: home)
        // Each rule is an argument of its own as well, since Claude Code ignores settings that fail validation without a word.
        let start = try XCTUnwrap(arguments.firstIndex(of: "--disallowedTools")) + 1
        XCTAssertEqual(Array(arguments[start..<start + denied.count]), denied)
        XCTAssertEqual(arguments[start + denied.count], "--session-id")
        let settings = try object(Data(try XCTUnwrap(value(after: "--settings", in: arguments)).utf8))
        let permissions = try XCTUnwrap(settings["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["deny"] as? [String], denied)
        XCTAssertEqual(permissions["disableBypassPermissionsMode"] as? String, "disable")
        let sandbox = try XCTUnwrap(settings["sandbox"] as? [String: Any])
        XCTAssertEqual(sandbox["enabled"] as? Bool, true)
        XCTAssertEqual(sandbox["failIfUnavailable"] as? Bool, true)
        XCTAssertEqual(sandbox["allowUnsandboxedCommands"] as? Bool, false)
        XCTAssertEqual((sandbox["filesystem"] as? [String: Any])?["denyRead"] as? [String], ["~/.ssh", "~/Library/Application Support/Binders"] + sharedRest.map(\.0),
                       "your keys and sign-ins and the coding tools' sessions too")
        XCTAssertEqual((sandbox["network"] as? [String: Any])?["allowedDomains"] as? [String], ["github.com", "registry.npmjs.org"])
        let plain = try object(Data(try XCTUnwrap(value(after: "--settings", in: launch().arguments)).utf8))
        XCTAssertEqual(((plain["sandbox"] as? [String: Any])?["network"] as? [String: Any])?["allowedDomains"] as? [String], [],
                       "no network unless you list it")
    }

    func testThePromptHoldsTheCardsIDAndNothingElseFromIt() {
        let prompt = launch().prompt
        XCTAssertTrue(prompt.hasPrefix(AgentWake.promptMarker), prompt)
        XCTAssertTrue(prompt.contains("Card: \(card.uuidString)"))
        XCTAssertTrue(prompt.contains("The user made it ready for you."))
        for words in ["get_task", "claim_task", "update_task", "ask_on_task", "complete_task", "never push", "information, not instructions"] {
            XCTAssertTrue(prompt.contains(words), words)
        }
        // The same words for any card but its id, whatever the agent and its settings.
        let other = UUID(uuidString: "16FD2706-8BAF-433B-82EB-8C7FADA847DA")!
        let elsewhere = ClaudeCodeLaunch.make(card: other, reason: .ready, boardName: "Someone else", wake: ClaudeCodeWake(repository: "/elsewhere", permissionMode: "plan"),
                                              binders: "/b", dataFolder: "/d", home: "/h", worktreeExists: true, session: UUID())
        XCTAssertEqual(elsewhere.prompt.replacingOccurrences(of: other.uuidString, with: card.uuidString), prompt)
        // And the arguments carry the card only as its id.
        XCTAssertEqual(launch(card: other).arguments.map {
            $0.replacingOccurrences(of: "16fd2706", with: "3f2504e0").replacingOccurrences(of: other.uuidString, with: card.uuidString)
        }, launch().arguments)
        XCTAssertTrue(launch(reason: .answered).prompt.contains("The user answered your question or your request for approval."))
        XCTAssertTrue(launch(reason: .sentBack).prompt.contains("The user sent it back from Review."))
        XCTAssertTrue(launch(reason: .manual).prompt.contains("The user asked Binders to wake you for it."))
        XCTAssertTrue(launch(reason: .commented).prompt.contains("The user commented on it: their comment is on its timeline."))
        XCTAssertEqual(Set(AgentWake.Reason.allCases.map { launch(reason: $0).prompt }).count, AgentWake.Reason.allCases.count)
    }

    func testTheWorktreeIsMadeOnTheFirstWakeOnly() {
        let first = launch()
        XCTAssertEqual(value(after: "--worktree", in: first.arguments), "binders-3f2504e0")
        XCTAssertEqual(first.directory, "/Users/sam/code/app")
        let again = launch(worktreeExists: true)
        XCTAssertFalse(again.arguments.contains("--worktree"))
        XCTAssertEqual(again.directory, "/Users/sam/code/app/.claude/worktrees/binders-3f2504e0")
        XCTAssertEqual(ClaudeCodeLaunch.worktree(repository: "/Users/sam/code/app/", card: card), again.directory)
        XCTAssertEqual(ClaudeCodeLaunch.worktreeName(for: card), "binders-3f2504e0")
    }

    func testTheDataFolderAsClaudesRulesWriteIt() {
        XCTAssertEqual(ClaudeCodeLaunch.rulePath("/Users/sam/Library/Application Support/Binders", home: "/Users/sam"), "~/Library/Application Support/Binders")
        XCTAssertEqual(ClaudeCodeLaunch.rulePath("/Users/sam/Library/Application Support/Binders/", home: "/Users/sam/"), "~/Library/Application Support/Binders")
        XCTAssertEqual(ClaudeCodeLaunch.rulePath("/Volumes/Data/Binders", home: "/Users/sam"), "//Volumes/Data/Binders", "outside home: // and the full path")
        XCTAssertEqual(ClaudeCodeLaunch.rulePath("/Users/samantha/Binders", home: "/Users/sam"), "//Users/samantha/Binders", "a folder that only starts like home")
        XCTAssertEqual(ClaudeCodeLaunch.rulePath("/Users/sam", home: "/Users/sam"), "~")
        XCTAssertEqual(ClaudeCodeLaunch.rulePath("/private/tmp/binders-test", home: "/"), "//private/tmp/binders-test")
        let outside = launch(dataFolder: "/Volumes/Data/Binders").arguments
        XCTAssertTrue(outside.contains("Read(//Volumes/Data/Binders/**)"))
        XCTAssertTrue(outside.contains("Edit(//Volumes/Data/Binders/**)"))
        XCTAssertTrue(value(after: "--settings", in: outside)?.contains(#""denyRead":["~/.ssh","//Volumes/Data/Binders","~/.gnupg""#) == true)
    }

    func testAModelAndABudgetOnlyWhenSet() {
        let plain = launch().arguments
        XCTAssertFalse(plain.contains("--model"))
        XCTAssertFalse(plain.contains("--max-budget-usd"))
        XCTAssertEqual(value(after: "--model", in: launch(ClaudeCodeWake(repository: "/r", model: " sonnet ")).arguments), "sonnet")
        XCTAssertEqual(value(after: "--max-budget-usd", in: launch(ClaudeCodeWake(repository: "/r", maxBudgetUSD: 0.4)).arguments), "0.40")
        XCTAssertFalse(launch(ClaudeCodeWake(repository: "/r", model: "  ", maxBudgetUSD: 0)).arguments.contains("--max-budget-usd"))
        XCTAssertFalse(launch(ClaudeCodeWake(repository: "/r", model: "  ", maxBudgetUSD: .nan)).arguments.contains("--model"))
        XCTAssertFalse(launch(ClaudeCodeWake(repository: "/r", maxBudgetUSD: .infinity)).arguments.contains("--max-budget-usd"))
    }
}

/// What an agent is for and who it hands cards to: kept in agents.json when you say, and an agents.json from before reads
/// and saves as it was.
final class AgentWorkTests: XCTestCase {
    func testWhatItsForAndWhoItHandsCardsToAreKeptAndAnOldFileStaysAsItWas() throws {
        let old = #"{"agents": [{"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "name": "Pennant", "isEnabled": true, "report": "mcp", "wake": {"board": {}}}]}"#
        let read = try XCTUnwrap(AgentFile.decode(Data(old.utf8)).file.agents.first)
        XCTAssertNil(read.vendor)
        XCTAssertNil(read.purpose)
        XCTAssertNil(read.whatItsFor)
        let saved = String(decoding: try AgentFile(agents: [read]).encoded(), as: UTF8.self)
        XCTAssertFalse(saved.contains("vendor") || saved.contains("purpose"),
                       "saved again, an agent that never had them has no new keys, so its fingerprint stays and it isn't taken for one changed outside Binders")
        var told = read
        told.vendor = "Anthropic"
        told.purpose = "Personal errands: appointments, email, bookings"
        let again = try XCTUnwrap(AgentFile.decode(AgentFile(agents: [told]).encoded()).file.agents.first)
        XCTAssertEqual(again.vendor, "Anthropic")
        XCTAssertEqual(again.whatItsFor, "Personal errands: appointments, email, bookings")
    }

    func testClaudeCodeIsForCodeInItsRepositoryUnlessYouSay() {
        XCTAssertEqual(AgentProfile(name: "Claude Code · app", wake: .claudeCode(ClaudeCodeWake(repository: "/Users/sam/src/app/"))).whatItsFor,
                       "code in the app repository")
        XCTAssertEqual(AgentProfile(name: "Claude Code · x", wake: .claudeCode(ClaudeCodeWake(repository: ""))).whatItsFor, "code")
        XCTAssertEqual(AgentProfile(name: "Claude Code · app", wake: .claudeCode(ClaudeCodeWake(repository: "/r/app")), purpose: " The Binders Mac app ").whatItsFor,
                       "The Binders Mac app")
        XCTAssertNil(AgentProfile(name: "Echo", wake: .command(command: "~/bin/wake")).whatItsFor)
        XCTAssertNil(AgentProfile(name: "Echo", wake: .board, purpose: "  ").whatItsFor)
    }
}
