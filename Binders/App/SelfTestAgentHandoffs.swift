import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// Handing work to agents, through the same tools and link the iPhone uses: list_agents says where each agent's cards
    /// go, with a fingerprint that changes when one is pointed somewhere new; the first time a card goes to an agent, what
    /// its binder knows is written on it ("From your binders"), from what that agent may read only; Give to on a capture's
    /// card or idea from the phone; and an idea said to yourself offered to the agent that fits. In a throwaway folder
    /// (BINDERS_DATA_DIR) only.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-agent-handoffs -notesShowMarkdown NO
    @MainActor
    static func agentHandoffsSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards, notes and agents")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let store = Store.shared
        let controller = DictationController()
        let board = controller.board
        let registry = AgentRegistry.shared
        let write = MCPServer.writeInApp(controller: controller)
        let folder = AppPaths.support
        let manager = FileManager.default
        /// A tool call as `actor`; `host`, when given, is the tool it comes from, with what Settings → MCP lets it read.
        func call(_ tool: String, _ arguments: [String: Any] = [:], as actor: BoardActor, host: String = "") async -> (ok: Bool, text: String) {
            let reads = host.isEmpty ? MCPServer.Reads.everything : MCPServer.reads(for: host)
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor, reads: reads, host: host)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func json(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
        func made(_ text: String) -> UUID { ((json(text) as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID() }
        func listed(as actor: BoardActor = .you) async -> [String: [String: Any]] {
            let agents = ((json(await call("list_agents", as: actor).text) as? [String: Any])?["agents"] as? [[String: Any]]) ?? []
            return Dictionary(agents.map { ($0["name"] as? String ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        }
        func contexts(_ id: UUID) -> [TaskEvent] { board.timeline(id).filter { $0.kind == .context } }
        func timeline(_ id: UUID, as actor: BoardActor = .you, host: String = "") async -> [[String: Any]] {
            ((json(await call("get_task", ["id": id.uuidString], as: actor, host: host).text) as? [String: Any])?["timeline"] as? [[String: Any]]) ?? []
        }
        /// The "From your binders" note as get_task gives it to the tool `host`, asking as `actor`: nil when it shows none.
        func shownContext(_ id: UUID, to host: String, as actor: BoardActor) async -> String? {
            await timeline(id, as: actor, host: host).first { $0["kind"] as? String == "context" }?["text"] as? String
        }
        let grants = [MCPServer.captureReaders, MCPServer.transcriptReaders, MCPServer.teamReaders]
        for key in grants { MCPServer.ReadGrants.set([], key) }

        // An agent woken with a script of its own, which keeps what it was handed.
        let script = folder.appendingPathComponent("wake-echo")
        try? """
            #!/bin/sh
            here="$(cd "$(dirname "$0")" && pwd)"
            printf 'WAKE %s %s\\n' "$BINDERS_EVENT" "$BINDERS_CARD" >> "$here/echo-wakes.txt"
            cat > "$here/echo-$BINDERS_CARD.json"
            """.write(to: script, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        func handed(_ id: UUID) async -> [String: Any] {
            let file = folder.appendingPathComponent("echo-\(id.uuidString).json")
            for _ in 0..<60 where (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        }
        func forget(_ id: UUID) { try? manager.removeItem(at: folder.appendingPathComponent("echo-\(id.uuidString).json")) }
        let echo = AgentProfile(name: "Echo", wake: .command(command: "./wake-echo", folder: folder.path), wakesPerHour: 30)
        let hook = AgentProfile(name: "Hooky", wake: .webhook(url: "https://hooks.example.test/cards?token=abc"))
        let looker = AgentProfile(name: "Looker", wake: .board)
        let quiet = AgentProfile(name: "Quiet", wake: .command(command: "./wake-echo", folder: folder.path), wakesPerHour: 30, binderContext: false)
        let repository = folder.appendingPathComponent("fake-repo")
        try? manager.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let bin = folder.appendingPathComponent("bin")
        try? manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("claude").path)
        let claude = AgentProfile(name: "Claude Code · fake", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "plan",
                                                                                               executable: bin.appendingPathComponent("claude").path)),
                                  preset: "claude-code")
        for agent in [echo, hook, looker, quiet, claude] { check(registry.upsert(agent) == nil, "\(agent.name) is saved: \(registry.problem(with: agent) ?? "")") }

        // a) Where each agent's cards go, for the iPhone to say before the first one goes.
        var agents = await listed()
        check(agents["Echo"]?["sends_to"] as? String == "wake-echo" && agents["Hooky"]?["sends_to"] as? String == "hooks.example.test"
              && agents["Claude Code · fake"]?["sends_to"] as? String == "Anthropic" && agents["Looker"]?["sends_to"] as? String == "wherever it runs",
              "list_agents says where each one's cards go: \(agents.mapValues { $0["sends_to"] as? String ?? "" })")
        check(!(agents["Hooky"]?["sends_to"] as? String ?? "").contains("token"), "a web hook by its host, never its address")
        let first = agents["Hooky"]?["fingerprint"] as? String ?? ""
        check(first.count == 16 && agents["Echo"]?["adds_context"] as? Bool == true && agents["Echo"]?["context_from"] as? String == "notes and meetings"
              && agents["Quiet"]?["adds_context"] as? Bool == false && agents["Quiet"]?["context_from"] as? String == "",
              "with a fingerprint, and whether it adds what the card's binder knows")
        let byAgent = await listed(as: BoardActor(name: "Helper", kind: .agent))
        check(byAgent["Hooky"].map { Set($0.keys) == ["name", "wakes"] } == true, "an agent asking hears names and kinds alone")
        var moved = hook
        moved.isEnabled = true
        moved.wakesPerHour = 2
        registry.upsert(moved)
        check((await listed())["Hooky"]?["fingerprint"] as? String == first, "how often it's woken doesn't change the fingerprint")
        moved.wake = .webhook(url: "https://elsewhere.example.test/cards")
        registry.upsert(moved)
        agents = await listed()
        check(agents["Hooky"]?["fingerprint"] as? String != first && agents["Hooky"]?["sends_to"] as? String == "elsewhere.example.test",
              "pointed somewhere new, it has a new one, so the iPhone asks again")
        // Who each one hands its cards to for its work, for the iPhone to name (App Store 5.1.2(i)): what Settings says, else
        // what its program says, and nothing where nothing does.
        check(agents["Claude Code · fake"]?["vendor"] as? String == "Anthropic" && agents["Echo"]?["vendor"] == nil && agents["Hooky"]?["vendor"] == nil
              && agents["Looker"]?["vendor"] == nil,
              "list_agents says who an agent hands its cards to where that's known: \(agents.mapValues { $0["vendor"] as? String ?? "none" })")
        let echoBefore = agents["Echo"]?["fingerprint"] as? String ?? ""
        var told = echo
        told.vendor = "OpenAI"
        registry.upsert(told)
        agents = await listed()
        check(agents["Echo"]?["vendor"] as? String == "OpenAI" && agents["Echo"]?["sends_to"] as? String == "wake-echo"
              && agents["Echo"]?["fingerprint"] as? String != echoBefore,
              "said in Settings, it's named, its program still says where it starts, and the iPhone asks again")
        // One that names itself a vendor in agents.json is held until you save it, and the iPhone hears none from it.
        let agentsJSON = folder.appendingPathComponent("agents.json")
        if let data = try? Data(contentsOf: agentsJSON), var file = try? AgentFile.decode(data).file,
           let index = file.agents.firstIndex(where: { $0.id == echo.id }) {
            file.agents[index].vendor = "Nowhere, it stays on this Mac"
            try? file.encoded().write(to: agentsJSON, options: .atomic)
        }
        registry.load()
        agents = await listed()
        check(registry.changedOutside.contains(echo.id) && agents["Echo"]?["vendor"] == nil,
              "a vendor an agent gave itself in agents.json isn't said: \(agents["Echo"]?["vendor"] as? String ?? "none")")
        // Mac 0.8.0 reads neither who it sends cards to nor what it's for, and saves without them: back here, that
        // agent isn't held as changed outside Binders, and 0.8.0 holds none it reads for having them.
        var described = echo
        described.vendor = "OpenAI"
        described.purpose = "Echoes cards back"
        registry.upsert(described)
        var asBefore = described
        asBefore.vendor = nil
        asBefore.purpose = nil
        check(AgentRegistry.fingerprint(described) == AgentRegistry.fingerprint(asBefore),
              "the fingerprint 0.8.0 checks leaves out who it sends cards to and what it's for")
        if let data = try? Data(contentsOf: agentsJSON), var file = try? AgentFile.decode(data).file,
           let index = file.agents.firstIndex(where: { $0.id == echo.id }) {
            file.agents[index].vendor = nil
            file.agents[index].purpose = nil
            try? file.encoded().write(to: agentsJSON, options: .atomic)
        }
        registry.load()
        check(!registry.changedOutside.contains(echo.id), "saved by 0.8.0 without them, it isn't held as changed outside Binders")
        registry.upsert(described)
        if let data = try? Data(contentsOf: agentsJSON), var file = try? AgentFile.decode(data).file,
           let index = file.agents.firstIndex(where: { $0.id == echo.id }) {
            file.agents[index].purpose = "Everything, always"
            try? file.encoded().write(to: agentsJSON, options: .atomic)
        }
        registry.load()
        check(registry.changedOutside.contains(echo.id), "what it's for changed in agents.json: held until you save it")
        registry.upsert(echo)
        let claudeBefore = agents["Claude Code · fake"]?["fingerprint"] as? String ?? ""
        MCPServer.ReadGrants.set(["Claude Code"], MCPServer.captureReaders)
        agents = await listed()
        check(agents["Claude Code · fake"]?["fingerprint"] as? String != claudeBefore
              && agents["Claude Code · fake"]?["context_from"] as? String == "notes, meetings and captures",
              "and so is one allowed to read captures, which then go with its cards")
        MCPServer.ReadGrants.set([], MCPServer.captureReaders)

        // b) What the binder knows, written on the card the first time it goes to an agent.
        let events = BinderRecord(name: "Events", colorIndex: 1)
        store.insert(events)
        @discardableResult
        func note(_ text: String, change: (NoteItem) -> Void = { _ in }) -> NoteItem {
            let note = NoteItem(text: text)
            note.binderID = events.id
            change(note)
            store.insert(note)
            return note
        }
        note("# Ignite booth plan\n\nBooth 14 in Hall B.\n- Two tables and the big banner")
        note("# Tomatoes\n\nWhen to plant them out.")
        note("# Ignite booth budget\n\nThe booth costs more than planned.") { $0.isTeamCopy = true; $0.teamAuthorName = "Maya" }
        note("# Ignite booth, by an agent\n\nThe agent's own booth notes.") { $0.madeBy = "Helper" }
        let venue = MeetingRecord(title: "Call with the Ignite venue", appName: "Zoom", templateID: "general")
        venue.status = "ready"
        venue.binderID = events.id
        venue.summary = "## Summary\nThe venue holds the booth space until Friday."
        store.insert(venue)
        store.replaceSegments(for: venue.id, with: [TranscriptSegment(channel: .microphone, start: 3, end: 6, text: "The Ignite booth wifi password is lighthouse.",
                                                                      speaker: "You")])
        let hallway = MeetingRecord(title: "Hallway chat about the Ignite booth", appName: "iPhone", templateID: "conversation")
        hallway.kind = MeetingRecord.conversationKind
        hallway.status = "ready"
        hallway.binderID = events.id
        hallway.summary = "## Summary\nThe booth moves to Hall C."
        store.insert(hallway)
        store.save()

        let banner = made(await call("create_task", ["title": "Order the banner for the Ignite booth", "binder": "Events", "column": "backlog"], as: .you).text)
        if let card = board.card(banner) { board.give(card, to: echo.name, by: .you) }
        let written = contexts(banner)
        let text = written.first?.text ?? ""
        check(written.count == 1 && written.first?.author == "Binders" && written.first?.authorIsAgent == false && text.hasPrefix("From your binders:"),
              "giving it to Echo writes what the binder knows on it, by Binders: \(text)")
        check(text.contains("“Ignite booth plan” (note)") && text.contains("“Call with the Ignite venue” (meeting)") && !text.contains("Tomatoes"),
              "the notes and meetings that match it")
        check(!text.contains("budget") && !text.contains("Hallway") && !text.contains("by an agent") && !text.contains("lighthouse"),
              "and no teammate's note, capture, agent's note or transcript")
        let payload = await handed(banner)
        check(payload["context"] as? String == text, "Echo's wake carries it too: \(payload["context"] as? String ?? "nothing")")
        let seen = await timeline(banner)
        check(seen.contains { $0["kind"] as? String == "context" && $0["who"] as? String == "Binders" && $0["agent"] as? Bool == false },
              "get_task shows it as Binders' own, kind context")
        if let card = board.card(banner) {
            try? board.move(card, to: .backlog, by: .you)
            forget(banner)
            board.give(card, to: echo.name, by: .you)
        }
        check(contexts(banner).count == 1, "given again, it isn't written twice")
        if let note = contexts(banner).first { board.editContext(note, text: "From your binders:\n• Use the blue banner.") }
        _ = await handed(banner)
        forget(banner)
        if let card = board.card(banner) {
            try? board.move(card, to: .backlog, by: .you)
            board.give(card, to: echo.name, by: .you)
        }
        check((await handed(banner))["context"] as? String == "From your binders:\n• Use the blue banner.", "as you edited it, it goes with the next wake")
        if let note = contexts(banner).first { board.editContext(note, text: "") }
        check(!(await timeline(banner)).contains { $0["kind"] as? String == "context" }, "deleted, no one sees it")
        forget(banner)
        if let card = board.card(banner) {
            try? board.move(card, to: .backlog, by: .you)
            board.give(card, to: echo.name, by: .you)
        }
        let afterDeleting = await handed(banner)
        check(contexts(banner).count == 1 && contexts(banner).first?.text == "" && afterDeleting["context"] as? String == "", "and it isn't written again")

        let quietCard = made(await call("create_task", ["title": "Print the Ignite booth badges", "binder": "Events", "column": "backlog"], as: .you).text)
        if let card = board.card(quietCard) { board.give(card, to: quiet.name, by: .you) }
        let quietly = await handed(quietCard)
        check(contexts(quietCard).isEmpty && quietly["context"] as? String == "", "an agent with Add context off gets none")
        let looked = made(await call("create_task", ["title": "Book the Ignite booth furniture", "binder": "Events", "column": "ready", "for": looker.name],
                                     as: .you).text)
        check(contexts(looked).first?.text.contains("Ignite booth plan") == true, "one that checks the board itself finds it on the card")

        // Allowed to read captures, an agent gets them; handed on to one that may not, the card loses them.
        MCPServer.ReadGrants.set([MCPServer.otherTools], MCPServer.captureReaders)
        let hall = made(await call("create_task", ["title": "Move the Ignite booth sign", "binder": "Events", "column": "backlog"], as: .you).text)
        if let card = board.card(hall) { board.give(card, to: echo.name, by: .you) }
        let wide = contexts(hall).first?.text ?? ""
        check(wide.contains("“Hallway chat about the Ignite booth” (capture)"), "allowed captures, Echo gets the capture too: \(wide)")
        // get_task gives the note only as far as whoever asks may read it, and the card keeps it as written.
        let desktop = await shownContext(hall, to: "Claude Desktop", as: BoardActor(name: "Claude Desktop", kind: .agent))
        check(desktop?.contains("Ignite booth plan") == true && desktop?.contains("Hallway") == false && contexts(hall).first?.text == wide,
              "get_task by a tool that may not read captures leaves the capture's line out, and the card keeps it: \(desktop ?? "none")")
        let toEcho = await shownContext(hall, to: echo.name, as: BoardActor(name: echo.name, kind: .agent))
        check(toEcho == wide, "Echo, which may read captures, reads it all")
        MCPServer.ReadGrants.set([], MCPServer.captureReaders)
        let revoked = await shownContext(hall, to: echo.name, as: BoardActor(name: echo.name, kind: .agent))
        check(revoked?.contains("Ignite booth plan") == true && revoked?.contains("Hallway") == false,
              "with captures taken from it again, Echo's get_task leaves the line out too: \(revoked ?? "none")")
        // An agent with Add context off reads none of it, as its own MCP server asks (pinned to its name); nor does one
        // that turned it on for itself in agents.json, which is held until you save it in Settings.
        func asQuiet() async -> String? {
            setenv("BINDERS_AGENT", quiet.name, 1)
            defer { unsetenv("BINDERS_AGENT") }
            return await shownContext(hall, to: quiet.name, as: BoardActor(name: "AI agent", kind: .agent))
        }
        let toQuiet = await asQuiet()
        check(toQuiet == nil, "an agent with Add context off reads none of it with get_task: \(toQuiet ?? "none")")
        let agentsFile = folder.appendingPathComponent("agents.json")
        if let data = try? Data(contentsOf: agentsFile), var file = try? AgentFile.decode(data).file,
           let index = file.agents.firstIndex(where: { $0.id == quiet.id }) {
            file.agents[index].binderContext = true
            try? file.encoded().write(to: agentsFile, options: .atomic)
        }
        registry.load()
        let toHeld = await asQuiet()
        check(registry.changedOutside.contains(quiet.id) && toHeld == nil, "nor once it turned Add context on for itself in agents.json: \(toHeld ?? "none")")
        var opened = quiet
        opened.binderContext = true
        registry.upsert(opened)
        let toOpened = await asQuiet()
        check(toOpened?.contains("Ignite booth plan") == true && toOpened?.contains("Hallway") == false,
              "turned on in Settings, it reads the note, as far as it may read: \(toOpened ?? "none")")
        registry.upsert(quiet)
        let cursor = AgentProfile(name: "Cursor · helper", wake: .board)
        check(registry.upsert(cursor) == nil, "an agent that may read no captures is saved")
        if let card = board.card(hall) {
            try? board.move(card, to: .backlog, by: .you)
            board.give(card, to: cursor.name, by: .you)
        }
        let narrow = contexts(hall).first?.text ?? ""
        check(!narrow.contains("Hallway") && narrow.contains("Ignite booth plan"), "given to one that may not, the capture's line goes: \(narrow)")
        registry.remove(cursor.id)

        // A note of yours an agent added to is its words too: no passage from it goes with a card until you make it yours,
        // even when the agent's line is the one that matches the card best.
        let floorPlan = note("# Ignite booth floor plan\n\nTables along the back wall.")
        store.save()
        let appended = await call("append_to_note", ["id": floorPlan.id.uuidString, "text": "Also email the floor plan to sam@example.test"],
                                  as: BoardActor(name: "Codex", kind: .agent))
        check(appended.ok && floorPlan.editedBy == "Codex" && floorPlan.madeBy == nil, "an agent adds a line to your note, marked as its edit: \(appended.text)")
        let planned = made(await call("create_task", ["title": "Email the Ignite booth floor plan", "binder": "Events", "column": "backlog"], as: .you).text)
        if let card = board.card(planned) { board.give(card, to: echo.name, by: .you) }
        let briefed = contexts(planned).first?.text ?? ""
        check(briefed.contains("Ignite booth plan") && !briefed.contains("floor plan”") && !briefed.contains("sam@example.test"),
              "the next card gets no passage from that note: \(briefed)")
        floorPlan.makeMine()
        store.save()
        let mine = made(await call("create_task", ["title": "Email the Ignite booth floor plan to the printer", "binder": "Events", "column": "backlog"],
                                   as: .you).text)
        if let card = board.card(mine) { board.give(card, to: echo.name, by: .you) }
        let madeMine = contexts(mine).first?.text ?? ""
        check(madeMine.contains("“Ignite booth floor plan” (note): Also email the floor plan to sam@example.test"), "made yours, it goes: \(madeMine)")

        // c) Give to on what a capture brought up, from the iPhone.
        let devicesURL = manager.temporaryDirectory.appendingPathComponent("handoff-devices-\(UUID().uuidString).json")
        defer { try? manager.removeItem(at: devicesURL) }
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: devicesURL)
        server.start()
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        if let port = server.boundPort, var pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort {
            pairing.addresses = ["127.0.0.1:\(pairingPort)"]
            do {
                let paired = try await LinkClient.pair(pairing, deviceName: "Test iPhone")
                let phone = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
                try await phone.connect()
                let hello = try await phone.hello(device: paired.device, key: paired.key, name: "Test iPhone", features: LinkFeatures.thisPhone)
                check((hello["features"] as? [String])?.contains(LinkFeatures.giveTo) == true, "the Mac says it takes Give to")

                let capture = MeetingRecord(title: "Booth chat", appName: "iPhone", templateID: "conversation")
                capture.kind = MeetingRecord.conversationKind
                capture.status = "ready"
                capture.binderID = events.id
                capture.summary = """
                    ## Summary
                    About the Ignite booth.
                    ## Promises
                    - [ ] You — book the photographer
                    - [ ] You — order the stickers
                    ## Ideas
                    - Hand out stickers at the booth
                    - A raffle for the big banner
                    """
                store.insert(capture)
                let promises = SuggestionPrompts.cardCandidates(summary: capture.summary, conversation: capture.id)
                let ideas = SuggestionPrompts.ideaCandidates(summary: capture.summary)
                capture.suggestions = promises.map { ConversationSuggestion(conversation: capture.id, kind: .card, text: $0.text, binder: "Events", todo: $0.todo) }
                    + ideas.map { ConversationSuggestion(conversation: capture.id, kind: .idea, text: $0, binder: "Events") }
                store.save()
                check(promises.count == 2 && ideas.count == 2, "the capture offers two promises and two ideas")
                let offered = (try await phone.request(ConversationSuggestion.listMethod) as? [String: Any])?["suggestions"] as? [[String: Any]] ?? []
                check(offered.filter { $0["kind"] as? String == "idea" }.count == 2, "a phone that reads ideas gets them")
                let old = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
                try await old.connect()
                _ = try await old.hello(device: paired.device, key: paired.key, name: "Old iPhone")
                let oldOffers = (try await old.request(ConversationSuggestion.listMethod) as? [String: Any])?["suggestions"] as? [[String: Any]] ?? []
                check(!oldOffers.isEmpty && !oldOffers.contains { $0["kind"] as? String == "idea" }, "iPhone 2.0 gets none, so it loses nothing")
                old.close()

                func give(_ suggestion: ConversationSuggestion, to agent: String) async -> (ok: Bool, message: String) {
                    await Self.give(suggestion, to: agent, from: phone)
                }
                let suggestions = capture.suggestions
                let photographer = suggestions[0], stickers = suggestions[1], handout = suggestions[2], raffle = suggestions[3]
                let promised = await give(photographer, to: echo.name)
                let promisedCard = board.card(forTodo: photographer.todo ?? "")
                check(promised.ok && promisedCard?.column == .ready && promisedCard?.meantFor == echo.name && promisedCard?.meantForByAgent == false,
                      "Give to on a promise puts its card in Ready, meant for Echo: \(promised.message)")
                if let promisedCard {
                    _ = await handed(promisedCard.id)
                    check(board.timeline(promisedCard.id).contains { $0.kind == .woke && $0.author == echo.name }, "and wakes it, with a receipt on the card")
                }
                check(capture.suggestions.first { $0.id == photographer.id }?.status == .accepted, "and the offer is settled")
                let idea = await give(handout, to: echo.name)
                let ideaCard = board.card(handout.cardID)
                check(idea.ok && ideaCard?.column == .ready && ideaCard?.meantFor == echo.name && ideaCard?.title == "Hand out stickers at the booth",
                      "Give to on an idea does the same with its card: \(idea.message)")
                check(ideaCard.map { MCPServer.fromCapture($0) } == true, "a card made from a capture, which only the agent it's meant for may read")
                let nobody = await give(stickers, to: "Nobody")
                check(!nobody.ok && capture.suggestions.first { $0.id == stickers.id }?.status == .offered, "to no such agent, it's refused and still offered: \(nobody.message)")
                let kept = controller.conversations.accept(raffle.id)
                let raffleCard = board.card(raffle.cardID)
                check(kept.ok && raffleCard?.column == .backlog && raffleCard?.meantFor == nil, "Add to Board puts an idea in Backlog: \(kept.message)")
                check(controller.conversations.accept(raffle.id).message.hasPrefix("Already on") && board.cards(in: events.id).filter { $0.id == raffle.cardID }.count == 1,
                      "and a second yes makes no second card")

                // d) An idea said to yourself that hands work to an agent by name: Give to, as for a to-do. (A name merely at the
                // end, "… for Echo", isn't a hand-off for the named-agent rule.)
                let moment = MomentPayload(id: UUID(), heard: Date(), text: "Idea for Events: have Echo set up a photo wall at the booth", device: "iPhone",
                                           engine: "test", wake: true)
                let reply = try await phone.request(MomentPayload.method, moment.jsonObject(), timeout: 40) as? [String: Any]
                let outcome = (reply?["outcome"]).flatMap { CaptureOutcome.decodeEach([$0]).first }
                check(outcome?.state == "acted" && outcome?.actions == ["undo", "assign"] && outcome?.agent == echo.name,
                      "an idea for Echo is offered to it: \(outcome?.actions ?? []) \(outcome?.agent ?? "no agent")")
                _ = try? await phone.request(CaptureOutcome.actMethod, ["id": moment.id.uuidString, "action": "assign"])
                let given = board.card(moment.id)
                check(given?.column == .ready && given?.meantFor == echo.name, "and Give to puts its card in Ready, meant for Echo")
                phone.close()
            } catch {
                check(false, "the link failed: \(error.localizedDescription)")
            }
        } else {
            check(false, "the link didn't start")
        }
        server.stop()

        for agent in [echo, hook, looker, quiet, claude] { registry.remove(agent.id) }
        for key in grants { MCPServer.ReadGrants.set([], key) }
        print(failures == 0 ? "AGENT_HANDOFFS_OK" : "AGENT_HANDOFFS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Give to on a capture's suggestion, as the iPhone sends it: whether the Mac did it, and what it said.
    private static func give(_ suggestion: ConversationSuggestion, to agent: String, from phone: LinkClient) async -> (ok: Bool, message: String) {
        do {
            let reply = try await phone.request(ConversationSuggestion.actMethod, ["id": suggestion.id, "action": "give", "agent": agent]) as? [String: Any]
            return (true, reply?["message"] as? String ?? "")
        } catch LinkClient.Failure.rejected(let message) {
            return (false, message)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
