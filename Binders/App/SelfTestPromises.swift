import AppKit
import Network
import SwiftUI
import SwiftData
import BindersKit

extension SelfTest {
    /// Who made a to-do, and which automations run for it: a to-do from Command Mode, the iPhone, a suggestion you tapped
    /// Add on, "Binders, …", an agent through a real `Binders --mcp`, a tool's inbox request and binders://todo each say
    /// where they came from; a rule runs for the ones you made, and for the others only when it also takes them, with
    /// BINDERS_TODO_ORIGIN. And binders://card/<id> opens the card. In a throwaway folder (BINDERS_DATA_DIR) only.
    @MainActor
    static func todoOriginSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes to-dos and automations")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        func objects(_ text: String?) -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data((text ?? "").utf8))) as? [[String: Any]] ?? [] }
        let store = Store.shared
        let controller = DictationController()
        let automations = AutomationService.shared
        let work = BinderRecord(name: "Work", colorIndex: 2)
        store.insert(work)
        store.save()

        // Two rules on "To-do added", each a script writing the origin it was given, the to-do and its binder to a file of
        // its own: one as rules are by default, one that also takes to-dos said to yourself, from agents and from links.
        func script(_ file: String) -> AutomationRule.Action {
            .script(command: "printf '%s|%s|%s\\n' \"$BINDERS_TODO_ORIGIN\" \"$BINDERS_TITLE\" \"$BINDERS_BINDER\" >> \"$BINDERS_DATA_DIR/\(file)\"")
        }
        let yours = AutomationRule(name: "Yours", trigger: .event(name: .todoAdded), action: script("rule-yours.log"))
        let every = AutomationRule(name: "Every to-do", trigger: .event(name: .todoAdded), action: script("rule-every.log"), anyOrigin: true)
        automations.upsert(yours)
        automations.upsert(every)
        let saved = (try? String(contentsOf: AppPaths.support.appendingPathComponent("automations.json"), encoding: .utf8)) ?? ""
        check(saved.contains("\"anyOrigin\" : true") && saved.components(separatedBy: "anyOrigin").count == 2,
              "automations.json keeps the option on the rule that has it, and says nothing on the other")
        func lines(_ file: String) -> [String] {
            ((try? String(contentsOf: AppPaths.support.appendingPathComponent(file), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        // Command Mode on this Mac ("Add to-do …").
        let voice = controller.commitments.addSpoken("Book the dentist")
        check(voice.commitment.todoOrigin == .voice && voice.commitment.madeBy == nil && voice.commitment.sourceTitle == "Added by voice",
              "a to-do said in Command Mode is yours, added by voice")

        // The iPhone, over the link: a to-do typed there, something said with "Binders, …", and one offered and added.
        guard let link = await testPhone(controller, name: "origin") else {
            check(false, "a test iPhone pairs and says hello")
            return 1
        }
        let phone = link.phone
        let typed = try? await phone.callTool("add_todo", ["text": "Buy stamps for the invitations", "binder": "Work"])
        let stamps = store.commitments().first { $0.task.hasPrefix("Buy stamps") }
        check(typed != nil && stamps?.todoOrigin == .phone && stamps?.madeBy == nil && stamps?.binderID == work.id
              && stamps?.sourceTitle == "Added on your iPhone", "a to-do from the iPhone is yours, in the binder it named: \(typed ?? "no answer")")
        func moment(_ text: String, wake: Bool) async -> UUID? {
            let payload = MomentPayload(heard: Date(), text: text, device: "iPhone", engine: "parakeet-v2", wake: wake)
            guard (try? await phone.request(MomentPayload.method, payload.jsonObject(), timeout: 40)) != nil else { return nil }
            return payload.id
        }
        let woke = await moment("remind me to call Sam tomorrow at 3", wake: true)
        let sam = store.commitments().first { $0.id == woke }
        check(sam?.todoOrigin == .moment && sam?.sourceTitle == "Said to yourself", "“Binders, …” is a to-do said to yourself, done at once")
        let offered = await moment("Man, I need to book a doctor's appointment", wake: false)
        if let offered { _ = try? await phone.request(CaptureOutcome.actMethod, ["id": offered.uuidString, "action": "add"]) }
        let doctor = store.commitments().first { $0.id == offered }
        check(doctor?.todoOrigin == .suggestion && doctor?.sourceTitle == "Said to yourself", "one offered and added with your tap is a suggestion you accepted")

        // An agent through a real `Binders --mcp`, and a tool that wrote an inbox request of its own.
        if let child = MCPChild(controller: controller), await child.initialize() {
            let reply = await child.result("add_todo", ["text": "Send the Ignite invoice by Friday", "binder": "Work"])
            let invoice = store.commitments().first { $0.task.hasPrefix("Send the Ignite invoice") }
            check(reply?.ok == true && invoice?.todoOrigin == .agent && invoice?.madeBy == "Claude Code" && invoice?.binderID == work.id
                  && invoice?.sourceTitle == "Added by Claude Code", "an agent's to-do says it's the agent's: \(invoice?.sourceTitle ?? reply?.text ?? "none")")
            child.stop()
        } else {
            check(false, "a Binders --mcp of its own answers")
        }
        let name = UUID().uuidString
        try? FileManager.default.createDirectory(at: InboxCommands.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(InboxRequest(action: "add_todo", fields: ["text": "Order the banner"]))
            .write(to: InboxCommands.directory.appendingPathComponent(Inbox.requestFile(name)))
        await InboxCommands.apply(named: name, controller: controller)
        let banner = store.commitments().first { $0.task == "Order the banner" }
        check(banner?.todoOrigin == .agent && banner?.madeBy == "AI agent" && banner?.sourceTitle == "Added by an AI agent",
              "a request file from any tool on this Mac is a tool's to-do, never yours")

        // binders://todo, which anything on this Mac can open.
        URLCommands.handle(URL(string: "binders://todo?text=Water%20the%20plants")!, controller: controller)
        let plants = store.commitments().first { $0.task == "Water the plants" }
        check(plants?.todoOrigin == .link && plants?.madeBy == "a link" && plants?.sourceTitle == "Added by a link",
              "a to-do from binders://todo says a link added it")

        // A to-do from before origins were kept reads as it did.
        let older = CommitmentRecord(task: "Renew the passport", kind: "todo", owner: TranscriptSegment.you)
        store.insert(older)
        store.save()
        check(older.todoOrigin == nil && older.sourceTitle == "Added by voice", "an older to-do still says added by voice")

        // What list_todos says about each, on the iPhone's link.
        let listed = objects(try? await phone.callTool("list_todos", ["status": "all"]))
        func item(_ task: String) -> [String: Any]? { listed.first { ($0["task"] as? String)?.hasPrefix(task) == true } }
        check(item("Send the Ignite invoice")?["made_by"] as? String == "Claude Code" && item("Send the Ignite invoice")?["origin"] as? String == "agent"
              && item("Send the Ignite invoice")?["source"] as? String == "Added by Claude Code", "list_todos names the agent that added one")
        check(item("Water the plants")?["made_by"] as? String == "a link" && item("Water the plants")?["origin"] as? String == "link",
              "and the link")
        check(item("Book the dentist")?["origin"] as? String == "voice" && item("Book the dentist")?["made_by"] == nil, "and says nothing more for yours")
        check(item("Renew the passport").map { $0["origin"] == nil && $0["made_by"] == nil } == true, "nor for one from before")

        // The rules: the default one ran for what you made; the other for every to-do. Each got the origin.
        var every_ = lines("rule-every.log")
        for _ in 0..<300 where every_.count < 7 {
            try? await Task.sleep(for: .milliseconds(100))
            every_ = lines("rule-every.log")
        }
        try? await Task.sleep(for: .seconds(1))
        let yours_ = lines("rule-yours.log")
        let origins = Set(yours_.compactMap { $0.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) })
        check(yours_.count == 3 && origins == ["voice", "phone", "suggestion"],
              "a rule as it comes runs for to-dos you made, and not for one said to yourself, an agent's or a link's: \(yours_)")
        check(Set(every_.compactMap { $0.split(separator: "|").first.map(String.init) }) == ["voice", "phone", "suggestion", "moment", "agent", "link"]
              && every_.count == 7, "one that also takes those runs for all seven: \(every_.count)")
        check(yours_.contains("phone|Buy stamps for the invitations|Work") && every_.contains("agent|Send the Ignite invoice|Work"),
              "with BINDERS_TODO_ORIGIN, and the binder the to-do went into")

        // binders://card/<id>, the link every woken agent gets: the card, open in its own window, without asking, without
        // bringing Binders forward or putting the cursor in it.
        let card = controller.board.create(title: "Plan the Ignite booth", binderID: work.id, column: .ready, by: .you)
        let navigation = HubWindowController.shared.navigation
        navigation.selection = .home
        URLCommands.handle(URL(string: AgentWakePayload(event: "assigned", agent: "Claude Code", card: card.id, title: card.title, details: "",
                                                        binder: "Work", column: .ready).link)!, controller: controller)
        check(CardWindows.shared.isOpen(card.id) && CardWindows.shared.openedFromLink(card.id) && navigation.selection == .home,
              "binders://card/<id> opens the card in its own window, and the Binders window stays where it was")
        CardWindows.shared.close(card.id)
        let gone = UUID()
        URLCommands.handle(URL(string: "binders://card/\(gone.uuidString)")!, controller: controller)
        check(!CardWindows.shared.isOpen(gone) && controller.flowBar.model.toastText == "That card isn't on a board any more.",
              "a card that's gone says so: \(controller.flowBar.model.toastText)")

        phone.close()
        link.server.stop()
        for rule in automations.rules { automations.remove(rule.id) }
        print(failures == 0 ? "TODO_ORIGIN_OK" : "TODO_ORIGIN_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Automations keep their promises: a web hook's token stays in the Keychain, never in automations.json, and goes as
    /// Authorization: Bearer, only to the address it was saved with; a rule from before has none and still posts; a link's
    /// values go only into its query, encoded, and one that would put a value in its path is refused, in the editor and
    /// when it runs. A local web hook on a spare port stands in for the server. In a throwaway folder (BINDERS_DATA_DIR) only.
    @MainActor
    static func automationHooksSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes automations and Keychain items")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        let automations = AutomationService.shared
        let hook = TestHook()
        guard let port = await hook.start() else {
            check(false, "a web hook on this Mac starts")
            return 1
        }
        let address = "http://127.0.0.1:\(port)/hook"
        let file = AppPaths.support.appendingPathComponent("automations.json")

        // A rule as Binders 0.8.0 wrote it: no token, no option.
        let oldID = UUID()
        let old = #"[{"action":{"webhook":{"body":"","url":"\#(address)"}},"id":"\#(oldID.uuidString)","isEnabled":true,"name":"Hook from before","trigger":{"event":{"name":"todoAdded"}}}]"#
        try? Data(old.utf8).write(to: file, options: .atomic)
        automations.load()
        check(automations.rules.map(\.id) == [oldID] && automations.rules.first?.anyOrigin == nil && !automations.withToken.contains(oldID),
              "a rule from before reads as it was")

        // A new web hook with a token, saved as the editor saves it.
        let secret = "selftest-token-\(UUID().uuidString)"
        let tokened = AutomationRule(name: "Hook with a token", trigger: .event(name: .todoAdded), action: .webhook(url: address, body: ""))
        automations.upsert(tokened, token: secret)
        let written = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(written.contains("Hook with a token") && !written.contains(secret) && !written.contains("\"token\""),
              "automations.json has the rule and not its token")
        check(automations.token(for: tokened.id) == secret && automations.withToken.contains(tokened.id), "the token is in the Keychain")

        // A to-do you made: both post, and only the new one sends a token.
        controller.commitments.addSpoken("Call the venue")
        let posts = await hook.wait(for: 2)
        let bearer = posts.filter { $0.authorization == "Bearer \(secret)" }
        check(posts.count == 2 && bearer.count == 1, "the web hook sends its token as Authorization: Bearer: \(posts.map { $0.authorization ?? "none" })")
        check(posts.contains { $0.authorization == nil && $0.path == "/hook" }, "and the rule from before still posts, with none")
        check(posts.allSatisfy { ($0.json["todo_origin"] as? String) == "voice" && ($0.json["title"] as? String) == "Call the venue" },
              "each payload says where the to-do came from")

        // The editor's Test with a token typed but not saved, then Remove Token, then a rule deleted.
        _ = await automations.run(tokened, payload: AutomationService.sample, quietly: true, token: "typed-token")
        let typed = await hook.wait(for: 3)
        check(typed.count == 3 && typed.last?.authorization == "Bearer typed-token", "Test sends the token as typed")
        automations.upsert(tokened, token: "")
        _ = await automations.run(tokened, payload: AutomationService.sample, quietly: true)
        let afterRemoving = await hook.wait(for: 4)
        check(automations.token(for: tokened.id) == nil && afterRemoving.count == 4 && afterRemoving.last?.authorization == nil,
              "Remove Token takes it out, and none goes")
        automations.upsert(tokened, token: secret)
        var changed = tokened
        changed.action = .script(command: "true")
        automations.upsert(changed)
        check(automations.token(for: tokened.id) == nil && !automations.withToken.contains(tokened.id), "a rule that no longer posts keeps no token")
        automations.upsert(tokened, token: secret)
        automations.remove(tokened.id)
        check(automations.token(for: tokened.id) == nil, "deleting the rule takes its token out of the Keychain")

        // Something else rewrites automations.json to send a rule with a token somewhere else: neither its token nor the
        // to-do goes there, and it says why, until the rule is saved again in Settings.
        let pointed = AutomationRule(name: "Hook pointed elsewhere", trigger: .event(name: .todoAdded), action: .webhook(url: address, body: ""))
        automations.upsert(pointed, token: secret)
        var moved = pointed
        moved.action = .webhook(url: "http://127.0.0.1:\(port)/elsewhere", body: "")
        try? JSONEncoder().encode(automations.rules.map { $0.id == pointed.id ? moved : $0 }).write(to: file, options: .atomic)
        automations.load()
        controller.commitments.addSpoken("Book the stand")
        for _ in 0..<50 where automations.outcomes[pointed.id] == nil { try? await Task.sleep(for: .milliseconds(100)) }
        // The rule from before posts the to-do, with no token, as it always did.
        _ = await hook.wait(for: 5)
        try? await Task.sleep(for: .milliseconds(300))
        let notSent = await hook.wait(for: 0)
        let refusal = automations.outcomes[pointed.id]
        check(automations.withToken.contains(pointed.id) && notSent.count == 5 && notSent.last?.path == "/hook" && notSent.last?.authorization == nil
              && !notSent.contains { $0.path == "/elsewhere" } && refusal?.ok == false
              && refusal?.message == AutomationService.Failure.addressChanged.errorDescription,
              "a rule pointed elsewhere outside Binders sends nothing there, and says why: \(refusal?.message ?? "nothing")")
        automations.upsert(moved)
        _ = await automations.run(moved, payload: AutomationService.sample, quietly: true)
        let resaved = await hook.wait(for: 6)
        check(resaved.count == 6 && resaved.last?.path == "/elsewhere" && resaved.last?.authorization == "Bearer \(secret)",
              "saved again in Settings, it posts there with its token")
        automations.remove(pointed.id)

        // Links: a value goes only into the query, every character outside the unreserved set encoded.
        var opened: [URL] = []
        automations.open = { opened.append($0) }
        defer { automations.open = { NSWorkspace.shared.open($0) } }
        let payload = AutomationPayload(text: "x", title: "../../Library/a.b", binder: "Work/Plans")
        let things = AutomationRule(name: "Things", trigger: .event(name: .todoAdded), action: .openURL(template: "things:///add?title={title}&list={binder}"))
        let ran = await automations.run(things, payload: payload, quietly: true)
        check(ran.ok && opened.last?.absoluteString == "things:///add?title=%2E%2E%2F%2E%2E%2FLibrary%2Fa%2Eb&list=Work%2FPlans",
              "a link takes the values in its query, encoded: \(opened.last?.absoluteString ?? ran.message)")
        let intoPath = AutomationRule(name: "Into the path", trigger: .event(name: .todoAdded),
                                      action: .openURL(template: "https://example.test/{binder}/new?title={title}"))
        let refused = await automations.run(intoPath, payload: payload, quietly: true)
        check(!refused.ok && refused.message.contains("{binder}") && opened.count == 1,
              "one with a value in its path is refused and nothing opens: \(refused.message)")
        check(AutomationTemplate.urlProblem("https://example.test/{binder}/new?title={title}") != nil
              && AutomationTemplate.urlProblem("things:///add?title={title}&list={binder}") == nil, "the editor refuses it for the same reason")

        // Drawn: the editor with a token kept, a to-do rule's option, and a link it refuses.
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let shown = AutomationRule(name: "Post to-dos", trigger: .event(name: .todoAdded), action: .webhook(url: "https://example.test/hook", body: ""))
            automations.upsert(shown, token: "selftest-drawn")
            for (rule, name) in [(shown, "automation-token"), (intoPath, "automation-link")] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560), styleMask: [.titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.alphaValue = 0
                let hosting = NSHostingView(rootView: AutomationEditor(rule: rule) { _, _ in }.environment(controller).environment(AppSettings.shared))
                hosting.wantsLayer = true
                window.contentView = hosting
                window.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(1500))
                capture(hosting, name: name, directory: directory)
                window.close()
            }
            automations.remove(shown.id)
            check(["automation-token", "automation-link"].allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0).png").path) },
                  "draws automation-token.png and automation-link.png")
        }

        for rule in automations.rules { automations.remove(rule.id) }
        hook.stop()
        print(failures == 0 ? "AUTOMATION_HOOKS_OK" : "AUTOMATION_HOOKS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// A note, a to-do, an answer or a hand-off sent again with the same request_id (the iPhone's outbox, its reply lost)
    /// is saved once and answered as the first time, across a restart too; without an id, or with a new one, it's done
    /// again; one that failed isn't remembered; and one sender's id never answers another's. Over a real phone link and a
    /// real `Binders --mcp`. In a throwaway folder (BINDERS_DATA_DIR) only.
    @MainActor
    static func dedupeSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes and to-dos")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        func object(_ text: String?) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data((text ?? "").utf8))) as? [String: Any] ?? [:] }
        let store = Store.shared
        let controller = DictationController()
        let general = store.defaultBinder()
        func notes(_ title: String) -> [NoteItem] { ((try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? []).filter { $0.title == title } }
        guard let link = await testPhone(controller, name: "dedupe") else {
            check(false, "a test iPhone pairs and says hello")
            return 1
        }
        let phone = link.phone
        check(link.features.contains(LinkFeatures.dedupe), "the Mac says it takes request_id")
        func send(_ tool: String, _ arguments: [String: Any]) async -> String? { try? await phone.callTool(tool, arguments, timeout: 20) }

        // A note sent twice with its id: one note, and the same answer.
        let noteID = UUID().uuidString
        let first = await send("add_note", ["text": "# Booth plan\n\nStand 14.", "request_id": noteID])
        let again = await send("add_note", ["text": "# Booth plan\n\nStand 14.", "request_id": noteID])
        check(first != nil && first == again && notes("Booth plan").count == 1, "a note sent again is saved once, and answered as the first time")
        check(object(again)["id"] as? String == notes("Booth plan").first?.id.uuidString, "the answer names the note that was saved")
        _ = await send("add_note", ["text": "# Booth plan\n\nStand 14.", "request_id": UUID().uuidString])
        check(notes("Booth plan").count == 2, "with a new id, it's a new note")
        _ = await send("add_note", ["text": "# Old phone\n\nNo id."])
        _ = await send("add_note", ["text": "# Old phone\n\nNo id."])
        check(notes("Old phone").count == 2, "without an id, as an older iPhone sends it, it's done each time")

        // A to-do.
        let todoID = UUID().uuidString
        _ = await send("add_todo", ["text": "Buy stamps", "request_id": todoID])
        let todoAgain = await send("add_todo", ["text": "Buy stamps", "request_id": todoID])
        check(store.commitments().filter { $0.task == "Buy stamps" }.count == 1 && todoAgain != nil, "a to-do sent again is added once")

        // An answer on a card, and a hand-off.
        let card = controller.board.create(title: "Book the Ignite booth", binderID: general.id, column: .ready, by: .you)
        let answerID = UUID().uuidString
        _ = await send("comment_task", ["id": card.id.uuidString, "text": "Stand 16, please.", "request_id": answerID])
        _ = await send("comment_task", ["id": card.id.uuidString, "text": "Stand 16, please.", "request_id": answerID])
        check(controller.board.timeline(card.id).filter { $0.text == "Stand 16, please." }.count == 1, "an answer sent again is on the card once")
        let handID = UUID().uuidString
        let handed = await send("update_task", ["id": card.id.uuidString, "for": "Claude Code", "progress": "Over to Claude Code.", "request_id": handID])
        let handedAgain = await send("update_task", ["id": card.id.uuidString, "for": "Claude Code", "progress": "Over to Claude Code.", "request_id": handID])
        check(handed != nil && handed == handedAgain && card.meantFor == "Claude Code"
              && controller.board.timeline(card.id).filter { $0.text == "Over to Claude Code." }.count == 1, "a hand-off sent again is made once")

        // One that failed isn't kept: once it can be done, the same id does it.
        let failedID = UUID().uuidString
        let failed = await send("add_note", ["text": "# Venue\n\nThe quayside.", "binder": "Events", "request_id": failedID])
        store.insert(BinderRecord(name: "Events", colorIndex: 4))
        store.save()
        let retried = await send("add_note", ["text": "# Venue\n\nThe quayside.", "binder": "Events", "request_id": failedID])
        check(failed == nil && retried != nil && notes("Venue").count == 1, "a request that failed is done when it's sent again")

        // Another sender's id is its own: the same id from an agent isn't the iPhone's.
        let agentWrite = MCPServer.writeInApp(controller: controller, arguments: ["request_id": noteID])
        let agent = try? await MCPServer.call("add_note", ["text": "# Booth plan\n\nStand 14.", "request_id": noteID], knowledge: controller.knowledge,
                                              write: agentWrite, actor: BoardActor(name: "Claude Code", kind: .agent))
        check(agent != nil && object(agent)["id"] as? String != object(first)["id"] as? String && notes("Booth plan").count == 3,
              "the same id from an agent is that agent's own request")

        // Kept in the data folder, written whole: after a restart it still answers.
        let kept = AppPaths.support.appendingPathComponent("handled-requests.json")
        let text = (try? String(contentsOf: kept, encoding: .utf8)) ?? ""
        check(text.contains(noteID) && text.contains(todoID) && text.contains(answerID) && text.contains(handID), "handled-requests.json keeps the ids")
        let restarted = HandledRequests(url: kept)
        let replay = InboxRequest(action: "add_note", fields: ["text": "# Booth plan\n\nStand 14.", "request_id": noteID])
        check(HandledRequests.key(for: replay).flatMap(restarted.answer(for:))?.id == object(first)["id"] as? String,
              "read again, as after a restart, it gives the first answer")

        // Through a real `Binders --mcp`, the inbox: the same.
        if let child = MCPChild(controller: controller), await child.initialize() {
            let childID = UUID().uuidString
            let one = await child.result("add_note", ["text": "# From the child\n\nOnce.", "request_id": childID])
            let two = await child.result("add_note", ["text": "# From the child\n\nOnce.", "request_id": childID])
            check(one?.ok == true && one?.text == two?.text && notes("From the child").count == 1, "through Binders --mcp, a request sent again is done once")
            child.stop()
        } else {
            check(false, "a Binders --mcp of its own answers")
        }

        phone.close()
        link.server.stop()
        print(failures == 0 ? "DEDUPE_OK" : "DEDUPE_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// A test iPhone, paired with a link server of this app on spare ports and past hello as this build of the phone says
    /// it. The devices file is in the throwaway folder.
    @MainActor
    static func testPhone(_ controller: DictationController, name: String) async -> (server: LinkServer, phone: LinkClient, features: [String])? {
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: AppPaths.support.appendingPathComponent("test-\(name)-devices.json"))
        server.start()
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        guard let port = server.boundPort, var pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort else { return nil }
        pairing.addresses = ["127.0.0.1:\(pairingPort)"]
        do {
            let paired = try await LinkClient.pair(pairing, deviceName: "Test iPhone")
            let phone = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            try await phone.connect()
            let hello = try await phone.hello(device: paired.device, key: paired.key, name: "Test iPhone", features: LinkFeatures.thisPhone)
            return (server, phone, hello["features"] as? [String] ?? [])
        } catch {
            server.stop()
            return nil
        }
    }
}

/// A web hook on this Mac for the self-test, on a spare loopback port: it answers 200 to every POST and keeps what each
/// one sent.
final class TestHook: @unchecked Sendable {
    struct Post: Sendable {
        var path: String
        var authorization: String?
        var body: String
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:] }
    }

    private let lock = NSLock()
    private var posts: [Post] = []
    private var listener: NWListener?

    /// Its port, once it listens.
    func start() async -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .utility))
            self?.read(connection, Data())
        }
        listener.start(queue: .global(qos: .utility))
        for _ in 0..<50 {
            if listener.state == .ready, let port = listener.port?.rawValue, port != 0 { return port }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    func stop() {
        listener?.cancel()
    }

    /// What it has been sent, once there are at least `count` (or after ten seconds).
    func wait(for count: Int) async -> [Post] {
        for _ in 0..<100 {
            let now = lock.withLock { posts }
            if now.count >= count { return now }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return lock.withLock { posts }
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let post = Self.parse(buffer) {
                self.lock.withLock { self.posts.append(post) }
                let answer = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                connection.send(content: Data(answer.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer)
            }
        }
    }

    /// A whole request: its headers and as much body as it said it has. Nil until it's all in.
    private static func parse(_ data: Data) -> Post? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        let path = head.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return Post(path: path, authorization: headers["authorization"], body: String(decoding: body.prefix(length), as: UTF8.self))
    }
}
