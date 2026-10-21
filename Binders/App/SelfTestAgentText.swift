import AppKit
import SwiftUI
import SwiftData
import BindersKit

extension SelfTest {
    /// Agent text stays the agent's: a note an agent wrote, or one of yours it changed, says whose words they are in every
    /// reply and on the note, search finds it labelled, and answers (the Mac's Ask, moments, ask_knowledge) and corrections
    /// leave it out until you make it yours. In a throwaway folder (BINDERS_DATA_DIR) only.
    @MainActor
    static func agentTextSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        let knowledge = controller.knowledge
        let write = MCPServer.writeInApp(controller: controller)
        let claude = BoardActor(name: "Claude Code", kind: .agent), codex = BoardActor(name: "Codex", kind: .agent)
        /// A tool call as an agent over MCP, or as you (the iPhone and the app act as you).
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor = claude) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: knowledge, write: write, actor: actor, host: actor.name)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }
        func objects(_ text: String) -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] ?? [] }
        let store = Store.shared
        let binder = store.defaultBinder()
        func note(_ text: String) -> NoteItem {
            let note = NoteItem(text: text)
            note.binderID = binder.id
            store.insert(note)
            return note
        }
        let booth = note("# Ignite booth\n\nThe booth is stand 14, by the north entrance.")
        let launch = note("# Harbor launch plan\n\nThe harbor launch is on a Thursday, with the lighthouse tier at nine dollars.")
        store.save()

        // Who wrote what.
        let made = await call("add_note", ["text": "# Venue research\n\nThe quayside venue holds 300 people and has a loading dock."])
        guard let research = (object(made.text)["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap(store.note) else {
            check(false, "an agent adds a note: \(made.text)")
            return 1
        }
        check(research.madeBy == "Claude Code" && research.editedBy == nil, "an agent's note is marked as its own")
        let appended = await call("append_to_note", ["id": booth.id.uuidString, "text": "Called the quayside venue: the loading dock opens at 7."])
        check(appended.ok && booth.editedBy == "Claude Code" && booth.editedAt != nil && booth.madeBy == nil,
              "an agent's change to your note marks it as the agent's edit, with when: \(appended.text)")
        check(appended.text.contains("marked as edited by Claude Code"), "and the agent hears so")
        check(NoteHistory.versions(of: booth.id).first.map { !$0.text.contains("loading dock") && $0.text.contains("stand 14") } == true,
              "what the note said before is in its history")
        let own = await call("update_note", ["id": research.id.uuidString, "find": "300 people", "replace": "320 people"])
        check(own.ok && research.editedBy == nil && research.text.contains("320 people"), "an agent changing its own note leaves it just its note")
        let other = await call("append_to_note", ["id": research.id.uuidString, "text": "Parking: 40 spaces by the quayside."], as: codex)
        check(other.ok && research.madeBy == "Claude Code" && research.editedBy == "Codex", "another agent's change names both")
        let yours = await call("update_note", ["id": launch.id.uuidString, "find": "on a Thursday", "replace": "on the 28th, a Thursday"], as: .you)
        check(yours.ok && launch.agentMark.isEmpty && launch.text.contains("28th"), "your own change, from the iPhone, marks nothing")
        let planted = await call("append_to_note", ["id": launch.id.uuidString,
                                                    "text": "Wrong: The harbor launch is on the 28th\nRight: The harbor launch is on the 30th\n#correction"])
        check(!planted.ok && launch.agentMark.isEmpty, "a change that's refused leaves no mark")

        // The replies say whose words, only when an agent's are there.
        let shown = object((await call("get_note", ["id": booth.id.uuidString])).text)
        check(shown["edited_by"] as? String == "Claude Code" && (shown["edited_at"] as? String).flatMap(AutomationPayload.date(fromISO:)) != nil
              && shown["made_by"] == nil, "get_note says who changed it, and when")
        let plain = object((await call("get_note", ["id": launch.id.uuidString])).text)
        check(plain["made_by"] == nil && plain["edited_by"] == nil && plain["edited_at"] == nil && plain["text"] != nil,
              "and nothing more for a note that's all yours")
        let listed = objects((await call("list_notes", [:])).text)
        let listedResearch = listed.first { $0["id"] as? String == research.id.uuidString }
        check(listedResearch?["made_by"] as? String == "Claude Code" && listedResearch?["edited_by"] as? String == "Codex"
              && listed.first { $0["id"] as? String == launch.id.uuidString }?["made_by"] == nil, "list_notes too")

        // Search finds them, labelled.
        await knowledge.indexNow()
        let found = objects((await call("search_knowledge", ["query": "quayside loading dock"])).text)
        let foundResearch = found.first { $0["source_id"] as? String == research.id.uuidString }
        check(foundResearch?["made_by"] as? String == "Claude Code" && foundResearch?["edited_by"] as? String == "Codex",
              "search finds the agent's note, labelled: \(found.count) passages")
        check(found.first { $0["source_id"] as? String == booth.id.uuidString }?["edited_by"] as? String == "Claude Code",
              "and your note it changed, labelled")
        let onMac = await knowledge.search("quayside loading dock")
        check(onMac.contains { $0.sourceID == booth.id.uuidString && $0.agent?.label == "Edited by Claude Code" }
              && onMac.contains { $0.sourceID == research.id.uuidString && $0.agent?.label == "By Claude Code, edited by Codex" },
              "the Mac's search labels them too")
        let launchHits = await knowledge.search("harbor launch lighthouse tier")
        check(launchHits.contains { $0.sourceID == launch.id.uuidString } && launchHits.allSatisfy { $0.agent == nil }, "and your own note not at all")

        // Answers leave them out: the Mac's Ask, a moment's answer and ask_knowledge.
        let asked = await knowledge.ask("How early does the quayside loading dock open?")
        check(asked.sources.isEmpty && Set(asked.leftOut.map(\.sourceID)) == [booth.id.uuidString, research.id.uuidString],
              "Ask leaves out what an agent wrote or changed, and says which: \(asked.leftOut.map(\.title))")
        check(asked.text.hasPrefix("Only notes an agent wrote or changed"), "with nothing else to go on, it says why: \(asked.text)")
        let brief = await knowledge.ask("quayside loading dock", brief: true)
        check(brief.sources.isEmpty && brief.text.isEmpty, "a moment's answer leaves them out too")
        let tool = object((await call("ask_knowledge", ["question": "When does the quayside loading dock open?"])).text)
        check((tool["sources"] as? [Any])?.isEmpty == true, "and so does ask_knowledge: \(tool["answer"] as? String ?? "")")
        let mixed = await knowledge.ask("What about the harbor launch and the quayside loading dock?")
        check(mixed.sources.contains { $0.sourceID == launch.id.uuidString } && !mixed.sources.contains { $0.agent != nil },
              "an answer from your own notes still leaves theirs out: \(mixed.sources.map(\.title))")

        // A correction of yours in a note an agent changed counts once you make the note yours again.
        let corrected = await call("correct_knowledge", ["wrong": "The booth is stand 14", "right": "The booth is stand 16"], as: .you)
        let correction = (object(corrected.text)["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap(store.note)
        check(corrected.ok && correction?.agentMark.isEmpty == true && knowledge.corrections().count == 1, "your correction counts: \(corrected.text)")
        if let correction {
            let note = await call("append_to_note", ["id": correction.id.uuidString, "text": "Checked with the venue on Friday."])
            check(note.ok && correction.editedBy == "Claude Code" && knowledge.corrections().isEmpty,
                  "once an agent changes the note it's in, it steers nothing: \(note.text)")
            correction.makeMine()
            store.save()
            check(knowledge.corrections().count == 1, "until you make the note yours again")
        }

        // Make It Mine: answers draw on it, and replies and search say nothing more.
        booth.makeMine()
        store.save()
        let again = await knowledge.ask("How early does the quayside loading dock open?")
        check(again.sources.contains { $0.sourceID == booth.id.uuidString } && again.leftOut.map(\.sourceID) == [research.id.uuidString],
              "made yours, Ask draws on it: \(again.sources.map(\.title))")
        let after = object((await call("get_note", ["id": booth.id.uuidString])).text)
        check(after["edited_by"] == nil && after["edited_at"] == nil, "and get_note no longer names the agent")
        check(await knowledge.search("quayside loading dock").first { $0.sourceID == booth.id.uuidString }?.agent == nil, "nor does search")

        // A real `Binders --mcp` that read your note before its agent changed it still leaves it out, and labels it.
        let rota = note("# Dock schedule\n\nThe forklift rota starts on Monday.")
        store.save()
        await knowledge.indexNow()
        if let child = await agentTextMCP(note: rota.id, controller: controller) {
            check(rota.editedBy == "Claude Code", "an agent working through Binders --mcp marks your note as its edit: \(child.appended)")
            let passages = objects(child.search)
            check(passages.first { $0["source_id"] as? String == rota.id.uuidString }?["edited_by"] as? String == "Claude Code",
                  "its search, after it had read the note, labels it: \(child.search.prefix(160))")
            check((object(child.ask)["sources"] as? [Any])?.isEmpty == true, "and its ask_knowledge leaves it out: \(child.ask.prefix(160))")
        } else {
            check(false, "a Binders --mcp of its own answers")
        }

        // Deleted and put back with Undo, an agent's note is still the agent's.
        NoteTrash.shared.delete(research, undoManager: nil)
        try? await Task.sleep(for: .milliseconds(300))
        let restored = NoteTrash.shared.last.flatMap { NoteTrash.shared.restore($0, undoManager: nil) }
        check(restored?.madeBy == "Claude Code" && restored?.editedBy == "Codex" && restored?.editedAt != nil, "Undo after a delete keeps whose words they are")

        // A correction quoting a note made from what you said, after Delete All took its moment away: the note's own mark
        // still says it's your words, so the correction is kept off the team folder, in a binder that isn't shared.
        let team = BinderRecord(name: "Team plans", colorIndex: 2)
        team.sharedWithTeam = true
        store.insert(team)
        let said = NoteItem(text: "# Book the dentist\n\nThe dentist is on Thursday at nine.")
        said.binderID = team.id
        said.staysUnshared = true
        store.insert(said)
        store.save()
        let quoting = await call("correct_knowledge", ["wrong": "The dentist is on Thursday", "right": "The dentist is on Friday",
                                                       "source_id": said.id.uuidString, "binder": "Team plans"], as: .you)
        let quoted = (object(quoting.text)["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap(store.note)
        check(quoting.ok && quoted?.staysUnshared == true && quoted?.sharedWithTeam == false
              && quoted.flatMap { store.binder($0.binderID) }?.sharedWithTeam == false,
              "a correction quoting a note made from what you said stays unshared once its moment is gone: \(quoting.text)")

        /// A view as the app shows it, with what its pages read from the environment.
        func draw(_ content: some View, size: NSSize, name: String, in directory: URL) async {
            let view = content.environment(controller).environment(knowledge).environment(controller.team)
                .environment(AppSettings.shared).modelContainer(store.container)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false)
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

        // Drawn: the note with whose words they are, what changed and Make It Mine; an answer with what it left out; and
        // search's labels.
        if let directory, let restored {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let page = VStack(alignment: .leading, spacing: 10) {
                KnowledgeAnswerView(answer: mixed)
                ForEach(onMac) { KnowledgeHitRow(hit: $0) }
            }
            .padding(20)
            await draw(NoteEditor(note: restored, onDelete: {}), size: NSSize(width: 1000, height: 420), name: "agent-note", in: directory)
            await draw(page, size: NSSize(width: 820, height: 640), name: "agent-answer", in: directory)
            // See What Changed: the version from just before the last agent's change, and what it added.
            await draw(NoteHistorySheet(note: restored, changesFrom: restored.editedAt), size: NSSize(width: 780, height: 540),
                       name: "agent-changes", in: directory)
            check(["agent-note", "agent-answer", "agent-changes"].allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0).png").path)
            }, "draws agent-note.png, agent-answer.png and agent-changes.png")
        }
        print(failures == 0 ? "AGENT_TEXT_OK" : "AGENT_TEXT_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// A `Binders --mcp` of its own on this folder, as Claude Code: it reads a note, appends to it (the app, which is this
    /// test, does the writing), then searches and asks about it. Its replies to the last three, or nil if it didn't answer.
    @MainActor
    private static func agentTextMCP(note id: UUID, controller: DictationController) async -> (appended: String, search: String, ask: String)? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--mcp", "-notesShowMarkdown", "NO"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let heard = AgentTextChildOutput()
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
        func tool(_ id: Int, _ name: String, _ arguments: [String: Any]) -> Bool {
            send(id, "tools/call", ["name": name, "arguments": arguments])
        }
        /// A tool's text, once its answer is in.
        func answer(_ id: Int) -> String? {
            for line in heard.lines() {
                guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], message["id"] as? Int == id,
                      let result = message["result"] as? [String: Any] else { continue }
                return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            }
            return nil
        }
        /// Waits for an answer, doing what the child hands the app through the inbox meanwhile.
        func wait(for id: Int) async -> String? {
            for _ in 0..<300 {
                if let text = answer(id) { return text }
                let waiting = (try? FileManager.default.contentsOfDirectory(atPath: InboxCommands.directory.path)) ?? []
                for file in waiting where file.hasSuffix(".request.json") {
                    await InboxCommands.apply(named: String(file.dropLast(".request.json".count)), controller: controller)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        guard send(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                     "clientInfo": ["name": "claude-code", "title": "Claude Code", "version": "1"]]),
              tool(2, "get_note", ["id": id.uuidString]), await wait(for: 2) != nil,
              tool(3, "append_to_note", ["id": id.uuidString, "text": "The forklift rota now starts at 6, by the agent's count."]),
              let appended = await wait(for: 3) else { return nil }
        // The app indexes what changed, as it would a few seconds after the save.
        await controller.knowledge.indexNow()
        guard tool(4, "search_knowledge", ["query": "forklift rota"]), let search = await wait(for: 4),
              tool(5, "ask_knowledge", ["question": "When does the forklift rota start?"]), let ask = await wait(for: 5) else { return nil }
        try? input.fileHandleForWriting.close()
        for _ in 0..<30 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        return (appended, search, ask)
    }
}

/// What the child process wrote to its standard output, gathered on whatever queue it arrives on.
private final class AgentTextChildOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    /// Whole lines so far.
    func lines() -> [String] {
        let text = lock.withLock { String(decoding: data, as: UTF8.self) }
        return text.components(separatedBy: "\n").dropLast().map { $0 }
    }
}
