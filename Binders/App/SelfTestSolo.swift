import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// The router self-test's section "Auto, only you" (lane Y2): captures in which the iPhone heard only you, over the link
    /// from paired iPhones, with the router's stand-in decision model, a stand-in language model for the captures' reading
    /// and notes, and stand-in agents, never the real tools. A capture's to-dos, fixes and ideas are handed over once each
    /// in Auto, with Binders' note and Stop; Suggest and Add at Once hand nothing over; a capture with someone else in it,
    /// one the Mac's checks refuse, and an older phone's are offered as today; a moment said in a capture goes with it, in
    /// either order, only with its own checks too; every hand-over from a capture takes a place among Auto's five in ten
    /// minutes; Stop All, Not Only Me and a lower mode reach a capture; a sentence kept without a cue is read with fixes.
    @MainActor
    static func soloSelfTest(controller: DictationController, models: DecisionModels, standIn: RouterStandIn, website: BinderRecord,
                             folder: URL, check: (Bool, String) -> Void) async {
        let store = Store.shared
        let board = controller.board
        let registry = AgentRegistry.shared
        let log = RouterLogFile.shared
        let conversations = controller.conversations
        let moments = controller.moments

        // The section's own agent, with the Mac's three yeses: the start switch's, Auto's and the one for captures.
        var quill = AgentProfile(name: "Quill", wake: .command(command: "./wake-scribe", folder: folder.path), binders: [website.id], wakesPerHour: 60,
                                 purpose: "the website: pages, copy, fixes and ideas")
        quill.autoStart = true
        check(registry.upsert(quill, startsOnItsOwn: true, startsInAuto: true, startsInSolo: true) == nil, "Solo: Quill is saved")
        guard let saved = registry.agent(named: "Quill"), registry.startsInSolo(saved), let scribe = registry.agent(named: "Scribe") else {
            check(false, "Solo: Quill has the Mac's yes for captures, and Scribe is there")
            return
        }
        quill = saved
        check(registry.startsInAuto(scribe) && !registry.startsInSolo(scribe), "Solo: Scribe has Auto mode's yes and not the one for captures")
        registry.setStartsInAuto(quill.id, false)
        let soloGoesWithAuto = !registry.startsInSolo(quill)
        registry.upsert(quill, startsOnItsOwn: true, startsInAuto: true, startsInSolo: true)
        check(soloGoesWithAuto && registry.startsInSolo(quill), "Solo: Auto's yes taken away takes the one for captures, and Turn On writes it again")

        // The language model's stand-in for captures: the reading's reply by the first sentence it was shown, fixed notes
        // (with a Promises line, which a capture read for what you said must never be asked for), Website for the binder,
        // and no questions. It keeps what it was asked.
        let llm = SoloLLMStandIn()
        let conversationsModel = conversations.model, momentsModel = moments.model
        conversations.model = { llm }
        moments.model = { llm }
        let pairedBefore = moments.pairedDevices
        let devicesURL = FileManager.default.temporaryDirectory.appendingPathComponent("solo-devices-\(UUID().uuidString).json")
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: devicesURL)
        server.start()
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        moments.pairedDevices = { server.devices.map(\.id) }
        defer {
            conversations.model = conversationsModel
            moments.model = momentsModel
            moments.pairedDevices = pairedBefore
            server.stop()
            try? FileManager.default.removeItem(at: devicesURL)
            AppDefaults.store.removeObject(forKey: MeetingService.callSpansKey)
        }
        // Auto's window of five in ten minutes, empty: the Auto section's late words were decided minutes ago.
        moments.ageForSelfTest(by: 3_600)

        func pairPhone(_ name: String, features: [String]) async throws -> (client: LinkClient, device: UUID, hello: [String: Any]) {
            guard let port = server.boundPort, var pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort else {
                throw CocoaError(.featureUnsupported)
            }
            pairing.addresses = ["127.0.0.1:\(pairingPort)"]
            let paired = try await LinkClient.pair(pairing, deviceName: name)
            let phone = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            try await phone.connect()
            let hello = try await phone.hello(device: paired.device, key: paired.key, name: name, features: features)
            return (phone, paired.device, hello)
        }

        do {
            let phone = try await pairPhone("Solo iPhone", features: LinkFeatures.thisPhone)
            let older = try await pairPhone("Y1 iPhone", features: LinkFeatures.thisPhone.filter { $0 != ConversationPayload.soloFeature })
            AutoPhones.allow(phone.device)
            AutoPhones.allow(older.device)
            defer {
                AutoPhones.forget(phone.device)
                AutoPhones.forget(older.device)
            }

            // MARK: (a) The hello, and what list_agents gives a phone that vouches for captures
            check((phone.hello["features"] as? [String])?.contains(ConversationPayload.soloFeature) == true,
                  "Solo: the hello's features list \(ConversationPayload.soloFeature)")
            let listed = (try JSONSerialization.jsonObject(with: Data(try await phone.client.callTool("list_agents").utf8)) as? [String: Any]) ?? [:]
            let entries = ((listed["agents"] as? [[String: Any]]) ?? [])
            let quillEntry = entries.first { $0["name"] as? String == "Quill" }, scribeEntry = entries.first { $0["name"] as? String == "Scribe" }
            let quillReads = AgentBriefing.reads(for: "Quill")
            let soloFingerprint = AgentRegistry.consentFingerprint(quill, reads: quillReads, startsOnItsOwn: true, auto: true, solo: true)
            let autoFingerprint = AgentRegistry.consentFingerprint(quill, reads: quillReads, startsOnItsOwn: true, auto: true)
            check(quillEntry?["solo_start"] as? Bool == true && quillEntry?["solo"] as? String == "takes" && quillEntry?["fingerprint"] as? String == soloFingerprint
                  && quillEntry?["auto_fingerprint"] as? String == autoFingerprint && scribeEntry?["solo"] as? String == "switch-before"
                  && scribeEntry?["solo_start"] == nil,
                  "Solo: list_agents gives Quill solo_start, takes and both fingerprints; Scribe was switched on before: \(scribeEntry?["solo"] ?? "none")")
            let olderListed = try await older.client.callTool("list_agents")
            check(!olderListed.contains("solo_start") && !olderListed.contains("\"solo\"") && !olderListed.contains("auto_fingerprint"),
                  "Solo: an older iPhone gets none of the keys")
            let yes: [String: String] = [RouterRules.PhoneCheck.consentKey("Quill"): soloFingerprint,
                                         RouterRules.PhoneCheck.consentKey("Scribe"): AgentRegistry.consentFingerprint(scribe, reads: AgentBriefing.reads(for: "Scribe"),
                                                                                                                      startsOnItsOwn: true, auto: true)]

            /// A capture as the iPhone sends it: each string a segment of yours, 6 seconds apart, heard `minutesAgo` ago.
            func capture(_ said: [String], id: UUID = UUID(), mode: String? = "auto", solo: Bool? = true, hold: String? = nil, agreed: [String: String]? = nil,
                         soloMoments: [UUID]? = nil, kept: Bool? = nil, others: [(String, String)] = [], minutesAgo: Double = 5,
                         from client: LinkClient? = nil, wait: Bool = true) async throws -> UUID {
                let started = Date().addingTimeInterval(-minutesAgo * 60)
                var segments = said.enumerated().map { TranscriptSegment(channel: .microphone, start: Double($0.offset) * 6, end: Double($0.offset) * 6 + 5,
                                                                         text: $0.element, speaker: "Speaker 1") }
                var speakers = ["Speaker 1": SoloRule.youLabel]
                for (index, other) in others.enumerated() {
                    segments.append(TranscriptSegment(channel: .microphone, start: Double(said.count + index) * 6, end: Double(said.count + index) * 6 + 5,
                                                      text: other.1, speaker: other.0))
                    speakers[other.0] = other.0
                }
                let payload = ConversationPayload(id: id, started: started, ended: started.addingTimeInterval(Double(segments.count) * 6 + 10), segments: segments,
                                                  speakers: speakers, device: "iPhone", engine: "parakeet-v2", mode: mode, solo: solo, soloHold: hold,
                                                  agreed: agreed ?? (mode == "auto" && solo == true ? yes : nil), voice: solo == true ? 0.86 : nil,
                                                  otherSpeech: solo == true ? 0.4 : nil, soloMoments: soloMoments, keptForMoment: kept)
                _ = try await (client ?? phone.client).request(ConversationPayload.method, payload.jsonObject(), timeout: 30)
                if wait { await settled(id) }
                return id
            }
            func settled(_ id: UUID) async {
                for _ in 0..<160 {
                    if let outcome = conversations.outcome(id), [CaptureOutcome.States.filed, CaptureOutcome.States.notKept, CaptureOutcome.States.failed]
                        .contains(outcome.state), !conversations.processing.contains(id) { return }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            func record(_ id: UUID) -> MeetingRecord? {
                (try? store.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id })))?.first
            }
            func card(_ outcome: CaptureOutcome?) -> TaskCard? { outcome?.card.flatMap(UUID.init(uuidString:)).flatMap(board.card) }
            func runs() -> Int { board.cards(in: website.id).reduce(0) { $0 + board.timeline($1.id).filter { $0.kind == .woke }.count } }
            func act(_ id: UUID, _ action: String, mode: String? = nil, from client: LinkClient? = nil) async -> (ok: Bool, message: String) {
                var params: [String: Any] = ["id": id.uuidString, "action": action]
                if let mode { params["mode"] = mode }
                do {
                    let reply = try await (client ?? phone.client).request(CaptureOutcome.actMethod, params) as? [String: Any]
                    return (true, reply?["message"] as? String ?? "")
                } catch LinkClient.Failure.rejected(let message) {
                    return (false, message)
                } catch {
                    return (false, error.localizedDescription)
                }
            }
            func entry(_ id: UUID) -> RouterLogEntry? {
                log.flush()
                return log.entries().last { $0.moment == id && $0.event == nil }
            }
            /// The reading's reply for a capture whose first sentence is `first`: an ITEM line per (kind, title, the
            /// sentences holding these words).
            func reads(_ said: [String], _ items: [(String, String, [String])]) {
                let sentences = SoloPrompts.numbered(said)
                let lines = items.map { item -> String in
                    let numbers = item.2.compactMap { words in sentences.first { $0.text.contains(words) }?.number }
                    return "ITEM: \(item.0) | \(item.1) | \(numbers.map(String.init).joined(separator: ", ")) | none"
                }
                llm.reply(to: sentences.first?.text ?? "", lines.isEmpty ? "NONE" : lines.joined(separator: "\n"))
            }

            // MARK: (b) A capture that's only you, in Auto: its fix and idea handed over once each, with the note and Stop
            let walk = ["Okay, so, walking back from the shop. The login on the site times out way too fast, I lost a draft twice today.",
                        "That's really annoying. We should add a weekly digest of what the agents did, something I can read on Sunday.",
                        "Hmm. The light is nice today. I should renew the domain before it lapses, that's next month I think.",
                        "Anyway. Lots to think about with the pricing, but not now."]
            let fix = "Fix the site's login timing out too fast", digest = "A weekly digest of what the agents did", domain = "Renew the domain before it lapses"
            reads(walk, [("fix", fix, ["times out"]), ("idea", digest, ["weekly digest"]), ("todo", domain, ["renew the domain"])])
            standIn.set(fix, binder: ["Website": 0.95], agent: ["Quill": 0.82])
            standIn.set(digest, binder: ["Website": 0.95], agent: ["Quill": 0.70])
            standIn.set(domain, binder: ["Website": 0.95], agent: [RouterQuestions.nobody: 0.90])
            let runsBefore = runs()
            let first = try await capture(walk)
            let filed = conversations.outcome(first)
            let found = filed?.found ?? []
            check(filed?.state == CaptureOutcome.States.filed && found.count == 3 && found.map(\.kind) == ["todo", "idea", "todo"]
                  && found.map(\.id) == (0..<3).map { SoloReading.itemID(capture: first, index: $0, title: [fix, digest, domain][$0]) },
                  "Solo: the capture is filed, with three things found, in the order said: \(found.map(\.kind)) · \(filed?.line ?? "")")
            let items = found.map { moments.outcome($0.id) }
            check(items[0]?.handedOver == CaptureOutcome.Handed.auto && items[1]?.handedOver == CaptureOutcome.Handed.auto
                  && items[0]?.actions == ["stop", "undo", "not-me"] && items[2]?.state == "acted" && items[2]?.handedOver == nil,
                  "Solo: the fix and the idea are handed to Quill, with Stop, Undo and Not Me; the domain is added: \(items.map { $0?.title ?? "none" })")
            check(runs() - runsBefore == 2, "Solo: Quill was woken twice, once for each: \(runs() - runsBefore)")
            check(filed?.line == "Filed in Website: Walk thoughts · 2 handed to agents · 1 added", "Solo: the capture's line counts them: \(filed?.line ?? "")")
            let fixCard = card(items[0])
            check(fixCard?.column == .ready && fixCard?.meantFor == "Quill"
                  && fixCard?.details.hasPrefix("“The login on the site times out way too fast, I lost a draft twice today.”\n\nSaid to your iPhone at ") == true
                  && fixCard?.details.hasSuffix(", while you thought out loud.") == true && fixCard?.details.contains("walking back") == false,
                  "Solo: the fix's card is in Ready, meant for Quill, quoting only its sentence: \(fixCard?.details ?? "none")")
            let note = fixCard.flatMap { card in board.timeline(card.id).first { $0.kind == .comment && $0.author == BoardService.binders.name } }?.text ?? ""
            check(note.hasPrefix("Binders handed this to Quill without asking: you thought it out loud to your iPhone at ")
                  && note.contains("with no one else talking, while it was in Auto"), "Solo: Binders' note says so: \(note)")
            check(fixCard.map(controller.router.showsStop) == true, "Solo: the card shows Stop")
            let fixLog = entry(found[0].id)
            check(fixLog?.origin == "solo" && fixLog?.mode == "auto" && fixLog?.did == "started",
                  "Solo: the log has origin \(fixLog?.origin ?? "none"), mode \(fixLog?.mode ?? "none"), did \(fixLog?.did ?? "none")")
            let written = record(first)
            check(llm.notesPrompts.last.map { !$0.contains("Promises") && $0.contains("No checkboxes and no to-dos") } == true
                  && written?.templateID == MeetingTemplate.conversation.id && written?.summary.contains("- [ ]") == false
                  && written?.suggestions.filter({ $0.kind != .answer }).isEmpty == true,
                  "Solo: its notes were asked without Promises, have no checklist, stay a conversation, and nothing is offered from them")
            check(llm.readingPrompts.last?.contains("[2] The login on the site times out way too fast") == true,
                  "Solo: the reading was shown your sentences, numbered")

            // MARK: (c) Sent again, and read again as after a quit: nothing made twice
            _ = try await capture(walk, id: first)
            if let written {
                written.status = "processing"
                store.save()
                await conversations.process(written)
            }
            check(runs() - runsBefore == 2 && board.cards(in: website.id).filter { $0.title == fix }.count == 1,
                  "Solo: sent again, and processed again, it makes nothing twice")

            // MARK: (d) Suggest and Add at Once hand nothing over
            let suggest = try await capture(walk, mode: nil, solo: nil)
            check(conversations.outcome(suggest)?.found == nil && conversations.outcome(suggest)?.soloLine == nil && runs() - runsBefore == 2
                  && record(suggest)?.suggestions.contains { $0.kind == .card } == true,
                  "Solo: from a phone in Suggest (no Y2 fields), today's suggestions are offered, and nothing handed over")
            // Other words, so nothing is already on the board.
            let walkTwo = ["Okay, so, heading to the station now. The signup form on the site loses what you typed, I saw it twice.",
                           "Not great. We should add a monthly summary of the cards that went to agents.", "I should renew the shop's certificate before it lapses."]
            reads(walkTwo, [("fix", "Fix the signup form losing what you typed", ["signup form"]), ("idea", "A monthly summary of the cards that went to agents", ["monthly summary"]),
                            ("todo", "Renew the shop's certificate before it lapses", ["certificate"])])
            let add = try await capture(walkTwo, mode: "add")
            let added = (conversations.outcome(add)?.found ?? []).map { moments.outcome($0.id) }
            check(added.count == 3 && added.allSatisfy { $0?.state == "acted" && $0?.handedOver == nil } && runs() - runsBefore == 2,
                  "Solo: in Add at Once the three are added at once, and nothing is handed over")

            // MARK: (e) Two voices, a failed diarizer, under the start bar, a reason this Mac doesn't know: offered
            for hold in ["voices", "diarizer", "voice", "a-new-reason"] {
                let held = try await capture(walk, solo: nil, hold: hold)
                let outcome = conversations.outcome(held)
                check(outcome?.found == nil && outcome?.soloLine == AutoText.soloHeader(why: hold, mode: .auto) && runs() - runsBefore == 2,
                      "Solo: held as \(hold), it's offered as today, and says why: \(outcome?.soloLine ?? "none")")
            }

            // MARK: (f) An older phone's capture, even with the fields written in: offered
            let olderCapture = try await capture(walk, from: older.client)
            check(conversations.outcome(olderCapture)?.found == nil && record(olderCapture)?.soloJSON.isEmpty == true && runs() - runsBefore == 2,
                  "Solo: an older iPhone's capture with solo written in is read as today")

            // MARK: (g) What the Mac checks
            let other = try await capture(walk, others: [("Speaker 2", Array(repeating: "and then we could walk down to the harbour", count: 5).joined(separator: " "))])
            check(conversations.outcome(other)?.soloLine == AutoText.soloHeader(why: "transcript", mode: .auto) && conversations.outcome(other)?.found == nil,
                  "Solo: a capture whose transcript has another voice's 40 words is offered: \(conversations.outcome(other)?.soloLine ?? "none")")
            let unsure = ["Right, the walk home now.", "The export on the site drops the dates column."]
            reads(unsure, [("fix", "Fix the export dropping the dates column", ["dates column"])])
            let notSure = try await capture(unsure, others: [(SoloRule.unsureLabel, "Excuse me, sorry."), (SoloRule.unsureLabel, "Mind the step there.")])
            check(conversations.outcome(notSure)?.found?.count == 1 && llm.readingPrompts.last.map { !$0.contains("Excuse me") && !$0.contains("Mind the step") } == true,
                  "Solo: two Not sure who segments: read, and their sentences aren't in the reading's prompt")
            let call = ["Hey, how are you? Yeah, I'm on a walk.", "Did you get the deck? Okay, can you send me the numbers by Friday?", "Great. Talk to you later, bye."]
            let called = try await capture(call)
            check(conversations.outcome(called)?.soloLine == AutoText.soloHeader(why: "talking", mode: .auto),
                  "Solo: one side of a call is offered, as talking to someone: \(conversations.outcome(called)?.soloLine ?? "none") · \(conversations.outcome(called)?.state ?? "")")
            let talking = ["So, about the newsletter, I think we keep it short.", "The header needs a new photo."]
            llm.reply(to: "So, about the newsletter, I think we keep it short.", "TALKING")
            let talked = try await capture(talking)
            check(conversations.outcome(talked)?.soloLine == AutoText.soloHeader(why: "talking", mode: .auto) && conversations.outcome(talked)?.found == nil,
                  "Solo: the reading answering TALKING: offered, the same line")
            MeetingService.noteCall(at: Date().addingTimeInterval(-4.9 * 60))
            let onMac = try await capture(walk)
            check(conversations.outcome(onMac)?.soloLine == AutoText.soloHeader(why: "mac-call", mode: .auto) && conversations.outcome(onMac)?.found == nil,
                  "Solo: a meeting app held this Mac's microphone during it: offered, \(conversations.outcome(onMac)?.soloLine ?? "none")")
            AppDefaults.store.removeObject(forKey: MeetingService.callSpansKey)
            let third = try await pairPhone("Another iPhone", features: LinkFeatures.thisPhone)
            let fromThird = try await capture(walk, mode: "add", from: third.client)
            check(conversations.outcome(fromThird)?.soloLine == AutoText.soloHeader(why: "phone", mode: .add) && conversations.outcome(fromThird)?.found == nil,
                  "Solo: from a second iPhone the Mac hasn't let hand over, in Add at Once: not read, and the line says why")
            let prose = ["Okay, first thing, the onboarding again.", "The third screen's button is cut off on small phones."]
            llm.reply(to: prose[0], "I found a couple of things worth doing on the site.")
            let unread = try await capture(prose)
            check(conversations.outcome(unread)?.soloLine == AutoText.unreadFound && conversations.outcome(unread)?.found == nil,
                  "Solo: a reply it can't read: today's notes, and the line says so")
            let nothing = ["Just walking now.", "The river is high today."]
            let none = try await capture(nothing)
            check(conversations.outcome(none)?.soloLine == AutoText.nothingFound && conversations.outcome(none)?.found == nil,
                  "Solo: NONE: nothing made, and the line says so")
            let filePayload = ConversationPayload(started: Date().addingTimeInterval(-600), ended: Date().addingTimeInterval(-500),
                                                  segments: [TranscriptSegment(channel: .microphone, start: 0, end: 5, text: walk[0], speaker: "Speaker 1")],
                                                  speakers: ["Speaker 1": "You"], device: "iPhone", engine: "parakeet-v2", mode: "auto", solo: true, agreed: yes)
            conversations.receive(filePayload)
            await settled(filePayload.id)
            check(record(filePayload.id)?.soloJSON.isEmpty == true && conversations.outcome(filePayload.id)?.found == nil,
                  "Solo: the same capture in a Binders file is kept as today, its vouch dropped")

            // MARK: (h) A moment after musing joins its capture, with its own checks
            moments.ageForSelfTest(by: 3_600)
            func moment(_ text: String, id: UUID = UUID(), wake: Bool = false, conversation: UUID? = nil, alone: Bool? = nil, minutesAgo: Double = 4,
                        hold: String? = nil, fromTranscript: Bool? = nil, uncued: String? = nil, cue: String? = "need to") async throws -> CaptureOutcome? {
                let payload = MomentPayload(id: id, heard: Date().addingTimeInterval(-minutesAgo * 60), text: text, device: "iPhone", engine: "parakeet-v2",
                                            wake: wake, seconds: 2.5, cue: wake ? nil : cue, voice: 0.86, conversation: conversation ?? UUID(),
                                            adds: wake ? nil : MomentModes.everyKind, agreed: conversation == nil && hold == nil ? yes : nil,
                                            mode: "auto", autoHold: hold, alone: conversation == nil ? true : alone, fromTranscript: fromTranscript, uncued: uncued)
                let reply = try await phone.client.request(MomentPayload.method, payload.jsonObject(), timeout: 40) as? [String: Any]
                var outcome = (reply?["outcome"]).flatMap { CaptureOutcome.decodeEach([$0]).first }
                for _ in 0..<80 where outcome == nil || outcome?.state == "working" {
                    try? await Task.sleep(for: .milliseconds(250))
                    outcome = moments.outcome(id)
                }
                return outcome
            }
            /// The to-do the rules made of what was said, from its line ("Added to Website: <task>. …"), for the decision model.
            func task(_ outcome: CaptureOutcome?) -> String {
                let line = outcome?.line ?? ""
                guard let colon = line.range(of: ": ") else { return "" }
                let rest = line[colon.upperBound...]
                return String(rest.components(separatedBy: ". Not handed over").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            }
            let musing = UUID()
            let joinedText = "I need to fix the export dates on the website"
            standIn.set(joinedText, binder: ["Website": 0.95], agent: ["Quill": 0.62])
            let joinA = UUID(), joinB = UUID(), joinC = UUID()
            let a = try await moment(joinedText, id: joinA, conversation: musing)
            standIn.set(task(a), binder: ["Website": 0.95], agent: ["Quill": 0.62])
            check(a?.state == "acted" && a?.joins == musing && a?.line.hasSuffix(AutoText.joinsCapture) == true && a?.handedOver == nil,
                  "Solo: a moment said in a capture in Auto is added, and waits for its capture: \(a?.line ?? "none")")
            let galleryText = "I need to fix the gallery captions on the website", blogText = "I need to fix the blog's dates on the website"
            let b = try await moment(galleryText, id: joinB, conversation: musing, hold: MomentAgreement.Hold.voice)
            standIn.set(task(b), binder: ["Website": 0.95], agent: ["Quill": 0.62])
            let c = try await moment(blogText, id: joinC, conversation: musing)
            standIn.set(task(c), binder: ["Website": 0.95], agent: ["Quill": 0.62])
            let musingSaid = ["Thinking about the site again.", "I need to fix the export dates on the website.", "The rest can wait."]
            llm.reply(to: musingSaid[0], "NONE")
            _ = try await capture(musingSaid, id: musing, soloMoments: [joinA, joinB])
            let aAfter = moments.outcome(joinA), bAfter = moments.outcome(joinB), cAfter = moments.outcome(joinC)
            check(aAfter?.handedOver == CaptureOutcome.Handed.auto && aAfter?.joins == nil
                  && conversations.outcome(musing)?.found?.contains { $0.id == joinA && $0.joined == true } == true,
                  "Solo: its capture arrives only you, the moment in soloMoments: handed to Quill, and listed as joined: \(aAfter?.line ?? "none")")
            check(bAfter?.handedOver == nil && bAfter?.line.contains("it didn't sound enough like you") == true,
                  "Solo: one the iPhone held back for its own voice stays held back: \(bAfter?.line ?? "none")")
            check(cAfter?.handedOver == nil && cAfter?.line.hasSuffix(AutoText.joinedNotYours) == true, "Solo: one not in soloMoments: \(cAfter?.line ?? "none")")
            check(llm.readingPrompts.last.map { !$0.contains("export dates") } == true, "Solo: the moment said in it is left out of the reading's sentences")
            let voices = UUID(), joinD = UUID()
            let d = try await moment("I need to fix the press page's photos on the website", id: joinD, conversation: voices)
            standIn.set(task(d), binder: ["Website": 0.95], agent: ["Quill": 0.62])
            _ = try await capture(musingSaid, id: voices, solo: nil, hold: "voices", soloMoments: [joinD])
            check(moments.outcome(joinD)?.line.hasSuffix(AutoText.joinedNot(why: "voices")) == true && moments.outcome(joinD)?.handedOver == nil,
                  "Solo: its capture had someone else in it: \(moments.outcome(joinD)?.line ?? "none")")
            let lost = UUID()
            _ = try await moment("I need to fix the events page on the website", id: lost, conversation: UUID(), minutesAgo: 12 * 60 + 1)
            check(moments.outcome(lost)?.line.hasSuffix(AutoText.joinedNoCapture) == true && moments.outcome(lost)?.joins == nil,
                  "Solo: its capture never came within 12 hours: \(moments.outcome(lost)?.line ?? "none")")

            // MARK: (i) A capture kept for a moment: its vouch only
            let kept = UUID(), joinG = UUID()
            let g = try await moment("I need to fix the contact page's map on the website", id: joinG, conversation: kept)
            standIn.set(task(g), binder: ["Website": 0.95], agent: ["Quill": 0.62])
            _ = try await capture([], id: kept, soloMoments: [joinG], kept: true)
            check(record(kept)?.status == "trivial" && moments.outcome(joinG)?.handedOver == CaptureOutcome.Handed.auto,
                  "Solo: a capture kept for a moment, with no words: trivial, and its moment handed over")

            // MARK: (j) A "Binders, …" found in a capture's transcript: never started by R1, and both orders of arrival
            moments.ageForSelfTest(by: 3_600)
            let heardIn = UUID(), joinH = UUID()
            let pricing = "update the pricing table on the website"
            standIn.set(pricing, binder: ["Website": 0.99], agent: ["Quill": 0.99])
            let h = try await moment(pricing, id: joinH, wake: true, conversation: heardIn, fromTranscript: true, cue: nil)
            standIn.set(task(h), binder: ["Website": 0.99], agent: ["Quill": 0.99])
            check(h?.joins == heardIn && h?.handedOver == nil && card(h) == nil,
                  "Solo: found in the transcript, at 0.99: added, waits, not started by R1: \(h?.state ?? "none") · \(h?.line ?? "")")
            _ = try await capture(musingSaid, id: heardIn, soloMoments: [joinH])
            check(moments.outcome(joinH)?.handedOver == CaptureOutcome.Handed.auto && entry(joinH)?.origin == "solo",
                  "Solo: its capture arrives: handed over by Auto's rule, the log's origin solo: \(entry(joinH)?.origin ?? "none")")
            let readFirst = UUID(), joinI = UUID()
            let menus = "update the menu labels on the website"
            standIn.set(menus, binder: ["Website": 0.99], agent: ["Quill": 0.9])
            standIn.set("Update the menu labels on the website", binder: ["Website": 0.99], agent: ["Quill": 0.9])
            _ = try await capture(musingSaid, id: readFirst, soloMoments: [joinI])
            let i = try await moment(menus, id: joinI, wake: true, conversation: readFirst, fromTranscript: true, cue: nil)
            check(i?.handedOver == CaptureOutcome.Handed.auto, "Solo: the other order, the capture first: handed over as it's decided: \(i?.line ?? "none")")
            let heldIn = UUID(), joinJ = UUID()
            _ = try await capture(musingSaid, id: heldIn, solo: nil, hold: "voices", soloMoments: [joinJ])
            let j = try await moment("update the team photos on the website", id: joinJ, wake: true, conversation: heldIn, fromTranscript: true, cue: nil)
            check(j?.handedOver == nil && j?.state == "acted", "Solo: with its capture's hold voices: added, never handed over")

            // MARK: (k) Every hand-over from a capture takes a place among the five in ten minutes
            moments.ageForSelfTest(by: 3_600)
            let broken = ["The header logo looks blurry on phones.", "The footer links point to the old domain.", "The sidebar is way too wide on tablets.",
                          "The cookie banner covers the checkout button.", "The sitemap still lists deleted posts.", "The gallery crashes on slow connections.",
                          "The breadcrumbs vanish on the pricing page."]
            let fixes = [("Fix the blurry header logo on phones", "header logo"), ("Point the footer links at the new domain", "footer links"),
                         ("Narrow the sidebar on tablets", "sidebar"), ("Move the cookie banner off the checkout button", "cookie banner"),
                         ("Drop deleted posts from the sitemap", "sitemap"), ("Stop the gallery crashing on slow connections", "gallery"),
                         ("Bring back the breadcrumbs on the pricing page", "breadcrumbs")]
            reads(broken, fixes.map { ("fix", $0.0, [$0.1]) })
            for fix in fixes { standIn.set(fix.0, binder: ["Website": 0.95], agent: ["Quill": 0.80]) }
            let seven = try await capture(broken)
            let sevenFound = (conversations.outcome(seven)?.found ?? []).map { moments.outcome($0.id) }
            check(sevenFound.count == 7 && sevenFound.prefix(5).allSatisfy { $0?.handedOver == CaptureOutcome.Handed.auto }
                  && sevenFound.suffix(2).allSatisfy { $0?.handedOver == nil && $0?.waiting == CaptureOutcome.Waiting.give },
                  "Solo: of seven for Quill, not late, the first five are handed over and two wait for Give to: \(sevenFound.map { $0?.handedOver ?? $0?.waiting ?? "-" })")
            let lateText = "I need to fix the archive page on the website"
            standIn.set(lateText, binder: ["Website": 0.95], agent: ["Quill": 0.9])
            let late = try await moment(lateText, minutesAgo: 120)
            check(late?.handedOver == nil && late?.waiting == CaptureOutcome.Waiting.give, "Solo: a late moment then waits too: one count")
            let freshText = "I need to fix the search box on the website"
            standIn.set(freshText, binder: ["Website": 0.95], agent: ["Quill": 0.9])
            let fresh = try await moment(freshText, minutesAgo: 0)
            check(fresh?.handedOver == CaptureOutcome.Handed.auto, "Solo: one said on its own just now still goes: \(fresh?.line ?? "none")")

            // MARK: (m) Already on the board
            moments.ageForSelfTest(by: 3_600)
            _ = board.create(title: "Fix the export dates", binderID: website.id, by: .you)
            let already = ["Oh, and the export again.", "The export dates are still wrong."]
            reads(already, [("fix", "Fix the export dates", ["export dates"])])
            let alreadyID = try await capture(already)
            let alreadyItem = conversations.outcome(alreadyID)?.found?.first.flatMap { moments.outcome($0.id) }
            check(alreadyItem?.state == "nothing" && alreadyItem?.line == "Already on the Website board: Fix the export dates.",
                  "Solo: an item that's already an open card makes nothing: \(alreadyItem?.line ?? "none")")

            // MARK: (n) Stop All, Not Only Me, and a lower mode
            let stopAll = await act(first, "stop-all")
            let firstItems = (conversations.outcome(first)?.found ?? []).compactMap { card(moments.outcome($0.id)) }
            check(stopAll.ok && stopAll.message.hasPrefix("Stopped 2 runs from what you said at ") && firstItems.allSatisfy { $0.column == .backlog },
                  "Solo: Stop All stops both runs and puts their cards back in Backlog: \(stopAll.message)")
            let notOnlyMe = await act(first, "not-only-me")
            let firstStates = (conversations.outcome(first)?.found ?? []).map { moments.outcome($0.id)?.state ?? "none" }
            log.flush()
            let firstIDs = Set((conversations.outcome(first)?.found ?? []).map(\.id))
            check(notOnlyMe.ok && notOnlyMe.message.hasPrefix("Took back what Binders made from what you said at ") && firstStates.allSatisfy { $0 == "undone" }
                  && log.entries().contains { $0.event == "not-me" && $0.moment.map(firstIDs.contains) == true },
                  "Solo: Not Only Me takes back everything from it, and the log has not-me: \(firstStates)")
            let olderTry = await act(first, "stop-all", from: older.client)
            check(!olderTry.ok, "Solo: from an older iPhone, a capture's action is turned down: \(olderTry.message)")
            moments.ageForSelfTest(by: 3_600)
            let lowered = ["Late thought on the blog.", "The blog's archive page is broken."]
            reads(lowered, [("fix", "Fix the blog's broken archive page", ["archive page"])])
            standIn.set("Fix the blog's broken archive page", binder: ["Website": 0.95], agent: ["Quill": 0.9])
            llm.holdReading = true
            let loweredID = try await capture(lowered, wait: false)
            for _ in 0..<80 where !llm.readingPrompts.contains(where: { $0.contains("archive page is broken") }) { try? await Task.sleep(for: .milliseconds(100)) }
            let modeAct = await act(loweredID, "mode", mode: "add")
            llm.holdReading = false
            await settled(loweredID)
            let loweredItem = conversations.outcome(loweredID)?.found?.first.flatMap { moments.outcome($0.id) }
            check(modeAct.ok && loweredItem?.state == "acted" && loweredItem?.handedOver == nil,
                  "Solo: Add at Once sent for a capture not yet read: its item is added, not handed over: \(modeAct.message) · \(loweredItem?.line ?? "none")")

            // MARK: (o) A sentence kept without a cue
            moments.ageForSelfTest(by: 3_600)
            let uncuedText = "The export doesn't include the dates on the website"
            standIn.set(uncuedText, binder: ["Website": 0.95], agent: ["Quill": 0.70])
            standIn.set("Fix the export leaving out the dates", binder: ["Website": 0.95], agent: ["Quill": 0.70])
            let kept1 = try await moment(uncuedText, uncued: "fix", cue: nil)
            check(llm.classifyPrompts.last?.contains(MomentPrompts.fixTodo) == true && kept1?.handedOver == CaptureOutcome.Handed.auto,
                  "Solo: kept without a cue, the classify call is asked with fixes and it's handed to Quill: \(kept1?.line ?? "none")")
            let kept2 = try await moment("Nothing there works the way the old one did on the website", uncued: "fix", cue: nil)
            check(kept2?.state == "nothing" && kept2?.handedOver == nil, "Solo: the classify call reading it as none: nothing")

            // MARK: (p) Names, on an item's own sentences
            moments.ageForSelfTest(by: 3_600)
            let named = ["Back to the site.", "I should get Quill to look at the sync bug on the website.", "Quill could fix the footer links on the website in a second.",
                         "Something else entirely now."]
            let namedSentences = SoloPrompts.numbered(named)
            llm.reply(to: namedSentences[0].text, "ITEM: fix | Fix the sync bug on the website | 2 | Quill\nITEM: fix | Fix the footer links on the website | 3 | none\n"
                      + "ITEM: todo | Give the footer links to Hooky | 3 | none")
            standIn.set("Fix the sync bug on the website", binder: ["Website": 0.95], agent: ["Scribe": 0.9])
            standIn.set("Fix the footer links on the website", binder: ["Website": 0.95], agent: ["Quill": 0.9])
            let namedID = try await capture(named)
            let namedItems = (conversations.outcome(namedID)?.found ?? []).map { moments.outcome($0.id) }
            check(namedItems.count == 2 && namedItems.first??.handedOver == CaptureOutcome.Handed.auto && namedItems.first??.title == "Handed to Quill",
                  "Solo: \"I should get Quill to…\" hands it to Quill whatever the model's top: \(namedItems.first??.title ?? "none")")
            check(namedItems.last??.handedOver == nil && namedItems.last??.line.contains("Quill is only mentioned in it, not given the work.") == true,
                  "Solo: \"Quill could fix…\" is added, not handed over: \(namedItems.last??.line ?? "none"); a title naming Hooky made no item")

            // MARK: (s) More than 8 items: the rest offered
            let tenThings = [("The map on the contact page never loads.", "Fix the map on the contact page", "map on the contact"),
                             ("The chart on the stats page shows last year.", "Fix the chart on the stats page", "chart on the stats"),
                             ("The toast after saving stays up forever.", "Fix the toast after saving", "toast after saving"),
                             ("Tooltips cover the buttons in the editor.", "Fix the tooltips covering the editor's buttons", "Tooltips cover"),
                             ("The signup modal can't be closed on phones.", "Fix the signup modal on phones", "signup modal"),
                             ("The price slider jumps by ten.", "Fix the price slider's jumps", "price slider"),
                             ("Avatars come out squashed in comments.", "Fix the squashed avatars in comments", "Avatars come out"),
                             ("The new badge never goes away.", "Fix the new badge that never goes away", "new badge"),
                             ("The spinner keeps going after the upload ends.", "Fix the spinner after the upload ends", "spinner keeps"),
                             ("The stepper in checkout skips step two.", "Fix the stepper skipping step two in checkout", "stepper in checkout")]
            let many = tenThings.map(\.0)
            reads(many, tenThings.map { ("fix", $0.1, [$0.2]) })
            let manyID = try await capture(many)
            check(conversations.outcome(manyID)?.found?.count == 8 && conversations.outcome(manyID)?.line.hasSuffix(" · 2 more offered") == true
                  && record(manyID)?.suggestions.filter({ $0.kind == .card }).count == 2,
                  "Solo: ten things: eight go on, two are offered: \(conversations.outcome(manyID)?.line ?? "none")")

            // MARK: (t) A short capture is read; the same in Suggest is trivial
            let short = ["The search on the site never finds the old posts.", "I should fix that this week."]
            reads(short, [("fix", "Fix the site's search missing old posts", ["search on the site"])])
            let shortID = try await capture(short)
            let shortSuggest = try await capture(short, mode: nil, solo: nil)
            check(conversations.outcome(shortID)?.found?.count == 1 && record(shortSuggest)?.status == "trivial",
                  "Solo: a short capture that's only you is read; the same in Suggest is trivial, as today")

            // MARK: (u) The words
            let lines = ["print", "voices", "a-new-reason"].flatMap { [AutoText.soloWhy($0), AutoText.soloHeader(why: $0, mode: .auto), AutoText.macUnread(why: $0)] }
                + [AutoText.joinsCapture, AutoText.joinedNotYours, AutoText.joinedNoCapture, AutoText.joinedAutoOff, AutoText.notOnlyMeOnPhone,
                   AutoText.macSection(mode: .auto), AutoText.stopAllLine(2, at: "at 10:42"), AutoText.notOnlyMeLine(at: "at 10:42")]
            check(lines.allSatisfy { !$0.contains("!") && !$0.lowercased().contains("successfully") }, "Solo: no line has an exclamation mark or \"successfully\"")
        } catch {
            check(false, "Solo: the link failed: \(error.localizedDescription)")
        }
        registry.remove(quill.id)
    }
}

/// Stands in for the language model in the solo section: the reading's reply by the first sentence it was shown, fixed
/// notes, Website for the binder, no questions, and the classify call's reading of a sentence kept without a cue. It
/// keeps what it was asked, and can hold the reading back until told.
final class SoloLLMStandIn: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: String] = [:]
    private var _readingPrompts: [String] = []
    private var _notesPrompts: [String] = []
    private var _classifyPrompts: [String] = []
    private var _holdReading = false

    var model: String { "stand-in" }

    func reply(to first: String, _ reply: String) { lock.withLock { replies[first] = reply } }
    func replyFor(_ first: String) -> String? { lock.withLock { replies[first] } }
    var readingPrompts: [String] { lock.withLock { _readingPrompts } }
    var notesPrompts: [String] { lock.withLock { _notesPrompts } }
    var classifyPrompts: [String] { lock.withLock { _classifyPrompts } }
    var holdReading: Bool {
        get { lock.withLock { _holdReading } }
        set { lock.withLock { _holdReading = newValue } }
    }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        if system.hasPrefix("You read what the user said out loud") {
            lock.withLock { _readingPrompts.append(user) }
            while holdReading { try? await Task.sleep(for: .milliseconds(50)) }
            let first = user.components(separatedBy: "\n").first { $0.hasPrefix("[1] ") }.map { String($0.dropFirst(4)) } ?? ""
            return lock.withLock { replies[first] } ?? "NONE"
        }
        if system.hasPrefix("You write short notes") {
            lock.withLock { _notesPrompts.append(system) }
            // As a model following its prompt: Promises only when it was asked for them.
            return system.contains("## Promises") ? "# Walk thoughts\n\n## Summary\nThinking about the site and the week.\n\n## Promises\n- [ ] You — renew the domain\n"
                : "# Walk thoughts\n\n## Summary\nThinking about the site and the week.\n\n## Ideas\n- A weekly digest\n"
        }
        if system.contains("You sort one thing") {
            lock.withLock { _classifyPrompts.append(system) }
            if user.localizedCaseInsensitiveContains("doesn't include the dates") {
                return "KIND: todo\nBINDER: Website\nTEXT: Fix the export leaving out the dates\nDUE: none\nAGENT: none\nFITS: none"
            }
            if user.localizedCaseInsensitiveContains("nothing there works") {
                return "KIND: none\nBINDER: none\nTEXT: none\nDUE: none\nAGENT: none\nFITS: none"
            }
            return "KIND: todo\nBINDER: none\nTEXT: none\nDUE: none\nAGENT: none\nFITS: none"
        }
        if system.contains("You file a conversation") { return "BINDER: Website\nREASON: the site" }
        return "NONE"
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout)
    }

    func listModels() async throws -> [String] { [model] }

    func warmUp() async {}
}
