import XCTest
@testable import BindersKit

/// Which moments carry the iPhone's yes, from every source.
final class MomentAgreementTests: XCTestCase {
    private let consents = ["claude code": "4d1c", "pennant": ""]
    private let features: Set<String> = [MomentPayload.feature, MomentPayload.agreedFeature]

    private func heard(_ change: (inout MomentAgreement.Heard) -> Void = { _ in }) -> MomentAgreement.Heard {
        var heard = MomentAgreement.Heard(wake: true, engine: "parakeet-v2", voice: 0.83, startBar: 0.78)
        change(&heard)
        return heard
    }

    private func agreed(_ heard: MomentAgreement.Heard, features: Set<String>? = nil) -> [String: String]? {
        MomentAgreement.agreed(heard, macFeatures: features ?? self.features, consents: consents)
    }

    func testAWakeClipInYourVoiceAtTheStartBar() {
        XCTAssertEqual(agreed(heard()), ["claude code": "4d1c"], "the consents with a fingerprint")
        XCTAssertEqual(agreed(heard { $0.voice = 0.78 }), ["claude code": "4d1c"], "at the bar")
        XCTAssertNil(agreed(heard { $0.voice = 0.779 }), "0.001 under it")
    }

    func testEveryOtherSourceCarriesNone() {
        XCTAssertNil(agreed(heard { $0.startBar = nil }), "no start bar: Calibrate hasn't set one")
        XCTAssertNil(agreed(heard { $0.voice = nil }), "not scored")
        XCTAssertNil(agreed(heard { $0.conversation = UUID() }), "in a conversation")
        XCTAssertNil(agreed(heard { $0.checkedFirst = true }), "its first second checked, as in a conversation")
        XCTAssertNil(agreed(heard { $0.fromTranscript = true }), "from a transcript")
        XCTAssertNil(agreed(heard { $0.engine = "siri" }), "Tell Binders, Shortcuts, the Action Button")
        XCTAssertNil(agreed(heard { $0.engine = "Siri" }))
        XCTAssertNil(agreed(heard { $0.engine = "test" }))
        XCTAssertNil(agreed(heard { $0.wake = false }), "heard on its own")
        XCTAssertNil(agreed(heard { $0.otherAudioPlaying = true }), "with other audio playing")
        XCTAssertNil(agreed(heard(), features: [MomentPayload.feature]), "to a Mac without the feature")
        XCTAssertNil(MomentAgreement.agreed(heard(), macFeatures: features, consents: ["pennant": ""]), "none left with a fingerprint")
        XCTAssertNil(MomentAgreement.agreed(heard(), macFeatures: features, consents: [:]))
    }

    func testThePayloadCarriesIt() throws {
        let heard = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try MomentPayload.decode(Data(#"{"id":"5E2B9C1A-3F4D-4E6B-8A7C-1D2E3F4A5B6C","heard":"2026-10-20T14:42:05Z","text":"fix it","wake":true}"#.utf8))
        XCTAssertNil(old.agreed, "a moment from an iPhone before it")
        let new = MomentPayload(heard: heard, text: "fix it", wake: true, agreed: ["claude code": "4d1c"])
        XCTAssertEqual(try MomentPayload.decode(new.encoded()).agreed, ["claude code": "4d1c"])
        XCTAssertNil(try MomentPayload(heard: heard, text: "x").jsonObject()["agreed"], "nil isn't sent")
        XCTAssertEqual(MomentPayload.agreedFeature, "momentAgreed")
        XCTAssertTrue(LinkFeatures.thisPhone.contains("momentAgreed"))
    }

    // MARK: Auto

    private let autoMac: Set<String> = [MomentPayload.feature, MomentPayload.agreedFeature, MomentPayload.autoFeature]

    /// Heard on its own, in Auto, in your voice past the start bar.
    private func onItsOwn(_ change: (inout MomentAgreement.Heard) -> Void = { _ in }) -> MomentAgreement.Heard {
        heard {
            $0.wake = false
            $0.mode = .auto
            change(&$0)
        }
    }

    func testHeardOnItsOwnInAutoCarriesTheYes() {
        XCTAssertEqual(agreed(onItsOwn(), features: autoMac), ["claude code": "4d1c"], "the consents with a fingerprint")
        XCTAssertEqual(agreed(onItsOwn { $0.voice = 0.78 }, features: autoMac), ["claude code": "4d1c"], "at the bar")
        for mode in [MomentMode.suggest, .add] {
            XCTAssertNil(agreed(onItsOwn { $0.mode = mode }, features: autoMac), mode.rawValue)
        }
        XCTAssertNil(agreed(onItsOwn { $0.mode = nil }, features: autoMac), "no mode")
        XCTAssertNil(agreed(onItsOwn(), features: features), "a Mac that doesn't hand over in Auto")
        XCTAssertNil(agreed(onItsOwn(), features: [MomentPayload.feature, MomentPayload.autoFeature]), "nor one that doesn't read the yes")
        XCTAssertNil(agreed(onItsOwn { $0.conversation = UUID() }, features: autoMac), "in a conversation")
        XCTAssertNil(agreed(onItsOwn { $0.checkedFirst = true }, features: autoMac), "its first second checked")
        XCTAssertNil(agreed(onItsOwn { $0.fromTranscript = true }, features: autoMac), "a transcript")
        for engine in ["siri", "Siri", "test"] {
            XCTAssertNil(agreed(onItsOwn { $0.engine = engine }, features: autoMac), engine)
        }
        XCTAssertNil(agreed(onItsOwn { $0.otherAudioPlaying = true }, features: autoMac), "other audio playing")
        XCTAssertNil(agreed(onItsOwn { $0.voice = 0.779 }, features: autoMac), "under the start bar")
        XCTAssertNil(agreed(onItsOwn { $0.startBar = nil }, features: autoMac), "no start bar")
        XCTAssertNil(agreed(onItsOwn { $0.voice = nil }, features: autoMac), "not scored")
        // A "Binders, …" in Auto, as today.
        XCTAssertEqual(agreed(heard { $0.mode = .auto }, features: autoMac), ["claude code": "4d1c"])
        XCTAssertEqual(agreed(heard { $0.mode = .suggest }, features: features), ["claude code": "4d1c"])
        XCTAssertNil(agreed(heard { $0.mode = .auto; $0.conversation = UUID() }, features: autoMac))
    }

    func testWhyTheIPhoneHoldsItsYesBackInAuto() {
        XCTAssertNil(MomentAgreement.hold(onItsOwn(), macFeatures: autoMac), "everything holds")
        XCTAssertEqual(MomentAgreement.hold(onItsOwn { $0.startBar = nil }, macFeatures: autoMac), "calibrate")
        XCTAssertEqual(MomentAgreement.hold(onItsOwn { $0.otherAudioPlaying = true }, macFeatures: autoMac), "audio")
        XCTAssertEqual(MomentAgreement.hold(onItsOwn { $0.voice = 0.779 }, macFeatures: autoMac), "voice")
        XCTAssertEqual(MomentAgreement.hold(onItsOwn { $0.voice = nil }, macFeatures: autoMac), "voice", "not scored")
        XCTAssertEqual(MomentAgreement.hold(onItsOwn { $0.startBar = nil; $0.otherAudioPlaying = true }, macFeatures: autoMac), "calibrate", "first")
        XCTAssertNil(MomentAgreement.hold(onItsOwn { $0.mode = .suggest; $0.startBar = nil }, macFeatures: autoMac), "outside Auto")
        XCTAssertNil(MomentAgreement.hold(onItsOwn { $0.startBar = nil }, macFeatures: features), "to a Mac without momentAuto")
        XCTAssertEqual([MomentAgreement.Hold.calibrate, MomentAgreement.Hold.audio, MomentAgreement.Hold.voice], ["calibrate", "audio", "voice"])
    }
}

/// The payload's fields for Auto: Optional, sent only to a Mac that lists momentAuto, and read as today when missing.
final class MomentPayloadAutoTests: XCTestCase {
    private let heard = Date(timeIntervalSince1970: 1_792_431_731)

    func testTheNewFieldsRoundTrip() throws {
        let payload = MomentPayload(heard: heard, text: "I need to fix the login timeout on the website", device: "iPhone", engine: "parakeet-v2",
                                    wake: false, conversation: UUID(), adds: MomentModes.everyKind, agreed: ["claude code · app": "3f2a9c41d0e7b815"],
                                    mode: "auto", autoHold: nil, alone: true)
        XCTAssertEqual(try MomentPayload.decode(payload.encoded()), payload)
        XCTAssertEqual(try MomentPayload(jsonObject: payload.jsonObject()), payload)
        let object = try payload.jsonObject()
        XCTAssertEqual(object["mode"] as? String, "auto")
        XCTAssertEqual(object["alone"] as? Bool, true)
        XCTAssertNil(object["autoHold"], "nil isn't sent")
        var held = payload
        held.autoHold = "voice"
        held.agreed = nil
        XCTAssertEqual(try MomentPayload.decode(held.encoded()).autoHold, "voice")
    }

    func testAPayloadFromBeforeReadsAsToday() throws {
        let json = #"{"id":"5E2B9C1A-3F4D-4E6B-8A7C-1D2E3F4A5B6C","heard":"2026-10-20T14:42:05Z","text":"fix it","wake":true,"#
            + #""conversation":"0D7C1B2A-5E4F-4A3B-9C8D-7E6F5A4B3C2D","adds":["todo"],"agreed":{"claude code":"4d1c"}}"#
        let old = try MomentPayload.decode(Data(json.utf8))
        XCTAssertNil(old.mode)
        XCTAssertNil(old.autoHold)
        XCTAssertNil(old.alone)
        XCTAssertEqual(old.agreed, ["claude code": "4d1c"])
        let keys = try MomentPayload(heard: heard, text: "x").jsonObject().keys.sorted()
        XCTAssertEqual(keys, ["heard", "id", "text"], "none of the new fields when nil")
    }

    func testTheFeature() {
        XCTAssertEqual(MomentPayload.autoFeature, "momentAuto")
        XCTAssertTrue(LinkFeatures.thisPhone.contains(MomentPayload.autoFeature))
        // Lane W1's two features are about comments: the names can't clash (W1 isn't merged in this lane, so its words).
        XCTAssertFalse(["commentsAskFirst", "commentWakes"].contains(MomentPayload.autoFeature))
        XCTAssertNotEqual(MomentPayload.autoFeature, MomentPayload.agreedFeature)
        XCTAssertNotEqual(MomentPayload.autoFeature, MomentPayload.addsFeature)
    }
}

final class MomentStartBarTests: XCTestCase {
    func testTheStartBar() {
        let others = (0..<100).map { 0.2 + Double($0) / 1_000 }      // up to 0.299
        XCTAssertNil(MomentBench.startThreshold(others: Array(others.prefix(99)), notMe: [], momentThreshold: 0.6), "99 other clips aren't enough")
        XCTAssertEqual(MomentBench.startThreshold(others: others, notMe: [], momentThreshold: 0.6), 0.65, "at least the moment threshold and 0.05")
        XCTAssertEqual(MomentBench.startThreshold(others: others + [0.712], notMe: [], momentThreshold: 0.6), 0.72, "above the highest other voice")
        XCTAssertEqual(MomentBench.startThreshold(others: others, notMe: [0.801], momentThreshold: 0.6), 0.81, "and above your Not me's")
        XCTAssertEqual(MomentBench.startThreshold(others: others, notMe: [0.70], momentThreshold: 0.6), 0.71, "one step above, never at it")
        XCTAssertEqual(MomentBench.startThreshold(others: others, notMe: [0.999], momentThreshold: 0.6), 1, "at most 1")
        XCTAssertEqual(MomentBench.startThreshold(others: others, notMe: [], momentThreshold: 0.98), 1)
    }

    /// Calibrate offers the start bar on its own, so a voice threshold already at its suggestion (no Use button) can still
    /// get one, and a bar set from fewer clips can follow the bench.
    func testTheStartBarIsOfferedWithoutUse() {
        let others = (0..<300).map { 0.2 + Double($0) / 3_000 }      // up to 0.2997
        XCTAssertEqual(MomentBench.startBarOffer(current: nil, others: others, notMe: [], momentThreshold: 0.78), 0.83,
                       "none set, 300 clips: offered at the moment threshold and 0.05")
        XCTAssertNil(MomentBench.startBarOffer(current: 0.83, others: others, notMe: [], momentThreshold: 0.78), "already that bar: not offered")
        XCTAssertNil(MomentBench.startBarOffer(current: Double(Float(0.83).nextUp), others: others, notMe: [], momentThreshold: 0.78),
                     "as the iPhone keeps it, a hair over")
        XCTAssertEqual(MomentBench.startBarOffer(current: 0.83, others: others + [0.861], notMe: [], momentThreshold: 0.78), 0.87,
                       "a louder other voice since: offered again, above it")
        XCTAssertNil(MomentBench.startBarOffer(current: nil, others: Array(others.prefix(99)), notMe: [], momentThreshold: 0.78), "too few clips: none")
    }
}

final class AgentKindsTests: XCTestCase {
    private let claude = AgentProfile(name: "Claude Code · app", wake: .claudeCode(ClaudeCodeWake(repository: "/Users/sam/code/app")))
    private let pennant = AgentProfile(name: "Pennant", wake: .board)

    func testDefaultsByWake() {
        XCTAssertEqual(claude.workKinds, ["coding"])
        for tool in CLIAgent.allCases {
            XCTAssertEqual(AgentProfile(name: tool.name, wake: .cliAgent(CLIAgentWake(tool: tool, repository: "/r"))).workKinds, ["coding"], tool.name)
        }
        XCTAssertEqual(pennant.workKinds, [], "the others are your choice")
        XCTAssertEqual(AgentProfile(name: "Hook", wake: .webhook(url: "https://example.test")).workKinds, [])
        var chosen = claude
        chosen.kinds = []
        XCTAssertEqual(chosen.workKinds, [], "what you chose, even none")
    }

    func testWhatTheModelReads() {
        var errands = pennant
        errands.purpose = "Personal errands: appointments, email, bookings"
        errands.kinds = ["errands", "scheduling"]
        XCTAssertEqual(errands.modelDescription, "Personal errands: appointments, email, bookings", "what it's for alone, as on the bench")
        var kindsOnly = pennant
        kindsOnly.kinds = ["errands", "Podcast editing"]
        XCTAssertEqual(kindsOnly.modelDescription, "Kinds of work: errands, Podcast editing.")
        XCTAssertNil(pennant.modelDescription, "nothing says: not offered")
        XCTAssertEqual(claude.modelDescription, "code in the app repository", "the coding default")
    }

    func testWhatItsForInYourWords() {
        var typed = claude
        typed.purpose = "  the Binders app: bugs and features "
        XCTAssertTrue(typed.hasOwnPurpose)
        XCTAssertFalse(claude.hasOwnPurpose, "the coding default isn't")
        var kindsOnly = pennant
        kindsOnly.kinds = ["errands"]
        XCTAssertFalse(kindsOnly.hasOwnPurpose, "nor kinds alone")
        var blank = pennant
        blank.purpose = " \n "
        XCTAssertFalse(blank.hasOwnPurpose)
    }

    func testYourOwnWords() {
        XCTAssertEqual(AgentKinds.presets.map(\.id), ["coding", "writing", "research", "outreach", "scheduling", "errands", "bookkeeping", "design"])
        XCTAssertEqual(AgentKinds.own("  Podcast editing, photos ,, photos, Coding"), ["Podcast editing", "photos"], "trimmed, once each, no preset again")
        XCTAssertEqual(AgentKinds.own(String(repeating: "x", count: 50)).first?.count, 40, "at most 40 characters")
        XCTAssertEqual(AgentKinds.own((1...12).map { "kind \($0)" }.joined(separator: ",")).count, 8, "at most 8")
        XCTAssertEqual(AgentKinds.kinds(presets: ["research", "coding"], own: "photos, writing"), ["coding", "writing", "research", "photos"],
                       "presets in their order, a typed preset ticked, then your words")
        XCTAssertEqual(AgentKinds.ticked(["coding", "photos"]), ["coding"])
        XCTAssertEqual(AgentKinds.ownText(["coding", "photos", "Podcasts"]), "photos, Podcasts")
        XCTAssertEqual(AgentKinds.summary(["coding", "research"]), "coding, research")
        XCTAssertNil(AgentKinds.summary([]))
        XCTAssertNil(AgentKinds.text([]))
    }

    func testEveryOldKindDecodesWithoutThemAndRoundTripsWithThem() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "agents-every-old-kind", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let read = try AgentFile.decode(data)
        XCTAssertEqual(read.file.agents.count, 5)
        XCTAssertTrue(read.file.agents.allSatisfy { $0.kinds == nil && $0.autoStart == nil }, "an agents.json from before has neither")
        XCTAssertEqual(try read.file.encoded(), data, "and saves byte for byte as it was")
        var file = read.file
        for index in file.agents.indices {
            file.agents[index].kinds = ["coding", "Podcasts"]
            file.agents[index].autoStart = true
        }
        let again = try AgentFile.decode(file.encoded()).file
        XCTAssertTrue(again.agents.allSatisfy { $0.kinds == ["coding", "Podcasts"] && $0.autoStart == true }, "both set, both kept")
    }

    func testOldAgentsDecodeWithoutThem() throws {
        let old = #"{"id":"6E1B6C2A-1F43-4C59-9F5E-2B4E8C6D7A10","isEnabled":true,"name":"Pennant","report":"mcp","wake":{"board":{}}}"#
        let agent = try JSONDecoder().decode(AgentProfile.self, from: Data(old.utf8))
        XCTAssertNil(agent.kinds)
        XCTAssertNil(agent.autoStart)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(agent), as: UTF8.self), old, "saved again, no new keys")
        var both = agent
        both.kinds = ["errands", "Podcasts"]
        both.autoStart = true
        let again = try JSONDecoder().decode(AgentProfile.self, from: encoder.encode(both))
        XCTAssertEqual(again.kinds, ["errands", "Podcasts"])
        XCTAssertEqual(again.autoStart, true)
    }
}

final class StartConsentTests: XCTestCase {
    func testTheFingerprintIsUnchangedWithoutStarts() {
        var claude = AgentProfile(name: "Claude Code", wake: .claudeCode(ClaudeCodeWake(repository: "/Users/sam/app")))
        XCTAssertEqual(AgentConsent.fingerprint(claude, reads: .nothing), "0141475ff89a46bc", "pinned")
        XCTAssertEqual(AgentConsent.fingerprint(claude, reads: .nothing, startsOnItsOwn: false), "0141475ff89a46bc")
        claude.autoStart = true
        claude.kinds = ["coding", "Podcasts"]
        XCTAssertEqual(AgentConsent.fingerprint(claude, reads: .nothing), "0141475ff89a46bc",
                       "the file's switch doesn't change it: an old iPhone isn't asked again because of it")
        let starts = AgentConsent.fingerprint(claude, reads: .nothing, startsOnItsOwn: true)
        XCTAssertNotEqual(starts, "0141475ff89a46bc", "with starts, a yes given before doesn't count")
        XCTAssertEqual(starts.count, 16)
    }

    func testTheDisclosureSaysSoOnlyWhenItStarts() {
        let plain = AgentConsent.disclosure(name: "Claude Code", wakes: "claudeCode", sendsTo: "Anthropic", vendor: "Anthropic", addsContext: true,
                                            contextFrom: "notes and meetings", mayAct: false)
        XCTAssertEqual(plain, AgentConsent.disclosure(name: "Claude Code", wakes: "claudeCode", sendsTo: "Anthropic", vendor: "Anthropic", addsContext: true,
                                                      contextFrom: "notes and meetings", mayAct: false, startsOnItsOwn: false))
        XCTAssertFalse(plain.contains("without asking"))
        let starts = AgentConsent.disclosure(name: "Claude Code", wakes: "claudeCode", sendsTo: "Anthropic", vendor: "Anthropic", addsContext: true,
                                             contextFrom: "notes and meetings", mayAct: false, startsOnItsOwn: true)
        XCTAssertTrue(starts.contains("Binders may also hand it a card without asking, when a “Binders, …” you say in your voice is clearly its work."))
        XCTAssertTrue(starts.hasSuffix("Nothing else from your binders goes with it."))
    }

    func testAutosYesIsAskedOnceMore() {
        let claude = AgentProfile(name: "Claude Code", wake: .claudeCode(ClaudeCodeWake(repository: "/Users/sam/app")))
        let plain = AgentConsent.fingerprint(claude, reads: .nothing)
        let starts = AgentConsent.fingerprint(claude, reads: .nothing, startsOnItsOwn: true)
        let auto = AgentConsent.fingerprint(claude, reads: .nothing, startsOnItsOwn: true, auto: true)
        XCTAssertNotEqual(auto, starts, "a yes given to the start sentence alone doesn't count for Auto mode")
        XCTAssertNotEqual(auto, plain)
        XCTAssertEqual(auto.count, 16)
        XCTAssertEqual(AgentConsent.fingerprint(claude, reads: .nothing, auto: true), plain, "without starts, auto changes nothing")
        XCTAssertEqual(plain, "0141475ff89a46bc", "every other fingerprint as it was")
        XCTAssertEqual(starts, AgentConsent.fingerprint(claude, reads: .nothing, startsOnItsOwn: true, auto: false))
    }

    func testTheDisclosureNamesAutoOnlyForAAutoModeStart() {
        func disclosure(starts: Bool?, auto: Bool?) -> String {
            AgentConsent.disclosure(name: "Claude Code", wakes: "claudeCode", sendsTo: "Anthropic", vendor: "Anthropic", addsContext: true,
                                    contextFrom: "notes and meetings", mayAct: false, startsOnItsOwn: starts, autoModeStart: auto)
        }
        let auto = disclosure(starts: true, auto: true)
        XCTAssertTrue(auto.contains(" " + AgentConsent.autoModeStartSentence + " Nothing else from your binders goes with it."), auto)
        XCTAssertFalse(auto.contains(AgentConsent.startSentence), "the Auto sentence holds the start sentence's case")
        XCTAssertTrue(auto.hasSuffix("Nothing else from your binders goes with it."))
        XCTAssertEqual(disclosure(starts: true, auto: false), disclosure(starts: true, auto: nil), "without it, R1's sentence, as today")
        XCTAssertTrue(disclosure(starts: true, auto: nil).contains(" " + AgentConsent.startSentence + " Nothing else"))
        XCTAssertFalse(disclosure(starts: false, auto: nil).contains("without asking"))
        XCTAssertEqual(AgentConsent.autoModeStartSentence, "Binders may also hand it a card without asking: when a “Binders, …” you say in your voice is "
                       + "clearly its work, and, while this iPhone is in Auto, when something you say on your own looks like its work, even hours later, "
                       + "with your words.")
        AutoTextTests.assertPlain(AgentConsent.autoModeStartSentence)
    }

    func testWhatGoesHereReachesTheLLMOnlyWhenSet() {
        let plain = ConversationPrompts.BinderHint(name: "Website", titles: ["Pricing page"])
        let about = ConversationPrompts.BinderHint(name: "Website", titles: ["Pricing page"], about: "the website: pages, pricing")
        XCTAssertEqual(plain.line, "- Website")
        XCTAssertEqual(about.line, "- Website: the website: pages, pricing")
        XCTAssertTrue(MomentPrompts.classifySystemPrompt(binders: [plain]).contains("\n- Website\n  - Pricing page"), "as before")
        XCTAssertTrue(MomentPrompts.classifySystemPrompt(binders: [about]).contains("\n- Website: the website: pages, pricing\n  - Pricing page"))
        XCTAssertTrue(ConversationPrompts.routingUserPrompt(binders: [about], title: "t", summary: "s").contains("- Website: the website: pages, pricing\n  - Pricing page"))
    }
}
