import XCTest
@testable import BindersKit

/// Reading each tool's own JSON output when its run ends, in the shapes the research found in each tool's code, with
/// made-up values.
final class CLIAgentOutputTests: XCTestCase {
    private func read(_ tool: CLIAgent, _ lines: [String]) -> CLIAgentResult {
        let whole = CLIAgentOutput.read(tool, lines.joined(separator: "\n"))
        // Fed a line at a time, it reads the same.
        var reader = CLIAgentOutputReader(tool: tool)
        for line in lines { reader.feed(Substring(line)) }
        XCTAssertEqual(reader.result, whole, "\(tool): line by line and whole agree")
        return whole
    }

    // MARK: Codex

    private let codexFinished = [
        #"{"type":"thread.started","thread_id":"0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.started","item":{"id":"item_0","type":"todo_list","items":[{"text":"Read the card","completed":true},{"text":"Running the tests","completed":false}]}}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"binders","tool":"get_task","arguments":{"id":"x"},"status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"swift test","aggregated_output":"ok","exit_code":0,"status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Fixed the footer link. The tests pass."}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":120,"cached_input_tokens":0,"output_tokens":40,"reasoning_output_tokens":0}}"#,
    ]

    func testCodexFinished() {
        let result = read(.codex, codexFinished)
        XCTAssertEqual(result.session, "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")
        XCTAssertEqual(result.lastText, "Fixed the footer link. The tests pass.")
        XCTAssertTrue(result.completed)
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.usedBoard)
        XCTAssertNil(result.cost, "token counts only")
        XCTAssertEqual(result.plan, "Running the tests")
    }

    func testCodexFailedTurnAndErrorLine() {
        let failed = read(.codex, Array(codexFinished.prefix(4)) + [#"{"type":"turn.failed","error":{"message":"stream disconnected before completion"}}"#])
        XCTAssertFalse(failed.completed)
        XCTAssertEqual(failed.failure, "stream disconnected before completion")
        XCTAssertNil(failed.lastText)
        let error = read(.codex, [#"{"type":"thread.started","thread_id":"t"}"#, #"{"type":"error","message":"Rate limit reached"}"#])
        XCTAssertEqual(error.failure, "Rate limit reached")
        XCTAssertFalse(error.completed)
        // An error Codex retried past, then a turn that completed: no failure to report on an exit 0.
        let retried = read(.codex, [codexFinished[0], #"{"type":"error","message":"Reconnecting... 1/5"}"#] + Array(codexFinished.dropFirst()))
        XCTAssertTrue(retried.completed)
        XCTAssertNil(retried.failure)
    }

    func testCodexRequiredServerFailureIsOnlyOnStderr() {
        // Its log (stdout) is empty: the reason is on stderr, which the dispatcher reads apart.
        let result = read(.codex, [])
        XCTAssertNil(result.session)
        XCTAssertFalse(result.completed)
        XCTAssertFalse(result.usedBoard)
    }

    func testCodexKeepsItsSessionPastAMegabyteOfOutput() {
        let big = String(repeating: "x", count: 1_100_000)
        let lines = [codexFinished[0],
                     #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"cat big","aggregated_output":"\#(big)","exit_code":0,"status":"completed"}}"#,
                     codexFinished[5], codexFinished[6]]
        let result = read(.codex, lines)
        XCTAssertEqual(result.session, "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", "the first line, read whole, not a tail")
        XCTAssertTrue(result.completed)
    }

    // MARK: OpenCode

    private func opencode(_ type: String, _ part: String) -> String {
        #"{"type":"\#(type)","timestamp":1792000000000,"sessionID":"ses_01JABCDEF","part":\#(part)}"#
    }

    func testOpenCodeFinishedWithCost() {
        let result = read(.opencode, [
            opencode("step_start", #"{"id":"prt_1","type":"step-start"}"#),
            opencode("tool_use", #"{"id":"prt_2","type":"tool","callID":"c1","tool":"binders_get_task","state":{"status":"completed","input":{"id":"x"},"output":"{}"}}"#),
            opencode("tool_use", #"{"id":"prt_3","type":"tool","callID":"c2","tool":"todowrite","state":{"status":"completed","input":{"todos":[{"content":"Read the card","status":"completed","priority":"high"},{"content":"Running the tests","status":"in_progress","priority":"high"}]}}}"#),
            opencode("step_finish", #"{"id":"prt_4","type":"step-finish","reason":"tool-calls","cost":0.01,"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}}"#),
            opencode("text", #"{"id":"prt_5","type":"text","text":"Fixed the footer link.","time":{"start":1,"end":2}}"#),
            opencode("text", #"{"id":"prt_5","type":"text","text":"Fixed the footer link.","time":{"start":1,"end":2}}"#),
            opencode("step_finish", #"{"id":"prt_6","type":"step-finish","reason":"stop","cost":0.03,"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}}"#),
        ])
        XCTAssertEqual(result.session, "ses_01JABCDEF")
        XCTAssertEqual(result.lastText, "Fixed the footer link.")
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.cost ?? 0, 0.04, accuracy: 0.0001)
        XCTAssertEqual(result.turns, 2)
        XCTAssertTrue(result.usedBoard)
        XCTAssertEqual(result.plan, "Running the tests")
        XCTAssertNil(result.failure)
    }

    func testOpenCodeStoppedAtAStepARunCantApprove() {
        let result = read(.opencode, [
            opencode("tool_use", #"{"id":"prt_2","type":"tool","tool":"bash","state":{"status":"error","input":{"command":"make"},"error":"The user rejected permission to use this specific tool call."}}"#),
            opencode("step_finish", #"{"id":"prt_3","type":"step-finish","reason":"tool-calls","cost":0.0}"#),
        ])
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failure, "it stopped at a step a run can't approve: bash")
        XCTAssertFalse(result.usedBoard, "no binders_ tool was called")
    }

    func testOpenCodeUsedItsSteps() {
        let result = read(.opencode, [
            opencode("text", #"{"id":"prt_9","type":"text","text":"I reached the maximum steps for this run, so I'm stopping here."}"#),
            opencode("step_finish", #"{"id":"prt_10","type":"step-finish","reason":"stop","cost":0.2}"#),
        ])
        XCTAssertEqual(result.failure, "it used its 150 steps")
    }

    func testOpenCodeErrorLine() {
        let result = read(.opencode, [
            opencode("step_finish", #"{"id":"prt_1","type":"step-finish","reason":"stop","cost":0.0}"#),
            #"{"type":"error","timestamp":1792000000000,"sessionID":"ses_01JABCDEF","error":{"name":"ProviderAuthError","data":{"message":"No API key for anthropic","providerID":"anthropic"}}}"#,
        ])
        XCTAssertFalse(result.completed, "an error line means it didn't finish")
        XCTAssertEqual(result.failure, "No API key for anthropic")
        let named = read(.opencode, [#"{"type":"error","sessionID":"ses_1","error":{"name":"UnknownError"}}"#])
        XCTAssertEqual(named.failure, "UnknownError")
    }

    // MARK: GitHub Copilot CLI

    private func copilot(_ type: String, _ data: String) -> String {
        #"{"id":"e1","timestamp":"2026-10-18T12:00:00.000Z","parentId":null,"type":"\#(type)","data":\#(data)}"#
    }

    private var copilotResult: String {
        #"{"type":"result","timestamp":"2026-10-18T12:01:00.000Z","sessionId":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","exitCode":0,"usage":{"premiumRequests":2,"totalApiDurationMs":900,"sessionDurationMs":1200,"codeChanges":{"linesAdded":1,"linesRemoved":0,"filesModified":["README.md"]}}}"#
    }

    func testCopilotFinishedWithAResult() {
        let result = read(.copilot, [
            copilot("assistant.turn_start", #"{"turnId":"t1"}"#),
            copilot("tool.execution_start", #"{"toolCallId":"c1","toolName":"report_intent","arguments":{"intent":"Running the tests"}}"#),
            copilot("tool.execution_start", #"{"toolCallId":"c2","toolName":"binders-get_task","arguments":{"id":"x"},"mcpServerName":"binders","mcpToolName":"get_task"}"#),
            copilot("assistant.message", #"{"content":"Fixed the footer link.","toolRequests":[]}"#),
            copilot("assistant.message", #"{"content":"A sub-agent's words.","parentToolCallId":"c9"}"#),
            copilot("assistant.message", #"{"content":"","toolRequests":[{"name":"view"}]}"#),
            copilot("assistant.turn_start", #"{"turnId":"t2"}"#),
            copilotResult,
        ])
        XCTAssertEqual(result.session, "6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        XCTAssertEqual(result.lastText, "Fixed the footer link.", "not a sub-agent's, not an empty one")
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.premiumRequests, 2)
        XCTAssertEqual(result.turns, 2)
        let fraction = read(.copilot, [#"{"type":"result","sessionId":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","exitCode":0,"usage":{"premiumRequests":0.33}}"#])
        XCTAssertEqual(fraction.premiumRequests ?? 0, 0.33, accuracy: 0.0001, "the sum of each request's multiplier, not cut to a whole number")
        XCTAssertTrue(result.usedBoard)
        XCTAssertEqual(result.plan, "Running the tests")
    }

    func testCopilotTodoListAndErrors() {
        let todo = read(.copilot, [copilot("tool.execution_start", #"{"toolCallId":"c3","toolName":"update_todo","arguments":{"todos":"- [x] Read the card\n- [ ] Write the fix\n- [ ] Run the tests"}}"#)])
        XCTAssertEqual(todo.plan, "Write the fix")
        let failed = read(.copilot, [copilot("session.error", #"{"errorType":"query","message":"Request failed with 403","statusCode":403}"#),
                                     #"{"type":"result","sessionId":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","exitCode":1,"usage":{"premiumRequests":0}}"#])
        XCTAssertEqual(failed.failure, "Request failed with 403")
        XCTAssertFalse(failed.completed)
        let policy = read(.copilot, [copilot("session.warning", #"{"warningType":"policy","message":"Third-party MCP servers are disabled by your organization's Copilot policy."}"#)])
        XCTAssertEqual(policy.failure, "your organization's Copilot policy turns off other MCP servers, so the run couldn't reach the board")
        let policyFinished = read(.copilot, [copilot("session.warning", #"{"warningType":"policy","message":"x"}"#), copilotResult])
        XCTAssertTrue(policyFinished.completed)
        XCTAssertEqual(policyFinished.failure, policy.failure, "a policy that kept the board away still says so, with a result line")
        let goneOn = read(.copilot, [copilot("session.error", #"{"errorType":"model_call","message":"Model call failed, retrying"}"#), copilotResult])
        XCTAssertNil(goneOn.failure, "a session error it went on from, then a result: no failure")
        let stopped = read(.copilot, [copilot("assistant.turn_start", #"{"turnId":"t1"}"#), copilot("assistant.message", #"{"content":"Looking at the card."}"#)])
        XCTAssertFalse(stopped.completed, "no result line: it didn't finish")
        XCTAssertNil(stopped.failure, "Binders knows it stopped")
        XCTAssertNil(stopped.session, "the dispatcher has the session it chose")
    }

    // MARK: Anything

    func testGarbageAndCutLinesReadSafely() {
        let ansi = "\u{1B}[31m! permission requested: bash (rm -rf x); auto-rejecting\u{1B}[0m"
        for tool in CLIAgent.allCases {
            let result = read(tool, ["", "not json", ansi, "{\"type\":", "[1,2]", "{\"type\":\"result\",\"exitCode\":\"zero\"}", #"{"type":"thread.started","thread_id":"abc"#])
            XCTAssertFalse(result.completed, tool.rawValue)
            XCTAssertNil(result.lastText)
        }
        // A tail that starts mid-line: the cut line is skipped, the rest read.
        let tail = String(codexFinished.joined(separator: "\n").dropFirst(30))
        XCTAssertTrue(CLIAgentOutput.read(.codex, tail).completed)
        XCTAssertNil(CLIAgentOutput.read(.codex, tail).session, "its first line was cut")
    }

    func testPremiumRequestsAsCopilotSaysThem() {
        XCTAssertEqual(CLIAgentOutput.premiumRequests(2), "2 premium requests")
        XCTAssertEqual(CLIAgentOutput.premiumRequests(1), "1 premium request")
        XCTAssertEqual(CLIAgentOutput.premiumRequests(0), "0 premium requests")
        XCTAssertEqual(CLIAgentOutput.premiumRequests(0.33), "0.33 premium requests")
        XCTAssertEqual(CLIAgentOutput.premiumRequests(1.5), "1.5 premium requests", "trailing zeros off, as Copilot prints it")
        XCTAssertEqual(CLIAgentOutput.premiumRequests(1.666), "1.67 premium requests")
        XCTAssertEqual(CLIAgentOutput.premiumRequests(0.001), "0 premium requests")
    }

    func testTheReasonInAToolsErrors() {
        // Copilot 1.0.10's words when it has no sign-in: the error first, then the ways to sign in.
        let copilot = """
        Error: No authentication information found.

        Copilot can be authenticated with GitHub using an OAuth Token or a Fine-Grained Personal Access Token.

        To authenticate, you can use any of the following methods:
          \u{2022} Start 'copilot' and run the '/login' command
          \u{2022} Set the COPILOT_GITHUB_TOKEN, GH_TOKEN, or GITHUB_TOKEN environment variable
          \u{2022} Run 'gh auth login' to authenticate with the GitHub CLI
        """
        XCTAssertEqual(CLIAgentOutput.reason(inErrors: copilot), "Error: No authentication information found.")
        XCTAssertNotNil(CLIAgentOutput.signIn(.copilot, said: copilot), "the whole of stderr says it isn't signed in")
        XCTAssertEqual(CLIAgentOutput.reason(inErrors: "Reading prompt from stdin...\nError: required MCP servers failed to initialize: binders\n"),
                       "Error: required MCP servers failed to initialize: binders")
        XCTAssertEqual(CLIAgentOutput.reason(inErrors: "\u{1B}[31mstand-in: done\u{1B}[0m\n{\"type\":\"x\"}\n\n"), "stand-in: done", "else the last plain line")
        XCTAssertNil(CLIAgentOutput.reason(inErrors: "\n {} \n"))
    }

    func testSignInFailuresInPlainWords() {
        XCTAssertEqual(CLIAgentOutput.signIn(.copilot, said: "Error: No authentication information found."),
                       "GitHub Copilot CLI isn't signed in for Binders' runs. Sign in with copilot login in Terminal, then Wake Now.")
        XCTAssertTrue(CLIAgentOutput.signIn(.codex, said: "unexpected status 401 Unauthorized")?
            .hasPrefix("Codex isn't signed in for Binders' runs. Sign in to Codex in Terminal (codex login), then Wake Now.") == true)
        XCTAssertTrue(CLIAgentOutput.signIn(.opencode, said: "ProviderInitError", model: "anthropic/claude-sonnet-4-5")?
            .hasPrefix("OpenCode couldn't use anthropic/claude-sonnet-4-5: set up that provider with opencode auth login, then Wake Now.") == true)
        XCTAssertNil(CLIAgentOutput.signIn(.copilot, said: "Request failed"))
        XCTAssertNil(CLIAgentOutput.signIn(.codex, said: "stream disconnected"))
    }
}
