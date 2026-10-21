import AppKit
import CryptoKit
import Foundation
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// Plays an iPhone sending the day's conversations over the phone link, in a throwaway folder (BINDERS_DATA_DIR) on
    /// spare ports: a three-minute conversation between two people with a promise in it, sent twice, a blip too short to
    /// keep, and one that isn't a conversation at all. Uses the language model in Settings for the notes and the binder.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-conversation
    @MainActor
    static func conversationSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes conversations and binders")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        func info(_ label: String) { print("INFO: \(label)") }

        let store = Store.shared
        // A folder an earlier Binders wrote: its meetings open as meetings.
        let earlier = (try? store.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        if earlier.isEmpty {
            info("no earlier meetings in this folder")
        } else {
            let meetingKind = (try? store.context.fetchCount(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.kind == "meeting" }))) ?? 0
            check(meetingKind == earlier.count && earlier.allSatisfy { !$0.isConversation },
                  "the store an earlier version wrote opens, and its \(earlier.count) meetings read as meetings (\(meetingKind))")
            if CommandLine.arguments.contains("--store-only") {
                print(failures == 0 ? "CONVERSATION_OK" : "CONVERSATION_FAILED: \(failures)")
                return failures == 0 ? 0 : 1
            }
            print("ERROR: the rest of this test needs an empty folder")
            return 1
        }
        let controller = DictationController()
        let general = store.defaultBinder()
        // Shared with the team, so the test can show a conversation filed there stays on this Mac.
        let harbor = BinderRecord(name: "Harbor launch", colorIndex: 1)
        harbor.sharedWithTeam = true
        store.insert(harbor)
        let garden = BinderRecord(name: "Garden", colorIndex: 4)
        store.insert(garden)
        for (text, binder) in [("# Launch pricing\n\nBeta customers, plan names and the launch email.", harbor),
                               ("# Support rota for launch day\n\nWho answers the inbox on launch day.", harbor),
                               ("# Launch date\n\nHarbor launches to everyone on November 12, a week after the beta closes on November 5.", harbor),
                               ("# Tomatoes\n\nWhen to plant them out, and the raised beds.", garden)] {
            let note = NoteItem(text: text)
            note.binderID = binder.id
            note.sharedWithTeam = binder.sharedWithTeam
            store.insert(note)
        }
        print("LLM: \(AppSettings.shared.makeLLMClient() == nil ? "none" : AppSettings.shared.llmModelName)")
        // So a question can be answered from these notes.
        await controller.knowledge.indexNow()

        let devicesURL = FileManager.default.temporaryDirectory.appendingPathComponent("link-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: devicesURL) }
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: devicesURL)
        server.start()
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        guard let port = server.boundPort, var pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort else {
            print("CONVERSATION_FAILED: the link didn't start")
            return 1
        }
        pairing.addresses = ["127.0.0.1:\(pairingPort)"]

        do {
            let paired = try await LinkClient.pair(pairing, deviceName: "Test iPhone")
            let phone = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            try await phone.connect()
            let hello = try await phone.hello(device: paired.device, key: paired.key, name: "Test iPhone")
            check((hello["features"] as? [String])?.contains(ConversationPayload.feature) == true
                  && (hello["features"] as? [String])?.contains(ConversationSuggestion.feature) == true, "the Mac says it takes conversations and has suggestions")

            // Three minutes about the Harbor launch, with a promise each way.
            let conversation = Self.conversationFixture()
            for _ in 0..<2 {
                let reply = try await phone.request(ConversationPayload.method, conversation.jsonObject()) as? [String: Any]
                check(reply?["id"] as? String == conversation.id.uuidString, "the Mac answers with the conversation's id")
            }
            let blip = ConversationPayload(started: conversation.ended.addingTimeInterval(600), ended: conversation.ended.addingTimeInterval(625),
                                           segments: [TranscriptSegment(channel: .microphone, start: 0, end: 4, text: "Thanks, see you later.", speaker: "Speaker 1")],
                                           speakers: ["Speaker 1": TranscriptSegment.you], device: "iPhone", engine: "parakeet-v2")
            _ = try await phone.request(ConversationPayload.method, blip.jsonObject())
            // Long enough to be read, with nothing in it worth keeping.
            let chat = ["Morning! Cold out there today, isn't it?", "Freezing. I nearly went back for a second coat.",
                        "Did you catch the game last night?", "Only the second half, it was a good one though.",
                        "Yeah, what a finish. Anyway, I'd better get going, my coffee's getting cold.", "Same here. Have a good one, see you around."]
            let smallTalk = ConversationPayload(started: conversation.ended.addingTimeInterval(1_800), ended: conversation.ended.addingTimeInterval(1_860),
                                                segments: chat.enumerated().map { index, text in
                                                    TranscriptSegment(channel: .microphone, start: Double(index) * 9, end: Double(index) * 9 + 7, text: text,
                                                                      speaker: index.isMultiple(of: 2) ? "Speaker 2" : "Speaker 1")
                                                }, speakers: ["Speaker 1": TranscriptSegment.you], device: "iPhone", engine: "parakeet-v2")
            _ = try await phone.request(ConversationPayload.method, smallTalk.jsonObject())
            let broken = try? await phone.request(ConversationPayload.method, ["id": "not a conversation"])
            check(broken == nil, "something that isn't a conversation is refused")

            // The same conversation as a Binders file, by AirDrop: already here, so not kept again. A new one in a file is.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("binders-file-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let another = ConversationPayload(started: conversation.started.addingTimeInterval(-3_600), ended: conversation.started.addingTimeInterval(-3_400),
                                              segments: conversation.segments, speakers: conversation.speakers, device: "iPhone", engine: "parakeet-v2")
            let fileURL = folder.appendingPathComponent(BindersTransfer.fileName(for: [conversation, another]))
            try BindersTransfer(conversations: [conversation, another]).encoded().write(to: fileURL)
            let opened = BindersFiles.open(fileURL, controller: controller)
            let again = BindersFiles.open(fileURL, controller: controller)
            check(opened == "Kept a capture from your iPhone" && again == "Already had these 2 captures",
                  "a Binders file keeps what's new in it, once: “\(opened)”, then “\(again)”")
            let notBinders = folder.appendingPathComponent("other.binders")
            try Data("{\"hello\":1}".utf8).write(to: notBinders)
            check(BindersFiles.open(notBinders, controller: controller).contains("isn't a Binders file"), "another file is refused")

            // Written up in the background: wait for both.
            let deadline = Date().addingTimeInterval(600)
            func record(_ id: UUID) -> MeetingRecord? {
                ((try? store.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id }))) ?? []).first
            }
            let anotherID = another.id
            while Date() < deadline, [conversation.id, blip.id, smallTalk.id, anotherID].contains(where: { record($0)?.status == "processing" })
                    || !controller.conversations.processing.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }

            // What the phone's capture rows say about each, asked over the link only.
            check((hello["features"] as? [String])?.contains(CaptureOutcome.feature) == true, "the Mac says it tells the phone what became of each capture")
            let asked = [conversation.id, blip.id, UUID()].map(\.uuidString)
            let answered = (try await phone.request(CaptureOutcome.listMethod, ["ids": asked]) as? [String: Any])?["outcomes"] as? [Any] ?? []
            let outcomes = Dictionary(CaptureOutcome.decodeEach(answered).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            check(outcomes.count == 2, "an outcome for each capture it has, none for one it doesn't know")
            check(outcomes[blip.id]?.state == CaptureOutcome.States.notKept && outcomes[blip.id]?.line == "Not kept: too short"
                  && outcomes[blip.id]?.settled == true, "a blip: \(outcomes[blip.id]?.line ?? "none")")
            let written = !(record(conversation.id)?.summary.trimmed.isEmpty ?? true)
            let main = outcomes[conversation.id]
            check(written ? main?.state == CaptureOutcome.States.filed && (main?.line.hasPrefix("Filed in ") ?? false)
                          : main?.state == CaptureOutcome.States.failed && (main?.line.hasPrefix("Couldn't write up") ?? false),
                  "the conversation: \(main?.line ?? "none")")
            if written, let main, let binder = main.binder {
                // The iPhone's Today reads the binder back out of the line it keeps, for the binder's chip.
                let names = ((try? store.context.fetch(FetchDescriptor<BinderRecord>())) ?? []).map(\.name)
                check(CaptureOutcome.filedBinder(in: main.line, among: names) == binder, "the iPhone reads its binder from the line: \(binder)")
            }
            if !written { check(record(conversation.id)?.routingReason == nil, "with no notes, no model call was spent filing it") }

            let kept = ((try? store.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []).filter { $0.id == conversation.id }
            check(kept.count == 1, "sent twice, kept once: \(kept.count)")
            guard let first = kept.first else { throw MCPCore.ToolFailure("the conversation wasn't kept") }
            check(first.isConversation && first.appName == "iPhone" && first.createdAt == conversation.started && first.endedAt == conversation.ended,
                  "kept as a conversation from the iPhone, at the time it was heard")
            check(store.segments(for: first.id).count == conversation.segments.count, "its transcript is there once, with speakers")
            check(first.status == "ready", "written up: \(first.status)")
            if let error = first.errorMessage { info("notes: \(error)") }
            check(!first.summary.trimmed.isEmpty && !MeetingService.hasPlaceholderTitle(first), "it has notes and a title: “\(first.title)”")
            let tasks = TaskCollector.collect(meetings: [first], notes: [], openMeeting: { _ in }, openNote: { _ in })
            let mine = tasks.filter { $0.owner == TranscriptSegment.you && $0.text.localizedCaseInsensitiveContains("pricing") }
            check(!mine.isEmpty, "your promise is a to-do: \(tasks.map { "\($0.owner ?? "?") — \($0.text)" })")
            let binderName = store.binder(first.binderID)?.name ?? "?"
            if first.binderID == harbor.id {
                check(true, "filed in Harbor launch (\(first.routingReason ?? "no reason given"))")
            } else {
                info("filed in \(binderName), not Harbor launch (\(first.routingReason ?? "no reason given"))")
            }
            check(!first.sharedWithTeam, "never shared with the team, even in a shared binder")

            // What it offers: a card for your promise, and the launch date you asked about, from the notes.
            let suggestions = first.suggestions
            let card = suggestions.first { $0.kind == .card && $0.text.localizedCaseInsensitiveContains("pricing") }
            check(card?.status == .offered, "it offers a card for your promise: \(suggestions.filter { $0.kind == .card }.map(\.text))")
            let answer = suggestions.first { $0.kind == .answer }
            check(answer?.answer?.contains("12") == true, "it answers the question you asked from your notes: \(answer.map { "\($0.text) → \($0.answer ?? "")" } ?? "none")")
            let listed = (try await phone.request(ConversationSuggestion.listMethod) as? [String: Any])?["suggestions"] as? [[String: Any]] ?? []
            let listedIDs = Set(listed.compactMap { $0["id"] as? String })
            check(!suggestions.isEmpty && suggestions.allSatisfy { listedIDs.contains($0.id) }, "the phone gets them: \(listed.count) in all")
            if let card {
                let added = try await phone.request(ConversationSuggestion.actMethod, ["id": card.id, "action": "accept"]) as? [String: Any]
                let onBoard = controller.board.card(forTodo: card.todo ?? "")
                check(onBoard?.binderID == first.binderID && onBoard?.column == .ready && first.suggestions.first { $0.id == card.id }?.status == .accepted,
                      "yes from the phone puts it on the board: “\(added?["message"] as? String ?? "")”")
                check(controller.conversations.accept(card.id).message.hasPrefix("Already on"), "and a second yes doesn't make a second card")
            }
            if let answer {
                _ = try await phone.request(ConversationSuggestion.actMethod, ["id": answer.id, "action": "dismiss"])
                check(first.suggestions.first { $0.id == answer.id }?.status == .dismissed, "no from the phone is kept")
            }
            controller.team.setShared(harbor, true)
            store.move(first, to: harbor)
            check(!first.sharedWithTeam, "still not shared after sharing its binder again and moving it there")

            let small = record(blip.id)
            check(small?.status == "trivial", "a blip is kept as trivial: \(small?.status ?? "missing")")
            let chatter = record(smallTalk.id)
            if chatter?.status == "trivial" {
                check(true, "small talk is kept as trivial by the model")
            } else {
                info("the model kept the small talk: \(chatter?.status ?? "missing") “\(chatter?.title ?? "")”")
            }
            store.purgeTrivialConversations(now: Date().addingTimeInterval(8 * 86_400))
            check(record(blip.id) == nil && record(conversation.id) != nil, "trivial ones are deleted after a week, the rest stay")

            // Out of the meetings lists, there when asked for.
            let meetings = try await phone.callTool("list_meetings")
            let conversations = try await phone.callTool("list_meetings", ["kind": "capture"])
            let byOldName = try await phone.callTool("list_meetings", ["kind": "conversation"])
            check(!meetings.contains(conversation.id.uuidString) && conversations.contains(conversation.id.uuidString)
                  && byOldName.contains(conversation.id.uuidString),
                  "list_meetings leaves captures out unless asked for them, as capture or conversation")
            check(store.counts(in: first.binderID ?? general.id).meetings == 0 && store.conversationCount(in: first.binderID ?? general.id) >= 1,
                  "a binder counts it as a conversation, not a meeting")
            let detail = try await phone.callTool("get_meeting", ["id": conversation.id.uuidString])
            check(detail.contains("\"kind\":\"capture\"") || detail.contains("\"kind\" : \"capture\""), "get_meeting says it's a capture")
            phone.close()

            // `--snapshot <dir>`: the binder's Conversations tab and the Today page, as pictures to look at.
            if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(index + 1) {
                let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let navigation = HubNavigation()
                navigation.binderID = first.binderID
                navigation.selection = .binder
                navigation.pendingBinderTab = .conversations
                navigation.pendingMeetingID = first.id
                let hosting = NSHostingView(rootView: HubView()
                    .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
                    .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
                    .modelContainer(store.container))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860), styleMask: [.titled, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.alphaValue = 0
                window.contentView = hosting
                hosting.wantsLayer = true
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(1500))
                capture(hosting, name: "conversation-binder", directory: directory)
                navigation.selection = .today
                try? await Task.sleep(for: .milliseconds(1500))
                capture(hosting, name: "conversation-today", directory: directory)
                window.close()
                print("SNAPSHOTS: \(directory.path)")
            }
        } catch {
            check(false, "the conversation failed: \((error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription)")
        }
        server.stop()
        print(failures == 0 ? "CONVERSATION_OK" : "CONVERSATION_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// All-day capture on the Mac, with a recording standing in for the microphone: the same worker cuts it into a
    /// conversation, which is written down here (speech model, diarizer) and kept like the iPhone's. A conversation
    /// closes after 5 s of quiet here, instead of three minutes.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-allday two-voices.wav
    @MainActor
    static func allDaySelfTest(file: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes conversations")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        controller.speech.activate(AppSettings.shared.speechModel, download: true)
        let capture = AllDayCaptureService(controller: controller, splitting: ConversationSplitter.Settings(silenceToClose: 5, maxLength: 5_400, minSpeech: 5))
        await capture.prepareDetector()
        guard let samples = try? AudioRecorder.readSamples(from: file), samples.count > 16_000 * 5 else {
            print("ERROR: couldn't read \(file.path)")
            return 1
        }
        // Heard just now: a second of quiet, the recording, then quiet until the conversation closes.
        let quiet = [Float](repeating: 0, count: 4_000)
        var heard = Date().addingTimeInterval(-Double(samples.count) / 16_000 - 12)
        func hear(_ chunk: [Float]) async {
            await capture.hear(chunk, at: heard)
            heard = heard.addingTimeInterval(Double(chunk.count) / 16_000)
        }
        for _ in 0..<4 { await hear(quiet) }
        var offset = 0
        while offset < samples.count {
            await hear(Array(samples[offset..<min(samples.count, offset + 4_000)]))
            offset += 4_000
        }
        for _ in 0..<40 { await hear(quiet) }
        let kind = MeetingRecord.conversationKind
        func kept() -> [MeetingRecord] {
            (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.kind == kind }))) ?? []
        }
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline, kept().first.map({ $0.status == "processing" }) ?? true {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let records = CaptureFiles.all()
        check(records.count == 1, "the recording became one conversation: \(records.count)")
        if let record = records.first {
            check(record.state == .sent && record.audioDeleted, "written down on this Mac, and its audio deleted: \(record.state.rawValue)")
            let speakers = Set((record.transcript ?? []).map(\.speaker))
            check(speakers.count >= 2, "the voices are told apart: \(speakers.sorted())")
            let steps = (record.steps ?? []).map(\.step)
            check(steps.starts(with: [CaptureStep.heard, CaptureStep.closed]), "its timeline starts with when it was heard and closed: \(steps)")
            print("TRANSCRIPT:")
            for segment in record.transcript ?? [] { print("  [\(TranscriptFormatter.timestamp(segment.start))] \(segment.speaker): \(segment.text)") }
        }
        let conversation = kept().first
        check(conversation?.appName == "Mac" && conversation?.status == "ready", "kept as a conversation from this Mac: \(conversation?.status ?? "missing")")
        check(conversation?.summary.localizedCaseInsensitiveContains("pricing") == true, "with notes: “\(conversation?.title ?? "")”")
        print(failures == 0 ? "ALLDAY_OK" : "ALLDAY_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Two people on the fictional Harbor launch, about three minutes, as the iPhone would send it.
    static func conversationFixture() -> ConversationPayload {
        let lines: [(String, String)] = [
            ("Speaker 2", "Hey, have you got a minute? It's about the Harbor launch email."),
            ("Speaker 1", "Sure. Where did we land on pricing for the beta customers?"),
            ("Speaker 2", "We agreed they keep their current price for a year, and then they move to the annual plan with the fifteen percent discount."),
            ("Speaker 1", "Good, that's simple to explain. And the plan names are final? Starter, Team and Business?"),
            ("Speaker 2", "Yes. Starter is eight dollars, Team is fifteen and Business is twenty nine, per seat a month."),
            ("Speaker 1", "Okay. I'll send Sam the final pricing email by Friday, so he can check the numbers before it goes out."),
            ("Speaker 2", "Perfect. I'll update the plan names on the website tomorrow morning, before the changelog post."),
            ("Speaker 1", "Do we still need someone on the support inbox on launch day?"),
            ("Speaker 2", "We do. I think two people in the morning and one in the afternoon is enough for the first day."),
            ("Speaker 1", "Let's put that on the rota then. I can take the morning shift."),
            ("Speaker 2", "Great. One more thing, the import test with the big customer file still fails on the dates."),
            ("Speaker 1", "Then we keep the import out of the launch email until it passes. No promises we can't keep."),
            ("Speaker 2", "Agreed. I'll tell the team in the standup tomorrow."),
            ("Speaker 1", "Thanks. Oh, and when is the Harbor launch date again? I keep forgetting."),
            ("Speaker 2", "No idea, I'd have to look it up."),
            ("Speaker 1", "Fine, let's check in again on Thursday afternoon."),
        ]
        var segments: [TranscriptSegment] = []
        var time: TimeInterval = 2
        for (speaker, text) in lines {
            let length = Double(text.split(separator: " ").count) * 0.42 + 1
            segments.append(TranscriptSegment(channel: .microphone, start: time, end: time + length, text: text, speaker: speaker))
            time += length + 6
        }
        let started = Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: Date()) ?? Date()
        // Whole seconds, as dates travel over the link.
        return ConversationPayload(started: started, ended: started.addingTimeInterval(time.rounded(.up)), segments: segments,
                                   speakers: ["Speaker 1": TranscriptSegment.you], device: "iPhone", engine: "parakeet-v2")
    }
}
