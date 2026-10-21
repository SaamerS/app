import AppKit
import CryptoKit
import Network
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// Ask that shows its hits at once and streams the answer, in a throwaway store (BINDERS_DATA_DIR), with stand-ins for
    /// the models so nothing reaches a real one:
    /// - each model client streams (Ollama's lines, an OpenAI-compatible server's events, through the model lane too), and
    ///   one that can't is read as one reply;
    /// - Ask says how it's going: the passages with the words before the search by meaning has its answer, then the
    ///   passages the answer draws on, then the answer in pieces; reasoning stays hidden, from a model whose replies start
    ///   inside it too once it's noted; stopping it stops the model, and so does Ask's time running out, search included;
    /// - the phone that asked hears it in binders/ask-progress, at most 4 times a second, before the reply, and no other
    ///   phone does; iPhone 2.0 hears nothing new;
    /// - Command Mode's panel shows it as it comes, closing it stops it, and the spoken status question is read aloud.
    /// The panel and the Knowledge page are drawn to `directory` as the answer comes.
    @MainActor
    static func askSelfTest(directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes, cards and dictations")
            return 1
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let checks = AskChecks()
        await checkModelClients(checks)

        // Three notes: one with the words of the question, one only about the same thing, one about nothing of it. The
        // stand-in embedding puts each on an axis of its own, and the question between the first two.
        let controller = DictationController()
        let knowledge = controller.knowledge
        knowledge.modelWork = false
        for (title, body) in [("Launch date", "We moved the launch to Thursday 14 November, after the pricing review."),
                              ("Shipping plan", "The release goes out the week after the beta closes, once support is staffed."),
                              ("Groceries", "Oat milk, coffee beans and lemons.")] {
            Store.shared.insert(NoteItem(text: "# \(title)\n\n\(body)"))
        }
        await knowledge.indexNow()
        let axes: [String: [Float]] = ["Launch date": [1, 0, 0], "Shipping plan": [0, 1, 0], "Groceries": [0, 0, 1]]
        let chunks = await knowledge.store.chunksNeedingEmbedding(limit: 50)
        await knowledge.store.setEmbeddings(chunks.compactMap { chunk in axes[chunk.title].map { (id: chunk.id, vector: $0) } })
        let stamps = Stamps()
        knowledge.queryEmbedder = { _ in
            try await Task.sleep(for: .milliseconds(400))
            stamps.mark("embedded")
            return [1, 1, 0]
        }

        await checkAsk(checks, knowledge: knowledge, stamps: stamps)
        await checkRun(checks, knowledge: knowledge)
        await checkLink(checks, controller: controller)
        await checkCommandMode(checks, controller: controller)
        await drawAsk(knowledge: knowledge, directory: directory)

        print(checks.failures == 0 ? "ASK_OK" : "ASK_FAILED: \(checks.failures)")
        return checks.failures == 0 ? 0 : 1
    }

    static let askPieces = ["The launch ", "moved to ", "**Thursday 14 November** [1], ", "after the ", "pricing review [1]. ",
                            "Shipping follows a week after the beta [2]."]
    static var askAnswer: String { OutputGuard.sanitize(askPieces.joined()) }

    // MARK: The model clients

    /// Each client against a model server on this Mac that streams its reply a piece every 80 ms.
    @MainActor
    private static func checkModelClients(_ checks: AskChecks) async {
        let pieces = askPieces
        let whole = pieces.joined()
        guard let server = FakeModelServer(pieces: pieces, gap: 0.08), let port = await server.start() else {
            checks.check(false, "a model server on this Mac for the clients to stream from")
            return
        }
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let ollama = OllamaClient(baseURL: base, model: "stand-in")
        let openAI = OpenAICompatibleClient(baseURL: base.appendingPathComponent("v1"), model: "stand-in", apiKey: nil)
        func listen(_ client: LLMClient) async -> (text: String?, log: TextLog, ended: ContinuousClock.Instant) {
            let log = TextLog()
            let text = try? await client.stream(system: "Answer.", user: "When is the launch?", maxTokens: 100, temperature: 0, timeout: 20,
                                                stopWhen: { _ in false }, onText: { log.add($0) })
            return (text, log, .now)
        }

        server.style = .streams
        let clients: [(String, LLMClient)] = [("Ollama", ollama), ("An OpenAI-compatible server", openAI),
                                              ("Through the model lane, Ollama", LanedClient(inner: ollama, lane: .now, interrupts: false))]
        for (name, client) in clients {
            let heard = await listen(client)
            let lead = heard.log.firstAt.map { heard.ended - $0 } ?? .zero
            checks.check(heard.text == whole && heard.log.texts.count == pieces.count && heard.log.isGrowing && lead >= .milliseconds(250),
                         "\(name) streams its reply: \(heard.log.texts.count) pieces, the first \(Self.ms(lead)) ms before the last")
        }

        server.style = .oneReply
        for (name, client) in [("Ollama", ollama as LLMClient), ("An OpenAI-compatible server", openAI)] {
            let heard = await listen(client)
            checks.check(heard.text == whole && heard.log.texts == [whole], "\(name) answering a stream in one piece is read as one reply")
        }

        server.style = .refusesStreams
        let refused = await listen(openAI)
        checks.check(refused.text == whole && refused.log.texts == [whole] && server.asked.suffix(2) == [true, false],
                     "a server that turns streaming down is asked again for one reply")

        let standIn = await listen(StandInModel(reply: whole))
        checks.check(standIn.text == whole && standIn.log.texts == [whole], "a model client that can't stream tells its reply once")
        print("NOTE: MLX streams token by token as it always generated; no MLX model is downloaded in a throwaway folder, so it isn't run here")
    }

    // MARK: Ask

    @MainActor
    private static func checkAsk(_ checks: AskChecks, knowledge: KnowledgeService, stamps: Stamps) async {
        let model = PiecemealModel(pieces: askPieces, gap: .milliseconds(60))
        knowledge.answerModel = model
        let log = ProgressLog()
        let answer = await knowledge.ask("When is the launch?", progress: { log.add($0) })
        let events = log.events
        let embedded = stamps.at("embedded")
        if let first = events.first {
            checks.check(first.progress.stage == .keywordHits && first.progress.sources.map(\.title) == ["Launch date"]
                         && embedded.map { first.at < $0 } == true,
                         "the passage with the words shows before the search by meaning has its answer: \(first.progress.sources.map(\.title))")
        } else {
            checks.check(false, "Ask says how it's going")
        }
        let found = events.first { $0.progress.stage == .sources }
        checks.check(Set(found?.progress.sources.map(\.title) ?? []) == ["Launch date", "Shipping plan"]
                     && (found?.at).map { at in embedded.map { at >= $0 } == true } == true,
                     "then the passages by their words and meaning together: \(found?.progress.sources.map(\.title) ?? [])")
        var stages: [AskStage] = []
        for event in events where stages.last != event.progress.stage { stages.append(event.progress.stage) }
        checks.check(stages == [.keywordHits, .sources, .writing], "in that order, then the answer: \(stages.map(\.rawValue))")
        let writing = events.filter { $0.progress.stage == .writing }
        let texts = writing.map(\.progress.text)
        checks.check(writing.count >= 3 && zip(texts, texts.dropFirst()).allSatisfy { $1.hasPrefix($0) && $1.count > $0.count },
                     "the answer comes in pieces as it's written, each longer than the last: \(writing.count)")
        checks.check(writing.first.map { first in model.finishedAt.map { first.at < $0 } == true } == true,
                     "the first piece shows before the model has finished writing")
        checks.check(answer.text == askAnswer && texts.last == answer.text, "the finished answer is the last piece, cleaned up")
        checks.check(answer.sources == found?.progress.sources && writing.allSatisfy { $0.progress.sources == answer.sources },
                     "and it draws on the passages shown while it was written")
        checks.check(model.streams == 1 && model.completes == 0, "an answer someone watches is streamed")

        knowledge.queryEmbedder = { _ in [1, 1, 0] }
        knowledge.answerModel = PiecemealModel(pieces: ["<think>", "The user asks", " about the launch.", "</think>", "The launch is ", "on Thursday."],
                                               gap: .milliseconds(30))
        let thinking = ProgressLog()
        let reasoned = await knowledge.ask("When is the launch?", progress: { thinking.add($0) })
        let shown = thinking.events.filter { $0.progress.stage == .writing }.map(\.progress.text)
        checks.check(!shown.isEmpty && shown.allSatisfy { !$0.contains("think") && !$0.contains("user asks") } && reasoned.text == "The launch is on Thursday.",
                     "reasoning a model writes before its answer never shows: \(shown)")

        // A model whose chat template opens its reasoning: its replies close reasoning they never opened. Its first reply
        // shows the reasoning until it closes, as nothing marks it yet; from then on nothing shows until it closes, and
        // "Writing the answer from …" stays up meanwhile. Once a reply has none (its server keeps it apart now), it's let go.
        let opener = "stand-in that opens in reasoning"
        let key = KnowledgeService.reasoningOpenersKey
        AppDefaults.store.removeObject(forKey: key)
        let opening = ["Okay, the user asks", " about the launch.", "</think>", "The launch is ", "on Thursday."]
        /// The answer, and each text shown while it was written (until the first, it says "Writing the answer from …").
        func written(_ pieces: [String]) async -> (answer: KnowledgeService.Answer, shown: [String]) {
            knowledge.answerModel = PiecemealModel(pieces: pieces, gap: .milliseconds(40), model: opener)
            let log = ProgressLog()
            let answer = await knowledge.ask("When is the launch?", progress: { log.add($0) })
            return (answer, log.events.filter { $0.progress.stage == .writing }.map(\.progress.text))
        }
        let firstOpening = await written(opening)
        let noted = KnowledgeService.opensInReasoning("\(AppSettings.shared.llmProvider.rawValue):\(opener)")
        print("NOTE: the first reply from a model that opens in reasoning shows it until it closes: \(firstOpening.shown.first ?? "")")
        let nextOpening = await written(opening)
        checks.check(noted && firstOpening.answer.text == "The launch is on Thursday." && nextOpening.answer.text == "The launch is on Thursday."
                     && nextOpening.shown.first?.hasPrefix("The launch") == true && nextOpening.shown.allSatisfy { !$0.contains("user asks") && !$0.contains("think") },
                     "a model whose replies start inside its reasoning is noted, and its reasoning doesn't show again: \(nextOpening.shown)")
        let parsed = await written(askPieces)
        let streamsAgain = await written(askPieces)
        checks.check(parsed.answer.text == askAnswer && parsed.shown.isEmpty && streamsAgain.answer.text == askAnswer && streamsAgain.shown.count >= 3
                     && !KnowledgeService.opensInReasoning("\(AppSettings.shared.llmProvider.rawValue):\(opener)"),
                     "a reply from it with no reasoning comes whole, and it's let go: the next streams again (\(streamsAgain.shown.count) pieces)")
        AppDefaults.store.removeObject(forKey: key)

        knowledge.answerModel = StandInModel(reply: "The launch is on Thursday [1].")
        let single = ProgressLog()
        let oneReply = await knowledge.ask("When is the launch?", progress: { single.add($0) })
        checks.check(single.events.filter { $0.progress.stage == .writing }.map(\.progress.text) == ["The launch is on Thursday [1]."]
                     && oneReply.text == "The launch is on Thursday [1].", "a model that can't stream shows its answer in one piece")

        let quiet = PiecemealModel(pieces: askPieces, gap: .milliseconds(5))
        knowledge.answerModel = quiet
        let unwatched = await knowledge.ask("When is the launch?")
        checks.check(quiet.completes == 1 && quiet.streams == 0 && unwatched.text == askAnswer,
                     "asked with nothing watching (MCP, what's said near the iPhone), it's one reply, as before")

        let failing = PiecemealModel(pieces: askPieces, gap: .milliseconds(5))
        failing.failAfter = 2
        knowledge.answerModel = failing
        let cut = await knowledge.ask("When is the launch?", progress: { _ in })
        checks.check(cut.text.hasPrefix(OutputGuard.sanitize(askPieces.prefix(2).joined()) + "\n\n") && cut.text.contains("Couldn't finish the answer"),
                     "an answer that stops part-way keeps what was written, and says why: “\(cut.text.prefix(90))”")

        let slow = PiecemealModel(pieces: askPieces + askPieces, gap: .milliseconds(250))
        knowledge.answerModel = slow
        let watching = ProgressLog()
        let asking = Task { await knowledge.ask("When is the launch?", progress: { watching.add($0) }) }
        for _ in 0..<150 where !watching.events.contains(where: { $0.progress.stage == .writing }) { try? await Task.sleep(for: .milliseconds(20)) }
        let stopped = ContinuousClock.now
        asking.cancel()
        _ = await asking.value
        let took = ContinuousClock.now - stopped
        checks.check(slow.cancelled && slow.finishedAt == nil && took < .milliseconds(400),
                     "a question that's stopped stops the model at once: \(Self.ms(took)) ms")

        // A slow model doesn't keep anyone waiting past Ask's time, which counts from the question, its search included:
        // what was written by then stays, with why it stopped, and the model is stopped.
        knowledge.queryEmbedder = { _ in
            try await Task.sleep(for: .milliseconds(500))
            return [1, 1, 0]
        }
        let late = PiecemealModel(pieces: askPieces + askPieces, gap: .milliseconds(250))
        knowledge.answerModel = late
        knowledge.answerSeconds = 1.5
        let began = ContinuousClock.now
        let timed = await knowledge.ask("When is the launch?", progress: { _ in })
        let tookAll = ContinuousClock.now - began
        knowledge.answerSeconds = 180
        knowledge.queryEmbedder = { _ in [1, 1, 0] }
        for _ in 0..<25 where !late.cancelled { try? await Task.sleep(for: .milliseconds(20)) }
        checks.check(tookAll >= .milliseconds(1_450) && tookAll < .milliseconds(1_900) && late.cancelled && late.finishedAt == nil
                     && timed.text.hasPrefix("The launch moved to") && timed.text.hasSuffix("\n\nCouldn't finish the answer in time. The closest matches are below."),
                     "a slow answer stops at Ask's time, its search counted: \(Self.ms(tookAll)) ms of 1500, “\(timed.text.prefix(40))…”")
    }

    /// What the Knowledge page and Command Mode's panel show, stage by stage.
    @MainActor
    private static func checkRun(_ checks: AskChecks, knowledge: KnowledgeService) async {
        knowledge.queryEmbedder = { _ in
            try await Task.sleep(for: .milliseconds(300))
            return [1, 1, 0]
        }
        knowledge.answerModel = PiecemealModel(pieces: askPieces, gap: .milliseconds(80))
        let run = AskRun(question: "When is the launch?")
        var said: [String] = run.status.map { [$0] } ?? []
        var lengths: [Int] = []
        let task = Task { await run.run(with: knowledge) }
        while run.isWorking {
            if let status = run.status, said.last != status { said.append(status) }
            if !run.text.isEmpty, lengths.last != run.text.count { lengths.append(run.text.count) }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let answer = await task.value
        checks.check(said == ["Searching your meetings, notes and dictations…", "Found 1 passage with those words. Searching by meaning…",
                              "Writing the answer from 2 passages…"], "while it waits, it says what it's doing: \(said)")
        checks.check(lengths.count >= 3, "then the answer shows as it's written: \(lengths.count) lengths")
        checks.check(!run.isWorking && run.status == nil && run.text == askAnswer && run.sources == answer.sources && run.sources.count == 2,
                     "and once it's done, the answer and its 2 sources")
    }

    // MARK: The phone link

    @MainActor
    private static func checkLink(_ checks: AskChecks, controller: DictationController) async {
        let knowledge = controller.knowledge
        knowledge.queryEmbedder = { _ in [1, 1, 0] }
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: AppPaths.support.appendingPathComponent("ask-test-devices.json"))
        server.start()
        defer { server.stop() }
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        guard let port = server.boundPort, var pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort else {
            checks.check(false, "the Mac's link is listening")
            return
        }
        pairing.addresses = ["127.0.0.1:\(pairingPort)"]
        do {
            let paired = try await LinkClient.pair(pairing, deviceName: "Test iPhone")
            try? await Task.sleep(for: .milliseconds(600))
            func phone(reading features: [String]) async throws -> (client: LinkClient, heard: LinkHeard) {
                let client = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
                try await client.connect()
                try await client.hello(device: paired.device, key: paired.key, name: "Test iPhone", features: features)
                let heard = LinkHeard()
                client.onNotification { heard.add($0) }
                _ = try await client.request("binders/subscribe")
                return (client, heard)
            }
            func answer(_ text: String) -> String? {
                (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["answer"] as? String
            }
            let asking = try await phone(reading: LinkFeatures.thisPhone)
            let other = try await phone(reading: LinkFeatures.thisPhone)
            let first = try await phone(reading: [])
            defer {
                asking.client.close()
                other.client.close()
                first.client.close()
            }

            knowledge.answerModel = PiecemealModel(pieces: askPieces, gap: .milliseconds(120))
            let reply = try await asking.client.callTool("ask_knowledge", ["question": "When is the launch?", LinkAskProgress.tokenKey: "ask-1"], timeout: 30)
            let repliedAt = ContinuousClock.now
            let updates = asking.heard.updates
            checks.check(!updates.isEmpty && updates.allSatisfy { $0.update.token == "ask-1" && $0.at < repliedAt },
                         "the phone that asked hears how it's going, before the reply: \(updates.count) updates")
            let seqs = updates.map(\.update.seq)
            checks.check(seqs == seqs.sorted() && Set(seqs).count == seqs.count, "numbered in order")
            func titles(_ update: LinkAskProgress.Update) -> [String] {
                ((update.sources.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
            }
            checks.check(updates.first?.update.stage == .keywordHits && updates.first.map { titles($0.update) } == ["Launch date"],
                         "first the passage with the words")
            checks.check(updates.first { $0.update.stage == .sources }.map { Set(titles($0.update)) } == ["Launch date", "Shipping plan"],
                         "then the passages the answer draws on, as ask_knowledge describes them")
            let writing = updates.filter { $0.update.stage == .writing }
            let final = answer(reply) ?? ""
            let texts = writing.compactMap(\.update.text)
            checks.check(texts.count >= 2 && texts.count == writing.count && texts.allSatisfy { final.hasPrefix($0) } && writing.allSatisfy { $0.update.sources == nil },
                         "then the answer as it's written: \(texts.count) pieces")
            let gaps = zip(writing, writing.dropFirst()).map { $1.at - $0.at }
            checks.check(gaps.allSatisfy { $0 >= .milliseconds(200) }, "at most 4 times a second: the shortest gap \(Self.ms(gaps.min() ?? .zero)) ms")
            checks.check(final == askAnswer, "the reply is the whole answer, as before")
            try? await Task.sleep(for: .milliseconds(300))
            checks.check(other.heard.updates.isEmpty && first.heard.updates.isEmpty, "no other phone hears it")

            let old = try await first.client.callTool("ask_knowledge", ["question": "When is the launch?", LinkAskProgress.tokenKey: "ask-2"], timeout: 30)
            try? await Task.sleep(for: .milliseconds(300))
            checks.check(first.heard.updates.isEmpty && answer(old) == askAnswer,
                         "a phone that doesn't read it (iPhone 2.0) hears nothing new, even with a token, and gets the same reply")
            let before = asking.heard.updates.count
            let plain = try await asking.client.callTool("ask_knowledge", ["question": "When is the launch?"], timeout: 30)
            try? await Task.sleep(for: .milliseconds(300))
            checks.check(asking.heard.updates.count == before && answer(plain) == askAnswer, "and one that asks without a token hears nothing more")
        } catch {
            checks.check(false, "the phone could ask: \(error.localizedDescription)")
        }
    }

    // MARK: Command Mode

    @MainActor
    private static func checkCommandMode(_ checks: AskChecks, controller: DictationController) async {
        let knowledge = controller.knowledge
        let panel = AnswerPanelController.shared
        panel.showsWindow = false
        let spoken = TextLog()
        AnswerSpeaker.shared.onSpeak = { spoken.add($0) }
        if AppDefaults.store.object(forKey: "readAnswersAloud") == nil {
            checks.check(AppSettings.shared.readAnswersAloud, "Read answers aloud is on until you turn it off")
        }
        AnswerSpeaker.shared.isOn = { true }

        let card = TaskCard(title: "Fix the sign-in bug", binderID: Store.shared.defaultBinder().id, column: .inProgress)
        card.assignee = "Claude Code"
        card.assigneeIsAgent = true
        Store.shared.insert(card)
        let status = "What's happening with my work streams?"
        await controller.command(heard: status)
        let digest = WorkStreams.digest(WorkStreams.cards(in: nil))
        checks.check(panel.run?.text == digest.summary && digest.summary.contains("Fix the sign-in bug") && spoken.texts == [digest.summary],
                     "asked out loud what's happening, Command Mode shows the boards' answer and reads it aloud: “\(spoken.texts.first ?? "")”")
        AnswerSpeaker.shared.isOn = { false }
        await controller.command(heard: status)
        checks.check(spoken.texts.count == 1 && panel.run?.text == digest.summary, "with Read answers aloud off, it's only shown")
        AnswerSpeaker.shared.isOn = { true }

        knowledge.queryEmbedder = { _ in
            try await Task.sleep(for: .milliseconds(300))
            return [1, 1, 0]
        }
        knowledge.answerModel = PiecemealModel(pieces: askPieces, gap: .milliseconds(80))
        let question = "What did we decide about the launch date?"
        let asked = Task { await controller.command(heard: question) }
        var stages: [String] = []
        var lengths: [Int] = []
        for _ in 0..<2_000 {
            if let run = panel.run, run.question == question {
                let stage = run.isWorking ? run.stage?.rawValue ?? "searching" : "done"
                if stages.last != stage { stages.append(stage) }
                if run.stage == .writing, run.isWorking, lengths.last != run.text.count { lengths.append(run.text.count) }
                if !run.isWorking { break }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await asked.value
        // The search by its words takes a few milliseconds: the panel may be seen searching, or already with what it found.
        checks.check(Array(stages.drop { $0 == "searching" }) == ["keyword", "sources", "writing", "done"] && lengths.count >= 3,
                     "a question asked out loud fills the panel as it goes: \(stages), \(lengths.count) lengths of the answer")
        let records = ((try? Store.shared.context.fetch(FetchDescriptor<TranscriptRecord>())) ?? []).filter { $0.mode == "command" && $0.rawText == question }
        checks.check(panel.run?.text == askAnswer && records.count == 1 && records.first?.status == "answered" && records.first?.finalText == askAnswer,
                     "the answer is kept in History as answered, never to be pasted")
        checks.check(spoken.texts.count == 1, "an answer from the binders shows in the panel and isn't read aloud")

        let slow = PiecemealModel(pieces: askPieces + askPieces, gap: .milliseconds(250))
        knowledge.answerModel = slow
        let again = "What did we decide about the shipping plan?"
        let closing = Task { await controller.command(heard: again) }
        for _ in 0..<300 where panel.run?.question != again || panel.run?.stage != .writing { try? await Task.sleep(for: .milliseconds(20)) }
        let closed = ContinuousClock.now
        panel.close()
        await closing.value
        let took = ContinuousClock.now - closed
        let kept = ((try? Store.shared.context.fetch(FetchDescriptor<TranscriptRecord>())) ?? []).filter { $0.rawText == again }
        checks.check(slow.cancelled && slow.finishedAt == nil && !panel.isAnswering && kept.isEmpty && took < .milliseconds(500),
                     "closing the panel while the answer is written stops the model, and nothing is kept: \(Self.ms(took)) ms")
        AnswerSpeaker.shared.onSpeak = nil
        AnswerSpeaker.shared.isOn = { AppSettings.shared.readAnswersAloud }
    }

    // MARK: Drawing

    /// Command Mode's panel with the passages found, while the answer is written, and done; and the Knowledge page, asked.
    @MainActor
    private static func drawAsk(knowledge: KnowledgeService, directory: URL) async {
        func draw<V: View>(_ view: V, size: NSSize, name: String, wait: Double) async -> NSWindow {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let hosting = NSHostingView(rootView: view)
            hosting.wantsLayer = true
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            capture(hosting, name: name, directory: directory)
            captureScrollContents(hosting, name: name, directory: directory)
            return window
        }
        knowledge.queryEmbedder = { _ in
            try await Task.sleep(for: .milliseconds(1_500))
            return [1, 1, 0]
        }
        knowledge.answerModel = PiecemealModel(pieces: askPieces, gap: .milliseconds(450))
        let run = AskRun(question: "When is the launch?")
        let answering = Task { await run.run(with: knowledge) }
        for _ in 0..<100 where run.stage == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let size = NSSize(width: 480, height: 440)
        await draw(AnswerPanelView(run: run, onClose: {}), size: size, name: "ask-panel-found", wait: 0.4).close()
        for _ in 0..<400 where run.text.count < 30 { try? await Task.sleep(for: .milliseconds(10)) }
        await draw(AnswerPanelView(run: run, onClose: {}), size: size, name: "ask-panel-writing", wait: 0.3).close()
        _ = await answering.value
        await draw(AnswerPanelView(run: run, onClose: {}), size: size, name: "ask-panel-done", wait: 0.6).close()

        let navigation = HubNavigation()
        navigation.pendingKnowledgeQuery = "When is the launch?"
        let page = KnowledgeView().environment(knowledge).environment(navigation).environment(AppSettings.shared)
        let window = await draw(page, size: NSSize(width: 1020, height: 720), name: "ask-page-found", wait: 1.2)
        for (wait, name) in [(1_200, "ask-page-writing"), (2_400, "ask-page-done")] {
            try? await Task.sleep(for: .milliseconds(wait))
            guard let hosting = window.contentView else { continue }
            capture(hosting, name: name, directory: directory)
            captureScrollContents(hosting, name: name, directory: directory)
        }
        window.close()
    }

    static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// The ask self-test's checks, counted.
@MainActor
private final class AskChecks {
    var failures = 0

    func check(_ passed: Bool, _ label: String) {
        print("\(passed ? "PASS" : "FAIL"): \(label)")
        fflush(stdout)
        if !passed { failures += 1 }
    }
}

/// When things happened, from any thread.
private final class Stamps: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [String: ContinuousClock.Instant] = [:]

    func mark(_ name: String) { lock.withLock { marks[name] = .now } }
    func at(_ name: String) -> ContinuousClock.Instant? { lock.withLock { marks[name] } }
}

/// What a client said it had so far, and when, from whatever thread it says it.
private final class TextLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(text: String, at: ContinuousClock.Instant)] = []

    func add(_ text: String) { lock.withLock { entries.append((text, .now)) } }
    var texts: [String] { lock.withLock { entries.map(\.text) } }
    var firstAt: ContinuousClock.Instant? { lock.withLock { entries.first?.at } }
    var isGrowing: Bool {
        let texts = texts
        return zip(texts, texts.dropFirst()).allSatisfy { $1.hasPrefix($0) && $1.count > $0.count }
    }
}

/// What Ask said of how it was going, and when.
@MainActor
private final class ProgressLog {
    private(set) var events: [(at: ContinuousClock.Instant, progress: KnowledgeService.AskProgress)] = []

    func add(_ progress: KnowledgeService.AskProgress) { events.append((.now, progress)) }
}

/// The binders/ask-progress notifications a phone heard, as they arrived on the link's queue.
private final class LinkHeard: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [(update: LinkAskProgress.Update, at: ContinuousClock.Instant)] = []

    func add(_ message: [String: Any]) {
        guard message["method"] as? String == LinkFeatures.askProgressMethod,
              let update = LinkAskProgress.Update(params: message["params"] as? [String: Any] ?? [:]) else { return }
        lock.withLock { heard.append((update, .now)) }
    }

    var updates: [(update: LinkAskProgress.Update, at: ContinuousClock.Instant)] { lock.withLock { heard } }
}

/// A model that writes its reply a piece at a time, as a real one does, and notes whether it finished or was stopped.
private final class PiecemealModel: LLMClient, @unchecked Sendable {
    let pieces: [String]
    let gap: Duration
    let model: String
    /// Fails after this many pieces, as a server that goes away.
    var failAfter: Int?
    private let lock = NSLock()
    private var completed = 0, streamed = 0, wasCancelled = false
    private var finished: ContinuousClock.Instant?

    init(pieces: [String], gap: Duration, model: String = "stand-in") {
        self.pieces = pieces
        self.gap = gap
        self.model = model
    }
    var completes: Int { lock.withLock { completed } }
    var streams: Int { lock.withLock { streamed } }
    var cancelled: Bool { lock.withLock { wasCancelled } }
    var finishedAt: ContinuousClock.Instant? { lock.withLock { finished } }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        lock.withLock { completed += 1 }
        return pieces.joined()
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout, stopWhen: stopWhen, onText: { _ in })
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        lock.withLock { streamed += 1 }
        var text = ""
        for (index, piece) in pieces.enumerated() {
            if let failAfter, index == failAfter { throw LLMError.http(503, "the model server went away") }
            do {
                try await Task.sleep(for: gap)
            } catch {
                lock.withLock { wasCancelled = true }
                throw error
            }
            text += piece
            onText(text)
        }
        lock.withLock { finished = .now }
        return text
    }

    func listModels() async throws -> [String] { [model] }
    func warmUp() async {}
}

/// A model server on this Mac, on the loopback address only: it answers /api/chat as Ollama does and /v1/chat/completions
/// as an OpenAI-compatible server does, streaming its reply a piece at a time, or in one piece (as a server that can't
/// stream), or turning a stream down.
private final class FakeModelServer: @unchecked Sendable {
    enum Style: Sendable { case streams, oneReply, refusesStreams }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.binders.selftest.model-server")
    private let lock = NSLock()
    private let pieces: [String]
    private let gap: TimeInterval
    private var current = Style.streams
    private var streamAsked: [Bool] = []

    var style: Style {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// Whether each request asked for a stream, in order.
    var asked: [Bool] { lock.withLock { streamAsked } }

    init?(pieces: [String], gap: TimeInterval) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        self.pieces = pieces
        self.gap = gap
    }

    func start() async -> UInt16? {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let once = Once()
        return await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: if once.first() { continuation.resume(returning: self?.listener.port?.rawValue) }
                case .failed, .cancelled: if once.first() { continuation.resume(returning: nil) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var received = received
            if let data { received.append(data) }
            if let request = Self.request(in: received) { return self.answer(request, on: connection) }
            if isComplete || error != nil { return connection.cancel() }
            self.read(connection, received)
        }
    }

    /// A whole request's path and JSON body; nil until all of it has come.
    private static func request(in data: Data) -> (path: String, body: [String: Any])? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let length = lines.lazy.compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return (path, (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any] ?? [:])
    }

    private func answer(_ request: (path: String, body: [String: Any]), on connection: NWConnection) {
        let wantsStream = request.body["stream"] as? Bool == true
        let openAI = request.path.hasSuffix("/chat/completions")
        let style = lock.withLock { () -> Style in
            streamAsked.append(wantsStream)
            return current
        }
        func send(_ text: String, then: (@Sendable () -> Void)? = nil) {
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in then?() })
        }
        if wantsStream, style == .refusesStreams {
            let body = #"{"error":{"message":"stream is not supported by this server"}}"#
            send("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)") {
                connection.cancel()
            }
            return
        }
        guard wantsStream, style == .streams else {
            // All of it at once, over several lines, as a server that doesn't stream answers.
            let whole = pieces.joined()
            let object: [String: Any] = openAI
                ? ["choices": [["index": 0, "message": ["role": "assistant", "content": whole], "finish_reason": "stop"]]]
                : ["model": "stand-in", "message": ["role": "assistant", "content": whole], "done": true]
            let body = String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])) ?? Data(), as: UTF8.self)
            send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)") {
                connection.cancel()
            }
            return
        }
        send("HTTP/1.1 200 OK\r\nContent-Type: \(openAI ? "text/event-stream" : "application/x-ndjson")\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n")
        for (index, piece) in pieces.enumerated() {
            let event = Self.event(piece, openAI: openAI)
            queue.asyncAfter(deadline: .now() + gap * Double(index + 1)) { send(event) }
        }
        let last = openAI ? "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
                          : "{\"model\":\"stand-in\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n"
        queue.asyncAfter(deadline: .now() + gap * Double(pieces.count + 1)) { send(last) { connection.cancel() } }
    }

    private static func event(_ piece: String, openAI: Bool) -> String {
        let object: [String: Any] = openAI
            ? ["choices": [["index": 0, "delta": ["content": piece], "finish_reason": NSNull()]]]
            : ["model": "stand-in", "message": ["role": "assistant", "content": piece], "done": false]
        let line = String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
        return openAI ? "data: \(line)\n\n" : line + "\n"
    }
}

/// True the first time it's asked, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
