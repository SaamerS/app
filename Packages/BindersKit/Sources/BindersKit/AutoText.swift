import Foundation

// Auto's words that both ends need: the Mac writes a moment's title and line (shown on the iPhone), the card's description
// and Binders' note on it, and the codes list_agents gives an iPhone; the iPhone writes the words for those codes, what Stop
// can do, when a late moment was said, and its own lines for Not Me and for what it keeps until the Mac is back. In one
// place, so the tests hold every line to the copy rules: plain words, a reason and the next step, no exclamation marks.
// None of the Mac's lines holds a time for an iPhone that sends a mode: the iPhone says when, in its own time zone.

// MARK: - What Auto can do now, as list_agents says

/// What Auto can hand over now, as the Mac's list_agents tells an iPhone that lists MomentPayload.autoFeature (its `auto`
/// object: `{"hands_over": true, "level": 0.6, "model": "Tev1 0.8B"}`), and the codes it and each agent's `auto` use.
/// Codes stay strings on the wire, so a newer Mac's reads as unknown, never as an error.
public struct AutoReach: Codable, Equatable, Sendable {
    /// Why the Mac can hand nothing over in Auto now (DecisionModels.whyNoAuto), in the order it's asked.
    public enum Why: String, Codable, Sendable, CaseIterable {
        /// The decision model is off.
        case off
        /// The model chosen is still being checked.
        case checking
        /// It can't sort cards now (a folder that can't answer, a server that doesn't).
        case unusable
        /// Never measured on this Mac, or a server whose probes no longer match its measure.
        case unmeasured
        /// Its measure record was changed outside Binders.
        case changed
        /// Measured before Auto: Measure Again gives it a level, or none.
        case measuredBefore = "measured-before"
        /// Its measure found no Auto level (MeasureRules.NoAuto).
        case noLevel = "no-level"
        /// Its numbers on this Mac differ from the ones it was measured with.
        case numbers
    }

    /// Each agent's `auto` in list_agents: `takes`, or the first that fails, in RouterRules.mayHandOver's order, of what
    /// doesn't depend on a moment. Held agents aren't in list_agents at all. `noYes` is the iPhone's own: it hasn't said
    /// yes to the agent since Auto, which only the iPhone knows.
    public enum Agent: String, Codable, Sendable, CaseIterable {
        case takes
        case mayAct = "may-act"
        case board
        case switchOff = "switch-off"
        case switchBefore = "switch-before"
        case purpose
        case paused
        case changed
        case noYes = "no-yes"

        /// The agent's code from what the Mac knows of it now, in mayHandOver's order: it may send, post or buy; it checks
        /// the board itself; its start switch is off; it was switched on before Auto; its What it's for isn't your words;
        /// agents are paused; it was changed outside Binders. An agent that may act, or checks the board itself, is never
        /// told to turn on a switch its editor doesn't have.
        public static func of(draftsFirst: Bool, checksBoard: Bool, startsOnItsOwn: Bool, startsInAuto: Bool, hasOwnPurpose: Bool, paused: Bool,
                              changedOutsideBinders: Bool) -> Agent {
            if !draftsFirst { return .mayAct }
            if checksBoard { return .board }
            if !startsOnItsOwn { return .switchOff }
            if !startsInAuto { return .switchBefore }
            if !hasOwnPurpose { return .purpose }
            if paused { return .paused }
            if changedOutsideBinders { return .changed }
            return .takes
        }
    }

    /// The Mac's decision model can hand things over in Auto now.
    public var handsOver: Bool
    /// Why not (a `Why`), when it can't.
    public var why: String?
    /// The decision model's name as Settings → AI shows it ("Tev1 0.8B"), never a path.
    public var model: String?
    /// Auto's level, when it can.
    public var level: Double?

    public init(handsOver: Bool, why: String? = nil, model: String? = nil, level: Double? = nil) {
        self.handsOver = handsOver
        self.why = why
        self.model = model
        self.level = level
    }

    /// `why`, read; nil for none, or a code this build doesn't know.
    public var reason: Why? { why.flatMap(Why.init(rawValue:)) }

    private enum CodingKeys: String, CodingKey { case handsOver = "hands_over", why, model, level }
}

// MARK: - The words

public enum AutoText {
    // MARK: Joining

    /// A line and the sentence after it: the line, ". " (or a space after a line that already ends a sentence) and the
    /// sentence. The Mac's lines have no period of their own ("Added to Website: Fix the login timeout").
    public static func joined(_ line: String, _ more: String?) -> String {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let more = more?.trimmingCharacters(in: .whitespacesAndNewlines), !more.isEmpty else { return line }
        guard !line.isEmpty else { return more }
        return (endsSentence(line) ? line + " " : line + ". ") + more
    }

    /// `text` as a sentence: with a period, unless it already ends one.
    static func sentence(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || endsSentence(text) ? text : text + "."
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!…".contains(last) || (["”", "\"", "’", ")"].contains(last) && text.dropLast().last.map { ".?!…".contains($0) } == true)
    }

    // MARK: Not handed over (each moment's line)

    /// How each reason's line starts.
    public static let notHandedOverStart = "Not handed over: "

    /// Why something you said wasn't handed over, as a sentence that names the reason and, where there is one, the next
    /// step, for the moment's line (after `joined`). Nil where nothing needs saying: not in Auto (`notAuto`), and a note, a
    /// question or a status request (`kind`), which are never handed over; and for the start rule's own reasons, which
    /// `mayHandOver` never gives. `hold` is MomentPayload.autoHold; `why` and `model` the Mac's reason and the decision
    /// model's name, asked for this moment (DecisionModels.whyNoAuto); `heardAgent` the agent whose name was heard;
    /// `clockAhead` the iPhone's heard time is in the Mac's future; `minutesAgo` how long since the same thing was said.
    /// `fromCapture` (lane Y2): it was read from a capture in which your iPhone heard only you, or went with one.
    public static func notHandedOver(_ reason: RouterRules.NotStarted, agent: String, binder: String, hold: String? = nil, why: AutoReach.Why? = nil,
                                     model: String? = nil, heardAgent: String? = nil, clockAhead: Bool = false, minutesAgo: Int? = nil,
                                     fromCapture: Bool = false) -> String? {
        let clause: String
        switch reason {
        case .notAuto, .kind, .noStartBar, .underBar, .notTheWake, .stale:
            return nil
        case .origin: clause = "something else was said in the 3 minutes before it, by you or someone near you."
        case .notOnItsOwn: clause = "it wasn't heard from you on your own."
        case .phoneNotAllowed:
            clause = "your Mac hasn't let Auto on this iPhone hand things over: Settings → Agents → Sorting new cards on your Mac."
        case .heldOnPhone:
            switch hold {
            case MomentAgreement.Hold.calibrate: clause = "Calibrate hasn't set how close your voice must be: Calibrate on the capture screen."
            case MomentAgreement.Hold.voice: clause = "it didn't sound enough like you to hand over without asking."
            case MomentAgreement.Hold.audio: clause = "your iPhone was playing audio when it heard it."
            default: clause = "your iPhone held it back: the capture screen says why."
            }
        case .tooLongAgo:
            clause = clockAhead ? "your iPhone's clock and your Mac's are more than 12 hours apart."
                : "it reached your Mac more than 12 hours after you said it."
        case .noAutoLevel: clause = sentence(macWhy(why, model: model))
        case .noAnswer: clause = "Binders' decision model didn't answer for it in time."
        case .numbersDiffer: clause = sentence(macWhy(.numbers, model: model))
        case .mayAct: clause = "\(agent) may send, post or buy for you, so it takes your tap."
        case .checksBoard: clause = "\(agent) checks the board itself, so it takes your tap."
        case .switchOff: clause = "Start on cards Binders sends it is off for \(agent) (Settings → Agents on your Mac)."
        case .switchBeforeAuto:
            clause = "\(agent) was let start on its own before Auto mode, so it takes your tap until you say yes for Auto mode too (Settings → Agents on your Mac)."
        case .switchBeforeSolo:
            clause = "\(agent) was let start on its own before Auto mode read what you think out loud, so what it reads from a capture takes your tap "
                + "until you say yes for that too (Settings → Agents on your Mac)."
        case .purposeNotTyped: clause = "\(agent)'s What it's for isn't in your own words yet (Settings → Agents on your Mac)."
        case .wouldNotWake: clause = "\(agent) can't be woken now: Settings → Agents on your Mac says why."
        case .notATaker: clause = "\(agent) doesn't take \(binder)'s cards: change that in Settings → Agents on your Mac."
        case .leftOutTaker: clause = "an agent Binders can't weigh also takes \(binder)'s cards: Settings → Agents on your Mac says which."
        case .notNamed: clause = "it isn't the agent you named."
        case .namedSomeoneElse: clause = "it reads as something for someone who isn't one of your agents."
        case .heardAnother: clause = "it sounds like you named \(heardAgent ?? "another agent")."
        case .onlyMentioned: clause = "\(agent) is only mentioned in it, not given the work."
        case .notThePick: clause = "Binders' decision model didn't pick it."
        case .underAutoBar: clause = "Binders wasn't sure enough it's \(agent)'s work."
        case .noYes:
            clause = fromCapture ? "you haven't said yes to \(agent) on your iPhone since Auto mode read what you think out loud. Give to asks."
                : "you haven't said yes to \(agent) on your iPhone as it's set up now. Give to asks."
        case .alreadyHanded: clause = "you said this \(ago(minutesAgo)), and \(agent) has it."
        case .tooManyAtOnce:
            clause = "Auto handed over \(AutoRules.lateAtOnce) things you said earlier in the last \(Int(AutoRules.lateWindow / 60)) minutes. "
                + "Give to hands this one over."
        case .modelChanged: clause = "the decision model changed while it was deciding."
        case .notConfirmed: clause = "the decision server on your Mac didn't confirm its model in time."
        case .changedSince: clause = "its card changed before Binders could hand it over."
        }
        return notHandedOverStart + clause
    }

    /// "1 minute ago", "4 minutes ago", "just now".
    static func ago(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "just now" }
        return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
    }

    /// Agents are paused: no agent question was asked, so there's no pick to name.
    public static let pausedLine = notHandedOverStart + "agents are paused. Resume them in Settings → Agents on your Mac."

    /// The model answered, its top pick an agent, but under the suggest band, so no agent was named at all.
    public static let notSureWhose = notHandedOverStart + "Binders wasn't sure enough whose work it is."

    // MARK: The Mac's reason, and each agent's

    /// The Mac's reason for handing nothing over in Auto, as a clause with its next step, for "Not handed over: …", the
    /// iPhone's "It hands nothing over now: …" and "Your Mac can't hand anything over now: …". `model` is the decision
    /// model's name; nil reads "the decision model". A reason this build doesn't know says where to look.
    public static func macWhy(_ why: AutoReach.Why?, model: String? = nil) -> String {
        let model = model.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "the decision model"
        switch why {
        case .off: return "the decision model on your Mac is off: choose one in Settings → AI on your Mac"
        case .checking: return "your Mac is still checking \(model), which takes a minute: Auto hands things over once it's done"
        case .unusable: return "\(model) on your Mac can't sort cards now: Settings → AI on your Mac says why"
        case .unmeasured: return "\(model) hasn't been measured on your Mac: Measure it in Settings → AI on your Mac"
        case .changed: return "\(model)'s measure was changed outside Binders: Measure Again in Settings → AI on your Mac"
        case .measuredBefore: return "\(model) was measured before Auto mode: Measure Again in Settings → AI on your Mac"
        case .noLevel:
            return "\(model)'s measure found no level at which it hands over the right agent often enough: "
                + "choose another decision model in Settings → AI on your Mac"
        case .numbers:
            return "\(model)'s numbers on your Mac differ from the ones it was measured with: Measure Again in Settings → AI on your Mac"
        case nil: return "the decision model on your Mac can't hand anything over now: Settings → AI on your Mac says why"
        }
    }

    /// The same, from list_agents' code.
    public static func macWhy(code: String?, model: String? = nil) -> String {
        macWhy(code.flatMap(AutoReach.Why.init(rawValue:)), model: model)
    }

    /// Why an agent won't take what you say in Auto, for the sheet's "Won't take it" rows: a sentence with what to do.
    /// Nil for one that takes it.
    public static func agentWhy(_ code: String?) -> String? {
        switch code.flatMap(AutoReach.Agent.init(rawValue:)) {
        case .takes: return nil
        case .mayAct: return "It may send, post or buy for you, so it always takes your tap."
        case .board: return "It checks the board itself, so it always takes your tap."
        case .switchOff: return "Start on cards Binders sends it is off for it on your Mac (Settings → Agents)."
        case .switchBefore:
            return "It was let start on its own before Auto mode: on your Mac, Review… beside its start switch (Settings → Agents) says what Auto adds."
        case .purpose: return "Its What it's for isn't in your own words yet, on your Mac (Settings → Agents)."
        case .paused: return "Agents are paused on your Mac: resume them in Settings → Agents."
        case .changed: return "It was changed outside Binders: open it on your Mac and save it."
        case .noYes: return "You haven't said yes to it on this iPhone since Auto mode."
        case nil: return "It can't take them now: see Settings → Agents on your Mac."
        }
    }

    /// What Stop can do for an agent that may take what you say, from list_agents' `wakes` and `open_session`: a run
    /// Binders starts ends; a command ends while it runs; anything that has the card already keeps it.
    public static func stopReach(wakes: String?, openSession: Bool? = nil) -> String {
        switch wakes {
        case "claudeCode" where openSession != true, "cliAgent": return "Stop ends its run."
        case "command": return "Stop ends its command while it runs; once it has rung the agent, Stop only moves the card back."
        default: return "Once it has the card, Stop only moves it back."
        }
    }

    /// Where agents left out of the agent question block an agent's hand-overs (list_agents' `auto_left_out`). Nil for none.
    public static func leftOutLine(_ agents: [String]) -> String? {
        let names = agents.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = names.first else { return nil }
        if names.count == 1 {
            return "Not in the binders \(first) also takes: Binders can't weigh \(first) now (Settings → Agents on your Mac)."
        }
        return "Not in the binders \(list(names)) also take: Binders can't weigh them now (Settings → Agents on your Mac)."
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    // MARK: Handed over (each moment's title and line)

    /// A hand-over's title: the agent, never your words.
    public static func handedTitle(_ agent: String) -> String { "Handed to \(agent)" }

    /// A card made ready for its agent and not woken: it waits on you.
    public static func notWokenTitle(_ agent: String) -> String { "Not woken yet: \(agent)" }

    /// A hand-over's line: "Added to Website and handed to Claude Code · app: Fix the login timeout." An idea is put on the
    /// board, to look into. `picked`: the decision model picked the binder, which the line says, as today's lines do.
    public static func handedLine(idea: Bool, binder: String, agent: String, task: String, picked: Bool = false) -> String {
        let pick = picked ? ", Binders' pick," : ""
        return idea ? "Put on the \(binder) board\(pick) and handed to \(agent) to look into: \(sentence(task))"
            : "Added to \(binder)\(pick) and handed to \(agent): \(sentence(task))"
    }

    /// A card made ready for its agent and not woken, with the dispatcher's reason (`why`, a clause): "… It wasn't woken:
    /// Claude Code · app was woken 6 times in the last hour. Wake Now on the card on your Mac does it."
    public static func notWokenLine(idea: Bool, binder: String, agent: String, task: String, why: String, picked: Bool = false) -> String {
        let pick = picked ? ", Binders' pick," : ""
        let made = idea ? "Put on the \(binder) board\(pick) and made ready for \(agent) to look into: \(sentence(task))"
            : "Added to \(binder)\(pick) and made ready for \(agent): \(sentence(task))"
        return made + " It wasn't woken: \(sentence(why)) Wake Now on the card on your Mac does it."
    }

    // MARK: Stop, Undo and Not me

    /// Undo of a hand-over, the card untouched by the agent: the card and what you said are taken back.
    public static func undoneLine(task: String, binder: String, agent: String) -> String {
        "Took “\(task)” off the \(binder) board and stopped \(agent)."
    }

    /// Undo of a hand-over the agent already had (a web hook, a Shortcut, a command that has rung, your open session).
    public static func undoneHadItLine(task: String, binder: String, agent: String) -> String {
        "Took “\(task)” off the \(binder) board. \(agent) already had the card: Binders can't fetch it back from it."
    }

    /// Undo once the agent has reported on the card or asked on it: stopped, and the card stays for you to delete.
    public static func undoneKeptLine(binder: String, agent: String, idea: Bool) -> String {
        idea ? "Stopped \(agent). It had reported on the card, so the card stays in the \(binder) board's Backlog: delete it there."
            : "Stopped \(agent). It had reported on the card, so the card and its to-do stay in the \(binder) board's Backlog: delete them there."
    }

    /// The iPhone's line after Not Me on a hand-over; `raised`: the start bar went up above that voice.
    public static func notMeLine(raised: Bool) -> String {
        let line = "Not you: stopped, taken back, and kept against your voice print."
        return raised ? line + " Your voice must now sound closer to yours for anything to go without asking; Calibrate again if that holds back too much."
            : line
    }

    /// What the iPhone says when it keeps Stop, Undo or Not Me until the Mac is back.
    public static func keptStop(agent: String) -> String { "Kept. Stop goes to your Mac when it's back; \(agent) keeps working until then." }
    public static let keptUndo = "Kept. Undo goes to your Mac when it's back."
    public static let keptNotMe = "Not you: kept against your voice print. Stopping it and taking it back go to your Mac when it's back."

    // MARK: Notifications

    /// Two Not me's among Auto's last ten hand-overs turned it off (AutoWatch).
    public static var turnedOff: NotificationText {
        NotificationText(title: "Auto is off",
                         body: "\(AutoRules.notMeToTurnOff) of the last \(AutoRules.notMeWindow) things Auto handed over weren't you, or weren't for Binders. "
                            + "Calibrate, then choose Auto again on the capture screen.")
    }

    /// The Mac lists MomentPayload.autoFeature for the first time, with Auto chosen: it opens the sheet.
    public static let canHandOverNow = NotificationText(title: "Auto can hand things over now",
                                                        body: "Open to see which agents may take what you say.")

    // MARK: When it was said

    /// When something was said, as the iPhone and the card say it after "You said it" or "Said to your iPhone": "at 3:10
    /// PM", "yesterday at 7:40 AM", "on Oct 17 at 9:02 AM", in `calendar`'s time zone and `locale`'s words for times and
    /// dates.
    public static func saidAt(_ heard: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        let time = heard.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(heard, inSameDayAs: now) { return "at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(heard, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        let day = heard.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
        return "on \(day) at \(time)"
    }

    /// The iPhone's sentence after a late moment's line (CaptureOutcome.late), in its own time zone: "You said it at 3:10 PM."
    public static func youSaidIt(_ heard: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "You said it \(saidAt(heard, now: now, calendar: calendar, locale: locale))."
    }

    // MARK: The card

    /// A to-do's card, handed over: what you said, and when.
    public static func todoDetails(said: String, heard: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "“\(sentence(said))”\n\nSaid to your iPhone \(saidAt(heard, now: now, calendar: calendar, locale: locale))."
    }

    /// What an idea's card asks of the agent it's handed to: a plan on the card, not the thing built. It limits itself, so
    /// Binders never edits the description afterwards: Send Back with what to do, or a comment, is the asking.
    public static let ideaAsk = "Look into this idea and write a short plan here: what it would take, and what to do first. "
        + "Don't build it until you're asked to on this card."

    /// An idea's card, handed over: what you said, when, and what's asked.
    public static func ideaDetails(said: String, heard: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        todoDetails(said: said, heard: heard, now: now, calendar: calendar, locale: locale) + "\n\n" + ideaAsk
    }

    /// Binders' note on a card it handed over in Auto, right after the wake. It begins as the start rule's note does
    /// ("Binders handed this to <agent> without asking"), which is what Stop on the card looks for, and says what Auto
    /// skips and what stays, which is true for you and for the agent, who reads it too. `asked`: a "Binders, …"; `named`:
    /// you named the agent; `idea`: to look into and plan.
    ///
    /// `solo` (lane Y2): read from a capture in which your iPhone heard only you ("you thought it out loud…"); `joined`: a
    /// moment said in such a capture that went with it ("you said it to your iPhone…, with no one else talking").
    public static func note(agent: String, idea: Bool, asked: Bool, named: Bool, heard: Date, now: Date, calendar: Calendar = .current,
                            locale: Locale = .current, solo: Bool = false, joined: Bool = false) -> String {
        let when = saidAt(heard, now: now, calendar: calendar, locale: locale)
        let said: String
        if solo, joined {
            said = (asked ? "you said it to Binders on your iPhone \(when)" : "you said it to your iPhone \(when)") + ", with no one else talking"
        } else if solo {
            said = "you thought it out loud to your iPhone \(when), with no one else talking"
        } else {
            said = asked ? "you said it to Binders on your iPhone \(when)" : "you said it on your own to your iPhone \(when)"
        }
        let why = named ? "and you named \(agent)." : "and it looks like \(agent)'s work."
        return "Binders handed this to \(agent) without asking\(idea ? ", to look into and plan" : ""): \(said), while it was in Auto, \(why) "
            + "Auto skips only Binders' own Give to question: drafting first, and asking approval before anything is sent, posted or bought, "
            + "stay as always. Stop it here, or turn off Auto on your iPhone (Binders → All-day capture)."
    }
}

// MARK: - Auto for thinking out loud (lane Y2)

extension AutoText {
    /// Why a capture wasn't read for what you said, as a clause, by the hold's word (the iPhone's or the Mac's): for "…, so
    /// it was offered, not handed over." and the Mac's "From your iPhone in Auto: offered, not handed over: …". A word this
    /// build doesn't know reads as the iPhone not hearing it as only you.
    public static func soloWhy(_ word: String?) -> String {
        switch word {
        case "print": "Binders doesn't know your voice yet: teach it on your iPhone's capture screen"
        case "calibrate": "Calibrate hasn't set how close your voice must be: Calibrate on your iPhone's capture screen"
        case "diarizer": "your iPhone couldn't tell the voices apart in it"
        case "audio": "your iPhone was playing audio while you spoke"
        case "call": "your iPhone was on a call during it"
        case "continues": "it carried on from a capture someone else spoke in"
        case "voice": "it didn't sound enough like you"
        case "voices": "someone else spoke in it"
        case "dialogue": "two voices took turns in it, though both sound like you"
        case "unsure": "too much of it wasn't heard as anyone's voice"
        case "parts": "it was too long to go to your Mac in one piece"
        case "transcript": "its transcript has more of someone else in it than a passing word"
        case "talking": "it sounded like you were talking to someone"
        case "mac-call": "you were on a call on your Mac during it"
        case "phone": "it came from an iPhone your Mac hasn't let hand things over: Settings → Agents → Sorting new cards on your Mac"
        default: "your iPhone didn't hear it as only you"
        }
    }

    /// The capture page's line for one that wasn't read: "Someone else spoke in it, so it was offered, not handed over."
    /// In Add at Once: "…, so it was offered, not added at once."
    public static func soloHeader(why word: String?, mode: MomentMode) -> String {
        let why = soloWhy(word)
        let start = why.prefix(1).uppercased() + why.dropFirst()
        return start + (mode == .add ? ", so it was offered, not added at once." : ", so it was offered, not handed over.")
    }

    /// The capture page's line for one that was read: "Only you, in Auto".
    public static func soloRead(mode: MomentMode) -> String { "Only you, in \(mode.name)" }

    /// A moment said in a capture in Auto, while it waits for its capture.
    public static let joinsCapture = "Not handed over yet: it goes with its capture, if only you spoke in it."

    /// A moment said in a capture that didn't go with it: the reason, from the capture's vouch.
    public static func joinedNot(why word: String?) -> String {
        let clause: String
        switch word {
        case "voices": clause = "someone else spoke in the capture it was in."
        case "audio": clause = "your iPhone was playing audio during the capture it was in."
        case "diarizer": clause = "your iPhone couldn't tell the voices apart in the capture it was in."
        case "voice": clause = "the capture it was in didn't sound enough like you."
        case "talking": clause = "the capture it was in sounded like you were talking to someone."
        case "transcript": clause = "the capture it was in had more of someone else in it than a passing word."
        default: clause = soloWhy(word) + ", in the capture it was in."
        }
        return notHandedOverStart + clause
    }

    /// A moment said in a capture whose own span wasn't heard as your voice (not in `soloMoments`).
    public static let joinedNotYours = notHandedOverStart + "your iPhone couldn't tell it was your voice that said it, in the capture it was in."
    /// …whose capture was read with Auto off by then.
    public static let joinedAutoOff = notHandedOverStart + "Auto was off by the time its capture was read."
    /// …whose capture had Stop All pressed on it first.
    public static let joinedStopped = notHandedOverStart + "you pressed Stop All on the capture it was in."
    /// …whose capture never came.
    public static let joinedNoCapture = notHandedOverStart + "its capture didn't reach your Mac within 12 hours."

    /// An item that's already an open card or to-do in its binder.
    public static func alreadyThere(binder: String, title: String) -> String { "Already on the \(binder) board: \(sentence(title))" }

    /// A card's description for something you thought out loud: your sentences, quoted, and when. An idea's ends with what's
    /// asked (`ideaAsk`).
    public static func soloDetails(said: String, heard: Date, now: Date, idea: Bool, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let text = "“\(sentence(SoloReading.cardWords(said)))”\n\nSaid to your iPhone \(saidAt(heard, now: now, calendar: calendar, locale: locale)), "
            + "while you thought out loud."
        return idea ? text + "\n\n" + ideaAsk : text
    }

    /// A capture's outcome line once it's read: "Filed in Website: Login, digest and the domain · 2 handed to agents · 1
    /// added · 8 more offered".
    public static func captureLine(binder: String, title: String, handed: Int, added: Int, offered: Int) -> String {
        var line = "Filed in \(binder)" + (title.isEmpty ? "" : ": \(title)")
        if handed > 0 { line += " · \(handed) handed to agents" }
        if added > 0 { line += " · \(added) added" }
        if offered > 0 { line += " · \(offered) more offered" }
        return line
    }

    /// "8 more from what you said", "1 more from what you said".
    public static func moreFound(_ count: Int) -> String { "\(count) more from what you said" }

    /// Stop All's line, from the Mac.
    public static func stopAllLine(_ count: Int, at time: String) -> String {
        count == 1 ? "Stopped 1 run from what you said \(time). Its card waits in Backlog; your to-do stays."
            : "Stopped \(count) runs from what you said \(time). Their cards wait in Backlog; your to-dos stay."
    }

    /// Not Only Me's line, from the Mac.
    public static func notOnlyMeLine(at time: String) -> String {
        "Took back what Binders made from what you said \(time), and Auto counts it as a Not Me. Its notes stay on your Mac."
    }

    /// The reading spoke and found nothing; or couldn't be read.
    public static let nothingFound = "Nothing to act on in what you said."
    public static let unreadFound = "Binders couldn't read it for things to do, so here's what its notes found."

    /// The Mac's capture page: the section's header, the line for a capture from an Auto iPhone that wasn't read, and where
    /// Not Only Me is.
    public static func macSection(mode: MomentMode) -> String { "From what you said, in \(mode.name): only you spoke in it" }
    public static func macUnread(why word: String?) -> String { "From your iPhone in Auto: offered, not handed over: \(soloWhy(word))." }
    public static let notOnlyMeOnPhone = "Not Only Me is on your iPhone, which keeps your voice print."
}
