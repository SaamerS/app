import Foundation

// The iPhone's own words for the modes and Auto: the line under the Mode menu, the capture screen's footers, the sheet
// that shows when Auto is chosen, the moment's page and Needs you. In the kit, beside AutoText, so the tests hold each one
// to the copy rules (a reason and the next step, no exclamation marks) and the Mode line picks its case by one rule.

public enum AutoPhoneText {
    // MARK: The Mode menu

    /// What Auto can't hear, under the Mode menu in Auto and on the sheet.
    public static let cantHear = "Say each thing on its own, starting with “I need to”, “remember to” or “idea for”. "
        + "Thinking out loud in between keeps what follows from going for three minutes."

    /// What the line under the Mode menu says, in Auto, about what it can do now (DESIGN 6.4).
    public struct ModeFacts: Equatable, Sendable {
        /// The Mac lists MomentPayload.autoFeature, and MomentPayload.addsFeature.
        public var macListsAuto: Bool
        public var macListsAdds: Bool
        /// The sheet has listed the agents once (`momentAutoListed`).
        public var listed: Bool
        /// The Mac can be reached now.
        public var macInReach: Bool
        /// Calibrate has set the start bar.
        public var startBarSet: Bool
        /// What list_agents last said about Auto; nil before it was heard.
        public var reach: AutoReach?
        /// The agents that may take what you say now (list_agents' `auto` "takes", and your yes here as each is now).
        public var mayTake: [String]

        public init(macListsAuto: Bool, macListsAdds: Bool = true, listed: Bool, macInReach: Bool, startBarSet: Bool, reach: AutoReach?,
                    mayTake: [String]) {
            self.macListsAuto = macListsAuto
            self.macListsAdds = macListsAdds
            self.listed = listed
            self.macInReach = macInReach
            self.startBarSet = startBarSet
            self.reach = reach
            self.mayTake = mayTake
        }
    }

    /// The line under the Mode menu in Auto: the first that holds of the Mac's update, the sheet not seen, the Mac out of
    /// reach, Calibrate, the Mac's decision model, no agent; else who may take what you say.
    public static func modeLine(_ facts: ModeFacts) -> String {
        if !facts.macListsAdds { return macNoAdds }
        if !facts.macListsAuto { return macNeedsUpdate }
        if !facts.listed { return notListed }
        if !facts.macInReach { return macAway }
        if !facts.startBarSet { return calibrate }
        if let reach = facts.reach, !reach.handsOver { return macCant(reach) }
        guard !facts.mayTake.isEmpty else { return noAgent }
        return mayTake(facts.mayTake)
    }

    /// "Claude Code · app and Grok Bot may take them now."; three or more: "A, B and 2 more may take them now."
    public static func mayTake(_ names: [String]) -> String {
        let names = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return noAgent }
        let who = names.count <= 2 ? AutoText.list(names) : "\(names[0]), \(names[1]) and \(names.count - 2) more"
        return "\(who) may take them now."
    }

    public static let noAgent = "No agent can take them now: choose Auto again to see what each one needs."
    public static let calibrate = "It hands nothing over until Calibrate sets how close your voice must be."
    public static let macNeedsUpdate = "Binders on your Mac needs an update for Auto mode. Until then it works as Add at Once."
    public static let notListed = "Auto works as Add at Once until you've seen which agents may take what you say: choose Auto again."
    public static let macAway = "Your Mac is out of reach: what you say waits here, and Auto hands it over when your Mac is back, "
        + "within 12 hours of when you said it."
    /// Add at Once or Auto with a Mac that doesn't list MomentPayload.addsFeature.
    public static let macNoAdds = "Binders on your Mac needs an update to add at once. Until then it offers each one."

    /// The Mac's decision model can't hand over: "It hands nothing over now: <reason, with its next step>. Until then it
    /// adds at once and offers Give to."
    public static func macCant(_ reach: AutoReach) -> String {
        "It hands nothing over now: \(AutoText.macWhy(code: reach.why, model: reach.model)). Until then it adds at once and offers Give to."
    }

    // MARK: Written down, or not (DESIGN 3.13)

    /// With Binders in the background, moments aren't written down now: CaptureWait's reason and way on.
    public static func notWrittenDownNow(_ reason: String) -> String {
        "With Binders in the background, what you say to yourself isn't written down now: \(reason)."
    }

    /// Clips let go today as they couldn't be written down. Nil for none.
    public static func notWrittenDown(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "1 thing you said today wasn't written down: Binders couldn't write it down in the background then."
            : "\(count) things you said today weren't written down: Binders couldn't write them down in the background then."
    }

    // MARK: The capture screen's footer and the first-time explanation

    /// The first-time explanation, as Said to yourself is turned on.
    public static let explanation = "While All-day capture listens, Binders writes down short things you say on your own. Said with “Binders, …”, "
        + "a to-do or an idea is added at once, with Undo; otherwise Binders offers it, until you've added nearly every one of its kind. "
        + "Only the words go to your Mac. Nothing from it is handed to an agent without your tap, unless you let that agent start on cards "
        + "Binders sends it and say “Binders, …” in your voice, or choose Auto under Mode. What isn't kept is forgotten."

    /// The section's footer: the same start in every mode, then what the mode does. `checks` is today's sentence on the
    /// cue, the voice, the quiet and Apple Intelligence.
    public static func footer(_ mode: MomentMode, checks: String) -> String {
        let start = "Say “Binders, …” while capture listens. Once Binders knows your voice (below), it also "
        switch mode {
        case .suggest:
            return start + "offers what you say to yourself, like “I need to book the dentist”. \(checks) A kind you add nearly every time, "
                + "40 times or more, is then added at once with Undo. Only the words go to your Mac, and nothing is kept of anything else."
        case .add:
            return start + "hears what you say to yourself, like “I need to book the dentist”. \(checks) In Add at Once, each one is added at once "
                + "with Undo. Only the words go to your Mac, and nothing is kept of anything else."
        case .auto:
            return start + "hears what you say to yourself, like “I need to book the dentist”. \(checks) In Auto, each one is added at once, and a "
                + "to-do or an idea goes to an agent you let start on its own, when it was you, on your own, past the bar Calibrate sets. "
                + "Only the words go to your Mac, with your yes for each agent, and nothing is kept of anything else."
        }
    }

    // MARK: A row, the moment's page, Needs you

    public static let handedOverWord = "Handed over"
    public static let notWokenWord = "Not woken yet"
    public static let waitsForGiveWord = "Waits for Give to"
    public static let stoppedWord = "Stopped"

    /// The moment's page, under your words: ", in Auto" after how it was heard.
    public static let inAuto = ", in Auto"

    /// The page's Auto section footer, naming the mode Turn Off Auto goes back to.
    public static func pageFooter(back: MomentMode) -> String {
        let off = back == .add ? "Off, what you say is still added at once, with Give to." : "Off, what you say is offered again, with Add and Not Now."
        return "Binders handed this over without asking, as your iPhone is in Auto. " + off
    }

    /// After Turn Off Auto.
    public static func turnedOff(back: MomentMode) -> String { "Auto is off: back to \(back == .auto ? MomentMode.suggest.name : back.name)." }

    /// Needs you's row for what waits on your Give to, or on Wake Now on the Mac.
    public static func waitsRow(_ count: Int) -> String {
        count == 1 ? "1 thing you said waits for you: Give to, or Wake Now on your Mac."
            : "\(count) things you said wait for you: Give to, or Wake Now on your Mac."
    }

    /// Not Me on something not handed over, kept until the Mac is back.
    public static let keptNotMe = "Not you: kept against your voice print. Taking it back goes to your Mac when it's back."

    // MARK: The sheet (DESIGN 6.2, 6.3)

    public enum Sheet {
        public static let title = "Auto"
        public static let heading = "Hand what you say to agents without asking?"
        public static let body = "In Auto, a to-do or an idea you say on your own, in your voice, is added at once and goes straight to the agent "
            + "Binders picks for it. Binders skips only its own question, Give to: each agent keeps its own permission checks, and is told to "
            + "ask your approval on the card before it sends, posts or buys anything. Notes, questions and “what's happening” are as before."
        public static let cantHear = String(AutoPhoneText.cantHear.dropLast()) + ", and nothing is handed over while your iPhone plays audio."
        public static let mayTakeHeader = "May take it now"
        public static let wontTakeHeader = "Won't take it"
        public static let toStopHeader = "To stop one"
        /// Under the heading, one line: what Auto does (`soloSubtitle` once it reads what you think out loud).
        public static let subtitle = "To-dos and ideas you say on your own go straight to an agent, without Give to."
        public static let soloSubtitle = "To-dos and ideas you say on your own, or think out loud where only you speak, go straight to an agent."
        /// The heading's disclosure, holding `body`, what it hears and when.
        public static let howItWorks = "How it works"
        public static let agentsHeader = "Agents"
        /// The agents list with no agent in it at all.
        public static let noAgents = "Your Mac has no agents Auto could hand things to. Add one in Settings → Agents on your Mac."
        /// Agents, none of them ready: the rows say what each needs.
        public static let noneReady = "None of your agents is ready for Auto yet."
        public static let noneReadyMore = "Each one below says what it needs."
        /// To stop one: where the buttons are, and a line for each, with More for the rest.
        public static let stopWhere = "Each hand-over sends a notification with:"
        public static let stopLine = "Stop: ends the run, card back to Backlog"
        public static let undoLine = "Undo: also takes back the to-do"
        public static let notMeLine = "Not Me: it wasn't you, so it's stopped and taken back"
        public static let turnOffLine = "Turn Auto off: on a hand-over's page, or under Mode"
        public static let more = "More"
        public static let stopMore = "Stop ends a run Binders started; an agent Binders sent the card to keeps what it got. Undo takes back the "
            + "to-do until the agent has reported on it. Not Me also keeps it against your voice print. The page a hand-over opens has "
            + "Turn Off Auto; so does Mode on the capture screen."

        /// What an agent's row says under its name.
        public enum Status: String, Sendable {
            /// Auto may hand it what you say now.
            case ready
            /// Its Mac lets it, and it waits for your yes here.
            case needsYes
            /// Something to do on your Mac first.
            case onMac
            /// It always asks: it may send, post or buy, or checks the board itself.
            case alwaysAsks
        }

        /// An agent's row: its status, one short thing to do (or why it always asks), and the longer reason behind the info
        /// button.
        public struct Row: Equatable, Sendable {
            public var status: Status
            public var label: String
            public var action: String?
            public var detail: String?
        }

        public static let readyWord = "Ready"
        public static let needsYesWord = "Needs your yes"
        public static let onMacWord = "Set up on your Mac"
        public static let alwaysAsksWord = "Always asks you first"

        /// The row for an agent's Auto code as the iPhone sees it (AgentConsents.autoCode): nil, or one this build doesn't
        /// know, says where to look.
        public static func row(_ code: String?) -> Row {
            let detail = AutoText.agentWhy(code)
            switch code.flatMap(AutoReach.Agent.init(rawValue:)) {
            case .takes: return Row(status: .ready, label: readyWord)
            case .noYes: return Row(status: .needsYes, label: needsYesWord, detail: detail)
            case .mayAct: return Row(status: .alwaysAsks, label: alwaysAsksWord, action: "It may send, post or buy for you", detail: detail)
            case .board: return Row(status: .alwaysAsks, label: alwaysAsksWord, action: "It checks the board itself", detail: detail)
            case .switchOff: return Row(status: .onMac, label: onMacWord, action: "Turn on Start on cards", detail: detail)
            case .switchBefore: return Row(status: .onMac, label: onMacWord, action: "Review its start switch", detail: detail)
            case .purpose: return Row(status: .onMac, label: onMacWord, action: "Add What it's for", detail: detail)
            case .paused: return Row(status: .onMac, label: onMacWord, action: "Resume agents", detail: detail)
            case .changed: return Row(status: .onMac, label: onMacWord, action: "Open it and save it", detail: detail)
            case nil: return Row(status: .onMac, label: onMacWord, action: "See Settings → Agents", detail: detail)
            }
        }

        /// A ready agent whose yes here (or on the Mac) is from before Auto read what you think out loud.
        public static let readyAlone = "Ready for what you say on its own"
        public static let sayYesAgainOnMac = "Say yes again on your Mac"
        /// A ready agent that Auto can't hand anything in some binders (list_agents' auto_left_out), its detail `leftOutLine`.
        public static let notEveryBinder = "Not in every binder"
        /// The info button's VoiceOver label.
        public static func moreLabel(_ agent: String) -> String { "More about \(agent)" }
        /// Review…'s VoiceOver label for the yes for what you think out loud.
        public static func reviewSoloLabel(_ agent: String) -> String { "Say yes to \(agent) for what you think out loud" }
        public static func macCant(_ reach: AutoReach) -> String {
            "Your Mac can't hand anything over now: \(AutoText.macWhy(code: reach.why, model: reach.model)). "
                + "Until it can, Auto adds what you say at once and offers Give to."
        }
        public static let calibrate = "Calibrate hasn't set how close your voice must be, so nothing you say is handed over yet."
        public static let macNeedsUpdate = "Binders on your Mac needs an update for Auto mode. Until then, Auto works as Add at Once: what you say is "
            + "added at once, and nothing is handed over."
        public static let notHeard = "Your iPhone hasn't heard which agents your Mac has. Open this again with your Mac in reach."
        public static let lastSaid = "As your Mac last said."
        public static let useAuto = "Use Auto"
        public static let notNow = "Not Now"
        public static let review = "Review…"
        public static let calibrateButton = "Calibrate"
        public static let sayYes = "Say Yes"
        /// Review…'s VoiceOver label: several rows have the same visible word.
        public static func reviewLabel(_ agent: String) -> String { "Say yes to \(agent)" }
        /// Review…'s question: Give to's own.
        public static func reviewTitle(_ agent: String) -> String { "Give cards to \(agent)?" }
    }
}

// MARK: - Auto for thinking out loud (lane Y2)

extension AutoPhoneText {
    /// What Auto hears, under the Mode menu in Auto, in place of `cantHear` once Auto reads what you think out loud.
    public static let soloHears = "Auto hears what you say on its own, and what you think out loud where only you speak. More than a passing word "
        + "from anyone near you keeps that capture asking, and nothing goes while your iPhone plays audio as you speak."

    /// Auto's state lines under the Mode menu, beside Y1's: a Mac with Auto but not this; when what you think out loud goes,
    /// with Write down while the iPhone is locked off or on; before the sheet with Y2's words.
    public static let macAutoNotSolo = "Your Mac hands over what you say on its own. For what you think out loud, update Binders on your Mac."
    public static let soloWhenLockedOff = "What you think out loud is handed over once it's written down: when you open Binders, or while your "
        + "iPhone charges, within 12 hours of when you said it."
    public static let soloWhenLockedOn = "What you think out loud is handed over a few minutes after you stop, for up to 15 minutes of speech."
    public static let soloBeforeSheet = "Auto reads what you think out loud once you've seen what's new: choose Auto again."

    /// The line under the Mode menu in Add at Once, once the Mac reads what you think out loud.
    public static let addSummarySolo = "Adds to-dos, ideas and notes at once, with Undo, and what you think out loud where only you speak, once "
        + "it's written down. Work for an agent is offered, with Give to."

    /// The section's footer for Add at Once and Auto, once the Mac reads what you think out loud.
    public static func soloFooter(_ mode: MomentMode, checks: String) -> String {
        let start = "Say “Binders, …” while capture listens. Once Binders knows your voice (below), it also "
        switch mode {
        case .suggest: return footer(.suggest, checks: checks)
        case .add:
            return start + "hears what you say to yourself, like “I need to book the dentist”. \(checks) In Add at Once, each one is added at once "
                + "with Undo, and so is what you think out loud where only you speak, once it's written down. Only the words go to your Mac, "
                + "and nothing is kept of anything else."
        case .auto:
            return start + "hears what you say to yourself, like “I need to book the dentist”. \(checks) In Auto, each one is added at once, and a "
                + "to-do or an idea goes to an agent you let start on its own, when it was you on your own past the bar Calibrate sets: said on "
                + "its own, or thought out loud in a capture where your iPhone heard only you. Only the words go to your Mac, with your yes for "
                + "each agent, and nothing is kept of anything else."
        }
    }

    /// The Mac first reads what you think out loud: once, in Auto (opening the sheet), or in Add at Once.
    public static let soloNowInAuto = NotificationText(title: "Auto can read what you think out loud now", body: "Open to see what's new before it does.")
    public static let soloNowInAdd = NotificationText(title: "Add at Once now adds what you think out loud",
                                                      body: "Where only you speak, its to-dos, fixes and ideas are added at once, with Undo. Open to see how.")

    // MARK: A capture's page, an item's page

    public static let fromWhatYouSaid = "From what you said"
    public static let addedWord = "Added"
    public static let offeredWord = "Offered"
    public static let takenBackWord = "Taken back"
    /// A moment's state word while it waits for its capture.
    public static let withItsCapture = "With its capture"
    /// Under a joined moment's time on its capture's page.
    public static let heardAsSaid = "heard as you said it"
    public static let stopAll = "Stop All"
    public static let stopAllFooter = "Stops what Binders handed over from this capture and puts the cards back in Backlog. Your to-dos stay."
    public static let notOnlyMe = "Not Only Me"
    public static let notOnlyMeFooter = "Someone else spoke in it: stop and take back what it made."
    public static let notOnlyMeTitle = "Take back everything from this capture?"
    public static func notOnlyMeMessage(todos: Int, cards: Int) -> String {
        let things = [todos == 1 ? "1 to-do" : "\(todos) to-dos", cards == 1 ? "1 card" : "\(cards) cards"]
        return "\(things.joined(separator: " and ")) go, and the runs stop. Your voice must sound closer to yours from now on."
    }
    public static let takeBack = "Take Back"
    /// Not Me's footer on an item's page: what it means for something read from a capture.
    public static let itemNotMeFooter = "Someone else said this."
    /// The capture page's Auto section footer, naming the mode Turn Off Auto goes back to.
    public static func capturePageFooter(back: MomentMode) -> String {
        let off = back == .add ? "Off, what you say is still added at once, with Give to." : "Off, what you say is offered again, with Add and Not Now."
        return "Binders handed these over without asking, as only you spoke in this capture and your iPhone is in Auto. " + off
    }
    /// After a capture's wait, in Auto.
    public static let readsThen = "Auto reads it then, if only you spoke in it."
    /// A moment waiting for its capture, after the Mac's line: its capture's own wait.
    public static let captureNotWrittenDown = "Its capture is waiting to be written down: open Binders or plug in."
    public static let captureOnItsWay = "Its capture is on its way to your Mac."
    public static let captureBeingRead = "Your Mac is reading its capture."
    /// An item's page, under your words.
    public static func itemHeard(_ time: String, mode: MomentMode) -> String { "\(time), in a capture where only you spoke, in \(mode.name)" }
    public static let openCapture = "Open Capture"
    /// A capture in Auto heard before the sheet with Y2's words: offered as before.
    public static let offeredAsBefore = "Offered as before: Auto reads what you think out loud once you've seen what's new. Choose Auto again."
    /// Kept for the Mac.
    public static let keptStopAll = "Kept. Stop All goes to your Mac when it's back; the agents keep working until then."
    public static let keptNotOnlyMe = "Someone else was in it: counted for Auto mode, and your voice must sound closer to yours from now on. "
        + "Taking back what it made goes to your Mac when it's back."
    /// A capture kept for a moment said in it, its row.
    public static let keptForMoment = "Kept for what you said in it"

    // MARK: The sheet, with Y2's words

    public enum SoloSheet {
        public static let body = "In Auto, a to-do or an idea you say on your own, in your voice, or think out loud where only you speak, is added "
            + "at once and goes straight to the agent Binders picks for it. Binders skips only its own question, Give to: each agent keeps its own "
            + "permission checks, and is told to ask your approval on the card before it sends, posts or buys anything. Notes, questions and "
            + "“what's happening” are as before."
        public static let hears = "It hears what you say on its own, with or without a cue like “I need to”, and what you think out loud where only "
            + "you speak: a capture in which your iPhone heard only your voice goes once it's written down, each thing in it on its own, with "
            + "only the sentences it came from. More than a passing word from anyone near you keeps that capture asking, as every conversation "
            + "does, and nothing is handed over while your iPhone plays audio as you speak. Before you talk with someone, Wrap Up on the Lock "
            + "Screen keeps what you thought out loud until then as only you."
        public static let whenOff = "On a walk, turn on Write down while the iPhone is locked: then what you think out loud is handed over a few "
            + "minutes after you stop, for up to 15 minutes of speech. A longer capture waits until you open Binders and keep it open, or plug "
            + "in, and nothing goes more than 12 hours after you said it. On a long walk, Wrap Up halfway keeps each part under 15 minutes."
        public static let whenOn = "What you think out loud is handed over a few minutes after you stop, for up to 15 minutes of speech; a longer "
            + "capture waits until you open Binders or plug in. On a long walk, Wrap Up halfway keeps each part under 15 minutes."
        public static let turnItOn = "Turn It On"
        public static let usesMoreBattery = "Uses more battery."
        public static let onlyBefore = "Only what you say on its own, until you say yes again for what you think out loud."
        public static let onlyBeforeMac = "Only what you say on its own, until you say yes again on your Mac (Settings → Agents)."
        public static let macAutoNotSolo = AutoPhoneText.macAutoNotSolo
    }

    // MARK: Calibrate

    public static let calibrateUncuedFooter = "In Auto, Calibrate also has you read 30 things said without a cue."
}
