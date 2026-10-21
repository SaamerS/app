import XCTest
@testable import BindersKit

final class AutomationTests: XCTestCase {
    // Tuesday 15 September 2026, 10:00 local.
    private var now: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 15; components.hour = 10
        return Calendar.current.date(from: components)!
    }

    func testPhraseRemainder() {
        XCTAssertEqual(AutomationTemplate.remainder(of: "Send to Things buy milk tomorrow.", afterPhrase: "send to things"), "buy milk tomorrow")
        XCTAssertEqual(AutomationTemplate.remainder(of: "hey send to things: buy milk", afterPhrase: "send to things"), "buy milk")
        XCTAssertEqual(AutomationTemplate.remainder(of: "Start focus mode", afterPhrase: "start focus mode"), "")
        XCTAssertNil(AutomationTemplate.remainder(of: "send to thingsville", afterPhrase: "send to things"))
        XCTAssertNil(AutomationTemplate.remainder(of: "please send to things buy milk", afterPhrase: "send to things"))
        XCTAssertNil(AutomationTemplate.remainder(of: "anything", afterPhrase: "   "))
    }

    func testSpokenPayloadSplitsTheTime() {
        let payload = AutomationPayload.spoken("buy milk tomorrow at 3 pm", now: now)
        XCTAssertEqual(payload.text, "buy milk tomorrow at 3 pm")
        XCTAssertEqual(payload.title, "buy milk")
        XCTAssertEqual(payload.when, "tomorrow at 3 pm")
        XCTAssertTrue(payload.date.hasPrefix("2026-09-16T15:00:00"), payload.date)

        let plain = AutomationPayload.spoken("buy milk", now: now)
        XCTAssertEqual(plain.title, "buy milk")
        XCTAssertEqual(plain.when, "")
        XCTAssertEqual(plain.date, "")
    }

    func testTemplatesAndEncodings() {
        let payload = AutomationPayload(text: "buy milk & eggs", title: "buy milk", when: "tomorrow", app: "Slack")
        XCTAssertEqual(AutomationTemplate.render("{title} ({when}) from {app}", payload: payload), "buy milk (tomorrow) from Slack")
        XCTAssertEqual(AutomationTemplate.render("things:///add?title={text}", payload: payload, encode: AutomationTemplate.percentEncoded),
                       "things:///add?title=buy%20milk%20%26%20eggs")
        let body = AutomationTemplate.render(#"{"content":"{text}","said":"{note}"}"#, payload: AutomationPayload(text: "He said \"go\"\nnow"),
                                             encode: AutomationTemplate.jsonEscaped)
        XCTAssertEqual(body, #"{"content":"He said \"go\"\nnow","said":"{note}"}"#)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(body.utf8)))
    }

    func testRulesRoundTripAsJSON() throws {
        let rules = [
            AutomationRule(name: "Things", trigger: .phrase(text: "send to things"), action: .openURL(template: "things:///add?title={text}")),
            AutomationRule(name: "Notes to Notion", isEnabled: false, trigger: .event(name: .meetingReady),
                           action: .shortcut(name: "File meeting", input: "{title}\n{summary}")),
            AutomationRule(name: "Ping", trigger: .event(name: .todoAdded), action: .webhook(url: "https://example.test/hook", body: "")),
            AutomationRule(name: "Log", trigger: .phrase(text: "log"), action: .script(command: "echo \"$BINDERS_TEXT\" >> ~/log.txt")),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        let decoded = try JSONDecoder().decode([AutomationRule].self, from: data)
        XCTAssertEqual(decoded, rules)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"phrase\""), "the file should read like what it is")
        XCTAssertTrue(text.contains("\"meetingReady\""))
        XCTAssertFalse(text.contains("anyOrigin"), "a rule that doesn't take other to-dos says nothing about it")
    }

    func testRulesFromBeforeOriginsStillRead() throws {
        // automations.json as Binders 0.8.0 wrote it.
        let old = #"""
        [{"action":{"webhook":{"body":"","url":"https:\/\/example.test\/hook"}},"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "isEnabled":true,"name":"Ping","trigger":{"event":{"name":"todoAdded"}}}]
        """#
        let rules = try JSONDecoder().decode([AutomationRule].self, from: Data(old.utf8))
        XCTAssertEqual(rules.first?.action, .webhook(url: "https://example.test/hook", body: ""))
        XCTAssertNil(rules.first?.anyOrigin)
        XCTAssertEqual(rules.first?.runs(for: .voice), true, "it runs for your own to-dos as before")
        XCTAssertEqual(rules.first?.runs(for: .moment), false, "and not for one said to yourself and done at once")
        // A rule with the option round-trips it.
        let wide = AutomationRule(name: "Everything", trigger: .event(name: .todoAdded), action: .script(command: "true"), anyOrigin: true)
        XCTAssertEqual(try JSONDecoder().decode(AutomationRule.self, from: JSONEncoder().encode(wide)), wide)
    }

    func testOriginsDecideWhichRulesRun() {
        let mine = AutomationRule(name: "Mine", trigger: .event(name: .todoAdded), action: .script(command: "true"))
        let wide = AutomationRule(name: "All", trigger: .event(name: .todoAdded), action: .script(command: "true"), anyOrigin: true)
        for origin in TodoOrigin.allCases {
            XCTAssertTrue(wide.runs(for: origin), "\(origin) runs a rule that takes every to-do")
            XCTAssertEqual(mine.runs(for: origin), [.voice, .phone, .suggestion].contains(origin), "\(origin)")
        }
        XCTAssertTrue(mine.runs(for: nil), "an event that isn't a to-do has no origin and runs as before")
        XCTAssertEqual(TodoOrigin.allCases.filter { !$0.madeByYou }, [.moment, .agent, .link])
        XCTAssertEqual(TodoOrigin.allCases.filter(\.isSaidToYourself), [.suggestion, .moment], "your own words, quoted where to-dos are listed")
    }

    func testATodoWithoutAnOriginIsSaidToYourselfByItsSource() {
        // A Mac before `origin`, or a list_todos reply cached before it: the source says.
        XCTAssertTrue(TodoOrigin.isSaidToYourself(origin: nil, source: "Said to yourself"))
        XCTAssertFalse(TodoOrigin.isSaidToYourself(origin: nil, source: "Command Mode"))
        XCTAssertFalse(TodoOrigin.isSaidToYourself(origin: nil, source: nil), "a checklist item has neither")
        // An origin this build knows decides.
        XCTAssertTrue(TodoOrigin.isSaidToYourself(origin: "moment", source: "Board"))
        XCTAssertTrue(TodoOrigin.isSaidToYourself(origin: "suggestion", source: nil))
        XCTAssertFalse(TodoOrigin.isSaidToYourself(origin: "agent", source: "Said to yourself"), "an agent's to-do is never quoted as your words")
        // One from a newer Mac that this build doesn't know: the source again.
        XCTAssertTrue(TodoOrigin.isSaidToYourself(origin: "watch", source: "Said to yourself"))
        XCTAssertFalse(TodoOrigin.isSaidToYourself(origin: "watch", source: "Apple Watch"))
    }

    func testTodoOriginReachesScriptsAndHooks() {
        let todo = AutomationPayload(event: "todoAdded", text: "call Sam", todoOrigin: .agent)
        XCTAssertEqual(todo.fields["todo_origin"], "agent")
        XCTAssertEqual(AutomationTemplate.render("{title} from {todo_origin}", payload: AutomationPayload(title: "call Sam", todoOrigin: .link)),
                       "call Sam from link")
        let other = AutomationPayload(event: "meetingReady", title: "Standup")
        XCTAssertNil(other.fields["todo_origin"], "other events' payloads are as they were")
        XCTAssertEqual(other.fields.count, 9)
        // Older payloads decode without it.
        let decoded = try? JSONDecoder().decode(AutomationPayload.self, from: Data(#"{"event":"phrase","text":"a","title":"a","when":"","date":"","app":"","binder":"","summary":"","link":""}"#.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.todoOrigin)
    }

    func testRenderingIsOnePass() {
        // A value that looks like a placeholder stays as it was said.
        let payload = AutomationPayload(text: "use {binder} here", title: "{summary}", binder: "Work", summary: "secret")
        XCTAssertEqual(AutomationTemplate.render("{text} / {title}", payload: payload), "use {binder} here / {summary}")
        XCTAssertEqual(AutomationTemplate.render("{{text}} {nope} {", payload: AutomationPayload(text: "a")), "{a} {nope} {")
    }

    func testQueryValuesAreEncodedStrictly() {
        XCTAssertEqual(AutomationTemplate.percentEncoded("../../etc/passwd"), "%2E%2E%2F%2E%2E%2Fetc%2Fpasswd")
        XCTAssertEqual(AutomationTemplate.percentEncoded("a&b=c?d#e f+g"), "a%26b%3Dc%3Fd%23e%20f%2Bg")
        XCTAssertEqual(AutomationTemplate.percentEncoded("Café-1_2~3"), "Caf%C3%A9-1_2~3")
        let payload = AutomationPayload(title: "x/../y", binder: "Work.Plans")
        let rendered = AutomationTemplate.render("https://example.test/add?title={title}&in={binder}", payload: payload, encode: AutomationTemplate.percentEncoded)
        XCTAssertEqual(rendered, "https://example.test/add?title=x%2F%2E%2E%2Fy&in=Work%2EPlans")
        XCTAssertEqual(URL(string: rendered)?.path, "/add", "the path stays the template's")
    }

    func testLinkTemplatesTakeValuesOnlyInTheQuery() {
        XCTAssertNil(AutomationTemplate.urlProblem("things:///add?title={title}&when={date}"))
        XCTAssertNil(AutomationTemplate.urlProblem("https://example.test/search?q=from%20{app}:{text}"))
        XCTAssertNil(AutomationTemplate.urlProblem("https://example.test/fixed/path"))
        XCTAssertNil(AutomationTemplate.urlProblem("mailto:me@example.test?subject={title}&body={text}"))
        for refused in ["https://example.test/{binder}/new?title={title}", "https://{binder}.example.test/", "{link}",
                        "https://example.test/?{title}=1", "https://example.test/?q=1#{title}", "obsidian://open?vault=A&file={title}/{binder}#{text}"] {
            XCTAssertNotNil(AutomationTemplate.urlProblem(refused), refused)
        }
        XCTAssertTrue(AutomationTemplate.urlProblem("https://example.test/{binder}")?.contains("{binder}") == true, "the reason names the placeholder")
        XCTAssertNotNil(AutomationTemplate.urlProblem("  "))
        XCTAssertNotNil(AutomationTemplate.urlProblem("example.test/add?title={title}"), "a link needs its scheme")
    }
}

final class MCPCoreTests: XCTestCase {
    private let tools = [
        MCPTool(name: "search", readOnly: true, description: "Search", parameters: [
            MCPToolParameter(name: "query", description: "What to look for", required: true),
            MCPToolParameter(name: "limit", type: "integer", description: "How many"),
        ]),
    ]

    private func handle(_ message: [String: Any], call: @escaping (String, [String: Any]) async throws -> String = { _, _ in "ok" }) async -> [String: Any]? {
        await MCPCore.handle(message, serverName: "binders", serverVersion: "0.2.0", instructions: "Test.", tools: tools, call: call)
    }

    func testInitializeEchoesASupportedVersion() async {
        let reply = await handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
        let result = reply?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "binders")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])

        let unknown = await handle(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        XCTAssertEqual((unknown?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
    }

    func testNotificationsGetNoReply() async {
        let reply = await handle(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(reply)
    }

    func testToolsListDescribesParameters() async {
        let reply = await handle(["jsonrpc": "2.0", "id": "a", "method": "tools/list"])
        let list = (reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)
        let schema = list?.first?["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["query"])
        let limit = (schema?["properties"] as? [String: Any])?["limit"] as? [String: Any]
        XCTAssertEqual(limit?["type"] as? String, "integer")
        // Hosts can tell a lookup from a change; a tool not marked as reading counts as a change.
        XCTAssertEqual((list?.first?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        let write = MCPTool(name: "add", description: "Add").schema["annotations"] as? [String: Any]
        XCTAssertEqual(write?["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(write?["destructiveHint"] as? Bool, false, "writes add or change and keep history: an unattended agent may write")
        XCTAssertEqual(write?["openWorldHint"] as? Bool, false, "nothing leaves this Mac")
    }

    func testToolsCallRunsTheToolAndReportsFailures() async {
        let ok = await handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "search", "arguments": ["query": "pricing"]]]) { name, arguments in
            "\(name):\(arguments["query"] as? String ?? "")"
        }
        let content = ((ok?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["text"] as? String, "search:pricing")
        XCTAssertEqual((ok?["result"] as? [String: Any])?["isError"] as? Bool, false)

        let failed = await handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "search", "arguments": [:]]]) { _, _ in
            throw MCPCore.ToolFailure("query is required")
        }
        XCTAssertEqual((failed?["result"] as? [String: Any])?["isError"] as? Bool, true)

        let missing = await handle(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "nope"]])
        XCTAssertEqual((missing?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testUnknownMethodAndParseError() async {
        let reply = await handle(["jsonrpc": "2.0", "id": 6, "method": "something/else"])
        XCTAssertEqual((reply?["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual((MCPCore.parseError()["error"] as? [String: Any])?["code"] as? Int, -32700)
    }
}
