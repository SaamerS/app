import XCTest
@testable import BindersKit

/// What Binders' MCP server offers a run, by what started it.
final class MCPServerModeTests: XCTestCase {
    private let card = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    func testEveryRunBindersStartsIsConfinedToItsCardOrGetsNothing() {
        // As every run Binders starts now has it: board, which a Binders before this one also confines to the card, and run.
        let run = ["BINDERS_TOOLS": "board", "BINDERS_RUN": "1"]
        XCTAssertEqual(MCPConfinement.read(run.merging(["BINDERS_CARD": card.uuidString, "BINDERS_AGENT": "Codex · app"]) { a, _ in a }), .card(card))
        XCTAssertEqual(MCPConfinement.read(run.merging(["BINDERS_AGENT": "Codex · app"]) { a, _ in a }), .nothing, "no card: no tools")
        XCTAssertEqual(MCPConfinement.read(run.merging(["BINDERS_CARD": "not-a-card", "BINDERS_AGENT": "Codex · app"]) { a, _ in a }), .nothing)
        XCTAssertEqual(MCPConfinement.read(run.merging(["BINDERS_CARD": card.uuidString]) { a, _ in a }), .nothing, "no name: no tools")
        XCTAssertEqual(MCPConfinement.read(run.merging(["BINDERS_CARD": card.uuidString, "BINDERS_AGENT": "You"]) { a, _ in a }), .nothing)
        XCTAssertEqual(MCPConfinement.read(["BINDERS_RUN": "1", "BINDERS_CARD": card.uuidString, "BINDERS_AGENT": "Codex · app"]), .card(card),
                       "BINDERS_RUN decides, whatever BINDERS_TOOLS says")
        XCTAssertEqual(MCPConfinement.read(["BINDERS_RUN": "", "BINDERS_TOOLS": "all"]), .nothing, "set at all, it's a run")
        // This build's first way of saying so still confines.
        XCTAssertEqual(MCPConfinement.read(["BINDERS_TOOLS": "card", "BINDERS_CARD": card.uuidString, "BINDERS_AGENT": "Codex · app"]), .card(card))
        XCTAssertEqual(MCPConfinement.read(["BINDERS_TOOLS": "card", "BINDERS_AGENT": "Codex · app"]), .nothing, "no card: no tools")
        XCTAssertEqual(MCPConfinement.read(["BINDERS_TOOLS": "card", "BINDERS_CARD": "not-a-card", "BINDERS_AGENT": "Codex · app"]), .nothing)
        XCTAssertEqual(MCPConfinement.read(["BINDERS_TOOLS": "card", "BINDERS_CARD": card.uuidString]), .nothing, "no name: no tools")
        XCTAssertEqual(MCPConfinement.read(["BINDERS_TOOLS": "card", "BINDERS_CARD": card.uuidString, "BINDERS_AGENT": "  "]), .nothing)
        XCTAssertEqual(MCPConfinement.read(["BINDERS_TOOLS": "card", "BINDERS_CARD": card.uuidString, "BINDERS_AGENT": "You"]), .nothing,
                       "never your name")
        XCTAssertEqual(MCPConfinement.read(["BINDERS_TOOLS": "board"]), .board(card: nil), "an agent's own server, as before")
        XCTAssertEqual(MCPConfinement.read(["BINDERS_TOOLS": "board", "BINDERS_CARD": card.uuidString]), .board(card: card))
        XCTAssertEqual(MCPConfinement.read([:]), .everything)
        XCTAssertEqual(MCPConfinement.read(["BINDERS_TOOLS": "all", "BINDERS_CARD": card.uuidString]), .everything, "anything else is your own host")
        XCTAssertEqual(MCPConfinement.card(card).card, card)
        XCTAssertNil(MCPConfinement.nothing.card)
        XCTAssertTrue(MCPConfinement.nothing.boardOnly)
        XCTAssertFalse(MCPConfinement.everything.boardOnly)
    }
}

/// Copilot's settings folder for Binders' runs, made ready before each one.
final class CopilotHomeTests: XCTestCase {
    func testWhatsSetBackAndWhatStays() throws {
        let looked = #"{"trusted_folders":["/Users/sam/.binders/worktrees/app-1/binders-x-copilot"],"disableAllHooks":false,"includeCoAuthoredBy":true,"auto_update":true,"ide":{"auto_connect":true,"other":1},"copilot_url":"https://example.test","allowed_urls":["*"],"hooks":{"agentStop":[]},"experimental":true,"model":"claude-sonnet-4.5","last_logged_in_user":{"login":"sam"}}"#
        let reset = try XCTUnwrap(JSONSerialization.jsonObject(with: try CopilotHome.reset(Data(looked.utf8))) as? [String: Any])
        XCTAssertEqual(reset["trusted_folders"] as? [String], [])
        XCTAssertEqual(reset["disableAllHooks"] as? Bool, true)
        XCTAssertEqual(reset["includeCoAuthoredBy"] as? Bool, false, "no commit trailer")
        XCTAssertEqual(reset["auto_update"] as? Bool, false)
        XCTAssertEqual(reset["ide"] as? NSDictionary, ["auto_connect": false, "other": 1] as NSDictionary)
        for key in ["copilot_url", "allowed_urls", "hooks", "experimental"] { XCTAssertNil(reset[key], key) }
        XCTAssertEqual(reset["model"] as? String, "claude-sonnet-4.5", "the rest stays")
        XCTAssertNotNil(reset["last_logged_in_user"])
        let fresh = try XCTUnwrap(JSONSerialization.jsonObject(with: try CopilotHome.reset(nil)) as? [String: Any])
        XCTAssertEqual(fresh["disableAllHooks"] as? Bool, true, "a folder Copilot hasn't used yet starts safe")
        XCTAssertThrowsError(try CopilotHome.reset(Data("not json".utf8)))
        XCTAssertThrowsError(try CopilotHome.reset(Data("[1]".utf8)))
        XCTAssertEqual(CopilotHome.deleted, ["permissions-config.json", "permissions-config"], "approvals given while looking in")
    }

    func testEachBlocker() {
        let folder = "~/.binders/copilot"
        XCTAssertNil(CopilotHome.problem(present: ["config.json", "session-state", "logs"], mcpConfig: nil, folder: folder))
        XCTAssertNil(CopilotHome.problem(present: [], mcpConfig: Data(#"{"mcpServers":{}}"#.utf8), folder: folder), "an empty server list")
        XCTAssertEqual(CopilotHome.problem(present: ["hooks"], mcpConfig: nil, folder: folder),
                       "Binders didn't start GitHub Copilot CLI: its settings folder for Binders' runs, ~/.binders/copilot, now has hooks/, probably added while you looked in on a run. Remove it there, then Wake Now.")
        XCTAssertTrue(CopilotHome.problem(present: [], mcpConfig: Data(#"{"mcpServers":{"mine":{"command":"x"}}}"#.utf8), folder: folder)?
            .contains("now has mcp-config.json with a server in it") == true)
        XCTAssertTrue(CopilotHome.problem(present: [], mcpConfig: Data("{".utf8), folder: folder)?.contains("isn't JSON") == true)
        for name in CopilotHome.blockingFiles + CopilotHome.blockingFolders {
            XCTAssertNotNil(CopilotHome.problem(present: [name], mcpConfig: nil, folder: folder), name)
        }
    }
}

/// Codex's settings from an administrator.
final class CodexManagedTests: XCTestCase {
    func testEachManagedFileAndAForcedPreferenceRefuses() {
        XCTAssertNil(CodexManaged.problem(existing: [], forced: []))
        for file in CodexManaged.files {
            XCTAssertEqual(CodexManaged.problem(existing: [file], forced: []),
                           "Binders didn't start Codex: this Mac has Codex settings from an administrator (\(file)), and they could change the run's sandbox or where it sends cards.")
            XCTAssertEqual(CodexManaged.found(existing: [file], forced: []), "Codex settings from an administrator are on this Mac (\(file)), so Binders won't start Codex.")
        }
        XCTAssertTrue(CodexManaged.problem(existing: [], forced: ["requirements_toml_base64"])?.contains("a managed com.openai.codex profile") == true)
        XCTAssertEqual(CodexManaged.forcedKeys, ["config_toml_base64", "requirements_toml_base64"])
        XCTAssertEqual(CodexManaged.files, ["/etc/codex/config.toml", "/etc/codex/requirements.toml", "/etc/codex/managed_config.toml"])
    }

    func testAnythingElseInTheFolderRefusesToo() {
        // Rules there load even with --ignore-rules, and hooks there count as trusted.
        XCTAssertEqual(CodexManaged.folder, "/etc/codex")
        XCTAssertTrue(CodexManaged.problem(existing: ["/etc/codex/rules"], forced: [])?.contains("(/etc/codex/rules)") == true)
        XCTAssertTrue(CodexManaged.problem(existing: ["/etc/codex/skills", "/etc/codex/hooks.json"], forced: [])?.contains("(/etc/codex/hooks.json)") == true,
                      "the first by name")
        XCTAssertTrue(CodexManaged.problem(existing: ["/etc/codex/rules", "/etc/codex/requirements.toml"], forced: [])?.contains("(/etc/codex/requirements.toml)") == true,
                      "a settings file is named first")
        XCTAssertTrue(CodexManaged.counts("rules") && CodexManaged.counts("hooks.json"))
        XCTAssertFalse(CodexManaged.counts(".DS_Store"), "a hidden file Codex doesn't read")
        XCTAssertTrue(CodexLaunch.disabledFeatures.contains("hooks"), "and Binders turns hooks off besides")
    }
}

/// The small TOML reader the self-test's stand-in reads Codex's overrides with.
final class TOMLValueTests: XCTestCase {
    func testValues() {
        XCTAssertEqual(TOMLValue.parse(#""a\"b\\c\u00e9""#), .string("a\"b\\cé"))
        XCTAssertEqual(TOMLValue.parse("'C:\\path'"), .string("C:\\path"), "a literal string keeps its backslashes")
        XCTAssertEqual(TOMLValue.parse("true"), .bool(true))
        XCTAssertEqual(TOMLValue.parse("1_000"), .integer(1000))
        XCTAssertEqual(TOMLValue.parse(#"["--mcp", 'x',]"#), .array([.string("--mcp"), .string("x")]))
        XCTAssertEqual(TOMLValue.parse(#"{ A = "1", "b.c" = { d = true }, e.f = 2 }"#),
                       .table(["A": .string("1"), "b.c": .table(["d": .bool(true)]), "e": .table(["f": .integer(2)])]))
        for broken in [#""open"#, "[1,", "{ a = }", "nope", #""a" trailing"#] { XCTAssertNil(TOMLValue.parse(broken), broken) }
        let all = TOMLValue.overrides(["exec", "-c", #"mcp_servers.binders.command="/b""#, "-c", "mcp_servers.binders.args=[\"--mcp\"]",
                                       "-c", "web_search=not toml", "-c", #"x.y={ a = "1" }"#, "-c", #"x.y={ b = "2" }"#, "-"])
        XCTAssertEqual(all["mcp_servers.binders.command"], .string("/b"))
        XCTAssertEqual(all["mcp_servers.binders.args"], .array([.string("--mcp")]))
        XCTAssertEqual(all["web_search"], .string("not toml"), "a value that isn't TOML is its raw text, as Codex reads it")
        XCTAssertEqual(all["x.y"], .table(["a": .string("1"), "b": .string("2")]))
    }
}

/// Consent for the CLI tools: the company each one names, and fingerprints that ask again when where cards go changes,
/// while every older agent keeps its own.
final class AgentConsentTests: XCTestCase {
    private func cli(_ tool: CLIAgent, model: String? = nil, executable: String? = nil, vendor: String? = nil) -> AgentProfile {
        AgentProfile(name: "\(tool.shortName) · app", wake: .cliAgent(CLIAgentWake(tool: tool, repository: "/Users/sam/code/app", model: model,
                                                                                 executable: executable)), preset: tool.rawValue, vendor: vendor)
    }

    /// Computed with this lane's code before the change (the base commit), for the same agents.
    func testOldAgentsKeepTheirFingerprints() {
        let some = AgentReads(captures: true, transcripts: false, team: true)
        let agents: [(AgentProfile, String, String)] = [
            (AgentProfile(name: "Claude Code · app", wake: .claudeCode(ClaudeCodeWake(repository: "/Users/sam/code/app", permissionMode: "plan",
                                                                                         allowedDomains: ["github.com"])), preset: "claude-code"),
             "6fee25257b43d4cb", "c572ed60b3dc4008"),
            (AgentProfile(name: "Codex helper", wake: .command(command: "codex exec -", folder: "/Users/sam/code/app")), "18b7ea9ad9b8d793", "77d9493e52c676c4"),
            (AgentProfile(name: "Grok Bot", wake: .webhook(url: "https://example.test/hook"), preset: "grok-bot"), "8e17e5b4870fdbb7", "fd256f9e4222383c"),
            (AgentProfile(name: "Filer", wake: .shortcut(name: "File card"), report: .manual), "0d153c55b29b5233", "f0b65883d0997c04"),
            (AgentProfile(name: "Pennant", wake: .board, preset: "pennant"), "3739effaf583a8ed", "4edee5c4e02778bd"),
            (AgentProfile(name: "Claude Code · app", wake: .claudeCode(ClaudeCodeWake(repository: "/Users/sam/code/app")), vendor: "Amazon Bedrock"),
             "728f9e7164e4cdbb", "79fb18ce72e76a16"),
        ]
        for (agent, nothing, more) in agents {
            XCTAssertEqual(AgentConsent.fingerprint(agent, reads: .nothing), nothing, agent.name)
            XCTAssertEqual(AgentConsent.fingerprint(agent, reads: some), more, agent.name)
        }
    }

    func testACopilotCommandIsNowGitHubSoItsFingerprintChanges() {
        let command = AgentProfile(name: "Copilot helper", wake: .command(command: "copilot -p x"))
        XCTAssertEqual(AgentConsent.vendor(command), "GitHub (Microsoft)")
        XCTAssertNotEqual(AgentConsent.fingerprint(command, reads: .nothing), "24b21ef7fb2df00d", "the yes it had didn't name GitHub, so its iPhone asks once more")
        XCTAssertEqual(AgentConsent.vendor(AgentProfile(name: "x", wake: .command(command: "/opt/homebrew/bin/copilot --model gpt-5"))), "GitHub (Microsoft)")
    }

    func testCLIAgentsNameTheirCompany() {
        XCTAssertEqual(AgentConsent.vendor(cli(.codex)), "OpenAI")
        XCTAssertEqual(AgentConsent.vendor(cli(.copilot)), "GitHub (Microsoft)")
        XCTAssertEqual(AgentConsent.vendor(cli(.codex, vendor: "Somewhere else")), "OpenAI", "Binders fixes where Codex sends cards: a typed name can't say otherwise")
        XCTAssertEqual(AgentConsent.vendor(cli(.copilot, vendor: "Anthropic")), "GitHub (Microsoft)")
        let opencode = cli(.opencode, model: "anthropic/claude-sonnet-4-5")
        XCTAssertEqual(AgentConsent.vendor(opencode), "the anthropic provider, as set up in your OpenCode")
        XCTAssertEqual(opencode.sendsTo, "the anthropic provider, as set up in your OpenCode")
        XCTAssertEqual(AgentConsent.vendor(cli(.opencode, model: "anthropic/x", vendor: "My proxy")), "My proxy", "what you typed, for OpenCode")
        XCTAssertNil(AgentConsent.vendor(cli(.opencode)))
        XCTAssertEqual(cli(.codex).sendsTo, "OpenAI")
        func disclosure(_ agent: AgentProfile, wakes: String? = nil) -> String {
            AgentConsent.disclosure(name: agent.name, wakes: wakes ?? agent.wake.kind, sendsTo: agent.sendsTo, vendor: AgentConsent.vendor(agent))
        }
        XCTAssertTrue(disclosure(cli(.codex)).contains("Binders starts Codex · app on your Mac, which sends them to OpenAI."), disclosure(cli(.codex)))
        XCTAssertTrue(disclosure(cli(.copilot)).contains("which sends them to GitHub (Microsoft)."))
        XCTAssertTrue(disclosure(opencode).contains("which sends them to the anthropic provider, as set up in your OpenCode."))
        // An iPhone from before this build shows its default words, with the same vendor.
        XCTAssertTrue(disclosure(cli(.codex), wakes: "somethingNew").contains("Codex · app sends them to OpenAI."))
        XCTAssertTrue(disclosure(opencode, wakes: "somethingNew").contains("OpenCode · app sends them to the anthropic provider, as set up in your OpenCode."))
    }

    func testOpenCodesProviderIsInItsFingerprint() {
        let zen = AgentConsent.fingerprint(cli(.opencode, model: "opencode/big-pickle", vendor: "Anthropic"), reads: .nothing)
        let anthropic = AgentConsent.fingerprint(cli(.opencode, model: "anthropic/claude-sonnet-4-5", vendor: "Anthropic"), reads: .nothing)
        XCTAssertNotEqual(zen, anthropic, "another provider asks again, even with a name typed under Sends cards to")
        XCTAssertEqual(anthropic, AgentConsent.fingerprint(cli(.opencode, model: "anthropic/claude-opus-4-1", vendor: "Anthropic"), reads: .nothing),
                       "another model of the same provider doesn't")
    }

    func testTheProgramIsInTheFingerprint() {
        let path = AgentConsent.fingerprint(cli(.codex), reads: .nothing)
        XCTAssertNotEqual(path, AgentConsent.fingerprint(cli(.codex, executable: "/Users/sam/bin/codex"), reads: .nothing))
        XCTAssertNotEqual(path, AgentConsent.fingerprint(cli(.copilot), reads: .nothing), "another tool")
        XCTAssertEqual(path, AgentConsent.fingerprint(cli(.codex, vendor: "Typed"), reads: .nothing), "a typed vendor doesn't count for Codex")
        XCTAssertEqual(path, AgentConsent.fingerprint(cli(.codex, model: "gpt-5"), reads: .nothing), "nor does its model")
        var acts = cli(.codex)
        acts.mayAct = true
        XCTAssertNotEqual(path, AgentConsent.fingerprint(acts, reads: .nothing))
    }
}
