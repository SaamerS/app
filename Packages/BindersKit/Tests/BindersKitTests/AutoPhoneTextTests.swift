@testable import BindersKit
import XCTest

/// The iPhone's words for the modes and Auto: the Mode line's cases in their order, and every line to the copy rules.
final class AutoPhoneTextTests: XCTestCase {
    private func facts(auto: Bool = true, adds: Bool = true, listed: Bool = true, reach: Bool = true, bar: Bool = true,
                       model: AutoReach? = AutoReach(handsOver: true, model: "Tev1 0.8B", level: 0.6), mayTake: [String] = ["Claude Code · app"])
        -> AutoPhoneText.ModeFacts {
        AutoPhoneText.ModeFacts(macListsAuto: auto, macListsAdds: adds, listed: listed, macInReach: reach, startBarSet: bar, reach: model,
                                mayTake: mayTake)
    }

    func testTheModeLineSaysTheFirstThatHolds() {
        XCTAssertEqual(AutoPhoneText.modeLine(facts()), "Claude Code · app may take them now.")
        XCTAssertEqual(AutoPhoneText.modeLine(facts(mayTake: ["Claude Code · app", "Grok Bot"])), "Claude Code · app and Grok Bot may take them now.")
        XCTAssertEqual(AutoPhoneText.modeLine(facts(mayTake: ["Claude Code · app", "Grok Bot", "Codex", "Inkwell"])),
                       "Claude Code · app, Grok Bot and 2 more may take them now.")
        XCTAssertEqual(AutoPhoneText.modeLine(facts(mayTake: [])), AutoPhoneText.noAgent)
        let unmeasured = AutoReach(handsOver: false, why: "unmeasured", model: "Qwen3.5-4B")
        XCTAssertEqual(AutoPhoneText.modeLine(facts(model: unmeasured)),
                       "It hands nothing over now: Qwen3.5-4B hasn't been measured on your Mac: Measure it in Settings → AI on your Mac. "
                        + "Until then it adds at once and offers Give to.")
        XCTAssertEqual(AutoPhoneText.modeLine(facts(model: nil)), "Claude Code · app may take them now.", "list_agents not heard: the agents decide")
        XCTAssertEqual(AutoPhoneText.modeLine(facts(bar: false, model: unmeasured)), AutoPhoneText.calibrate)
        XCTAssertEqual(AutoPhoneText.modeLine(facts(reach: false, bar: false)), AutoPhoneText.macAway)
        XCTAssertEqual(AutoPhoneText.modeLine(facts(listed: false, reach: false)), AutoPhoneText.notListed)
        XCTAssertEqual(AutoPhoneText.modeLine(facts(auto: false, listed: false)), AutoPhoneText.macNeedsUpdate)
        XCTAssertEqual(AutoPhoneText.modeLine(facts(auto: false, adds: false)), AutoPhoneText.macNoAdds)
    }

    func testTheFootersAndLines() {
        let checks = "It goes by a cue like “I need to”, your voice and the quiet around it."
        XCTAssertTrue(AutoPhoneText.footer(.suggest, checks: checks).hasPrefix("Say “Binders, …” while capture listens. Once Binders knows your voice (below), it also offers"))
        XCTAssertTrue(AutoPhoneText.footer(.add, checks: checks).contains("In Add at Once, each one is added at once with Undo."))
        XCTAssertTrue(AutoPhoneText.footer(.auto, checks: checks).contains("with your yes for each agent"))
        XCTAssertNil(AutoPhoneText.notWrittenDown(0))
        XCTAssertEqual(AutoPhoneText.notWrittenDown(3),
                       "3 things you said today weren't written down: Binders couldn't write them down in the background then.")
        XCTAssertEqual(AutoPhoneText.notWrittenDownNow("Low Power Mode is on, so with Binders open or while charging"),
                       "With Binders in the background, what you say to yourself isn't written down now: Low Power Mode is on, so with Binders open or while charging.")
        XCTAssertEqual(AutoPhoneText.turnedOff(back: .suggest), "Auto is off: back to Suggest.")
        XCTAssertEqual(AutoPhoneText.turnedOff(back: .add), "Auto is off: back to Add at Once.")
        XCTAssertEqual(AutoPhoneText.pageFooter(back: .add),
                       "Binders handed this over without asking, as your iPhone is in Auto. Off, what you say is still added at once, with Give to.")
        XCTAssertEqual(AutoPhoneText.waitsRow(2), "2 things you said wait for you: Give to, or Wake Now on your Mac.")
        XCTAssertEqual(AutoPhoneText.Sheet.cantHear,
                       "Say each thing on its own, starting with “I need to”, “remember to” or “idea for”. Thinking out loud in between keeps what "
                        + "follows from going for three minutes, and nothing is handed over while your iPhone plays audio.")
        XCTAssertEqual(AutoPhoneText.Sheet.macCant(AutoReach(handsOver: false, why: "off")),
                       "Your Mac can't hand anything over now: the decision model on your Mac is off: choose one in Settings → AI on your Mac. "
                        + "Until it can, Auto adds what you say at once and offers Give to.")
    }

    func testNoLineBreaksTheCopyRules() {
        let checks = "It goes by a cue."
        var lines = [AutoPhoneText.cantHear, AutoPhoneText.noAgent, AutoPhoneText.calibrate, AutoPhoneText.macNeedsUpdate, AutoPhoneText.notListed,
                     AutoPhoneText.macAway, AutoPhoneText.macNoAdds, AutoPhoneText.explanation, AutoPhoneText.keptNotMe,
                     AutoPhoneText.waitsRow(1), AutoPhoneText.notWrittenDown(1) ?? "", AutoPhoneText.notWrittenDownNow("the iPhone is warm"),
                     AutoPhoneText.Sheet.heading, AutoPhoneText.Sheet.body, AutoPhoneText.Sheet.cantHear,
                     AutoPhoneText.Sheet.subtitle, AutoPhoneText.Sheet.soloSubtitle, AutoPhoneText.Sheet.noAgents, AutoPhoneText.Sheet.noneReady,
                     AutoPhoneText.Sheet.noneReadyMore, AutoPhoneText.Sheet.stopWhere, AutoPhoneText.Sheet.stopLine, AutoPhoneText.Sheet.undoLine,
                     AutoPhoneText.Sheet.notMeLine, AutoPhoneText.Sheet.turnOffLine, AutoPhoneText.Sheet.stopMore, AutoPhoneText.Sheet.readyAlone,
                     AutoPhoneText.Sheet.sayYesAgainOnMac, AutoPhoneText.Sheet.notEveryBinder, AutoPhoneText.Sheet.calibrate, AutoPhoneText.Sheet.macNeedsUpdate, AutoPhoneText.Sheet.notHeard,
                     AutoPhoneText.Sheet.lastSaid, AutoPhoneText.Sheet.reviewLabel("Inkwell"), AutoPhoneText.Sheet.reviewTitle("Inkwell")]
        lines += MomentMode.allCases.map { AutoPhoneText.footer($0, checks: checks) }
        lines += MomentMode.allCases.map { AutoPhoneText.pageFooter(back: $0) }
        lines += AutoReach.Why.allCases.map { AutoPhoneText.macCant(AutoReach(handsOver: false, why: $0.rawValue, model: "Tev1 0.8B")) }
        lines += (AutoReach.Agent.allCases.map(\.rawValue) + ["something-new"]).flatMap { code -> [String] in
            let row = AutoPhoneText.Sheet.row(code)
            return [row.label, row.action ?? "", row.detail ?? ""]
        }
        for line in lines {
            XCTAssertFalse(line.contains("!"), line)
            XCTAssertFalse(line.lowercased().contains("successfully"), line)
            XCTAssertFalse(line.contains(".."), line)
        }
    }

    /// The sheet's rows: a status for every code, one short thing to do for each that needs the Mac, and its reason kept
    /// for the info button. The founder's agents lacked What it's for: the row says so, not the start switch.
    func testEachAgentsRowSaysOneThingToDo() {
        typealias Sheet = AutoPhoneText.Sheet
        XCTAssertEqual(Sheet.row("takes"), Sheet.Row(status: .ready, label: "Ready"))
        XCTAssertEqual(Sheet.row("no-yes").status, .needsYes)
        XCTAssertEqual(Sheet.row("no-yes").label, "Needs your yes")
        XCTAssertEqual(Sheet.row("purpose"), Sheet.Row(status: .onMac, label: "Set up on your Mac", action: "Add What it's for",
                                                       detail: AutoText.agentWhy("purpose")))
        XCTAssertEqual(Sheet.row("switch-off").action, "Turn on Start on cards")
        XCTAssertEqual(Sheet.row("switch-before").action, "Review its start switch")
        XCTAssertEqual(Sheet.row("paused").action, "Resume agents")
        XCTAssertEqual(Sheet.row("may-act").status, .alwaysAsks)
        XCTAssertEqual(Sheet.row("board").status, .alwaysAsks)
        XCTAssertEqual(Sheet.row("something-new").status, .onMac)
        for code in AutoReach.Agent.allCases where code != .takes {
            let row = Sheet.row(code.rawValue)
            XCTAssertEqual(row.detail, AutoText.agentWhy(code.rawValue), "the reason stays behind the info button: \(code)")
            if row.status != .needsYes { XCTAssertLessThanOrEqual(row.action?.count ?? 99, 32, "one short action: \(code)") }
        }
        XCTAssertFalse(Sheet.noneReady.contains("Start on cards"), "never points at a step that may be done")
        XCTAssertTrue(Sheet.reviewLabel("Grok Bot").hasPrefix("Say yes to "))
        XCTAssertTrue(Sheet.reviewSoloLabel("Grok Bot").hasPrefix("Say yes to "))
        for line in [Sheet.stopLine, Sheet.undoLine, Sheet.notMeLine, Sheet.turnOffLine] { XCTAssertLessThanOrEqual(line.count, 56, line) }
    }

    /// The yes page holds every fact the disclosure says, each in its part, for each way an agent is woken.
    func testTheYesPageKeepsEveryFactOfTheDisclosure() {
        struct Case { var wakes: String; var sendsTo: String?; var vendor: String?; var context: Bool?; var mayAct: Bool?; var open: Bool?
            var starts: Bool?; var auto: Bool?; var solo: Bool? }
        let cases = [
            Case(wakes: "claudeCode", sendsTo: "Anthropic, or the Claude Code session you have open in its repository", vendor: "Anthropic",
                 context: true, mayAct: false, open: true, starts: true, auto: true, solo: true),
            Case(wakes: "claudeCode", sendsTo: "Anthropic", vendor: "Anthropic", context: false, mayAct: true, open: false, starts: true, auto: false, solo: nil),
            Case(wakes: "command", sendsTo: "grok.py", vendor: "xAI", context: true, mayAct: false, open: nil, starts: true, auto: true, solo: false),
            Case(wakes: "command", sendsTo: nil, vendor: nil, context: nil, mayAct: nil, open: nil, starts: nil, auto: nil, solo: nil),
            Case(wakes: "webhook", sendsTo: "hooks.example.com", vendor: "OpenAI", context: nil, mayAct: false, open: nil, starts: false, auto: nil, solo: nil),
            Case(wakes: "shortcut", sendsTo: nil, vendor: nil, context: nil, mayAct: false, open: nil, starts: nil, auto: nil, solo: nil),
            Case(wakes: "board", sendsTo: "on another machine, over SSH", vendor: "Google", context: true, mayAct: false, open: nil, starts: nil,
                 auto: nil, solo: nil),
            Case(wakes: "cliAgent", sendsTo: "OpenAI", vendor: "OpenAI", context: true, mayAct: false, open: nil, starts: true, auto: true, solo: true),
            Case(wakes: "somethingNew", sendsTo: nil, vendor: nil, context: nil, mayAct: nil, open: nil, starts: nil, auto: nil, solo: nil),
        ]
        for c in cases {
            let name = "Grok Bot"
            let said = AgentConsent.disclosure(name: name, wakes: c.wakes, sendsTo: c.sendsTo, vendor: c.vendor, addsContext: c.context,
                                               contextFrom: "notes and meetings", mayAct: c.mayAct, openSession: c.open, startsOnItsOwn: c.starts,
                                               autoModeStart: c.auto, soloStart: c.solo)
            let page = AgentConsent.page(name: name, wakes: c.wakes, sendsTo: c.sendsTo, vendor: c.vendor, addsContext: c.context,
                                         contextFrom: "notes and meetings", mayAct: c.mayAct, openSession: c.open, startsOnItsOwn: c.starts,
                                         autoModeStart: c.auto, soloStart: c.solo)
            let text = page.allText.joined(separator: "\n")
            func both(_ fact: String, _ note: String) {
                XCTAssertEqual(said.contains(fact), text.contains(fact), "\(note) (\(c.wakes)): \(fact)\n\(said)\n---\n\(text)")
            }
            XCTAssertTrue(text.contains("Binders on your Mac hands \(name) the card"))
            for fact in ["title, details and links", "binder and due date", "answers and comments", "Nothing else from your binders goes with it."] {
                XCTAssertTrue(said.contains(fact) && text.contains(fact), fact)
            }
            XCTAssertEqual(said.contains("up to 3 short passages"), text.contains("Up to 3 short passages"), "context")
            // Where it goes: the disclosure's own sentence, word for word, and the open session's.
            let goes = AgentConsent.goesSentence(name: name, wakes: c.wakes, sendsTo: c.sendsTo, vendor: c.vendor, openSession: nil)
            XCTAssertTrue(said.contains(goes) && page.parts.first { $0.kind == .goes }?.lines.first == goes, goes)
            both(AgentConsent.openSessionSentence, "open session")
            // Acting for you.
            XCTAssertEqual(said.contains("ask your approval before it sends, posts or buys"), text.contains("Binders tells it to ask your approval"))
            both("You let it send, post or buy for you without asking first.", "may act")
            // Without asking: the cue, Auto, and what you think out loud with only its sentences.
            XCTAssertEqual(said.contains("Binders may also hand it a card without asking"), page.parts.contains { $0.kind == .starts })
            both("“Binders, …” you say in your voice is clearly its work", "the cue")
            XCTAssertEqual(said.contains("while this iPhone is in Auto"), text.contains("While this iPhone is in Auto"))
            both("even hours later", "late")
            both("think out loud where only you speak", "solo")
            both("only the sentences it came from", "only its sentences")
            XCTAssertEqual(said.contains("with your words"), text.contains("Your words, when Auto hands it something you said"))
            for line in page.allText {
                XCTAssertFalse(line.contains("!"), line)
            }
        }
    }
}
