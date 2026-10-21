import XCTest
@testable import BindersKit

/// Auto's rule for what comes from a capture that's only you (RouteOrigin.solo), and the rest of lane Y2's kit: the
/// words, the notification, the yes, the link's fields and flag, the prompts and the bench.
final class SoloAutoRuleTests: XCTestCase {
    private let tev1 = RouterBands(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33, auto: 0.60)
    private let now = Date()
    private let agent = "Scribe"

    /// A base that hands over: a to-do read from a capture vouched as only you, the Mac's three yeses, the iPhone's yes
    /// for the "solo" fingerprint, Tev1's bands, the model's top Scribe at 0.70.
    private func check(_ change: (inout RouterRules.StartCheck, inout RouterRules.AutoCheck) -> Void = { _, _ in }) -> RouterRules.NotStarted? {
        let key = RouterRules.PhoneCheck.consentKey(agent)
        var check = RouterRules.StartCheck(agent: agent, how: .model, startsOnItsOwn: true, hasOwnPurpose: true, draftsFirst: true, checksBoard: false,
                                           bands: tev1, numbersMatch: true, modelTop: RankedOption(key: agent, p: 0.70), takesBinder: true, takerNow: true,
                                           leftOutTakesBinder: false, origin: .solo, kind: .todo,
                                           phone: RouterRules.PhoneCheck(wake: false, engine: "parakeet-v2", conversation: UUID(), kind: nil, adds: nil,
                                                                         heard: now.addingTimeInterval(-300), now: now, agreed: [key: "with solo"], key: key,
                                                                         fingerprint: "with starts", autoFingerprint: "with auto", soloFingerprint: "with solo"),
                                           wouldWake: true, wakeable: true)
        var auto = RouterRules.AutoCheck(mode: .auto, phoneAllowed: true, levelNow: 0.60, startsInAuto: true, vouched: true, startsInSolo: true)
        change(&check, &auto)
        return RouterRules.mayHandOver(check, auto: auto)
    }

    func testAnItemFromAVouchedCapture() {
        XCTAssertNil(check(), "a to-do")
        XCTAssertNil(check { c, _ in c.kind = .idea }, "an idea")
        XCTAssertEqual(check { _, y in y.vouched = false }, .notOnItsOwn, "not vouched")
        XCTAssertEqual(check { _, y in y.mode = .add }, .notAuto)
        XCTAssertEqual(check { c, _ in c.phone?.engine = "siri" }, .notOnItsOwn)
    }

    func testY1sOriginsAsTheyWere() {
        XCTAssertEqual(check { c, _ in c.origin = .auto }, .notOnItsOwn, "a .auto moment with a conversation")
        XCTAssertNil(check { c, _ in c.origin = .auto; c.phone?.conversation = nil; c.phone?.agreed = [RouterRules.PhoneCheck.consentKey(self.agent): "with auto"] })
        XCTAssertNil(check { c, _ in c.origin = .auto; c.phone?.conversation = nil }, "the newer yes holds the older")
        XCTAssertEqual(check { c, _ in c.origin = .transcript }, .origin)
        XCTAssertEqual(check { c, _ in c.origin = .conversation }, .origin)
    }

    func testAJoinedMomentHeldOnThePhone() {
        XCTAssertEqual(check { _, y in y.hold = MomentAgreement.Hold.voice }, .heldOnPhone, "its own voice under the bar: the critics' case")
    }

    func testTheYesForCaptures() {
        XCTAssertEqual(check { _, y in y.startsInSolo = false }, .switchBeforeSolo)
        XCTAssertEqual(check { c, _ in c.phone?.agreed = [RouterRules.PhoneCheck.consentKey(self.agent): "with auto"] }, .noYes, "only Y1's yes")
        XCTAssertNil(check { c, y in c.origin = .auto; c.phone?.conversation = nil; y.startsInSolo = false },
                     "what's said on its own keeps going on Y1's yes")
    }

    func testTheLimitTakesEveryHandOverFromACapture() {
        XCTAssertNil(check { _, y in y.lateRecently = 4 })
        XCTAssertEqual(check { _, y in y.lateRecently = 5 }, .tooManyAtOnce, "five not late fill it")
        XCTAssertNil(check { c, y in
            c.origin = .auto; c.phone?.conversation = nil; c.phone?.heard = self.now.addingTimeInterval(-30); y.lateRecently = 5
        }, "a fresh moment then still goes")
    }

    func testTheNamesForAnItem() {
        XCTAssertEqual(check { _, y in y.onlyMentioned = true }, .onlyMentioned)
        XCTAssertEqual(check { _, y in y.heard = ["Hooky"] }, .heardAnother)
        XCTAssertNil(check { c, y in c.named = ["Scribe"]; y.heard = ["Scribe"]; c.modelTop = RankedOption(key: "Hooky", p: 0.9) }, "a name decides")
    }

    func testStartNeverTakesIt() {
        for origin in [RouteOrigin.solo, .transcript] {
            var check = RouterRules.StartCheck(agent: agent, how: .model, startsOnItsOwn: true, hasOwnPurpose: true, draftsFirst: true,
                                               checksBoard: false, bands: tev1, numbersMatch: true, modelTop: RankedOption(key: agent, p: 0.99),
                                               takesBinder: true, takerNow: true, leftOutTakesBinder: false, origin: origin, kind: .todo, wouldWake: true)
            check.phone = nil
            XCTAssertEqual(RouterRules.mayStart(check), .origin, origin.rawValue)
        }
        XCTAssertEqual(Set(RouterRules.NotStarted.allCases.map(\.rawValue)).count, RouterRules.NotStarted.allCases.count)
    }

    func testTheSameThingTwice() {
        let decided = now.addingTimeInterval(-2 * 3_600)
        XCTAssertTrue(AutoRules.isRepeat(decided: decided, heard: now.addingTimeInterval(-10 * 60), now: now, heardNow: now))
        XCTAssertFalse(AutoRules.isRepeat(decided: decided, heard: now.addingTimeInterval(-31 * 60), now: now, heardNow: now))
        XCTAssertTrue(AutoRules.isRepeat(decided: now.addingTimeInterval(-10 * 60), heard: nil, now: now, heardNow: now))
    }

    func testASiriMomentNeverGetsAYes() {
        let heard = MomentAgreement.Heard(wake: false, engine: "siri", voice: 0.9, startBar: 0.8, mode: .auto)
        XCTAssertNil(MomentAgreement.agreed(heard, macFeatures: [MomentPayload.agreedFeature, MomentPayload.autoFeature], consents: ["scribe": "x"]))
        XCTAssertEqual(check { c, y in c.origin = .auto; c.phone?.engine = "siri"; y.mode = nil }, .notAuto)
    }
}

final class SoloWordsTests: XCTestCase {
    private func clean(_ line: String, file: StaticString = #filePath, line number: UInt = #line) {
        XCTAssertFalse(line.contains("!"), line, file: file, line: number)
        XCTAssertFalse(line.lowercased().contains("successfully"), line, file: file, line: number)
        XCTAssertFalse(line.isEmpty, file: file, line: number)
    }

    func testEveryLine() {
        let words = ["print", "calibrate", "diarizer", "audio", "call", "continues", "voice", "voices", "dialogue", "unsure", "parts", "transcript",
                     "talking", "mac-call", "phone", "a-new-reason"]
        for word in words {
            clean(AutoText.soloWhy(word))
            clean(AutoText.soloHeader(why: word, mode: .auto))
            clean(AutoText.joinedNot(why: word))
            clean(AutoText.macUnread(why: word))
        }
        XCTAssertEqual(AutoText.soloWhy("a-new-reason"), "your iPhone didn't hear it as only you")
        XCTAssertEqual(AutoText.soloHeader(why: "voices", mode: .auto), "Someone else spoke in it, so it was offered, not handed over.")
        XCTAssertEqual(AutoText.soloHeader(why: "voices", mode: .add), "Someone else spoke in it, so it was offered, not added at once.")
        XCTAssertEqual(AutoText.joinedNot(why: "voices"), "Not handed over: someone else spoke in the capture it was in.")
        for line in [AutoText.joinsCapture, AutoText.joinedNotYours, AutoText.joinedAutoOff, AutoText.joinedNoCapture, AutoText.nothingFound,
                     AutoText.unreadFound, AutoText.notOnlyMeOnPhone, AutoText.macSection(mode: .auto), AutoText.soloRead(mode: .add),
                     AutoText.alreadyThere(binder: "Website", title: "Fix the export dates"), AutoText.stopAllLine(1, at: "at 10:42"),
                     AutoText.stopAllLine(2, at: "at 10:42"), AutoText.notOnlyMeLine(at: "at 10:42"), AutoText.moreFound(8),
                     AutoText.captureLine(binder: "Website", title: "Login, digest and the domain", handed: 2, added: 1, offered: 8)] {
            clean(line)
        }
        XCTAssertEqual(AutoText.captureLine(binder: "Website", title: "Login, digest and the domain", handed: 2, added: 1, offered: 0),
                       "Filed in Website: Login, digest and the domain · 2 handed to agents · 1 added")
        XCTAssertEqual(AutoText.stopAllLine(1, at: "at 10:42"), "Stopped 1 run from what you said at 10:42. Its card waits in Backlog; your to-do stays.")
        let switchLine = AutoText.notHandedOver(.switchBeforeSolo, agent: "Scribe", binder: "Website")
        XCTAssertEqual(switchLine, "Not handed over: Scribe was let start on its own before Auto mode read what you think out loud, so what it reads from a capture takes your tap until you say yes for that too (Settings → Agents on your Mac).")
        XCTAssertEqual(AutoText.notHandedOver(.noYes, agent: "Scribe", binder: "Website", fromCapture: true),
                       "Not handed over: you haven't said yes to Scribe on your iPhone since Auto mode read what you think out loud. Give to asks.")
    }

    func testTheCardAndTheNote() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let details = AutoText.soloDetails(said: "The login on the site times out way too fast.", heard: now, now: now, idea: false, calendar: calendar,
                                           locale: Locale(identifier: "en_US"))
        XCTAssertTrue(details.hasPrefix("“The login on the site times out way too fast.”\n\nSaid to your iPhone at "))
        XCTAssertTrue(details.hasSuffix(", while you thought out loud."))
        XCTAssertTrue(AutoText.soloDetails(said: "x", heard: now.addingTimeInterval(-3 * 86_400), now: now, idea: true).hasSuffix(AutoText.ideaAsk))
        let note = AutoText.note(agent: "Scribe", idea: false, asked: false, named: false, heard: now, now: now, solo: true)
        XCTAssertTrue(note.hasPrefix("Binders handed this to Scribe without asking: you thought it out loud to your iPhone at "))
        XCTAssertTrue(note.contains(", with no one else talking, while it was in Auto, and it looks like Scribe's work. Auto skips only Binders' own Give to question"))
        let idea = AutoText.note(agent: "Scribe", idea: true, asked: false, named: true, heard: now, now: now, solo: true)
        XCTAssertTrue(idea.hasPrefix("Binders handed this to Scribe without asking, to look into and plan: you thought it out loud"))
        XCTAssertTrue(idea.contains("and you named Scribe."))
        let joined = AutoText.note(agent: "Scribe", idea: false, asked: true, named: false, heard: now, now: now, solo: true, joined: true)
        XCTAssertTrue(joined.contains("you said it to Binders on your iPhone at "))
        XCTAssertTrue(joined.contains(", with no one else talking, while it was in Auto"))
        // Y1's note is unchanged.
        XCTAssertTrue(AutoText.note(agent: "Scribe", idea: false, asked: false, named: false, heard: now, now: now)
            .contains("you said it on your own to your iPhone"))
    }

    func testTheCapturesNotification() {
        let things = [LockScreenText.FoundThing(title: "Fix the site's login timing out too fast", agent: "Codex · site"),
                      LockScreenText.FoundThing(title: "A weekly digest of what the agents did", agent: "Claude Code · app"),
                      LockScreenText.FoundThing(title: "Renew the domain before it lapses", binder: "Personal")]
        let withWords = LockScreenText.captureFound(things, offered: 0, time: "10:42", showsWords: true)
        XCTAssertEqual(withWords?.title, "Handed 2 things to agents")
        XCTAssertEqual(withWords?.body, "Codex · site: Fix the site's login timing out too fast. Claude Code · app: A weekly digest of what the agents did. "
                       + "Added to Personal: Renew the domain before it lapses.")
        let without = LockScreenText.captureFound(things, offered: 2, time: "10:42", showsWords: false)
        XCTAssertEqual(without?.body, "From what you said at 10:42: 1 to Codex · site, 1 to Claude Code · app, 1 added to Personal. 2 more offered.")
        var waiting = things
        waiting[1].waits = true
        XCTAssertEqual(LockScreenText.captureFound(waiting, offered: 0, time: "10:42", showsWords: false)?.title, "Handed 1 thing to Codex · site")
        XCTAssertTrue(LockScreenText.captureFound(waiting, offered: 0, time: "10:42", showsWords: true)?.body
            .hasSuffix("1 waits for you: Give to, or Wake Now on your Mac.") == true)
        XCTAssertEqual(LockScreenText.captureFound(things.map { LockScreenText.FoundThing(title: $0.title, binder: "Website") }, offered: 0, time: "10:42",
                                                   showsWords: false)?.title, "Added 3 things from what you said")
        XCTAssertNil(LockScreenText.captureFound([things[0]], offered: 0, time: "10:42", showsWords: true), "one thing only: Y1's own")
        XCTAssertEqual(LockScreenText.foundPlaceholder, "%u from what you said")
        XCTAssertFalse(MomentNotice.rings(capture: UUID(), decidedNow: true), "a capture's item never rings")
        XCTAssertTrue(MomentNotice.rings(capture: nil, decidedNow: true))
        XCTAssertFalse(MomentNotice.rings(capture: nil, decidedNow: false))
    }
}

final class SoloLinkTests: XCTestCase {
    func testThePayloadsFields() throws {
        let moment = UUID()
        let payload = ConversationPayload(started: Date(timeIntervalSince1970: 0), ended: Date(timeIntervalSince1970: 60), segments: [], device: "iPhone",
                                          engine: "parakeet-v2", mode: "auto", solo: true, soloHold: nil, agreed: ["scribe": "fp"], voice: 0.84,
                                          otherSpeech: 0.9, soloMoments: [moment], keptForMoment: true)
        XCTAssertEqual(try ConversationPayload.decode(payload.encoded()), payload)
        let today = #"{"id":"3A02EC85-6FEF-4AF9-9231-14713C1AEB2F","started":"2026-10-19T09:42:00Z","ended":"2026-10-19T09:52:10Z","segments":[],"speakers":{},"device":"iPhone","engine":"parakeet-v2"}"#
        let old = try ConversationPayload.decode(Data(today.utf8))
        XCTAssertNil(old.mode)
        XCTAssertNil(old.solo)
        XCTAssertNil(old.soloMoments)
        XCTAssertNil(try old.jsonObject()["solo"], "nil is left out")
        XCTAssertEqual(ConversationPayload.soloFeature, "soloAuto")
        XCTAssertTrue(LinkFeatures.thisPhone.contains("soloAuto"))
        XCTAssertFalse(LinkFeatures.firstPhone.contains("soloAuto"))
        XCTAssertFalse(LinkFeatures.phone(nil).contains("soloAuto"))
        for other in [MomentPayload.autoFeature, LinkFeatures.commentWakes, LinkFeatures.commentsAskFirst] {
            XCTAssertNotEqual(ConversationPayload.soloFeature, other)
        }
        XCTAssertNil(SoloVouch(old, device: nil), "nothing of Y2's: no vouch")
        let vouch = try XCTUnwrap(SoloVouch(payload, device: "phone-1"))
        XCTAssertTrue(vouch.vouched)
        XCTAssertEqual(SoloVouch.decode(vouch.json), vouch)
    }

    func testInPartsCarriesOnlyTheModeAndWhy() {
        let segments = (0..<40).map { TranscriptSegment(channel: .microphone, start: Double($0), end: Double($0) + 1,
                                                        text: String(repeating: "word ", count: 200), speaker: "Speaker 1") }
        let payload = ConversationPayload(started: Date(), ended: Date(), segments: segments, device: "iPhone", engine: "parakeet-v2", mode: "auto",
                                          solo: true, agreed: ["scribe": "fp"], soloMoments: [UUID()])
        let parts = payload.parts(maxBytes: 8_000)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertEqual(part.mode, "auto")
            XCTAssertEqual(part.soloHold, "parts")
            XCTAssertNil(part.solo)
            XCTAssertNil(part.agreed)
            XCTAssertNil(part.soloMoments)
        }
    }

    func testTheMomentsAndTheOutcomesFields() throws {
        let moment = MomentPayload(heard: Date(timeIntervalSince1970: 0), text: "x", fromTranscript: true, uncued: "fix")
        XCTAssertEqual(try MomentPayload.decode(moment.encoded()), moment)
        let y1 = try MomentPayload.decode(Data(#"{"id":"3A02EC85-6FEF-4AF9-9231-14713C1AEB2F","heard":"2026-10-19T09:42:00Z","text":"x","mode":"auto"}"#.utf8))
        XCTAssertNil(y1.fromTranscript)
        XCTAssertNil(y1.uncued)
        let outcome = CaptureOutcome(id: UUID(), state: "filed", line: "Filed", found: [.init(id: UUID(), heard: Date(timeIntervalSince1970: 0), said: "x",
                                                                                             kind: "todo", joined: true)],
                                     soloLine: "Someone else spoke in it", joins: UUID())
        XCTAssertEqual(try JSONDecoder().decode(CaptureOutcome.self, from: JSONEncoder().encode(outcome)), outcome)
        let older = try JSONDecoder().decode(CaptureOutcome.self, from: Data(#"{"id":"3A02EC85-6FEF-4AF9-9231-14713C1AEB2F","state":"filed","line":"x"}"#.utf8))
        XCTAssertNil(older.found)
        XCTAssertNil(older.joins)
    }

    func testTheYesForCaptures() {
        let agent = AgentProfile(name: "Scribe", wake: .board)
        let r1 = AgentConsent.fingerprint(agent, reads: AgentReads(), startsOnItsOwn: true)
        let y1 = AgentConsent.fingerprint(agent, reads: AgentReads(), startsOnItsOwn: true, auto: true)
        let y2 = AgentConsent.fingerprint(agent, reads: AgentReads(), startsOnItsOwn: true, auto: true, solo: true)
        XCTAssertEqual(Set([r1, y1, y2]).count, 3)
        XCTAssertEqual(AgentConsent.fingerprint(agent, reads: AgentReads(), startsOnItsOwn: true, auto: false, solo: true), r1, "solo needs auto")
        let with = AgentConsent.disclosure(name: "Scribe", wakes: "board", startsOnItsOwn: true, autoModeStart: true, soloStart: true)
        XCTAssertTrue(with.contains(AgentConsent.soloStartSentence))
        XCTAssertFalse(AgentConsent.disclosure(name: "Scribe", wakes: "board", startsOnItsOwn: true, autoModeStart: true).contains(AgentConsent.soloStartSentence))
    }
}

final class SoloPromptChangesTests: XCTestCase {
    func testTheGatesInstructions() {
        XCTAssertTrue(MomentGate.uncuedInstructions.contains("- todo: something they need or mean to do, or a problem they noticed in something they make or look after, such as their site, their app or their docs, that needs fixing."))
        XCTAssertTrue(MomentGate.uncuedInstructions.contains("a complaint about something other people make, media playing"))
        XCTAssertTrue(MomentGate.instructions.contains("- todo: something they need or mean to do.\n"))
        XCTAssertTrue(MomentGate.confirmsUncued(.todo, uncued: "fix"))
        XCTAssertTrue(MomentGate.confirmsUncued(.todo, uncued: "todo"))
        XCTAssertTrue(MomentGate.confirmsUncued(.idea, uncued: "idea"))
        for kind in [MomentKind.note, .question, .status, .none] {
            XCTAssertFalse(MomentGate.confirmsUncued(kind, uncued: "fix"))
            XCTAssertFalse(MomentGate.confirmsUncued(kind, uncued: "idea"))
        }
        XCTAssertFalse(MomentGate.confirmsUncued(.todo, uncued: "idea"))
        XCTAssertFalse(MomentGate.confirmsUncued(.idea, uncued: "fix"))
    }

    func testTheClassifyAndTheNotesPrompts() {
        let with = MomentPrompts.classifySystemPrompt(binders: [ConversationPrompts.BinderHint(name: "Website", titles: [])], agents: [String](), fixes: true)
        XCTAssertTrue(with.contains(MomentPrompts.fixTodo))
        XCTAssertEqual(MomentPrompts.classifySystemPrompt(binders: [ConversationPrompts.BinderHint(name: "Website", titles: [])]),
                       MomentPrompts.classifySystemPrompt(binders: [ConversationPrompts.BinderHint(name: "Website", titles: [])], agents: [String](), fixes: false))
        XCTAssertFalse(MomentPrompts.classifySystemPrompt(binders: ["Website"]).contains("needs fixing"))
        let solo = ConversationPrompts.summarySystemPrompt(solo: true)
        XCTAssertFalse(solo.contains("Promises"))
        XCTAssertTrue(solo.contains("- No checkboxes and no to-dos: what they mean to do is listed elsewhere. Write bullets."))
        XCTAssertTrue(solo.contains("One to three sentences on what they were thinking about."))
        XCTAssertEqual(ConversationPrompts.summarySystemPrompt(solo: false), ConversationPrompts.summarySystemPrompt())
        XCTAssertTrue(ConversationPrompts.summarySystemPrompt().contains("## Promises"))
        XCTAssertTrue(ConversationPrompts.summaryUserPrompt(date: "d", duration: 60, transcript: "t", solo: true)
            .contains("Only the user spoke in it: they were thinking out loud."))
        XCTAssertFalse(ConversationPrompts.summaryUserPrompt(date: "d", duration: 60, transcript: "t").contains("thinking out loud"))
        XCTAssertFalse(MeetingTemplate.thinkingAloud.sections.contains("Promises"))
        XCTAssertFalse(MeetingTemplate.all.contains { $0.id == MeetingTemplate.thinkingAloud.id })
        XCTAssertEqual(MeetingTemplate.template(id: "conversation").id, "conversation")
    }

    func testTheBench() throws {
        let uncued = MomentBench.phrases.filter { $0.group == .uncued }
        XCTAssertEqual(uncued.count, 30)
        XCTAssertEqual(uncued.first?.id, "uncued-01")
        for phrase in uncued {
            XCTAssertNil(MomentRules.cue(in: phrase.text))
            XCTAssertEqual(MomentRules.uncued(in: phrase.text), phrase.uncued, phrase.text)
        }
        let chatter = MomentBench.phrases.filter { $0.group == .chatter }
        XCTAssertEqual(chatter.count, 30)
        XCTAssertEqual(chatter.last?.id, "chatter-30")
        XCTAssertEqual(chatter[15].text, "Their website is so slow.")
        XCTAssertTrue(chatter.allSatisfy { MomentRules.cue(in: $0.text) == nil })
        XCTAssertEqual(MomentBench.phrases(inAuto: false).filter { $0.group == .uncued || $0.group == .chatter }.count, 15)
        XCTAssertEqual(MomentBench.phrases(inAuto: true).count, MomentBench.phrases.count)
        XCTAssertFalse(MomentBench.Group.uncued.shouldBeTaken)
        XCTAssertTrue(MomentBench.Group.uncued.shouldBeTaken(inAuto: true))
        // Results with the new fields round-trip, and an older one decodes.
        let session = UUID()
        let result = MomentBench.Result(run: .phrases, session: session, heard: Date(timeIntervalSince1970: 0), phrase: "uncued-01", detector: .onItsOwn,
                                        voice: 0.86, failures: [.noCue], uncued: "fix", uncuedModel: "todo")
        XCTAssertEqual(try JSONDecoder().decode(MomentBench.Result.self, from: JSONEncoder().encode(result)), result)
        XCTAssertTrue(result.taken(at: 0.65, auto: true, startBar: 0.8))
        XCTAssertFalse(result.taken(at: 0.65, auto: false, startBar: 0.8), "outside Auto")
        XCTAssertFalse(result.taken(at: 0.65, auto: true, startBar: 0.9), "under the start bar")
        var none = result
        none.uncuedModel = "none"
        XCTAssertFalse(none.taken(at: 0.65, auto: true, startBar: 0.8))
        var unanswered = result
        unanswered.uncuedModel = ""
        let chat = MomentBench.Result(run: .phrases, session: session, heard: Date(), phrase: "chatter-16", detector: .onItsOwn, voice: 0.9,
                                      failures: [.noCue], uncued: "", uncuedModel: nil)
        let row = MomentBench.autoRow(MomentBench.Store(results: [result, unanswered, chat]), threshold: 0.65, startBar: 0.8)
        XCTAssertEqual(row.taken.taken, 1)
        XCTAssertEqual(row.taken.total, 2)
        XCTAssertEqual(row.falseKeeps.taken, 0)
        XCTAssertEqual(row.falseKeeps.total, 1)
        XCTAssertEqual(row.unanswered, 1)
        XCTAssertEqual(row.summary, "In Auto: 1 of 2 said without a cue taken · 0 kept that weren't meant · Apple's model didn't answer for 1")
        XCTAssertTrue(MomentBench.csv(MomentBench.Store(results: [result]), threshold: 0.65).hasPrefix("run,"))
        XCTAssertTrue(MomentBench.csv(MomentBench.Store(results: [result]), threshold: 0.65).components(separatedBy: "\n")[0].hasSuffix(",uncued,uncued_model"))
    }
}
