import AppKit
import Foundation
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// The library that didn't open, in a throwaway folder (BINDERS_DATA_DIR): with this flag the store opens the empty
    /// stand-in, as when its file can't be read. Then every way something gets saved is tried, and each one refuses and
    /// says why, so nothing seems kept that would be gone at quit: your saves in the app, the inbox and MCP (here and in a
    /// `Binders --mcp` of its own), the phone link, captures and moments, dictation and Command Mode (pasted, but kept
    /// neither in History nor as a recording), and the tidying that would take what the library still uses. Ask on this
    /// Mac says it can't answer, and search leaves notes out, as whose words they hold is in the library. Given a folder, it
    /// also draws the hub there, with its banner.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-fallback [folder]
    @MainActor
    static func fallbackSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test opens its library as one that didn't open")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let store = Store.shared
        check(store.isFallback && !store.canSave, "the library counts as one that didn't open: an empty stand-in, and nothing can be saved")
        // Everything below would save, record or listen for real with a library that opened: stop before any of it.
        guard store.isFallback else {
            print("FALLBACK_FAILED: \(failures)")
            return 1
        }
        let refusals = Refusals()
        store.onRefused = { refusals.count += 1 }
        func count<T: PersistentModel>(_ type: T.Type) -> Int { (try? store.context.fetchCount(FetchDescriptor<T>())) ?? -1 }
        /// Nothing kept: the stand-in has only the General binder it opened with.
        func nothingKept() -> Bool {
            count(NoteItem.self) == 0 && count(CommitmentRecord.self) == 0 && count(TaskCard.self) == 0 && count(TaskEvent.self) == 0
                && count(MeetingRecord.self) == 0 && count(MeetingSegmentRecord.self) == 0 && count(TranscriptRecord.self) == 0
                && count(DictionaryWord.self) == 0 && count(SnippetItem.self) == 0 && count(WritingRecord.self) == 0
                && count(BinderRecord.self) == 1
        }
        let manager = FileManager.default
        let controller = DictationController()

        // Loud: the line the menu bar menu starts with (the hub's banner is drawn at the end).
        check(Store.unavailableMessage == "Binders couldn't open its library, so nothing new can be saved. Quit and reopen Binders."
              && StatusItemController.libraryLine(target: nil)?.title == Store.unavailableMessage,
              "the menu bar menu starts with: \(StatusItemController.libraryLine(target: nil)?.title ?? "nothing")")

        // 1. Your saves in the app: each says why instead (the app shows the line above), and keeps nothing.
        var before = refusals.count
        HubWindowController.shared.newNote(nil)
        HubWindowController.shared.newNoteWindow(nil)
        ScratchpadController.shared.show()
        URLCommands.handle(URL(string: "binders://todo?text=Call%20Sam%20tomorrow%20at%203")!, controller: controller)
        await controller.meetings.start()
        let imported = await controller.meetings.importRecording(AppPaths.support.appendingPathComponent("Standup.m4a"))
        controller.capture.start(requireAccessibility: false)
        check(refusals.count == before + 7 && imported == nil && !controller.meetings.isRecording && !controller.capture.isOn && nothingKept(),
              "a new note (⌘N, ⌥⌘N, the scratchpad), binders://todo, recording or importing a meeting and writing capture each say why and keep nothing: \(refusals.count - before) of 7")
        check(!store.addDictionaryWord("Ignite", aliases: ["ignight"], source: "manual") && nothingKept(),
              "a word learned isn't added to the dictionary, so it isn't announced as added")

        let segment = TranscriptSegment(channel: .microphone, start: 0, end: 4, text: "Let's book the Ignite booth by Friday.", speaker: TranscriptSegment.you)
        let conversation = ConversationPayload(started: Date().addingTimeInterval(-600), ended: Date().addingTimeInterval(-540), segments: [segment],
                                               device: "iPhone", engine: "parakeet-v2")
        let file = AppPaths.support.appendingPathComponent("Capture.\(BindersTransfer.fileExtension)")
        try? BindersTransfer(conversations: [conversation]).encoded().write(to: file)
        before = refusals.count
        let opened = BindersFiles.open(file, controller: controller)
        check(opened == Store.unavailableMessage && refusals.count == before + 1 && manager.fileExists(atPath: file.path) && nothingKept(),
              "a Binders file from the iPhone isn't opened: it stays where it is, to open once Binders can keep it")

        // 2. Captures and moments.
        check(controller.conversations.receive(conversation) == .refused && nothingKept(), "a capture is refused, so whoever sent it keeps it")
        let moment = await controller.moments.receive(MomentPayload(heard: Date(), text: "remind me to call Sam tomorrow at 3", device: "iPhone", wake: true))
        check(moment.state == "nothing" && moment.line.contains("library") && nothingKept(), "a moment is refused and keeps nothing: \(moment.line)")
        let heard = CapturedConversation(id: UUID(), started: Date().addingTimeInterval(-300), ended: Date().addingTimeInterval(-240), speech: 40,
                                         state: .recorded, spans: CaptureSpans())
        manager.createFile(atPath: CaptureFiles.audioURL(heard.id).path, contents: Data(count: 64))
        CaptureFiles.write(heard)
        controller.allDay.processWaiting()
        try? await Task.sleep(for: .milliseconds(600))
        check(CaptureFiles.all().first { $0.id == heard.id }?.state == .recorded && manager.fileExists(atPath: CaptureFiles.audioURL(heard.id).path)
              && nothingKept(), "a conversation this Mac heard waits, audio and all, for a library that opens")

        // Dictating and Command Mode: what you said still goes where you asked (pasted here into a stand-in, with a stand-in
        // for the speech model), and nothing is kept, neither in History nor as a recording, which the bar says. A to-do
        // said in Command Mode is refused with why, and what's happening on the boards says the library didn't open rather
        // than that nothing is.
        AppSettings.shared.aiFormatting = false
        AppSettings.shared.playSounds = false
        let panel = AnswerPanelController.shared
        panel.showsWindow = false
        var spoken: [String] = []
        AnswerSpeaker.shared.isOn = { true }
        AnswerSpeaker.shared.onSpeak = { spoken.append($0) }
        var pasted: [String] = []
        controller.pasteStandIn = { pasted.append($0) }
        func recordings() -> Set<String> { Set((try? manager.contentsOfDirectory(atPath: AppPaths.audio.path)) ?? []) }
        let recordedBefore = recordings()
        // A second of a low hum, loud enough to count as speech.
        let tone = (0..<Int(AudioRecorder.sampleRate * 1.2)).map { Float(sin(Double($0) * 0.05) * 0.2) }
        check(AppSettings.shared.saveAudio, "Keep audio for re-transcription is on, as it is until you turn it off, so a recording would be kept")
        controller.speech.standIn(StandInSpeech(text: "Send it by Thursday."), downloading: 0.4)
        await controller.heard(tone, mode: .dictation)
        let waiting = controller.flowBar.model.toastText
        controller.speech.standIn(StandInSpeech(text: "Send it by Thursday."))
        await controller.heard(tone, mode: .dictation)
        let dictated = controller.flowBar.model.toastText
        // A recording would be written off the main thread.
        try? await Task.sleep(for: .milliseconds(500))
        check(pasted.count == 1 && pasted.first?.contains("Thursday") == true && dictated == Store.notKeptMessage && recordings() == recordedBefore
              && nothingKept(), "a dictation is pasted, and neither it nor its recording is kept, which the bar says: \(pasted) “\(dictated)”")
        // With AI formatting on and no model to answer in this folder, it's pasted as said: the bar still says it isn't kept.
        AppSettings.shared.aiFormatting = true
        await controller.heard(tone, mode: .dictation)
        let formatted = controller.flowBar.model.toastText
        AppSettings.shared.aiFormatting = false
        check(pasted.count == 2 && [Store.notKeptUnformattedMessage, Store.notKeptMessage].contains(formatted) && nothingKept(),
              "with AI formatting on, a dictation pasted without it says too that it isn't kept: “\(formatted)”")
        pasted.removeLast()
        check(waiting.contains("The recording wasn't kept") && !waiting.contains("saved to History") && recordings() == recordedBefore && nothingKept(),
              "with the speech model still downloading, the recording isn't kept for History, and the bar doesn't say it is: “\(waiting)”")
        before = refusals.count
        controller.speech.standIn(StandInSpeech(text: "Add to-do call Sam tomorrow at 3"))
        await controller.heard(tone, mode: .command)
        await controller.command(heard: "What's happening with my work streams?")
        check(refusals.count == before + 1 && panel.run?.text == Store.unanswerableMessage && spoken == [Store.unanswerableMessage] && nothingKept(),
              "in Command Mode a to-do is refused with why, and what's happening on the boards says the library didn't open, shown and said; History keeps neither: \(panel.run?.text ?? "nothing shown")")
        await controller.pasteLast()
        check(controller.flowBar.model.toastText == Store.nothingToPasteMessage && pasted.count == 1, "Paste Last Transcript says why there's nothing to paste")
        controller.pasteStandIn = nil
        AnswerSpeaker.shared.onSpeak = nil
        AnswerSpeaker.shared.isOn = { AppSettings.shared.readAnswersAloud }
        controller.flowBar.hide()

        // 3. The inbox and MCP: every write is refused with why, before anything else is looked at.
        let some = UUID().uuidString
        let agent = ["actor": "Echo", "actor_kind": BoardActor.Kind.agent.rawValue]
        let writes: [(String, [String: String])] = [
            ("add_note", ["text": "# Ignite booth\n\nBook it by Friday."]),
            ("append_to_note", ["id": some, "text": "And the banner."]),
            ("update_note", ["id": some, "text": "# Ignite booth"]),
            ("correct_knowledge", ["wrong": "the booth is on level two", "right": "the booth is on level three"]),
            ("create_binder", ["name": "Ignite"]),
            ("add_meeting", ["title": "Booth planning", "notes": "We picked the corner spot."]),
            ("set_todo_status", ["id": some, "status": "done"]),
            ("add_todo", ["text": "Call Sam tomorrow at 3"]),
            ("create_task", ["title": "Print the banner"].merging(agent) { a, _ in a }),
            ("claim_task", ["id": some].merging(agent) { a, _ in a }),
            ("update_task", ["id": some, "progress": "Halfway"].merging(agent) { a, _ in a }),
            ("ask_on_task", ["id": some, "text": "Which size?"].merging(agent) { a, _ in a }),
            ("comment_task", ["id": some, "text": "Dark, please."]),
            ("release_task", ["id": some, "text": "Not now"].merging(agent) { a, _ in a }),
            ("complete_task", ["id": some, "text": "Done"].merging(agent) { a, _ in a }),
        ]
        var answered: [String] = []
        for (action, fields) in writes {
            let result = await InboxCommands.perform(InboxRequest(action: action, fields: fields), controller: controller)
            if result.ok || result.error != Store.refusedMessage { answered.append("\(action): \(result.ok ? result.message : result.error ?? "")") }
        }
        check(answered.isEmpty && nothingKept(), "each of the \(writes.count) writes the inbox, MCP and the phone's tools make is refused: \(answered.isEmpty ? Store.refusedMessage : answered.joined(separator: "; "))")

        let name = UUID().uuidString
        try? manager.createDirectory(at: InboxCommands.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(InboxRequest(action: "add_note", fields: ["text": "# From an agent"]))
            .write(to: InboxCommands.directory.appendingPathComponent(Inbox.requestFile(name)))
        await InboxCommands.apply(named: name, controller: controller)
        let result = (try? Data(contentsOf: InboxCommands.directory.appendingPathComponent(Inbox.resultFile(name))))
            .flatMap { try? JSONDecoder().decode(InboxResult.self, from: $0) }
        check(result?.ok == false && result?.error == Store.refusedMessage && nothingKept(), "a request file, as Binders --mcp leaves one, gets the refusal back")

        func tool(_ name: String, _ arguments: [String: Any], as actor: BoardActor) async -> String {
            do { return "answered: " + (try await MCPServer.call(name, arguments, knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller), actor: actor)) }
            catch { return (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription }
        }
        let echo = BoardActor(name: "Echo", kind: .agent)
        var said = [await tool("add_note", ["text": "# Kept?"], as: echo)]
        said.append(await tool("add_to_knowledge", ["title": "Booth", "text": "Level three"], as: echo))
        said.append(await tool("add_todo", ["text": "Call Sam"], as: .you))
        said.append(await tool("create_task", ["title": "Print the banner"], as: .you))
        check(said.allSatisfy { $0 == Store.refusedMessage } && nothingKept(), "MCP's write tools answer with the refusal as their error: \(Set(said).sorted())")
        said = [await tool("list_notes", [:], as: echo)]
        said.append(await tool("search_knowledge", ["query": "booth"], as: echo))
        said.append(await tool("list_todos", [:], as: .you))
        said.append(await tool("get_task", ["id": some], as: .you))
        check(said.allSatisfy { $0 == Store.unreadableMessage }, "and its reads say the library didn't open, rather than show an empty one: \(Set(said).sorted())")

        let child = await fallbackMCP(controller: controller)
        check(child?.read == Store.unreadableMessage && child?.write == Store.refusedMessage && nothingKept(),
              "a Binders --mcp whose library didn't open says so for a read, and passes on the app's refusal for a write: \(child.map { "\($0.read) / \($0.write)" } ?? "it didn't answer")")

        // 4. The phone link: turned away at hello, so the phone stays offline and keeps what it has. Past hello (a backstop
        // the self-test lets a phone through), each thing it sends is refused the way that phone keeps it.
        let devicesURL = manager.temporaryDirectory.appendingPathComponent("fallback-devices-\(UUID().uuidString).json")
        defer { try? manager.removeItem(at: devicesURL) }
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: devicesURL)
        server.start()
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        if let port = server.boundPort, var pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort {
            pairing.addresses = ["127.0.0.1:\(pairingPort)"]
            do {
                let paired = try await LinkClient.pair(pairing, deviceName: "Test iPhone")
                func phone() -> LinkClient { LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key) }
                let turnedAway = phone()
                try await turnedAway.connect()
                var why = ""
                do { try await turnedAway.hello(device: paired.device, key: paired.key, name: "Test iPhone", features: LinkFeatures.thisPhone) }
                catch LinkClient.Failure.rejected(let message) { why = message }
                try? await Task.sleep(for: .milliseconds(600))
                let after = try? await turnedAway.request("ping", timeout: 3)
                check(why == LinkServer.unavailableForPhone && after == nil && !server.connectedDevices.contains(paired.device),
                      "a phone is turned away at hello with why, and the link closes: \(why)")
                turnedAway.close()

                server.admitsWhileUnavailable = true
                /// What one request gets on a link of its own, past hello: `tool` sends it as tools/call.
                func send(_ method: String, _ params: [String: Any] = [:], tool: Bool = false) async -> String {
                    let link = phone()
                    defer { link.close() }
                    var connected = false
                    do {
                        try await link.connect()
                        try await link.hello(device: paired.device, key: paired.key, name: "Test iPhone", features: LinkFeatures.thisPhone)
                        connected = true
                        if tool {
                            _ = try await link.callTool(method, params, timeout: 10)
                        } else {
                            _ = try await link.request(method, params, timeout: 10)
                        }
                        return "answered"
                    } catch {
                        // Only what the request itself got: a link that never opened says so.
                        guard connected else { return "not connected: \(error.localizedDescription)" }
                        switch error as? LinkClient.Failure {
                        case .closed?: return "closed"
                        case .rejected(let message)?: return message
                        default: return error.localizedDescription
                        }
                    }
                }
                let dictation: [String: Any] = ["id": UUID().uuidString, "text": "Send it by Thursday.", "raw": "send it by thursday",
                                                "app": "iPhone keyboard", "date": "2026-10-17T09:30:00Z"]
                let kept = [await send("binders/dictation", dictation),
                            await send(ConversationPayload.method, (try? conversation.jsonObject()) ?? [:]),
                            await send(MomentPayload.method, (try? MomentPayload(heard: Date(), text: "Binders, remind me to call Sam", device: "iPhone", wake: true).jsonObject()) ?? [:]),
                            await send("get_task", ["id": some], tool: true),
                            await send("comment_task", ["id": some, "text": "Dark, please."], tool: true)]
                check(kept.allSatisfy { $0 == "closed" } && nothingKept(),
                      "a dictation, a capture, a moment and an answer (get_task, comment_task) close the link unanswered, which every iPhone build keeps for later: \(kept)")
                let saves = [await send("add_note", ["text": "# From the iPhone"], tool: true), await send("add_todo", ["text": "Call Sam"], tool: true)]
                check(saves.allSatisfy { $0 == Store.refusedMessage } && nothingKept(), "a note or a to-do gets the refusal, which the phone keeps them on: \(saves)")
                let taps = [await send(CaptureOutcome.actMethod, ["id": UUID().uuidString, "action": "add"]),
                            await send(ConversationSuggestion.actMethod, ["id": some, "action": "accept"])]
                check(taps.allSatisfy { $0 == Store.refusedMessage } && nothingKept(), "a tap (Add on a moment, a suggestion) hears why, to show it: \(taps)")
                let read = await send("list_notes", [:], tool: true)
                check(read == Store.unreadableMessage, "and a read says the library didn't open: \(read)")
            } catch {
                check(false, "the link failed: \(error.localizedDescription)")
            }
        } else {
            check(false, "the link didn't start")
        }
        server.stop()

        // 5. Nothing the library still has is tidied away: its index, its recordings, attachments and notes' history.
        let indexed = KnowledgeDocument(id: "note:\(some)", kind: .note, sourceID: some, title: "Ignite booth", createdAt: Date(), contentHash: "1")
        await controller.knowledge.store.upsert(indexed, chunks: [KnowledgeChunk(text: "The Ignite booth is on level three.")])
        before = refusals.count
        await controller.knowledge.indexNow()
        await controller.knowledge.rebuild()
        let documents = await controller.knowledge.store.stats().documents
        check(documents == 1 && refusals.count == before + 1, "the index keeps what it has (a pass over the stand-in would take it all out), and Rebuild says why instead")

        // Ask and search on this Mac: the index still has that note, which an agent may have written, and a meeting. Which
        // notes hold an agent's words, and your corrections, are in the library: Ask says it can't answer, as MCP's reads
        // do, and search leaves notes out rather than show an agent's words unlabelled, as yours. The meeting is found.
        let knowledge = controller.knowledge
        let meetingID = UUID().uuidString
        await knowledge.store.upsert(KnowledgeDocument(id: "meeting:\(meetingID)", kind: .meeting, sourceID: meetingID, title: "Booth planning",
                                                       createdAt: Date(), contentHash: "1"),
                                     chunks: [KnowledgeChunk(text: "We picked the corner spot for the Ignite booth.")])
        // Stand-ins, so no model is asked: no search by meaning, and an answer that would draw on whatever was found.
        knowledge.queryEmbedder = { _ in throw CancellationError() }
        knowledge.answerModel = StandInModel(reply: "The Ignite booth is on level three [1].")
        let run = AskRun(question: "Where is the Ignite booth?")
        let asked = await run.run(with: knowledge)
        let brief = await knowledge.ask("Where is the Ignite booth?", brief: true)
        check(asked.text == Store.unanswerableMessage && asked.sources.isEmpty && asked.leftOut.isEmpty && run.text == asked.text && run.sources.isEmpty
              && brief.text.isEmpty && brief.sources.isEmpty,
              "Ask (the Knowledge page, Command Mode) draws on nothing the index has and says why: \(asked.text)")
        var first: [KnowledgeHit] = []
        let found = await knowledge.search("Ignite booth", onKeywordHits: { first = $0 })
        let mention = KnowledgeHit(chunkID: -1, documentID: "note:\(some)", kind: .note, sourceID: some, title: "Ignite booth", createdAt: Date(),
                                   text: "The Ignite booth is on level three.", snippet: "", startTime: nil, speaker: nil, author: nil, binderID: nil, score: 1)
        check(found.map(\.sourceID) == [meetingID] && first.map(\.sourceID) == [meetingID] && knowledge.labelled([mention]).isEmpty,
              "search (what it shows first too) and a person's or topic's mentions leave the note out, and still find the meeting: \(found.map(\.title))")
        knowledge.answerModel = nil
        knowledge.queryEmbedder = nil

        let recording = AppPaths.audio.appendingPathComponent("\(UUID().uuidString).wav")
        manager.createFile(atPath: recording.path, contents: Data(count: 64))
        before = refusals.count
        store.deleteAllHistory()
        check(manager.fileExists(atPath: recording.path) && refusals.count == before + 1,
              "Delete All in History leaves the recordings of dictations the stand-in doesn't have, and says why")

        try? manager.createDirectory(at: Attachments.folder, withIntermediateDirectories: true)
        let attachment = Attachments.folder.appendingPathComponent("booth-plan.png")
        manager.createFile(atPath: attachment.path, contents: Data(count: 64))
        try? manager.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: attachment.path)
        let version = NoteHistory.folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("1760000000000.md")
        try? manager.createDirectory(at: version.deletingLastPathComponent(), withIntermediateDirectories: true)
        manager.createFile(atPath: version.path, contents: Data("# Ignite booth".utf8))
        LaunchHousekeeping.run()
        check(manager.fileExists(atPath: attachment.path) && manager.fileExists(atPath: version.path),
              "launch's tidying leaves attachments and note history the stand-in knows nothing about")

        check(nothingKept(), "and nothing was kept, so nothing seemed saved: the stand-in still has only its General binder")

        if let directory {
            let navigation = HubNavigation()
            navigation.selection = .home
            let view = HubView().environment(navigation).environment(controller).environment(controller.meetings)
                .environment(controller.knowledge).environment(controller.team).environment(controller.capture)
                .environment(controller.commitments).environment(AppSettings.shared).modelContainer(store.container)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let hosting = NSHostingView(rootView: view)
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(2000))
            capture(hosting, name: "fallback-home", directory: directory)
            window.close()
            print("DRAWN: \(directory.appendingPathComponent("fallback-home.png").path)")
        }
        print(failures == 0 ? "FALLBACK_OK" : "FALLBACK_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Counts the saves refused with the app's line, as the app shows it.
    private final class Refusals {
        var count = 0
    }

    /// A `Binders --mcp` of its own on this folder, its library opened as one that didn't: what a host hears for a read,
    /// and for a write, which comes here through the inbox as it would reach the app. Nil when it didn't answer.
    @MainActor
    private static func fallbackMCP(controller: DictationController) async -> (read: String, write: String)? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--mcp", "--selftest-fallback", "-notesShowMarkdown", "NO"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let heard = ChildOutput()
        output.fileHandleForReading.readabilityHandler = { handle in heard.append(handle.availableData) }
        // A child that has gone doesn't take the test with it.
        signal(SIGPIPE, SIG_IGN)
        do { try process.run() } catch { return nil }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "selftest", "version": "1"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "list_notes", "arguments": [String: Any]()]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "add_note", "arguments": ["text": "# From an agent"]]],
        ]
        do {
            for message in messages {
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
            }
        } catch {
            return nil
        }
        /// A tool's text, once its answer is in.
        func answer(_ id: Int) -> String? {
            for line in heard.lines() {
                guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], message["id"] as? Int == id,
                      let result = message["result"] as? [String: Any] else { continue }
                let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                return result["isError"] as? Bool == true ? text : "answered: \(text)"
            }
            return nil
        }
        // Its write waits in the inbox for the app, which is this test.
        for _ in 0..<200 where answer(2) == nil || answer(3) == nil {
            let waiting = (try? FileManager.default.contentsOfDirectory(atPath: InboxCommands.directory.path)) ?? []
            for file in waiting where file.hasSuffix(".request.json") {
                await InboxCommands.apply(named: String(file.dropLast(".request.json".count)), controller: controller)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? input.fileHandleForWriting.close()
        for _ in 0..<30 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        guard let read = answer(2), let write = answer(3) else { return nil }
        return (read, write)
    }
}

/// Stands in for the speech model: hears `text` in any recording, with nothing to download or load.
private final class StandInSpeech: SpeechEngine {
    let modelID = SpeechModelID.parakeetV2
    let text: String

    init(text: String) {
        self.text = text
    }

    func isDownloaded() -> Bool { true }
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(_ samples: [Float], language: String?, vocabulary: [VocabularyTerm], boost: Bool) async throws -> String { text }
}

/// What a child process wrote to its standard output, gathered on whatever queue it arrives on.
private final class ChildOutput: @unchecked Sendable {
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
