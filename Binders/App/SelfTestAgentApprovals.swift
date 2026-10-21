import Foundation
import BindersKit

extension SelfTest {
    /// Agents that could act in the world draft first, through the same tools and link agents and the iPhone use: one that
    /// may not act is told so, asks with request_approval and waits in Blocked; phones that read approvals hear who asks and
    /// what, never who it goes to or what it says; you approve from the iPhone or decline on the Mac, for exactly the
    /// request shown; each decision leaves a receipt and goes back as the card's answer, which wakes the agent. Part of
    /// --selftest-agents, in its throwaway folder. Returns how many checks failed.
    @MainActor
    static func agentApprovalChecks(controller: DictationController) async -> Int {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let board = controller.board
        let registry = AgentRegistry.shared
        let write = MCPServer.writeInApp(controller: controller)
        let folder = AppPaths.support
        let manager = FileManager.default
        func call(_ tool: String, _ arguments: [String: Any] = [:], as actor: BoardActor) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func json(_ text: String) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:] }
        func made(_ text: String) -> UUID { (json(text)["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID() }
        func task(_ id: UUID) async -> [String: Any] { json(await call("get_task", ["id": id.uuidString], as: .you).text) }
        func last(_ id: UUID, _ kind: TaskEvent.Kind) -> TaskEvent? { board.timeline(id).last { $0.kind == kind } }
        Store.shared.insert(BinderRecord(name: "Outreach", colorIndex: 3))

        // An agent woken with a script of its own, which keeps the card it was handed, then says it woke.
        let script = folder.appendingPathComponent("wake-scribe")
        try? """
            #!/bin/sh
            here="$(cd "$(dirname "$0")" && pwd)"
            cat > "$here/scribe-$BINDERS_CARD.json"
            printf 'WAKE %s %s\\n' "$BINDERS_EVENT" "$BINDERS_CARD" >> "$here/scribe-wakes.txt"
            """.write(to: script, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        func wakes() -> [String] {
            ((try? String(contentsOf: folder.appendingPathComponent("scribe-wakes.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        /// The card it was handed the `times`th time it was woken for that card for that reason, once it has been.
        func woken(_ event: String, _ id: UUID, times: Int = 1) async -> [String: Any]? {
            let line = "WAKE \(event) \(id.uuidString)"
            for _ in 0..<80 where wakes().filter({ $0 == line }).count < times { try? await Task.sleep(for: .milliseconds(100)) }
            guard wakes().filter({ $0 == line }).count >= times else { return nil }
            let data = try? Data(contentsOf: folder.appendingPathComponent("scribe-\(id.uuidString).json"))
            return data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
        var scribe = AgentProfile(name: "Scribe", wake: .command(command: "./wake-scribe", folder: folder.path), wakesPerHour: 30)
        check(registry.upsert(scribe) == nil, "an agent is saved, and drafts first: \(scribe.draftsFirst)")
        let saved = (try? String(contentsOf: folder.appendingPathComponent("agents.json"), encoding: .utf8)) ?? ""
        check(!saved.contains("mayAct"), "with nothing new in agents.json for it")
        let actor = BoardActor(name: "Scribe", kind: .agent)
        let listed = (json(await call("list_agents", as: .you).text)["agents"] as? [[String: Any]])?.first { $0["name"] as? String == "Scribe" }
        check(listed?["may_act"] as? Bool == false, "list_agents tells the iPhone it may not act for you")

        // a) Handed a card, it hears that it may not act for you.
        let card = made(await call("create_task", ["title": "Email the venue about the booth", "binder": "Outreach", "column": "ready", "for": "Scribe"],
                                   as: .you).text)
        let first = await woken("ready", card)
        check(first?["event"] as? String == "ready" && first?["may_act"] as? Bool == false, "its wake says may_act false: \((first?["may_act"] as? Bool).map { String($0) } ?? "none")")
        _ = await call("claim_task", ["id": card.uuidString], as: actor)

        // b) What it can't ask, and who can't ask.
        let empty = await call("request_approval", ["id": card.uuidString, "action": "Send an email", "recipients": "sam@example.com"], as: actor)
        check(!empty.ok && empty.text.contains("exact text"), "without the exact text it can't ask: \(empty.text)")
        let mine = await call("request_approval", ["id": card.uuidString, "action": "Send an email", "text": "Hi"], as: .you)
        check(!mine.ok && board.card(card)?.column == .inProgress, "and you don't ask yourself: \(mine.text)")

        // c) Phones: one that reads approvals, and iPhone 2.0, which doesn't.
        final class Heard: @unchecked Sendable {
            private let lock = NSLock()
            private var messages: [(method: String, params: String)] = []
            func add(_ message: [String: Any]) {
                let params = (try? JSONSerialization.data(withJSONObject: message["params"] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? ""
                lock.withLock { messages.append((message["method"] as? String ?? "", params)) }
            }
            func of(_ method: String) -> [String] { lock.withLock { messages.filter { $0.method == method }.map(\.params) } }
        }
        let heard = Heard(), heardOld = Heard()
        let devicesURL = manager.temporaryDirectory.appendingPathComponent("approval-devices-\(UUID().uuidString).json")
        defer { try? manager.removeItem(at: devicesURL) }
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: devicesURL)
        server.start()
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        var phone: LinkClient?
        var old: LinkClient?
        if let port = server.boundPort, var pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort {
            pairing.addresses = ["127.0.0.1:\(pairingPort)"]
            do {
                let paired = try await LinkClient.pair(pairing, deviceName: "Test iPhone")
                let reading = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
                try await reading.connect()
                reading.onNotification { heard.add($0) }
                let hello = try await reading.hello(device: paired.device, key: paired.key, name: "Test iPhone", features: LinkFeatures.thisPhone)
                check((hello["features"] as? [String])?.contains(LinkFeatures.approvals) == true, "the Mac says its agents ask for approval")
                _ = try await reading.request("binders/subscribe")
                let first = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
                try await first.connect()
                first.onNotification { heardOld.add($0) }
                _ = try await first.hello(device: paired.device, key: paired.key, name: "Old iPhone")
                _ = try await first.request("binders/subscribe")
                phone = reading
                old = first
            } catch {
                check(false, "the link failed: \(error.localizedDescription)")
            }
        } else {
            check(false, "the link didn't start")
        }

        // d) It asks: the card waits in Blocked, with exactly what it asks on it.
        let email = AgentApproval(action: "Send an email", recipients: ["sam@example.com", "Smith, Pat <pat@example.com>"],
                                  text: "Hi Sam,\n\nThe booth is 14 in Hall B.\n\nPat", link: "https://example.test/draft")
        let asked = await call("request_approval", ["id": card.uuidString, "action": "Send an email", "recipients": "sam@example.com\nSmith, Pat <pat@example.com>",
                                                    "text": "Hi Sam,\n\nThe booth is 14 in Hall B.\n\nPat", "link": "https://example.test/draft"], as: actor)
        let request = last(card, .approval)
        check(asked.ok && asked.text.contains("waits in Blocked") && board.card(card)?.column == .blocked, "it asks, and the card waits in Blocked: \(asked.text)")
        check(request?.author == "Scribe" && request?.authorIsAgent == true && request?.text == email.timelineText,
              "the timeline keeps exactly what it asks, by the agent: \(request?.text ?? "nothing")")
        var detail = await task(card)
        let shown = detail["approval"] as? [String: Any]
        check(detail["state"] as? String == "input_required", "its state is input_required: \(detail["state"] ?? "none")")
        check(shown?["id"] as? String == request?.id.uuidString && shown?["recipients"] as? [String] == email.recipients
              && shown?["text"] as? String == email.text && shown?["link"] as? String == email.link
              && shown?["headline"] as? String == "Scribe asks to send an email", "get_task shows exactly who it goes to and what it says: \(shown ?? [:])")
        for _ in 0..<30 where heard.of(LinkFeatures.approvalMethod).isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        let notice = heard.of(LinkFeatures.approvalMethod).first.map { json($0) } ?? [:]
        check(notice["card"] as? String == card.uuidString && notice["approval"] as? String == request?.id.uuidString && notice["agent"] as? String == "Scribe"
              && notice["headline"] as? String == "Scribe asks to send an email" && notice["title"] as? String == "Email the venue about the booth",
              "a phone that reads approvals hears who asks and what: \(notice)")
        let flat = heard.of(LinkFeatures.approvalMethod).joined()
        check(!flat.contains("sam@example.com") && !flat.contains("Hall B"), "never who it goes to or what it says")
        try? await Task.sleep(for: .milliseconds(2600))
        check(heardOld.of(LinkFeatures.approvalMethod).isEmpty && !heardOld.of(LinkFeatures.changed).isEmpty,
              "iPhone 2.0 hears only that the board changed")
        check(wakes().count == 1, "asking wakes no one")

        // e) A decision is for the request shown, and only you decide.
        func decide(_ approve: Bool, approval: String?, reason: String = "") async -> (ok: Bool, message: String) {
            guard let phone else { return (false, "no phone") }
            do {
                let reply = try await phone.request(LinkFeatures.decisionMethod,
                                                    AgentApproval.Decision(card: card.uuidString, approval: approval ?? "", approve: approve, reason: reason).params)
                return (true, (reply as? [String: Any])?["message"] as? String ?? "")
            } catch LinkClient.Failure.rejected(let message) {
                return (false, message)
            } catch {
                return (false, error.localizedDescription)
            }
        }
        let stale = await decide(true, approval: UUID().uuidString)
        check(!stale.ok && stale.message.contains("something else") && board.card(card)?.column == .blocked && last(card, .decision) == nil,
              "an approval for another request is refused: \(stale.message)")
        if let target = board.card(card) {
            check((try? board.decide(target, approve: true, by: actor, on: "Scribe's server")) == nil && target.column == .blocked,
                  "an agent can't approve its own request")
        }
        check(!MCPServer.tools.contains { $0.name.contains("decide") || $0.name.contains("approve") } && MCPServer.boardTools.contains("request_approval"),
              "agents have a tool to ask and none to decide")
        let forged = await InboxCommands.perform(InboxCommands.fromAgent(InboxRequest(action: "decide", fields: ["id": card.uuidString, "actor": "You"])),
                                                 controller: controller)
        check(!forged.ok && board.card(card)?.column == .blocked, "nor can an inbox request: \(forged.error ?? "")")

        // f) Approved from the iPhone: a receipt, then the answer, and the agent goes back to work.
        let approved = await decide(true, approval: request?.id.uuidString)
        let receipt = last(card, .decision), answer = last(card, .answer)
        check(approved.ok && approved.message.hasPrefix("Approved."), "approved from the iPhone: \(approved.message)")
        check(receipt?.author == "Binders" && receipt?.authorIsAgent == false && receipt?.text.hasPrefix("You approved this on Test iPhone, ") == true
              && receipt?.text.hasSuffix("\n" + email.timelineText) == true, "the receipt says who decided, where, when and exactly what: \(receipt?.text ?? "none")")
        check(answer?.author == "You" && answer?.text == "Approved" && board.card(card)?.column == .inProgress && board.card(card)?.assignee == "Scribe",
              "the card's answer is Approved, and it's back in progress with Scribe")
        let afterYes = await woken("answered", card)
        check(afterYes?["answer"] as? String == "Approved", "the agent is woken with it: \(wakes().last ?? "")")
        detail = await task(card)
        check(detail["approval"] == nil && detail["state"] as? String == "working", "and nothing waits for your approval")
        let twice = await decide(true, approval: request?.id.uuidString)
        check(!twice.ok && twice.message.contains("Nothing"), "a second tap does nothing: \(twice.message)")

        // g) Declined on this Mac, with a reason the agent hears.
        _ = await call("request_approval", ["id": card.uuidString, "action": "Post in #events", "recipients": "#events",
                                            "text": "The booth is 14 in Hall B."], as: actor)
        if let target = board.card(card), let asking = last(card, .approval) {
            let said = try? board.decide(target, approval: asking.id, approve: false, reason: "Not this week, the venue is closed", by: .you, on: "Studio Mac")
            check(said?.hasPrefix("Declined.") == true, "declined on the Mac: \(said ?? "refused")")
        }
        check(last(card, .decision)?.text.hasPrefix("You declined this on Studio Mac, ") == true
              && last(card, .decision)?.text.contains(": Not this week, the venue is closed\nPost in #events\nTo: #events") == true,
              "its receipt says so, and why: \(last(card, .decision)?.text ?? "none")")
        let afterNo = await woken("answered", card, times: 2)
        check(last(card, .answer)?.text == "Declined: Not this week, the venue is closed" && afterNo?["answer"] as? String == "Declined: Not this week, the venue is closed",
              "the agent hears Declined, and why")

        // h) A new request replaces one that waits: the old one can't be approved.
        _ = await call("request_approval", ["id": card.uuidString, "action": "Send an email", "recipients": "sam@example.com", "text": "Draft one"], as: actor)
        let replaced = last(card, .approval)
        _ = await call("request_approval", ["id": card.uuidString, "action": "Send an email", "recipients": "sam@example.com", "text": "Draft two"], as: actor)
        let current = last(card, .approval)
        if let target = board.card(card), let replaced {
            do {
                try board.decide(target, approval: replaced.id, approve: true, by: .you, on: "Studio Mac")
                check(false, "the first draft can't be approved once a second is asked")
            } catch {
                check(error.localizedDescription.contains("something else") && target.column == .blocked, "the first draft can't be approved once a second is asked")
            }
        }
        check((await task(card)["approval"] as? [String: Any])?["id"] as? String == current?.id.uuidString, "the second is what waits")
        if let target = board.card(card) { _ = try? board.decide(target, approval: current?.id, approve: false, by: .you, on: "Studio Mac") }
        check(last(card, .answer)?.text == "Declined", "declined with no reason is just Declined")

        // i) A run Binders started asks on its own card, with the board's tools, and is told it drafts first.
        let other = made(await call("create_task", ["title": "Book the hotel", "binder": "Outreach", "column": "backlog"], as: .you).text)
        setenv("BINDERS_TOOLS", "board", 1)
        setenv("BINDERS_CARD", card.uuidString, 1)
        setenv("BINDERS_AGENT", "Scribe", 1)
        check(MCPServer.offered.contains { $0.name == "request_approval" } && MCPServer.offeredInstructions.contains("You draft first"),
              "a confined run gets request_approval, and is told it drafts first")
        let elsewhere = await call("request_approval", ["id": other.uuidString, "action": "Buy a room", "text": "One night"], as: BoardActor(name: "Claude", kind: .agent))
        let own = await call("request_approval", ["id": card.uuidString, "action": "Buy a room", "recipients": "Hotel Lighthouse", "text": "One night, Friday"],
                             as: BoardActor(name: "Claude", kind: .agent))
        check(!elsewhere.ok && own.ok && last(card, .approval)?.author == "Scribe", "only on its own card, as the agent it woke: \(elsewhere.text)")
        if let target = board.card(card) { _ = try? board.decide(target, approve: false, reason: "Not now", by: .you, on: "Studio Mac") }
        unsetenv("BINDERS_CARD")
        unsetenv("BINDERS_AGENT")
        unsetenv("BINDERS_TOOLS")

        // j) Let it act: it's told so, the iPhone asks again, and nothing else may change it.
        let before = listedFingerprint(json(await call("list_agents", as: .you).text), "Scribe")
        scribe.mayAct = true
        check(registry.upsert(scribe) == nil, "letting it act is saved")
        let agentsFile = (try? String(contentsOf: folder.appendingPathComponent("agents.json"), encoding: .utf8)) ?? ""
        let after = json(await call("list_agents", as: .you).text)
        check(agentsFile.contains("\"mayAct\" : true") && (after["agents"] as? [[String: Any]])?.first { $0["name"] as? String == "Scribe" }?["may_act"] as? Bool == true,
              "agents.json and list_agents say it may act")
        check(listedFingerprint(after, "Scribe") != before, "and its fingerprint changed, so the iPhone asks again")
        let acting = made(await call("create_task", ["title": "Email the printer", "binder": "Outreach", "column": "ready", "for": "Scribe"], as: .you).text)
        let actingWake = await woken("ready", acting)
        check(actingWake?["may_act"] as? Bool == true, "its wake says may_act true")
        setenv("BINDERS_TOOLS", "board", 1)
        setenv("BINDERS_AGENT", "Scribe", 1)
        check(MCPServer.offeredInstructions.contains("The user lets Scribe send, post or buy"), "and its MCP server says so")
        unsetenv("BINDERS_AGENT")
        unsetenv("BINDERS_TOOLS")
        // An agent can't give itself leave: one changed in agents.json is held until you save it here.
        var quiet = AgentProfile(name: "Quiet Scribe", wake: .command(command: "./wake-scribe", folder: folder.path), wakesPerHour: 30)
        check(registry.upsert(quiet) == nil, "another agent is saved, drafting first")
        let quietBefore = listedFingerprint(json(await call("list_agents", as: .you).text), "Quiet Scribe")
        let path = folder.appendingPathComponent("agents.json")
        if let data = try? Data(contentsOf: path), var file = try? AgentFile.decode(data).file,
           let index = file.agents.firstIndex(where: { $0.id == quiet.id }) {
            file.agents[index].mayAct = true
            try? file.encoded().write(to: path, options: .atomic)
        }
        registry.load()
        check(registry.changedOutside.contains(quiet.id) && registry.agent(named: "Quiet Scribe").map(registry.wakeable) == false,
              "one that gave itself leave in agents.json doesn't run until you save it")
        setenv("BINDERS_TOOLS", "board", 1)
        setenv("BINDERS_AGENT", "Quiet Scribe", 1)
        let heldTold = MCPServer.offeredInstructions
        unsetenv("BINDERS_AGENT")
        unsetenv("BINDERS_TOOLS")
        check(heldTold.contains("You draft first") && !heldTold.contains("The user lets Quiet Scribe"), "its MCP server still tells it to draft first")
        let heldList = json(await call("list_agents", as: .you).text)
        let heldEntry = (heldList["agents"] as? [[String: Any]])?.first { $0["name"] as? String == "Quiet Scribe" }
        check(heldEntry?["may_act"] as? Bool == false && listedFingerprint(heldList, "Quiet Scribe") == quietBefore,
              "and list_agents tells the iPhone it drafts first, with the fingerprint it had, so nothing asks about a leave you never gave")
        quiet.mayAct = nil
        registry.upsert(quiet)

        // k) Claude Code's prompt: drafting first unless you let it act.
        let repository = folder.appendingPathComponent("approvals-repo")
        try? manager.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let bin = folder.appendingPathComponent("approvals-bin")
        try? manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try? """
            #!/bin/sh
            here="$(cd "$(dirname "$0")/.." && pwd)"
            cat > "$here/prompt-$BINDERS_CARD.txt"
            exit 0
            """.write(to: fake, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var claude = AgentProfile(name: "Claude Code · drafts", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "plan",
                                                                                                 executable: fake.path)),
                                  preset: "claude-code", wakesPerHour: 30)
        check(registry.upsert(claude) == nil, "a Claude Code agent is saved: \(registry.problem(with: claude) ?? "")")
        func prompt(for title: String) async -> String {
            let id = made(await call("create_task", ["title": title, "binder": "Outreach", "column": "ready", "for": claude.name], as: .you).text)
            let file = folder.appendingPathComponent("prompt-\(id.uuidString).txt")
            for _ in 0..<80 where !((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("Your name on the board") {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        }
        let drafting = await prompt(for: "Reply to the venue")
        check(drafting.contains("6. Draft first.") && drafting.contains("call request_approval"), "its prompt tells it to draft first and ask: \(drafting.isEmpty ? "no prompt" : "yes")")
        claude.mayAct = true
        registry.upsert(claude)
        let letting = await prompt(for: "Reply to the printer")
        check(!letting.contains("Draft first") && letting.contains("The user lets you send, post or buy"), "let act, it's told it may")

        phone?.close()
        old?.close()
        server.stop()
        for agent in [scribe.id, quiet.id, claude.id] { registry.remove(agent) }
        return failures
    }

    /// The fingerprint list_agents gives the iPhone for one agent.
    private static func listedFingerprint(_ list: [String: Any], _ name: String) -> String {
        ((list["agents"] as? [[String: Any]])?.first { $0["name"] as? String == name }?["fingerprint"] as? String) ?? ""
    }
}
