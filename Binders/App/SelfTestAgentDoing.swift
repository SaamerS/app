import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// What a run Binders started says it's doing, read from what Claude Code writes anyway, in a throwaway agent home: a
    /// stand-in for claude that the test writes keeps a task list and a session record there as Claude Code does, and the
    /// card, Home's digest and work_streams (in the app, over the link as this iPhone asks it, and from a `Binders --mcp`
    /// of its own, as an agent on this Mac would) say the task in progress, as the agent's words. Only for runs Binders
    /// started, only while the card is in progress, read no more than every 30 seconds, from the run's own task list and
    /// nothing else in the agent home (a stand-in for your own session sits beside it), never told to an iPhone that would
    /// save it, and nothing kept but the line, which goes when no page shows it. In throwaway folders (BINDERS_DATA_DIR and
    /// BINDERS_AGENT_HOME) only. A folder after the flag gets drawings of the card, its page and Home's digest.
    @MainActor
    static func agentDoingSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo, let home = ProcessInfo.processInfo.environment["BINDERS_AGENT_HOME"], !home.isEmpty else {
            print("ERROR: set BINDERS_DATA_DIR and BINDERS_AGENT_HOME to throwaway folders")
            return 1
        }
        let manager = FileManager.default
        let agentHome = URL(fileURLWithPath: home, isDirectory: true)
        // Never a real home: the agent home is an empty folder, or one this test marked as its own.
        let marker = agentHome.appendingPathComponent(".binders-agent-doing-test")
        let existing = (try? manager.contentsOfDirectory(atPath: agentHome.path)) ?? []
        guard agentHome.standardizedFileURL.path != manager.homeDirectoryForCurrentUser.standardizedFileURL.path,
              existing.isEmpty || manager.fileExists(atPath: marker.path) else {
            print("ERROR: BINDERS_AGENT_HOME must be an empty folder")
            return 1
        }
        try? manager.createDirectory(at: agentHome, withIntermediateDirectories: true)
        manager.createFile(atPath: marker.path, contents: Data())
        let claudeFolder = agentHome.appendingPathComponent(".claude", isDirectory: true)

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
        let feed = AgentDoingFeed.shared, reader = AgentDoingReader.shared
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }
        func made(_ text: String) -> UUID { (object(text)["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID() }
        func text(_ file: String) -> String { (try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)) ?? "" }
        func setting(_ name: String, _ value: String) { try? value.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        /// A task as Claude Code's TaskCreate and TaskUpdate write it.
        func task(_ id: Int, _ subject: String, _ active: String?, _ status: String, session: String) {
            var task: [String: Any] = ["id": String(id), "subject": subject, "description": "", "status": status, "blocks": [String](),
                                       "blockedBy": id > 1 ? [String(id - 1)] : [String]()]
            if let active { task["activeForm"] = active }
            let url = claudeFolder.appendingPathComponent("tasks/\(session)/\(id).json")
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: task).write(to: url, options: .atomic)
        }
        /// A JSON file the test wrote, or the stand-in did.
        func record(_ url: URL) -> [String: Any] { (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:] }
        /// Each work_streams stream's doing, by who.
        func doing(_ reply: String) -> [String: [[String: String]]] {
            ((object(reply)["working"] as? [[String: Any]]) ?? []).reduce(into: [:]) { found, stream in
                if let who = stream["who"] as? String, let lines = stream["doing"] as? [[String: String]] { found[who] = lines }
            }
        }

        check(AgentDoingReader.claudeFolder(environment: [:], throwaway: true) == nil
              && AgentDoingReader.claudeFolder(environment: ["BINDERS_AGENT_HOME": home], throwaway: true)?.path == claudeFolder.path
              && AgentDoingReader.claudeFolder?.path == claudeFolder.path,
              "with a throwaway data folder, only a throwaway agent home is read, never yours")

        // A stand-in for claude, in the throwaway folder: it keeps a task list and a session record in the agent home as
        // Claude Code does, under the session Binders gave it, and works until it's told to stop.
        let repository = folder.appendingPathComponent("fake-repo")
        try? manager.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        try? manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        let script = #"""
            #!/bin/sh
            # A stand-in for claude: keeps a task list and a session record under its agent home as Claude Code does, then works a while.
            here="$(cd "$(dirname "$0")/.." && pwd)"
            session=""; name=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --session-id) session="$2"; shift ;;
                --name) name="$2"; shift ;;
              esac
              shift
            done
            cat > /dev/null
            claude="$BINDERS_AGENT_HOME/.claude"
            mkdir -p "$claude/tasks/$session" "$claude/sessions"
            printf '{"pid":%s,"sessionId":"%s","kind":"print","entrypoint":"cli","name":"%s","nameSource":"user","status":"busy"}' "$$" "$session" "$name" > "$claude/sessions/$$.json"
            printf '%s' '{"id":"1","subject":"Read the card","description":"","activeForm":"Reading the card","status":"completed","blocks":[],"blockedBy":[]}' > "$claude/tasks/$session/1.json"
            printf '%s' '{"id":"2","subject":"Find the broken link","description":"","activeForm":"Finding the broken link","status":"in_progress","blocks":[],"blockedBy":["1"]}' > "$claude/tasks/$session/2.json"
            printf '%s' '{"id":"3","subject":"Run the tests","description":"","activeForm":"Running the tests","status":"pending","blocks":[],"blockedBy":["2"]}' > "$claude/tasks/$session/3.json"
            printf '3' > "$claude/tasks/$session/.highwatermark"
            printf '%s' "$session" > "$here/doing-session.txt"
            end=$(( $(date +%s) + 60 ))
            while [ "$(date +%s)" -lt "$end" ] && [ ! -f "$here/doing-stop-$session.txt" ]; do sleep 0.2; done
            rm -f "$claude/sessions/$$.json"
            exit 0
            """#
        try? script.write(to: fake, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        try? manager.removeItem(at: folder.appendingPathComponent("doing-session.txt"))
        Store.shared.insert(BinderRecord(name: "Launch", colorIndex: 2))
        let claude = AgentProfile(name: "Claude Code · fake", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "plan",
                                                                                               executable: fake.path)),
                                  preset: "claude-code", wakesPerHour: 30)
        check(registry.upsert(claude) == nil, "a Claude Code agent is saved: \(registry.problem(with: claude) ?? "")")
        let agent = BoardActor(name: claude.name, kind: .agent)
        let digests = WorkStreamsFeed.shared
        /// What Home's digest says the run is doing.
        func digested() -> [WorkStreams.Doing]? { digests.digest?.streams.first { $0.who == claude.name }?.doing }

        // Your own Claude Code session, in the same agent home: its record among the sessions running, and a task list of its
        // own. Nothing of it is read for a card.
        let yours = "0f1e2d3c-4b5a-4968-8776-655443322110"
        task(1, "Plan the release notes", "Planning the release notes", "in_progress", session: yours)
        let sessions = claudeFolder.appendingPathComponent("sessions", isDirectory: true)
        try? manager.createDirectory(at: sessions, withIntermediateDirectories: true)
        let yourRecord: [String: Any] = ["pid": 4243, "sessionId": yours, "kind": "interactive", "entrypoint": "cli", "name": "Release notes",
                                         "nameSource": "auto", "status": "busy"]
        try? JSONSerialization.data(withJSONObject: yourRecord).write(to: sessions.appendingPathComponent("4243.json"), options: .atomic)
        feed.show()
        digests.show()

        // Made ready for it, the card wakes the agent: Binders starts the run, whose receipt names its session, and the run
        // takes the card.
        let id = made(await call("create_task", ["title": "Fix the footer link", "binder": "Launch", "column": "ready", "for": claude.name], as: .you).text)
        if let target = board.card(id) { try? board.claim(target, by: agent) }
        for _ in 0..<100 where text("doing-session.txt").isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        let session = text("doing-session.txt")
        let receipt = board.timeline(id).last { $0.kind == .woke }
        check(UUID(uuidString: session) != nil && receipt.flatMap { AgentDoing.session(inReceipt: $0.text) } == session && dispatcher.isWorking(on: id),
              "Binders started the run, and its receipt names the session the run writes under: \(receipt?.text ?? "no receipt")")
        // The run's own record among the sessions running, as the stand-in wrote it.
        let runRecord = ((try? manager.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []).first { record($0)["sessionId"] as? String == session }

        // The card says what the run is doing: its task in progress, as it says it while doing it. (The first look, as the
        // run took the card, may have come before its task list did, and stands for 30 seconds; the test doesn't wait.)
        reader.forget()
        await feed.update()
        check(feed.lines[id] == "Finding the broken link", "the card shows the run's task in progress: \(feed.lines[id] ?? "nothing")")
        let reply = await call("work_streams", [:], as: .you)
        check(doing(reply.text)[claude.name] == [["card": "Fix the footer link", "line": "Finding the broken link"]] && doing(reply.text).count == 1,
              "work_streams gives it as the stream's doing: \(doing(reply.text))")

        // Over the link: this iPhone is told it. One from before this build saves work_streams whole, without showing the
        // line, and iPhone 2.0 lists nothing: both are told the rest without the run's words.
        let phones = await agentDoingPhones(controller)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let phone = phones.this.flatMap { try? JSONSerialization.data(withJSONObject: object($0)["working"] ?? []) }
            .flatMap { try? decoder.decode([WorkStreams.Working].self, from: $0) }
        check(phone?.first { $0.who == claude.name }?.doing == [WorkStreams.Doing(card: "Fix the footer link", line: "Finding the broken link")]
              && (phones.this.flatMap { object($0)["summary"] as? String } ?? "").contains("and says: Finding the broken link"),
              "this iPhone, which lists \(LinkFeatures.workStreamsDoing), is told it over the link, and reads it as it is: \(phones.this ?? "no answer")")
        func toldTheRest(_ reply: String?) -> Bool {
            guard let reply else { return false }
            return doing(reply).isEmpty && !reply.contains(#""doing""#) && !reply.contains("broken link") && reply.contains("Fix the footer link")
        }
        check(toldTheRest(phones.older) && toldTheRest(phones.first),
              "an iPhone from before, and iPhone 2.0, are told the rest without it: \(phones.older ?? "no answer") | \(phones.first ?? "no answer")")
        let kept = WorkStreams.keepable(phones.this ?? "")
        check(!kept.contains("broken link") && kept.contains("Fix the footer link"), "this iPhone keeps it without the run's words, to show at once the next time")
        // The whole reply is what an older build saved: read back as the iPhone reads its copy, it has none of the run's words.
        let readBack = (try? decoder.decode(AgentDoingPhoneDigest.self, from: Data(WorkStreams.keepable(reply.text).utf8)))?.working
        check(reply.text.contains("broken link") && readBack?.first { $0.who == claude.name }.map { $0.doing == nil && $0.cards == ["Fix the footer link"] } == true,
              "and a copy an older build saved whole is read back without them")
        let summary = object(reply.text)["summary"] as? String ?? "", headline = object(reply.text)["headline"] as? String ?? ""
        check(summary.contains("\(claude.name) is working on “Fix the footer link” and says: Finding the broken link."), "the summary says it as the agent's words: \(summary)")
        check(!headline.contains("broken link"), "the headline, which notifications show and the history keeps, doesn't: \(headline)")
        for _ in 0..<50 where digested()?.isEmpty != false { try? await Task.sleep(for: .milliseconds(100)) }
        check(digested() == [WorkStreams.Doing(card: "Fix the footer link", line: "Finding the broken link")], "and so does Home's digest")
        let overMCP = await agentDoingMCP()
        check(overMCP.map(doing)?[claude.name] == [["card": "Fix the footer link", "line": "Finding the broken link"]],
              "and a Binders --mcp of its own, as an agent on this Mac asks it, reads the same: \(overMCP.map(doing) ?? [:])")

        // Drawn: the card on the board, its page and Home's digest, saying what the run is doing.
        if let directory, let card = board.card(id) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            func draw(_ content: some View, size: NSSize, name: String) async {
                let view = content.environment(controller).environment(controller.knowledge).environment(HubNavigation())
                    .environment(AppSettings.shared).modelContainer(Store.shared.container)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.alphaValue = 0
                let hosting = NSHostingView(rootView: view)
                hosting.wantsLayer = true
                window.contentView = hosting
                window.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(1500))
                capture(hosting, name: name, directory: directory)
                window.close()
            }
            await draw(CardTile(card: card).frame(width: 240).padding(16).pageGround(), size: NSSize(width: 272, height: 150), name: "doing-card")
            await draw(CardDetailView(card: card), size: NSSize(width: CardLayout.defaultWidth, height: CardLayout.defaultHeight), name: "doing-card-page")
            await draw(WorkStreamsSection().frame(width: 420).padding(16).pageGround(), size: NSSize(width: 452, height: 300), name: "doing-digest")
            check(["doing-card", "doing-card-page", "doing-digest"].allSatisfy { manager.fileExists(atPath: directory.appendingPathComponent("\($0).png").path) },
                  "draws doing-card.png, doing-card-page.png and doing-digest.png")
        }

        // Claude Code moves on to its next task. The files are read again 30 seconds after the last time, and not before.
        reader.forget()
        let looked = Date()
        await feed.update()
        let reads = reader.reads
        task(2, "Find the broken link", "Finding the broken link", "completed", session: session)
        task(3, "Run the tests", "Running the tests", "in_progress", session: session)
        await feed.update()
        check(feed.lines[id] == "Finding the broken link" && reader.reads == reads, "asked again at once, the files aren't read again: \(reader.reads - reads) reads")
        let held = [board.card(id)].compactMap { $0 }
        let soon = AgentDoing.lines(for: held, on: Store.shared.context, now: looked.addingTimeInterval(20))
        check(soon[id] == "Finding the broken link" && reader.reads == reads, "nor 20 seconds later")
        let later = AgentDoing.lines(for: held, on: Store.shared.context, now: looked.addingTimeInterval(31))
        check(later[id] == "Running the tests" && reader.reads == reads + 1, "31 seconds later they are, once: \(later[id] ?? "nothing")")

        // With no task in progress there's nothing to say, though the run's record has a title: the records of the sessions
        // running aren't read.
        task(3, "Run the tests", "Running the tests", "completed", session: session)
        if let runRecord {
            let titled: [String: Any] = ["pid": 4242, "sessionId": session, "kind": "print", "entrypoint": "cli", "name": "Footer and header links",
                                         "nameSource": "auto", "status": "busy"]
            try? JSONSerialization.data(withJSONObject: titled).write(to: runRecord, options: .atomic)
        }
        reader.forget()
        await feed.update()
        let untitled = doing(await call("work_streams", [:], as: .you).text)
        check(runRecord != nil && feed.lines[id] == nil && untitled.isEmpty,
              "with no task in progress, nothing: no line, and no doing in work_streams, though the run's record has a title")

        // One plain line of the agent's words: no link, no control or direction characters, 120 characters at most.
        task(4, "Check the privacy page", "Checking the\n[privacy page](https://example.test/privacy)\u{0007} \u{202E}now", "in_progress", session: session)
        reader.forget()
        await feed.update()
        check(feed.lines[id] == "Checking the privacy page now", "the line is cleaned of links and control characters: \(feed.lines[id] ?? "nothing")")
        task(4, "Check the privacy page", String(repeating: "Checking every page that links to the privacy page ", count: 6), "in_progress", session: session)
        reader.forget()
        await feed.update()
        check(feed.lines[id]?.count == AgentDoing.limit && feed.lines[id]?.hasSuffix("…") == true, "and cut to \(AgentDoing.limit) characters")
        task(4, "Check the privacy page", "Checking the privacy page", "in_progress", session: session)
        reader.forget()
        await feed.update()

        // With no page showing them, the lines go: the card's, and the digest's copy. And a line that went meanwhile, with no
        // change to the board, isn't shown when a page is again.
        let privacy = [WorkStreams.Doing(card: "Fix the footer link", line: "Checking the privacy page")]
        for _ in 0..<50 where digested() != privacy { try? await Task.sleep(for: .milliseconds(100)) }
        check(feed.lines[id] == "Checking the privacy page" && digested() == privacy, "shown, the card and Home's digest say it")
        feed.hide()
        digests.hide()
        check(feed.lines.isEmpty && digests.digest?.saysWhatRunsAreDoing == false && digests.digest?.streams.contains { $0.who == claude.name } == true,
              "with no page showing it, the line goes, from the card and from the digest, which keeps the rest")
        task(4, "Check the privacy page", "Checking the privacy page", "completed", session: session)
        reader.forget()
        let built = digests.builds
        feed.show()
        digests.show()
        await feed.update()
        for _ in 0..<50 where digests.builds == built { try? await Task.sleep(for: .milliseconds(100)) }
        check(feed.lines[id] == nil && digests.builds > built && digested() == [],
              "shown again after the run finished that task, with the board unchanged, neither says it")
        task(4, "Check the privacy page", "Checking the privacy page", "in_progress", session: session)
        reader.forget()
        await feed.update()

        // Only for runs Binders started: a card the agent holds with no run, whatever its words say, has no line.
        let other = made(await call("create_task", ["title": "Tidy the scripts", "binder": "Launch", "column": "backlog"], as: .you).text)
        if let target = board.card(other) {
            try? board.claim(target, by: agent)
            board.report(target, progress: "To look in: claude --resume \(session) there.", by: agent)
        }
        await feed.update()
        check(board.card(other)?.column == .inProgress && feed.lines[other] == nil && feed.lines[id] == "Checking the privacy page",
              "a card the agent holds with no run Binders started says nothing, whatever its own words say")

        // Only while it's in progress: a question puts it in Blocked, waiting on you.
        _ = await call("ask_on_task", ["id": id.uuidString, "question": "The old footer or the new one?"], as: agent)
        await feed.update()
        let asking = doing(await call("work_streams", [:], as: .you).text)
        check(board.card(id)?.column == .blocked && feed.lines[id] == nil && asking.isEmpty,
              "only while the card is in progress: asked a question, it has no line")

        // Your answer calls for a newer run: the one still ending says nothing more, and the newer one, its own receipt.
        _ = await call("comment_task", ["id": id.uuidString, "text": "The new one."], as: .you)
        await feed.update()
        check(board.card(id)?.column == .inProgress && feed.lines[id] == nil, "answered, the run that asked says nothing more")
        try? await Task.sleep(for: .milliseconds(2500))
        setting("doing-stop-\(session).txt", "1")
        for _ in 0..<150 where text("doing-session.txt") == session { try? await Task.sleep(for: .milliseconds(100)) }
        let newer = text("doing-session.txt")
        let receipts = board.timeline(id).filter { $0.kind == .woke }.compactMap { AgentDoing.session(inReceipt: $0.text) }
        check(UUID(uuidString: newer) != nil && newer != session && receipts == [session, newer] && dispatcher.isWorking(on: id),
              "once it ended, Binders started the newer run, with a receipt of its own: \(receipts)")
        await feed.update()
        check(feed.lines[id] == "Finding the broken link", "whose task in progress the card shows: \(feed.lines[id] ?? "nothing")")

        // Taken over, it's yours, and its run stops: nothing of the run is shown as yours, nor when you give it back.
        if let target = board.card(id) { try? board.claim(target, by: .you) }
        await feed.update()
        check(feed.lines[id] == nil, "a card you took over shows nothing of the run")
        for _ in 0..<100 where dispatcher.isWorking(on: id) { try? await Task.sleep(for: .milliseconds(100)) }
        check(!dispatcher.isWorking(on: id), "and its run stopped")
        if let target = board.card(id) { try? board.release(target, by: .you) }
        if let target = board.card(id), target.column == .ready { try? board.claim(target, by: agent) }
        await feed.update()
        check(board.card(id)?.column == .inProgress && feed.lines[id] == nil, "nor once the agent has it again with no run Binders started")

        // Nothing of Claude Code's was read but the runs' own task lists: not the records of the sessions running, and
        // nothing of your own session.
        check(reader.folders == ["tasks/\(session)", "tasks/\(newer)"], "only the runs' own task lists were read: \(reader.folders.sorted())")

        // Nothing kept but the line on screen: no card, timeline or file in the data folder holds what the run said.
        Store.shared.save()
        let said = ["Finding the broken link", "Running the tests", "Footer and header links", "Checking the privacy page", "Checking every page",
                    "Planning the release notes"]
        let events = ((try? Store.shared.context.fetch(FetchDescriptor<TaskEvent>())) ?? []).map(\.text)
        let cards = ((try? Store.shared.context.fetch(FetchDescriptor<TaskCard>())) ?? []).flatMap { [$0.title, $0.details] }
        check(!(events + cards).contains { kept in said.contains { kept.contains($0) } }, "no card or timeline holds what the run said")
        var holders: [String] = []
        let files = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        let standIn = fake.resolvingSymlinksInPath().standardizedFileURL.path
        while let url = files?.nextObject() as? URL {
            // The stand-in's own script has its words, and the agent home is somewhere else.
            guard url.resolvingSymlinksInPath().standardizedFileURL.path != standIn,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, let data = try? Data(contentsOf: url) else { continue }
            if said.contains(where: { data.range(of: Data($0.utf8)) != nil }) { holders.append(url.lastPathComponent) }
        }
        check(holders.isEmpty, "nor does any file in the data folder, the store's among them: \(holders)")
        feed.hide()
        digests.hide()
        registry.remove(claude.id)

        print(failures == 0 ? "AGENT_DOING_OK" : "AGENT_DOING_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// work_streams as three iPhones ask it over the link, from a link server of this app on spare ports with its devices
    /// file in the throwaway folder: this build, one from before it (which lists what it reads, without
    /// `LinkFeatures.workStreamsDoing`), and iPhone 2.0, which lists nothing. Nil for one that got no answer.
    @MainActor
    private static func agentDoingPhones(_ controller: DictationController) async -> (this: String?, older: String?, first: String?) {
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: AppPaths.support.appendingPathComponent("doing-test-devices.json"))
        server.start()
        defer { server.stop() }
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        guard let port = server.boundPort, var pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort else { return (nil, nil, nil) }
        pairing.addresses = ["127.0.0.1:\(pairingPort)"]
        guard let paired = try? await LinkClient.pair(pairing, deviceName: "Test iPhone") else { return (nil, nil, nil) }
        func ask(listing features: [String]) async -> String? {
            let phone = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            defer { phone.close() }
            do {
                try await phone.connect()
                _ = try await phone.hello(device: paired.device, key: paired.key, name: "Test iPhone", features: features)
                return try await phone.callTool("work_streams", [:], timeout: 20)
            } catch {
                return nil
            }
        }
        let this = await ask(listing: LinkFeatures.thisPhone)
        let older = await ask(listing: LinkFeatures.thisPhone.filter { $0 != LinkFeatures.workStreamsDoing })
        let first = await ask(listing: [])
        return (this, older, first)
    }

    /// A `Binders --mcp` of its own on this folder and agent home, as an agent on this Mac would start it: its
    /// work_streams, or nil if it didn't answer.
    @MainActor
    private static func agentDoingMCP() async -> String? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--mcp", "-notesShowMarkdown", "NO"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let heard = AgentDoingChildOutput()
        output.fileHandleForReading.readabilityHandler = { handle in heard.append(handle.availableData) }
        // A child that has gone doesn't take the test with it.
        signal(SIGPIPE, SIG_IGN)
        do { try process.run() } catch { return nil }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        func send(_ id: Int, _ method: String, _ params: [String: Any]) -> Bool {
            let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
            return (try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))) != nil
        }
        func answer(_ id: Int) -> String? {
            for line in heard.lines() {
                guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], message["id"] as? Int == id,
                      let result = message["result"] as? [String: Any] else { continue }
                return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            }
            return nil
        }
        guard send(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                     "clientInfo": ["name": "claude-code", "title": "Claude Code", "version": "1"]]),
              send(2, "tools/call", ["name": "work_streams", "arguments": [String: Any]()]) else { return nil }
        for _ in 0..<300 {
            if let text = answer(2) {
                try? input.fileHandleForWriting.close()
                for _ in 0..<30 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                return text
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

/// The parts of work_streams the iPhone's What's happening reads (`WorkStreamsView.Digest`), for reading back a saved copy.
private struct AgentDoingPhoneDigest: Decodable {
    let headline: String
    let working: [WorkStreams.Working]
}

/// What the child process wrote to its standard output, gathered on whatever queue it arrives on.
private final class AgentDoingChildOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    func lines() -> [String] {
        lock.withLock { String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) }
    }
}
