import XCTest
@testable import BindersKit

/// Auto's words, every line held to the copy rules: a reason and, where there is one, the next step; no exclamation marks,
/// never "successfully"; no time in the Mac's lines; titles that never hold your words. The agents and binders are the
/// design's made-up ones.
final class AutoTextTests: XCTestCase {
    static func assertPlain(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains("!"), text, file: file, line: line)
        XCTAssertFalse(text.lowercased().contains("successfully"), text, file: file, line: line)
        XCTAssertFalse(text.contains(".."), text, file: file, line: line)
        XCTAssertFalse(text.contains("  "), text, file: file, line: line)
    }

    /// A clock time: "3:10", "15.10", "AM", "PM".
    static func holdsATime(_ text: String) -> Bool {
        text.range(of: #"\d{1,2}[:.]\d{2}|\b[AP]M\b"#, options: .regularExpression) != nil
    }

    /// Times as the formatter writes them, with an ordinary space before AM and PM.
    static func plainSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func line(_ reason: RouterRules.NotStarted, hold: String? = nil, why: AutoReach.Why? = nil, clockAhead: Bool = false,
                      minutesAgo: Int? = nil) -> String? {
        AutoText.notHandedOver(reason, agent: "Claude Code · app", binder: "Website", hold: hold, why: why, model: "Qwen3.5-4B", heardAgent: "Codex",
                               clockAhead: clockAhead, minutesAgo: minutesAgo)
    }

    func testEveryReasonsLine() throws {
        let expected: [(RouterRules.NotStarted, String)] = [
            (.origin, "something else was said in the 3 minutes before it, by you or someone near you."),
            (.notOnItsOwn, "it wasn't heard from you on your own."),
            (.phoneNotAllowed, "your Mac hasn't let Auto on this iPhone hand things over: Settings → Agents → Sorting new cards on your Mac."),
            (.tooLongAgo, "it reached your Mac more than 12 hours after you said it."),
            (.noAnswer, "Binders' decision model didn't answer for it in time."),
            (.numbersDiffer, "Qwen3.5-4B's numbers on your Mac differ from the ones it was measured with: Measure Again in Settings → AI on your Mac."),
            (.mayAct, "Claude Code · app may send, post or buy for you, so it takes your tap."),
            (.checksBoard, "Claude Code · app checks the board itself, so it takes your tap."),
            (.switchOff, "Start on cards Binders sends it is off for Claude Code · app (Settings → Agents on your Mac)."),
            (.switchBeforeAuto, "Claude Code · app was let start on its own before Auto mode, so it takes your tap until you say yes for Auto mode too (Settings → Agents on your Mac)."),
            (.purposeNotTyped, "Claude Code · app's What it's for isn't in your own words yet (Settings → Agents on your Mac)."),
            (.wouldNotWake, "Claude Code · app can't be woken now: Settings → Agents on your Mac says why."),
            (.notATaker, "Claude Code · app doesn't take Website's cards: change that in Settings → Agents on your Mac."),
            (.leftOutTaker, "an agent Binders can't weigh also takes Website's cards: Settings → Agents on your Mac says which."),
            (.notNamed, "it isn't the agent you named."),
            (.namedSomeoneElse, "it reads as something for someone who isn't one of your agents."),
            (.heardAnother, "it sounds like you named Codex."),
            (.onlyMentioned, "Claude Code · app is only mentioned in it, not given the work."),
            (.notThePick, "Binders' decision model didn't pick it."),
            (.underAutoBar, "Binders wasn't sure enough it's Claude Code · app's work."),
            (.noYes, "you haven't said yes to Claude Code · app on your iPhone as it's set up now. Give to asks."),
            (.tooManyAtOnce, "Auto handed over 5 things you said earlier in the last 10 minutes. Give to hands this one over."),
            (.modelChanged, "the decision model changed while it was deciding."),
            (.notConfirmed, "the decision server on your Mac didn't confirm its model in time."),
            (.changedSince, "its card changed before Binders could hand it over."),
        ]
        for (reason, words) in expected {
            XCTAssertEqual(line(reason), "Not handed over: " + words, reason.rawValue)
        }
        XCTAssertEqual(line(.tooLongAgo, clockAhead: true), "Not handed over: your iPhone's clock and your Mac's are more than 12 hours apart.")
        XCTAssertEqual(line(.heldOnPhone, hold: "calibrate"),
                       "Not handed over: Calibrate hasn't set how close your voice must be: Calibrate on the capture screen.")
        XCTAssertEqual(line(.heldOnPhone, hold: "voice"), "Not handed over: it didn't sound enough like you to hand over without asking.")
        XCTAssertEqual(line(.heldOnPhone, hold: "audio"), "Not handed over: your iPhone was playing audio when it heard it.")
        XCTAssertEqual(line(.heldOnPhone, hold: "something new"), "Not handed over: your iPhone held it back: the capture screen says why.")
        XCTAssertEqual(line(.alreadyHanded, minutesAgo: 4), "Not handed over: you said this 4 minutes ago, and Claude Code · app has it.")
        XCTAssertEqual(line(.alreadyHanded, minutesAgo: 1), "Not handed over: you said this 1 minute ago, and Claude Code · app has it.")
        XCTAssertEqual(line(.alreadyHanded, minutesAgo: 0), "Not handed over: you said this just now, and Claude Code · app has it.")
        XCTAssertEqual(line(.noAutoLevel, why: .unmeasured),
                       "Not handed over: Qwen3.5-4B hasn't been measured on your Mac: Measure it in Settings → AI on your Mac.")
        XCTAssertEqual(line(.noAutoLevel, why: .off), "Not handed over: the decision model on your Mac is off: choose one in Settings → AI on your Mac.")
        XCTAssertEqual(AutoText.notHandedOver(.heardAnother, agent: "Scribe", binder: "Website"), "Not handed over: it sounds like you named another agent.")
        // Nothing to say: not in Auto, a note or a question, and the start rule's own reasons, which mayHandOver never gives.
        for reason in [RouterRules.NotStarted.notAuto, .kind, .noStartBar, .underBar, .notTheWake, .stale] {
            XCTAssertNil(line(reason), reason.rawValue)
        }
        // Every reason mayHandOver can give, but those two, has a line, plain, with no time, and every wait its next step.
        for reason in RouterRules.NotStarted.allCases where ![.notAuto, .kind, .noStartBar, .underBar, .notTheWake, .stale].contains(reason) {
            let words = try XCTUnwrap(line(reason, hold: "voice", why: .measuredBefore, minutesAgo: 4), reason.rawValue)
            Self.assertPlain(words)
            XCTAssertFalse(Self.holdsATime(words), words)
            XCTAssertTrue(words.hasPrefix(AutoText.notHandedOverStart))
            XCTAssertTrue(words.hasSuffix("."), words)
        }
        XCTAssertEqual(AutoText.pausedLine, "Not handed over: agents are paused. Resume them in Settings → Agents on your Mac.")
        XCTAssertEqual(AutoText.notSureWhose, "Not handed over: Binders wasn't sure enough whose work it is.")
    }

    func testTheJoinedLine() {
        let reason = AutoText.notHandedOver(.underAutoBar, agent: "Grok Bot", binder: "Website")
        XCTAssertEqual(AutoText.joined("Added to Website: Fix the login timeout", reason),
                       "Added to Website: Fix the login timeout. Not handed over: Binders wasn't sure enough it's Grok Bot's work.")
        XCTAssertEqual(AutoText.joined("Added to Website: Is the login slow?", reason), "Added to Website: Is the login slow? " + (reason ?? ""))
        XCTAssertEqual(AutoText.joined("Added to Website: Fix the login timeout.", AutoText.pausedLine),
                       "Added to Website: Fix the login timeout. Not handed over: agents are paused. Resume them in Settings → Agents on your Mac.",
                       "one period, never two")
        XCTAssertEqual(AutoText.joined("Added to Website: Fix it", nil), "Added to Website: Fix it")
        XCTAssertEqual(AutoText.joined("Added to Website: Fix it", ""), "Added to Website: Fix it")
        Self.assertPlain(AutoText.joined("Added to Website: Fix the login timeout.", reason))
    }

    func testTheHandOversTitlesAndLines() {
        XCTAssertEqual(AutoText.handedTitle("Claude Code · app"), "Handed to Claude Code · app")
        XCTAssertEqual(AutoText.notWokenTitle("Claude Code · app"), "Not woken yet: Claude Code · app")
        XCTAssertEqual(AutoText.handedLine(idea: false, binder: "Website", agent: "Claude Code · app", task: "Fix the login timeout"),
                       "Added to Website and handed to Claude Code · app: Fix the login timeout.")
        XCTAssertEqual(AutoText.handedLine(idea: false, binder: "Website", agent: "Claude Code · app", task: "Fix the login timeout", picked: true),
                       "Added to Website, Binders' pick, and handed to Claude Code · app: Fix the login timeout.")
        XCTAssertEqual(AutoText.handedLine(idea: true, binder: "Website", agent: "Grok Bot", task: "A weekly digest of what agents did"),
                       "Put on the Website board and handed to Grok Bot to look into: A weekly digest of what agents did.")
        XCTAssertEqual(AutoText.notWokenLine(idea: false, binder: "Website", agent: "Claude Code · app", task: "Fix the login timeout",
                                             why: "Claude Code · app was woken 6 times in the last hour"),
                       "Added to Website and made ready for Claude Code · app: Fix the login timeout. It wasn't woken: Claude Code · app was woken 6 "
                       + "times in the last hour. Wake Now on the card on your Mac does it.")
        XCTAssertEqual(AutoText.handedLine(idea: false, binder: "Website", agent: "Scribe", task: "Is the pricing page live?"),
                       "Added to Website and handed to Scribe: Is the pricing page live?", "a task that ends a sentence gets no period")
        // Titles never hold your words; nothing is shouted; the Mac's lines hold no time.
        for title in [AutoText.handedTitle("Claude Code · app"), AutoText.notWokenTitle("Claude Code · app")] {
            XCTAssertFalse(title.contains("login"), title)
            Self.assertPlain(title)
        }
        for line in [AutoText.handedLine(idea: true, binder: "Website", agent: "Grok Bot", task: "A digest", picked: true),
                     AutoText.notWokenLine(idea: true, binder: "Website", agent: "Grok Bot", task: "A digest", why: "Grok Bot is held.")] {
            Self.assertPlain(line)
            XCTAssertFalse(Self.holdsATime(line), line)
        }
    }

    func testStopUndoAndNotMe() {
        XCTAssertEqual(AutoText.undoneLine(task: "Fix the login timeout", binder: "Website", agent: "Claude Code · app"),
                       "Took “Fix the login timeout” off the Website board and stopped Claude Code · app.")
        XCTAssertEqual(AutoText.undoneHadItLine(task: "Look up flights to Lisbon", binder: "Website", agent: "Grok Bot"),
                       "Took “Look up flights to Lisbon” off the Website board. Grok Bot already had the card: Binders can't fetch it back from it.")
        XCTAssertEqual(AutoText.undoneKeptLine(binder: "Website", agent: "Claude Code · app", idea: false),
                       "Stopped Claude Code · app. It had reported on the card, so the card and its to-do stay in the Website board's Backlog: delete them there.")
        XCTAssertEqual(AutoText.undoneKeptLine(binder: "Website", agent: "Grok Bot", idea: true),
                       "Stopped Grok Bot. It had reported on the card, so the card stays in the Website board's Backlog: delete it there.")
        XCTAssertEqual(AutoText.notMeLine(raised: false), "Not you: stopped, taken back, and kept against your voice print.")
        XCTAssertEqual(AutoText.notMeLine(raised: true),
                       "Not you: stopped, taken back, and kept against your voice print. Your voice must now sound closer to yours for anything to go "
                       + "without asking; Calibrate again if that holds back too much.")
        XCTAssertEqual(AutoText.keptStop(agent: "Claude Code · app"), "Kept. Stop goes to your Mac when it's back; Claude Code · app keeps working until then.")
        XCTAssertEqual(AutoText.keptUndo, "Kept. Undo goes to your Mac when it's back.")
        XCTAssertEqual(AutoText.keptNotMe, "Not you: kept against your voice print. Stopping it and taking it back go to your Mac when it's back.")
        for text in [AutoText.notMeLine(raised: true), AutoText.keptStop(agent: "Scribe"), AutoText.keptUndo, AutoText.keptNotMe,
                     AutoText.undoneKeptLine(binder: "Website", agent: "Scribe", idea: false)] {
            Self.assertPlain(text)
        }
    }

    func testTheNotifications() {
        XCTAssertEqual(AutoText.turnedOff, NotificationText(title: "Auto is off", body: "2 of the last 10 things Auto handed over weren't you, or weren't "
                                                            + "for Binders. Calibrate, then choose Auto again on the capture screen."))
        XCTAssertEqual(AutoText.canHandOverNow, NotificationText(title: "Auto can hand things over now", body: "Open to see which agents may take what you say."))
        for text in [AutoText.turnedOff, AutoText.canHandOverNow] {
            Self.assertPlain(text.title)
            Self.assertPlain(text.body)
        }
    }

    func testWhenItWasSaidInTheIPhonesOwnTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Lisbon"))
        let us = Locale(identifier: "en_US")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 16, minute: 30)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15, minute: 10)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 7, minute: 40)))
        let before = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9, minute: 2)))
        XCTAssertEqual(Self.plainSpaces(AutoText.youSaidIt(today, now: now, calendar: calendar, locale: us)), "You said it at 3:10 PM.")
        XCTAssertEqual(Self.plainSpaces(AutoText.youSaidIt(yesterday, now: now, calendar: calendar, locale: us)), "You said it yesterday at 7:40 AM.")
        XCTAssertEqual(Self.plainSpaces(AutoText.youSaidIt(before, now: now, calendar: calendar, locale: us)), "You said it on Oct 17 at 9:02 AM.")
        let british = Self.plainSpaces(AutoText.youSaidIt(before, now: now, calendar: calendar, locale: Locale(identifier: "en_GB")))
        XCTAssertTrue(british.hasPrefix("You said it on 17 Oct at ") && british.contains("9:02") && !british.contains("AM"),
                      "in the iPhone's own words for dates and times: \(british)")
        // The same instants are other hours, and another day, in another zone: the iPhone's zone decides.
        var tokyo = calendar
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(Self.plainSpaces(AutoText.saidAt(today, now: now, calendar: tokyo, locale: us)), "yesterday at 11:10 PM",
                       "3:10 PM in Lisbon is 11:10 PM in Tokyo, and 4:30 PM there is already the next day")
        // The joined line on the iPhone, after the Mac's.
        let line = AutoText.handedLine(idea: false, binder: "Website", agent: "Claude Code · app", task: "Fix the login timeout")
        XCTAssertEqual(Self.plainSpaces(AutoText.joined(line, AutoText.youSaidIt(today, now: now, calendar: calendar, locale: us))),
                       "Added to Website and handed to Claude Code · app: Fix the login timeout. You said it at 3:10 PM.")
    }

    func testTheCardsDescriptionAndNote() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Lisbon"))
        let us = Locale(identifier: "en_US")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 16, minute: 30)))
        let heard = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15, minute: 10)))
        XCTAssertEqual(Self.plainSpaces(AutoText.todoDetails(said: "I need to fix the login timeout on the website", heard: heard, now: now,
                                                             calendar: calendar, locale: us)),
                       "“I need to fix the login timeout on the website.”\n\nSaid to your iPhone at 3:10 PM.")
        let idea = Self.plainSpaces(AutoText.ideaDetails(said: "Idea for Binders: a weekly digest of what agents did", heard: heard, now: now,
                                                         calendar: calendar, locale: us))
        XCTAssertEqual(idea, "“Idea for Binders: a weekly digest of what agents did.”\n\nSaid to your iPhone at 3:10 PM.\n\nLook into this idea and write a "
                       + "short plan here: what it would take, and what to do first. Don't build it until you're asked to on this card.")
        XCTAssertTrue(idea.hasSuffix("Don't build it until you're asked to on this card."))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: heard))
        XCTAssertTrue(Self.plainSpaces(AutoText.todoDetails(said: "fix it", heard: yesterday, now: now, calendar: calendar, locale: us))
            .hasSuffix("Said to your iPhone yesterday at 3:10 PM."), "the day too when it wasn't today")

        func note(idea: Bool = false, asked: Bool = false, named: Bool = false, agent: String = "Claude Code · app") -> String {
            Self.plainSpaces(AutoText.note(agent: agent, idea: idea, asked: asked, named: named, heard: heard, now: now, calendar: calendar, locale: us))
        }
        XCTAssertEqual(note(), "Binders handed this to Claude Code · app without asking: you said it on your own to your iPhone at 3:10 PM, while it was "
                       + "in Auto, and it looks like Claude Code · app's work. Auto skips only Binders' own Give to question: drafting first, and asking "
                       + "approval before anything is sent, posted or bought, stay as always. Stop it here, or turn off Auto on your iPhone "
                       + "(Binders → All-day capture).")
        XCTAssertTrue(note(idea: true, agent: "Grok Bot").hasPrefix("Binders handed this to Grok Bot without asking, to look into and plan: you said it "
                                                                    + "on your own to your iPhone at 3:10 PM, while it was in Auto, "))
        XCTAssertTrue(note(named: true).contains(", while it was in Auto, and you named Claude Code · app. Auto skips only"))
        XCTAssertTrue(note(asked: true).contains(": you said it to Binders on your iPhone at 3:10 PM, while it was in Auto, "))
        for text in [note(), note(idea: true), note(asked: true, named: true)] {
            // What Stop on the card looks for (CardRouter.handedOver), and what Auto skips, for you and the agent.
            XCTAssertTrue(text.hasPrefix("Binders handed this to "), text)
            XCTAssertTrue(text.contains(" without asking"))
            XCTAssertTrue(text.contains("Auto skips only Binders' own Give to question"))
            Self.assertPlain(text)
        }
        XCTAssertTrue(note(agent: "Scribe").hasPrefix("Binders handed this to Scribe without asking"))
    }

    func testTheMacsReasonsAndEachAgents() {
        let mac: [(AutoReach.Why?, String)] = [
            (.off, "the decision model on your Mac is off: choose one in Settings → AI on your Mac"),
            (.checking, "your Mac is still checking Qwen3.5-4B, which takes a minute: Auto hands things over once it's done"),
            (.unusable, "Qwen3.5-4B on your Mac can't sort cards now: Settings → AI on your Mac says why"),
            (.unmeasured, "Qwen3.5-4B hasn't been measured on your Mac: Measure it in Settings → AI on your Mac"),
            (.changed, "Qwen3.5-4B's measure was changed outside Binders: Measure Again in Settings → AI on your Mac"),
            (.measuredBefore, "Qwen3.5-4B was measured before Auto mode: Measure Again in Settings → AI on your Mac"),
            (.noLevel, "Qwen3.5-4B's measure found no level at which it hands over the right agent often enough: choose another decision model in Settings → AI on your Mac"),
            (.numbers, "Qwen3.5-4B's numbers on your Mac differ from the ones it was measured with: Measure Again in Settings → AI on your Mac"),
            (nil, "the decision model on your Mac can't hand anything over now: Settings → AI on your Mac says why"),
        ]
        XCTAssertEqual(mac.compactMap(\.0), AutoReach.Why.allCases, "every code")
        for (why, words) in mac {
            XCTAssertEqual(AutoText.macWhy(why, model: "Qwen3.5-4B"), words)
            XCTAssertEqual(AutoText.macWhy(code: why?.rawValue, model: "Qwen3.5-4B"), words)
            Self.assertPlain(words)
            XCTAssertTrue(words.contains("Settings → AI") || why == .checking, words)
        }
        XCTAssertEqual(AutoReach.Why.allCases.map(\.rawValue), ["off", "checking", "unusable", "unmeasured", "changed", "measured-before", "no-level", "numbers"])
        XCTAssertEqual(AutoText.macWhy(code: "something-new"), mac.last?.1)
        XCTAssertEqual(AutoText.macWhy(.unmeasured), "the decision model hasn't been measured on your Mac: Measure it in Settings → AI on your Mac")

        let agents: [(String?, String?)] = [
            ("takes", nil),
            ("may-act", "It may send, post or buy for you, so it always takes your tap."),
            ("board", "It checks the board itself, so it always takes your tap."),
            ("switch-off", "Start on cards Binders sends it is off for it on your Mac (Settings → Agents)."),
            ("switch-before", "It was let start on its own before Auto mode: on your Mac, Review… beside its start switch (Settings → Agents) says what Auto adds."),
            ("purpose", "Its What it's for isn't in your own words yet, on your Mac (Settings → Agents)."),
            ("paused", "Agents are paused on your Mac: resume them in Settings → Agents."),
            ("changed", "It was changed outside Binders: open it on your Mac and save it."),
            ("no-yes", "You haven't said yes to it on this iPhone since Auto mode."),
            ("something-new", "It can't take them now: see Settings → Agents on your Mac."),
            (nil, "It can't take them now: see Settings → Agents on your Mac."),
        ]
        XCTAssertEqual(agents.compactMap { $0.0.flatMap(AutoReach.Agent.init(rawValue:)) }, AutoReach.Agent.allCases, "every code")
        for (code, words) in agents {
            XCTAssertEqual(AutoText.agentWhy(code), words, code ?? "nil")
            if let words { Self.assertPlain(words) }
        }
    }

    func testAnAgentsCodeFollowsTheRulesOrder() {
        func code(draftsFirst: Bool = true, checksBoard: Bool = false, startsOnItsOwn: Bool = true, startsInAuto: Bool = true, hasOwnPurpose: Bool = true,
                  paused: Bool = false, changed: Bool = false) -> AutoReach.Agent {
            AutoReach.Agent.of(draftsFirst: draftsFirst, checksBoard: checksBoard, startsOnItsOwn: startsOnItsOwn, startsInAuto: startsInAuto,
                               hasOwnPurpose: hasOwnPurpose, paused: paused, changedOutsideBinders: changed)
        }
        XCTAssertEqual(code(), .takes)
        XCTAssertEqual(code(draftsFirst: false, startsOnItsOwn: false, startsInAuto: false), .mayAct, "never a switch its editor doesn't have")
        XCTAssertEqual(code(checksBoard: true, startsOnItsOwn: false, startsInAuto: false), .board)
        XCTAssertEqual(code(startsOnItsOwn: false, startsInAuto: false), .switchOff)
        XCTAssertEqual(code(startsInAuto: false, hasOwnPurpose: false), .switchBefore)
        XCTAssertEqual(code(hasOwnPurpose: false, paused: true), .purpose)
        XCTAssertEqual(code(paused: true, changed: true), .paused)
        XCTAssertEqual(code(changed: true), .changed)
    }

    func testWhatStopCanDoForEach() {
        XCTAssertEqual(AutoText.stopReach(wakes: "claudeCode"), "Stop ends its run.")
        XCTAssertEqual(AutoText.stopReach(wakes: "cliAgent"), "Stop ends its run.")
        XCTAssertEqual(AutoText.stopReach(wakes: "command"), "Stop ends its command while it runs; once it has rung the agent, Stop only moves the card back.")
        for wakes in ["webhook", "shortcut", "board", "somethingNew"] {
            XCTAssertEqual(AutoText.stopReach(wakes: wakes), "Once it has the card, Stop only moves it back.", wakes)
        }
        XCTAssertEqual(AutoText.stopReach(wakes: "claudeCode", openSession: true), "Once it has the card, Stop only moves it back.", "your open session")
        XCTAssertEqual(AutoText.leftOutLine(["Hooky"]), "Not in the binders Hooky also takes: Binders can't weigh Hooky now (Settings → Agents on your Mac).")
        XCTAssertEqual(AutoText.leftOutLine(["Hooky", "Echo"]),
                       "Not in the binders Hooky and Echo also take: Binders can't weigh them now (Settings → Agents on your Mac).")
        XCTAssertNil(AutoText.leftOutLine([]))
        XCTAssertNil(AutoText.leftOutLine([" "]))
    }

    func testWhatListAgentsSaysAboutAutoReads() throws {
        let reach = try JSONDecoder().decode(AutoReach.self, from: Data(#"{"hands_over": true, "level": 0.6, "model": "Tev1 0.8B"}"#.utf8))
        XCTAssertEqual(reach, AutoReach(handsOver: true, model: "Tev1 0.8B", level: 0.6))
        let none = try JSONDecoder().decode(AutoReach.self, from: Data(#"{"hands_over": false, "why": "unmeasured", "model": "Qwen3.5-4B", "extra": 1}"#.utf8))
        XCTAssertEqual(none.reason, .unmeasured)
        XCTAssertNil(try JSONDecoder().decode(AutoReach.self, from: Data(#"{"hands_over": false, "why": "something-new"}"#.utf8)).reason,
                     "a newer Mac's code reads as unknown, not as an error")
        let text = String(decoding: try JSONEncoder().encode(reach), as: UTF8.self)
        XCTAssertTrue(text.contains(#""hands_over":true"#), text)
    }
}
