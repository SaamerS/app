import Foundation

// MARK: - The checks, named

extension MomentGate {
    /// The checks something heard goes through on the iPhone, in the order the gate (MomentCenter.gate) runs them. The
    /// first that fails says why it isn't a moment. The calibration bench, which runs them all, keeps every one that
    /// failed, so it can tell what another voice threshold would have done.
    public enum Check: String, Codable, Sendable, CaseIterable {
        /// Said in a conversation (too little quiet before it, or someone answered), and it doesn't open with "Binders,".
        case inConversation
        /// Capture wrote down 20 things in ten minutes (a TV, a podcast), so moments rest for ten minutes.
        case resting
        /// Neither speech engine could write it down then.
        case notWrittenDown
        /// Fewer than two words.
        case tooFewWords
        /// No voice print yet, so nothing heard on its own can be yours.
        case noVoicePrint
        /// No cue in the words, like "I need to" or "what was our … again".
        case noCue
        /// The voice couldn't be told: two voices in it, or too little of one.
        case voiceUnclear
        /// The voice wasn't close enough to your print.
        case notYourVoice
        /// Apple's model on the iPhone read it as another kind, or as nothing to act on.
        case modelDisagreed

        /// Why it wasn't taken, in a few words.
        public var reason: String {
            switch self {
            case .inConversation: "Said in a conversation"
            case .resting: "Resting after 20 in ten minutes"
            case .notWrittenDown: "Couldn't be written down"
            case .tooFewWords: "Under two words"
            case .noVoicePrint: "No voice print yet"
            case .noCue: "No cue in the words"
            case .voiceUnclear: "The voice couldn't be told"
            case .notYourVoice: "Not close enough to your voice"
            case .modelDisagreed: "Apple Intelligence disagreed"
            }
        }
    }
}

// MARK: - The calibration bench

/// The calibration bench for things said to yourself (Capture → Calibrate on the iPhone): phrases said one at a time, by
/// you and by someone else, a timed run of TV or a podcast, and a 40-line check of automatic mode. Each clip goes through
/// the iPhone's real gate with every score kept and its audio dropped. From the scores come what each group of phrases
/// got through, the false accepts, and the voice threshold that lets about 1% of other voices through on 2-5 s clips.
/// Scores, timings and labels only, never audio or what was said. Pure, so it's tested here; the iPhone records and scores.
public enum MomentBench {
    /// One run of the bench, and whose voice it hears.
    public enum Run: String, Codable, Sendable, CaseIterable {
        /// You, saying the phrases.
        case phrases
        /// Someone else saying them: "not me".
        case otherVoices
        /// TV or a podcast playing, timed: anything taken is a false accept.
        case media
        /// You, saying the 40 lines that check automatic mode.
        case script

        /// It hears your voice.
        public var isYours: Bool { self == .phrases || self == .script }

        /// Whose voice, as a result is labelled: "me", "not me", or "tv" for TV and podcasts.
        public var speaker: String {
            switch self {
            case .phrases, .script: "me"
            case .otherVoices: "not me"
            case .media: "tv"
            }
        }
    }

    /// The groups of phrases: five kinds that should be taken, and two that shouldn't.
    public enum Group: String, Codable, Sendable, CaseIterable {
        case todo, question, idea, status, note
        /// Sounds like a cue but isn't meant for Binders: said to someone, quoted from TV, read aloud, a passing remark.
        case notMeant
        /// Plain talk, with no cue.
        case chatter
        /// Lane Y2: a to-do, a fix or an idea said without a cue, which only Auto takes. Said only while the mode is Auto.
        case uncued

        public var title: String {
            switch self {
            case .todo: "To-dos"
            case .question: "Questions"
            case .idea: "Ideas"
            case .status: "How things stand"
            case .note: "Notes"
            case .notMeant: "Not meant for Binders"
            case .chatter: "Chatter"
            case .uncued: "Without a cue"
            }
        }

        /// Its phrases should get through the gate.
        public var shouldBeTaken: Bool { kind != nil }

        /// …in Auto too: the phrases without a cue should then (lane Y2).
        public func shouldBeTaken(inAuto auto: Bool) -> Bool { shouldBeTaken || (auto && self == .uncued) }

        /// The kind its phrases are, for the five that should be taken.
        public var kind: MomentKind? {
            switch self {
            case .todo: .todo
            case .question: .question
            case .idea: .idea
            case .status: .status
            case .note: .note
            case .notMeant, .chatter, .uncued: nil
            }
        }
    }

    /// One phrase to say.
    public struct Phrase: Equatable, Sendable, Identifiable {
        /// Its group and its place there, "todo-07": what a result keeps. New phrases go at the end of their group, so
        /// the ids results already hold stay the same.
        public let id: String
        public let group: Group
        public let text: String
        /// How to say it, when that matters: "To someone in the room".
        public let hint: String?
        /// For a phrase without a cue (lane Y2): what Auto should read it as, "fix", "todo" or "idea".
        public var uncued: String? = nil

        /// The kind it should be taken as in Auto: a fix is a to-do.
        public var uncuedKind: MomentKind? { uncued.map { $0 == "idea" ? .idea : .todo } }
    }

    // MARK: Phrases

    /// About 150 phrases in seven groups, in the order they're said. Some name a binder or say when, and the bench scores
    /// those too (`expectations`).
    public static let phrases: [Phrase] = [
        made(.todo, [
            "I need to book a doctor's appointment.",
            "Man, I need to call the plumber about the leak.",
            "I have to renew my passport before March.",
            "I've got to send Sam the slides tonight.",
            "Gotta pick up milk on the way home.",
            "Don't forget to water the plants.",
            "Remember to take the bins out tonight.",
            "Remind me to call the dentist tomorrow morning.",
            "I really need to answer the email from the landlord.",
            "Oh, I need to order more printer ink.",
            "I have to finish the expense report by Friday.",
            "We need to book the venue for the offsite.",
            "I need to cancel the gym membership.",
            "Don't let me forget to pay the electricity bill.",
            "I have to move the car before eight.",
            "Need to buy a birthday present for Sam.",
            "I need to email the accountant about the receipts.",
            "So I have to update the booth plan for Ignite.",
            "I've got to fix the squeaky door.",
            "I need to schedule the car service.",
            "Remember to bring the charger tomorrow.",
            "I need to text Sam the address.",
            "Okay, I need to print the boarding passes.",
            "I need to check when the insurance renews.",
            "I have to return the library books this week.",
            "Don't forget the dry cleaning.",
            "I need to back up my laptop.",
            "Gotta call the bank about the card.",
            "I need to write the newsletter draft.",
            "Remind me to defrost the chicken.",
            "I need to call the plumber for Home.",
            "I need to book the venue for Events by Friday.",
            "I need to send Sam the slides in two days.",
        ]),
        made(.question, [
            "What was our Ignite booth again?",
            "What was the name of that restaurant again?",
            "When is the dentist again?",
            "When's the team offsite again?",
            "What was the wifi password at the office again?",
            "What was our budget for the launch again?",
            "When is Sam's flight again?",
            "I need to find out when the Ignite setup is.",
            "I need to know what the booth number is.",
            "What was the plumber's number again?",
            "When is the car service again?",
            "What was the dentist's address again?",
            "I have to figure out where the venue is.",
            "What was our order number again?",
            "When is the rent due again?",
            "What was the title of that book again?",
            "When's the school concert again?",
            "What was our price with the printer again?",
            "I need to remember what Sam said about pricing.",
            "What was the conference hotel again?",
            "What was our budget for Ignite again?",
        ]),
        made(.idea, [
            "Idea for a feature for Binders: a weekly digest of my promises.",
            "Idea for a talk: building apps that work offline.",
            "Here's an idea for the offsite: a walking meeting.",
            "Idea for a blog post about local-first software.",
            "Quick idea for the booth: a live demo screen.",
            "Idea for the newsletter, a monthly reading list.",
            "I have an idea for the keyboard: snippets by voice.",
            "Idea for a product: a shopping list that learns what I buy.",
            "New idea for the website: a short film on the home page.",
            "Idea for a post: what I learned shipping a Mac app.",
            "Idea for Binders: let me snooze a card until Monday.",
            "Idea for the team: a demo hour on Fridays.",
            "Idea for a feature: search by who said it.",
            "Here's an idea for the launch, a waitlist with a referral code.",
            "Idea for the podcast: an episode on taking notes.",
            "Idea for a talk at Ignite about voice interfaces.",
            "Idea for the app: a widget that shows what needs me.",
            "Another idea for the booth: free stickers.",
            "Idea for a side project: a reminder to water the plants.",
            "Idea for the onboarding: a thirty second tour.",
            "Idea for Events: a quiz at the booth.",
        ]),
        made(.status, [
            "What's happening with my work streams?",
            "What's going on with my projects?",
            "Catch me up on everything.",
            "What's the latest on my agents?",
            "Where are we on everything today?",
            "Status of my boards?",
            "What's going on today?",
            "So, what's happening this week?",
            "What's the status of my tasks?",
            "Okay, catch me up.",
            "What's happening with the agents right now?",
            "Where are we with the work streams?",
            "Give me the status on my projects.",
            "What's going on with everything?",
            "Catch me up on my agents.",
            "What's the latest with the team?",
            "Where are we on my tasks this week?",
            "What's happening on the boards today?",
            "Right, what's going on with my work?",
            "What's the latest on my cards?",
        ]),
        made(.note, [
            "Note to self: the booth is 12B.",
            "Note to self, the gate code is 4512.",
            "Remind me that the parking is on level three.",
            "Don't forget the spare key is under the blue pot.",
            "Note to self: Sam prefers mornings.",
            "Note to self, the printer needs the A4 tray.",
            "Remind me, the invoice number starts with 77.",
            "Note to self: the dentist moved to Harbour Street.",
            "Note to self, Sam's size is a medium.",
            "Remind me the wifi password is on the fridge.",
            "Note to self: the recycling goes out on Tuesdays.",
            "Note to self, the booth needs two extension cords.",
            "Remind me the meeting room is on the fourth floor.",
            "Note to self: the tyre pressure is thirty-two.",
            "Note to self, the landlord's number is on the lease.",
            "Note to self for Events: the booth is 12B.",
        ]),
        made(.notMeant, [
            ("Sam, we need to leave in five minutes.", room),
            ("Honey, don't forget your keys.", room),
            ("Can you remind me to call you back?", phone),
            ("We have to get going, the film starts at eight.", room),
            ("Do you need to use the bathroom before we go?", room),
            ("I'll remember to bring it next time, promise.", phone),
            ("Hold on, I have to take this call.", room),
            ("Remember to wash your hands before dinner.", room),
            ("Mum, I need to go, talk later.", phone),
            ("Don't forget to text me when you land.", phone),
            ("And then the detective says, I need to see the body.", tv),
            ("Like in the film, we have to go back.", tv),
            ("The ad keeps saying don't forget to subscribe.", tv),
            ("He shouted, I've got to get out of here.", tv),
            ("The host asked, what was the capital of Peru again?", tv),
            ("Chapter two. She knew she had to leave the city.", reading),
            ("Step three: remember to preheat the oven.", reading),
            ("The sign says don't forget your belongings.", reading),
            ("The email says we need to reschedule our call.", reading),
            ("Dear team, we have to move the launch to May.", reading),
            ("I need to stop eating so much chocolate.", remark),
            ("Ugh, I have to admit that was funny.", remark),
            ("I really need to get more sleep.", remark),
            ("Gotta love Monday mornings.", remark),
            ("Remind me never to eat there again.", remark),
            ("What's going on with this traffic?", remark),
            ("Where are we on the map right now?", remark),
            ("Idea for dinner: let's just order pizza.", room),
            ("Note to self, never trust the weather app.", remark),
            ("What's happening? Why is the music so loud?", remark),
        ]),
        made(.chatter, [
            "That was a really good lunch.",
            "It's freezing in here.",
            "Where did I put my glasses?",
            "The traffic was terrible this morning.",
            "I think it's going to rain later.",
            "This coffee is too strong.",
            "Okay, let's see what's on the news.",
            "Wow, look at that sunset.",
            "I can't believe it's already October.",
            "Hmm, that's interesting.",
            "The kids loved the park today.",
            "My back is sore from the gym.",
            "Nice, the package arrived early.",
            "Let me think about it for a minute.",
            "That song is stuck in my head.",
            // Lane Y2: the walk's complaints and musing that the rules for no cue could keep, said in Auto only.
            "Their website is so slow.",
            "The menu at that place was confusing.",
            "The football app crashed during the match.",
            "The ticket machine doesn't work.",
            "The post was too long to read on the bus.",
            "Maybe we could try that new place.",
            "How about trying the other path.",
            "The light at the crossing is broken.",
            "What if I'm wrong about all this?",
            "The traffic is way too slow today.",
            "We should get going before it rains.",
            "I should have brought a jacket.",
            "It would be nice if the sun came out.",
            "That podcast was way too long.",
            "My headphones keep falling out.",
        ]),
        uncuedPhrases,
    ].flatMap { $0 }

    /// Lane Y2's group: things said without a cue that Auto should take, each with its kind.
    private static let uncuedPhrases: [Phrase] = [
        ("The site's login times out too fast.", "fix"),
        ("The export doesn't include the dates.", "fix"),
        ("The search is way too slow on big binders.", "fix"),
        ("There's a typo on the pricing page.", "fix"),
        ("The dark mode toggle keeps resetting.", "fix"),
        ("The share button is hidden on the iPhone.", "fix"),
        ("The sync is really flaky when the Mac is asleep.", "fix"),
        ("The onboarding is confusing.", "fix"),
        ("The widget shows the wrong count.", "fix"),
        ("The app crashes when I rotate the phone.", "fix"),
        ("The upload hangs when the file is big.", "fix"),
        ("I just noticed the footer links are broken.", "fix"),
        ("The newsletter template looks cramped on a phone.", "fix"),
        ("The board should remember which column I was in.", "fix"),
        ("I should email the accountant about the receipts.", "todo"),
        ("I should probably renew the domain this week.", "todo"),
        ("I must call the bank about the card.", "todo"),
        ("I'd better book the flights tonight.", "todo"),
        ("To-do: order more printer ink.", "todo"),
        ("I want to rewrite the README before the launch.", "todo"),
        ("Must send the invoice to the printer.", "todo"),
        ("We should fix the login timeout before the launch.", "todo"),
        ("What if the board showed who's busiest?", "idea"),
        ("We could add a weekly digest of what the agents did.", "idea"),
        ("We should add a weekly digest.", "idea"),
        ("It would be nice to have a snooze on cards.", "idea"),
        ("Maybe we should offer a yearly plan.", "idea"),
        ("Feature idea: let me drag cards between binders.", "idea"),
        ("How about adding a quiz at the booth.", "idea"),
        ("Wouldn't it be cool if the widget showed the next card?", "idea"),
    ].enumerated().map { index, phrase in
        Phrase(id: "uncued-\(String(format: "%02d", index + 1))", group: .uncued, text: phrase.0, hint: nil, uncued: phrase.1)
    }

    /// The chatter phrases said only in Auto (lane Y2), after the fifteen before them.
    public static let autoChatter: ClosedRange<Int> = 16...30

    /// The phrases said in a run: the group without a cue, and the chatter after the fifteenth, only in Auto.
    public static func phrases(inAuto auto: Bool) -> [Phrase] {
        guard !auto else { return phrases }
        return phrases.filter { phrase in
            if phrase.group == .uncued { return false }
            if phrase.group == .chatter, let place = Int(phrase.id.dropFirst("chatter-".count)), autoChatter.contains(place) { return false }
            return true
        }
    }

    private static let room = "To someone in the room"
    private static let phone = "As if on the phone"
    private static let tv = "As if quoting the TV"
    private static let reading = "Read it aloud, as from a page"
    private static let remark = "A passing remark, not for Binders"

    private static func made(_ group: Group, _ texts: [String]) -> [Phrase] {
        made(group, texts.map { ($0, nil) })
    }

    private static func made(_ group: Group, _ lines: [(String, String?)]) -> [Phrase] {
        lines.enumerated().map { index, line in
            Phrase(id: "\(group.rawValue)-\(String(format: "%02d", index + 1))", group: group, text: line.0, hint: line.1)
        }
    }

    /// A phrase by its id.
    public static func phrase(_ id: String?) -> Phrase? {
        guard let id else { return nil }
        return phrasesByID[id]
    }

    private static let phrasesByID = Dictionary(uniqueKeysWithValues: phrases.map { ($0.id, $0) })

    // MARK: The 40 lines

    /// What a line of the 40 should come to.
    public enum Expected: Equatable, Sendable {
        /// Taken, as this kind; nil for any kind.
        case taken(MomentKind?)
        /// Let go, and which check should do it.
        case letGo(LetGo)

        /// "Taken, as a to-do", "Let go: no cue".
        public var summary: String {
            switch self {
            case .taken(let kind?): "Taken, as \(MomentBench.named(kind))"
            case .taken(nil): "Taken"
            case .letGo(let why): "Let go: \(why.summary)"
            }
        }
    }

    /// Which check should let a line go.
    public enum LetGo: String, Sendable {
        /// The rules: no cue in the words.
        case noCue
        /// Apple's model: it has a cue, but isn't meant for Binders. Only an iPhone with Apple Intelligence can tell.
        case notMeant
        /// The detector: too short, too long, or answered.
        case detector

        public var summary: String {
            switch self {
            case .noCue: "no cue"
            case .notMeant: "not meant for Binders"
            case .detector: "not said on its own"
            }
        }
    }

    /// One line of the 40.
    public struct Line: Equatable, Sendable, Identifiable {
        /// "line-07".
        public let id: String
        public let text: String
        public let hint: String?
        public let expected: Expected
        /// What it should come to in Auto, when that differs (lane Y2): line-36's idea without a cue is taken.
        public var inAuto: Expected? = nil
    }

    /// Automatic mode, checked line by line: no wake phrase, so it takes what's said on its own with a cue in your voice
    /// (and that Apple's model agrees with), and lets the rest go. Fixed, so each run says the same 40 lines.
    public static let script: [Line] = lines([
        ("I need to book a doctor's appointment.", nil, .taken(.todo)),
        ("You need to try this recipe.", nil, .letGo(.noCue)),
        ("What was our Ignite booth again?", nil, .taken(.question)),
        ("Man, I need to call the plumber about the leak.", nil, .taken(.todo)),
        ("Idea for a feature for Binders: a weekly digest of my promises.", nil, .taken(.idea)),
        ("I got to the office late today.", nil, .letGo(.noCue)),
        ("What's happening with my work streams?", nil, .taken(.status)),
        ("Sam, we need to leave in five minutes.", room, .letGo(.notMeant)),
        ("Don't forget to renew the car insurance.", nil, .taken(.todo)),
        ("Okay.", "Just this one word", .letGo(.detector)),
        ("When is the team offsite again?", nil, .taken(.question)),
        ("I have to say, the film was great.", nil, .letGo(.noCue)),
        ("I have to send the invoice to the printer by Friday.", nil, .taken(.todo)),
        ("And then the detective says, I need to see the body.", tv, .letGo(.notMeant)),
        ("Catch me up on everything.", nil, .taken(.status)),
        ("The weather is lovely this morning.", nil, .letGo(.noCue)),
        ("Idea for a talk about building apps that work offline.", nil, .taken(.idea)),
        ("Gotta pick up the dry cleaning tomorrow.", nil, .taken(.todo)),
        ("I need to call Sam. Yes, after lunch.", "Say the first sentence, wait two seconds, then the second", .letGo(.detector)),
        ("I need to find out when the Ignite setup is.", nil, .taken(.question)),
        ("Can you pass me the salt?", room, .letGo(.noCue)),
        ("Remember to take the bins out tonight.", nil, .taken(.todo)),
        ("Gotta love Monday mornings.", remark, .letGo(.notMeant)),
        ("Note to self: the booth is 12B.", nil, .taken(nil)),
        ("They really have to fix that road.", nil, .letGo(.noCue)),
        ("Where are we with the work streams?", nil, .taken(.status)),
        ("We need to order more coffee for the office.", nil, .taken(.todo)),
        ("Step three: remember to preheat the oven.", reading, .letGo(.notMeant)),
        ("Where did I put my glasses?", nil, .letGo(.noCue)),
        ("I've got to email Sam the booth plan.", nil, .taken(.todo)),
        ("Here's an idea for the offsite: a walking meeting.", nil, .taken(.idea)),
        ("I need a holiday.", nil, .letGo(.noCue)),
        ("What was the plumber's number again?", nil, .taken(.question)),
        ("Hold on, I have to take this call.", room, .letGo(.notMeant)),
        ("Note to self, the gate code is 4512.", nil, .taken(nil)),
        ("What if we let the keyboard suggest snippets?", nil, .letGo(.noCue)),
        ("I need to pay the electricity bill by Thursday.", nil, .taken(.todo)),
        ("I need to remember to pick up the groceries, call the bank about the card, book the car service for next week, email the accountant the receipts, water the plants on the balcony, and sort out the photos from the holiday before anyone asks for them again.",
         "At your normal pace, without stopping", .letGo(.detector)),
        ("Binders, what was our Ignite booth again?", "With the wake word", .taken(.question)),
        ("Remind me to call the dentist tomorrow morning.", nil, .taken(.todo)),
    ])

    private static func lines(_ lines: [(String, String?, Expected)]) -> [Line] {
        lines.enumerated().map { index, line in
            Line(id: "line-\(String(format: "%02d", index + 1))", text: line.0, hint: line.1, expected: line.2,
                 inAuto: index + 1 == 36 ? .taken(.idea) : nil)
        }
    }

    /// A kind as a line of the 40 expects it: "a to-do", "a status request".
    public static func named(_ kind: MomentKind) -> String {
        kind == .status ? "a status request" : MomentGate.described(kind)
    }

    /// A line by its id.
    public static func line(_ id: String?) -> Line? {
        guard let id else { return nil }
        return script.first { $0.id == id }
    }

    // MARK: The binder named and the due date

    /// The binders the bench reads what was said against, whatever binders this iPhone knows: so every iPhone scores the
    /// binder named alike, and a phrase naming one of these is read the same way everywhere.
    public static let binders = ["Binders", "Events", "Home", "Ignite", "Personal"]

    /// When a phrase or line says it's due, counted from the day it was said.
    public enum Due: Equatable, Sendable {
        /// That many days after the day it was said: 0 for "tonight", 1 for "tomorrow".
        case days(Int)
        /// The next such weekday, that day included (Calendar's numbering: 1 is Sunday, 6 is Friday): "by Friday".
        case weekday(Int)
        /// Later the week it was said in: "this week".
        case thisWeek
        /// Before the next first of that month: "before March".
        case beforeMonth(Int)

        /// "today", "tomorrow", "by Friday", "this week", "before March".
        public var summary: String {
            switch self {
            case .days(0): "today"
            case .days(1): "tomorrow"
            case .days(let n): "in \(n) days"
            case .weekday(let day): "by " + Self.weekdays[((day - 1) % 7 + 7) % 7]
            case .thisWeek: "this week"
            case .beforeMonth(let month): "before " + Self.months[((month - 1) % 12 + 12) % 12]
            }
        }

        private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                     "October", "November", "December"]

        /// Whether `day`, the day the rules read, is this, for something said at `heard`.
        public func matches(_ day: Date, heard: Date, calendar: Calendar = .current) -> Bool {
            let from = calendar.startOfDay(for: heard), to = calendar.startOfDay(for: day)
            guard let after = calendar.dateComponents([.day], from: from, to: to).day, after >= 0 else { return false }
            switch self {
            case .days(let n):
                return after == n
            case .weekday(let weekday):
                return after <= 7 && calendar.component(.weekday, from: to) == weekday
            case .thisWeek:
                return calendar.isDate(to, equalTo: from, toGranularity: .weekOfYear)
            case .beforeMonth(let month):
                guard let first = calendar.nextDate(after: from, matching: DateComponents(month: month, day: 1), matchingPolicy: .nextTime)
                else { return false }
                return to < first
            }
        }
    }

    /// What a phrase or line names besides its kind: a binder, when it names one, and when it's due, when it says.
    public struct Expects: Equatable, Sendable {
        public var binder: String?
        public var due: Due?
    }

    /// The phrases and lines that name a binder or say when, by id. The rest name neither. "Before eight" (todo-15) has
    /// none, as its day depends on when it's said.
    public static let expectations: [String: Expects] = [
        "todo-03": Expects(due: .beforeMonth(3)),
        "todo-04": Expects(due: .days(0)),
        "todo-07": Expects(due: .days(0)),
        "todo-08": Expects(due: .days(1)),
        "todo-11": Expects(due: .weekday(6)),
        "todo-18": Expects(binder: "Ignite"),
        "todo-21": Expects(due: .days(1)),
        "todo-25": Expects(due: .thisWeek),
        "todo-31": Expects(binder: "Home"),
        "todo-32": Expects(binder: "Events", due: .weekday(6)),
        "todo-33": Expects(due: .days(2)),
        "question-21": Expects(binder: "Ignite"),
        "idea-01": Expects(binder: "Binders"),
        "idea-11": Expects(binder: "Binders"),
        "idea-21": Expects(binder: "Events"),
        "note-16": Expects(binder: "Events"),
        "line-05": Expects(binder: "Binders"),
        "line-13": Expects(due: .weekday(6)),
        "line-18": Expects(due: .days(1)),
        "line-22": Expects(due: .days(0)),
        "line-37": Expects(due: .weekday(5)),
        "line-40": Expects(due: .days(1)),
    ]

    /// What the rules read as the binder named and the day it's due, from what was written down, heard at `heard`: against
    /// the bench's own binders. Each is "" when the rules read none, and the day is "2026-09-25" in `calendar`.
    public static func readBinderAndDue(_ written: String, heard: Date, calendar: Calendar = .current) -> (binder: String, due: String) {
        let reading = MomentRules.read(written, binders: binders, agents: [], heard: heard, calendar: calendar)
        return (reading.binder ?? "", reading.dueAt.map { day($0, calendar: calendar) } ?? "")
    }

    /// "2026-09-25", in `calendar`.
    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The date a "2026-09-25" stands for, in `calendar`: the start of that day.
    public static func date(_ day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// How the rules read one thing besides the kind.
    public enum Read: String, Sendable {
        /// What the phrase names, or says.
        case right
        /// Something else, or nothing, where the phrase names or says one.
        case wrong
        /// One read where the phrase names or says none.
        case unasked
    }

    /// Right, wrong or unasked for the binder a clip's rules read; nil when there's nothing to score (an older build's
    /// result, nothing written down, or neither asked nor read).
    public static func binderRead(_ result: Result) -> Read? {
        guard let read = result.binder else { return nil }
        guard let expected = expectations[result.phrase ?? ""]?.binder else { return read.isEmpty ? nil : .unasked }
        return read.caseInsensitiveCompare(expected) == .orderedSame ? .right : .wrong
    }

    /// The same for the day it's due, judged from when it was said.
    public static func dueRead(_ result: Result, calendar: Calendar = .current) -> Read? {
        guard let read = result.due else { return nil }
        guard let expected = expectations[result.phrase ?? ""]?.due else { return read.isEmpty ? nil : .unasked }
        guard let day = date(read, calendar: calendar) else { return .wrong }
        return expected.matches(day, heard: result.heard, calendar: calendar) ? .right : .wrong
    }

    /// The kind the iPhone read for one of your phrases or lines that should be taken as a kind: nil where there's none to
    /// check, or nothing was read (your Mac decides those). Notes aren't counted: without "Binders," the rules can't call
    /// anything a note, and Apple's model decides.
    public static func kindRead(_ result: Result) -> Read? {
        let expected: MomentKind? = result.group?.kind ?? MomentBench.line(result.phrase).flatMap {
            if case .taken(let kind) = $0.expected { kind } else { nil }
        }
        guard let expected, expected != .note, let read = result.kindRead, result.detector != .letGo else { return nil }
        return read == expected ? .right : .wrong
    }

    /// One of your phrases or lines that should be taken: the ones whose binder and due date count.
    static func shouldBeTaken(_ result: Result) -> Bool {
        if let group = result.group { return group.shouldBeTaken }
        if let line = MomentBench.line(result.phrase), case .taken = line.expected { return true }
        return false
    }

    // MARK: Results

    /// What the detector made of what was said, before any check.
    public enum Detector: String, Codable, Sendable {
        /// Said on its own, with quiet before and after it: checked as a moment.
        case onItsOwn
        /// Said in a conversation: too little quiet before it, or someone answered. Only "Binders, …" gets through.
        case inConversation
        /// Let go before any check: too little speech, too long, or answered.
        case letGo
    }

    /// One clip, scored: numbers, kinds and labels, never its audio or its words. Everything past the first four is
    /// Optional, so results kept by an older build still read.
    public struct Result: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var run: Run
        /// The pass it belongs to (Session).
        public var session: UUID
        /// When it was said.
        public var heard: Date
        /// The phrase or line said, by its id; nil in a media run.
        public var phrase: String?
        public var detector: Detector?
        /// First word to last, as the detector heard it (what a moment sends as its seconds), and the speech in it.
        public var seconds: Double?
        public var speech: Double?
        /// From the last word to the clip being handed on: the quiet the detector waits for before it's a moment.
        public var endpointMillis: Int?
        /// Writing it down, scoring the voice, and Apple's model, each; and the gate in all.
        public var asrMillis: Int?
        public var voiceMillis: Int?
        public var modelMillis: Int?
        public var gateMillis: Int?
        /// The speech engine that wrote it down ("parakeet-v2", "apple-speech").
        public var engine: String?
        /// Words written down, and the share of the phrase's words among them (0…1).
        public var words: Int?
        public var accuracy: Double?
        /// It opened with "Binders,".
        public var wake: Bool?
        /// The cue found, as MomentRules.cue gives it.
        public var cue: String?
        /// How alike the voice was to your print (0…1), and the threshold then.
        public var voice: Double?
        public var threshold: Double?
        /// What the rules read it as: a MomentKind, or "unsure" when they can't tell.
        public var rules: String?
        /// What Apple's model read it as: a MomentKind, "unavailable" or "noAnswer"; nil when it wasn't asked.
        public var model: String?
        /// Every check that failed, in the gate's order; empty when it was taken.
        public var failures: [MomentGate.Check]?
        /// The voice print it was scored against, as VoicePrint's short fingerprint.
        public var voicePrint: String?
        /// Heard while the iPhone was locked, and scored once it was open again.
        public var scoredLater: Bool?
        /// The binder the rules read it as naming, against the bench's own binders, and the day they read it as due
        /// ("2026-09-25"): "" when they read none; nil when not read (nothing written down, or an older build).
        public var binder: String?
        public var due: String?
        /// Lane Y2: what MomentRules.uncued read in the written words ("fix", "todo", "idea", or "" for none), for every clip
        /// with no cue; and what Apple's model read with MomentGate.uncuedInstructions (the kind, "none", or "" when it didn't
        /// answer), asked only in Auto for a clip with `uncued` set. Nil from an older build.
        public var uncued: String?
        public var uncuedModel: String?

        public init(id: UUID = UUID(), run: Run, session: UUID, heard: Date, phrase: String? = nil, detector: Detector? = nil,
                    seconds: Double? = nil, speech: Double? = nil, endpointMillis: Int? = nil, asrMillis: Int? = nil,
                    voiceMillis: Int? = nil, modelMillis: Int? = nil, gateMillis: Int? = nil, engine: String? = nil, words: Int? = nil,
                    accuracy: Double? = nil, wake: Bool? = nil, cue: String? = nil, voice: Double? = nil, threshold: Double? = nil,
                    rules: String? = nil, model: String? = nil, failures: [MomentGate.Check]? = nil, voicePrint: String? = nil,
                    scoredLater: Bool? = nil, binder: String? = nil, due: String? = nil, uncued: String? = nil, uncuedModel: String? = nil) {
            self.uncued = uncued
            self.uncuedModel = uncuedModel
            self.id = id
            self.run = run
            self.session = session
            self.heard = heard
            self.phrase = phrase
            self.detector = detector
            self.seconds = seconds
            self.speech = speech
            self.endpointMillis = endpointMillis
            self.asrMillis = asrMillis
            self.voiceMillis = voiceMillis
            self.modelMillis = modelMillis
            self.gateMillis = gateMillis
            self.engine = engine
            self.words = words
            self.accuracy = accuracy
            self.wake = wake
            self.cue = cue
            self.voice = voice
            self.threshold = threshold
            self.rules = rules
            self.model = model
            self.failures = failures
            self.voicePrint = voicePrint
            self.scoredLater = scoredLater
            self.binder = binder
            self.due = due
        }

        /// The checks that would fail with the voice threshold at `threshold`, in the gate's order: the voice check
        /// is judged again from the score, the rest stand. The bench ran every check, so nothing is missing.
        public func failures(at threshold: Double) -> [MomentGate.Check] {
            var failed = Set(failures ?? []).subtracting([.notYourVoice])
            if wake != true, let voice, voice < threshold { failed.insert(.notYourVoice) }
            return MomentGate.Check.allCases.filter(failed.contains)
        }

        /// The gate would take it with the voice threshold at `threshold`.
        public func taken(at threshold: Double) -> Bool {
            detector != .letGo && detector != nil && failures(at: threshold).isEmpty
        }

        /// The gate in Auto would take it (lane Y2): as `taken(at:)`, or, a clip whose only failure is no cue, with
        /// `uncued` set, the voice at or past `startBar`, and Apple's model agreeing (MomentGate.confirmsUncued).
        public func taken(at threshold: Double, auto: Bool, startBar: Double?) -> Bool {
            if taken(at: threshold) { return true }
            guard auto, detector != .letGo, detector != nil, failures(at: threshold) == [.noCue] else { return false }
            guard let read = uncued, !read.isEmpty, let bar = startBar, let voice, voice >= bar,
                  let model = uncuedModel.flatMap(MomentKind.init(rawValue:)) else { return false }
            return MomentGate.confirmsUncued(model, uncued: read)
        }

        /// What the iPhone read it as: the rules' kind, or Apple's model's when the rules couldn't tell. Nil when neither
        /// could, which leaves it to your Mac.
        public var kindRead: MomentKind? {
            if let rules, let kind = MomentKind(rawValue: rules) { return kind }
            return model.flatMap(MomentKind.init(rawValue:))
        }

        /// The group of the phrase said, when it's one of the phrases.
        public var group: Group? { MomentBench.phrase(phrase)?.group }
    }

    /// A pass through one run: your phrases, one reader's, one timed media run, or the 40 lines once.
    public struct Session: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var run: Run
        public var started: Date
        /// When a media run stopped, for the time it listened.
        public var ended: Date?
        /// Who read, in someone else's runs: 1 for the first, 2 for the next.
        public var reader: Int?

        public init(id: UUID = UUID(), run: Run, started: Date, ended: Date? = nil, reader: Int? = nil) {
            self.id = id
            self.run = run
            self.started = started
            self.ended = ended
            self.reader = reader
        }
    }

    /// Everything the bench keeps, in one file on the iPhone.
    public struct Store: Codable, Equatable, Sendable {
        public var results: [Result]
        public var sessions: [Session]

        public init(results: [Result] = [], sessions: [Session] = []) {
            self.results = results
            self.sessions = sessions
        }

        /// Either list may be missing, as in a file a newer or older build wrote.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            results = try container.decodeIfPresent([Result].self, forKey: .results) ?? []
            sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        }

        /// A result in its place: one per phrase or line in a pass, so saying it again replaces the last time.
        public mutating func record(_ result: Result) {
            if let phrase = result.phrase {
                results.removeAll { $0.run == result.run && $0.session == result.session && $0.phrase == phrase }
            }
            results.removeAll { $0.id == result.id }
            results.append(result)
        }

        /// The latest pass of a run.
        public func latest(_ run: Run) -> Session? {
            sessions.filter { $0.run == run }.max { $0.started < $1.started }
        }

        /// A pass's results, by the phrase or line said.
        public func results(in session: UUID) -> [String: Result] {
            var found: [String: Result] = [:]
            for result in results where result.session == session {
                guard let phrase = result.phrase else { continue }
                if let earlier = found[phrase], earlier.heard > result.heard { continue }
                found[phrase] = result
            }
            return found
        }
    }

    // MARK: Words

    /// The share of the phrase's words that were written down, in order (1 less the word error rate, never below 0):
    /// how well it was heard, without keeping what was. Apostrophes and punctuation don't count; numbers written as
    /// digits for words said do.
    public static func accuracy(heard: String, said: String) -> Double {
        let expected = comparable(said), written = comparable(heard)
        guard !expected.isEmpty else { return written.isEmpty ? 1 : 0 }
        return max(0, 1 - Double(editDistance(expected, written)) / Double(expected.count))
    }

    private static func comparable(_ text: String) -> [String] {
        TextNorm.normalizedWords(text).map(TextNorm.compact).filter { !$0.isEmpty }
    }

    /// Words inserted, left out or changed to turn one into the other.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: Scoring

    /// The clips the voice threshold is set from: 2 to 5 seconds, first word to last.
    public static let clipSeconds: ClosedRange<Double> = 2...5
    /// The share of other voices that may get through: about 1%.
    public static let falseAcceptRate = 0.01
    /// Clips of other voices it takes to tell 1%: with fewer, even none through says little.
    public static let enoughOthers = 100
    /// Thresholds go in hundredths.
    public static let thresholdStep = 0.01

    /// Taken out of all.
    public struct Tally: Equatable, Sendable {
        public var taken: Int
        public var total: Int

        public init(taken: Int = 0, total: Int = 0) {
            self.taken = taken
            self.total = total
        }

        /// Taken, 0…1; 0 with none.
        public var share: Double { total == 0 ? 0 : Double(taken) / Double(total) }
    }

    /// A voice threshold that lets through at most `rate` of other voices.
    public struct Threshold: Equatable, Sendable {
        /// The least score taken, in hundredths.
        public var value: Double
        /// The other voices' clips it was set from, and how many of them still get through.
        public var others: Int
        public var through: Int
        /// The most the share getting through could be, at 95%, from so few: the Wilson upper bound.
        public var upperBound: Double
        /// From enough clips to tell 1% (`enoughOthers`).
        public var isEnough: Bool { others >= MomentBench.enoughOthers }
    }

    /// The lowest threshold, in steps of `step`, that lets at most `rate` of `others` through (a score at or above it gets
    /// through): just above the score of the one more than may get through. Nil without any.
    public static func threshold(others: [Double], rate: Double = falseAcceptRate, step: Double = thresholdStep) -> Threshold? {
        guard !others.isEmpty, step > 0 else { return nil }
        let sorted = others.sorted(by: >)
        let allowed = Int((rate * Double(sorted.count) + 1e-9).rounded(.down))
        guard allowed < sorted.count else { return nil }
        // Above the highest that mustn't get through, by at least a hair, rounded up to the step.
        let highestKept = sorted[allowed]
        let steps = (highestKept / step + 1e-9).rounded(.down) + 1
        let value = min(1, max(0, (steps * step * 1000).rounded() / 1000))
        let through = sorted.filter { $0 >= value }.count
        return Threshold(value: value, others: sorted.count, through: through,
                         upperBound: 1 - MomentGraduation.wilsonLowerBound(sorted.count - through, of: sorted.count))
    }

    /// How much closer to your voice than the moment threshold a "Binders, …" must be to start an agent you let start on
    /// cards Binders sends it.
    public static let startMargin = 0.05

    /// The start bar: how close to your voice a "Binders, …" said on its own must be for the iPhone to send its yes with it
    /// (MomentAgreement). Nil with fewer than `enoughOthers` clips of other voices. Otherwise the larger of the moment
    /// threshold plus `startMargin` and one step above the highest score of any other voice or Not me the bench heard,
    /// at most 1: stricter than the moment threshold by construction, and no clip heard from anyone else would pass it.
    public static func startThreshold(others: [Double], notMe: [Double], momentThreshold: Double, step: Double = thresholdStep) -> Double? {
        guard others.count >= enoughOthers, step > 0 else { return nil }
        let highest = (others + notMe).max() ?? 0
        let above = ((highest / step + 1e-9).rounded(.down) + 1) * step
        let bar = max(momentThreshold + startMargin, above)
        return min(1, (bar * 1000).rounded() / 1000)
    }

    /// The start bar after a Not me on something Binders handed over without asking (in Auto, or a "Binders, …" by the start
    /// rule): unchanged when that clip's score was under it; else one step above the score, rounded as `startThreshold`
    /// rounds, at most 1, as Calibrate would set it with that miss among its Not me's. So the same voice can't hand anything
    /// over again before the next Calibrate.
    public static func raisedStartBar(current: Double, notMe score: Double, step: Double = thresholdStep) -> Double {
        guard score >= current, step > 0 else { return current }
        let above = ((score / step + 1e-9).rounded(.down) + 1) * step
        return min(1, (above * 1000).rounded() / 1000)
    }

    /// The start bar Calibrate offers to set, from the clips it has now and the moment threshold as it is: the one
    /// `startThreshold` gives, when the bar set (`current`, nil for none) isn't already it. Nil with too few clips of
    /// other voices, or with the bar set already. So the bar can be set without changing the voice threshold, as when
    /// that's already the one suggested (and Use isn't offered), and set again once more clips moved it.
    public static func startBarOffer(current: Double?, others: [Double], notMe: [Double], momentThreshold: Double) -> Double? {
        guard let bar = startThreshold(others: others, notMe: notMe, momentThreshold: momentThreshold) else { return nil }
        if let current, abs(current - bar) < thresholdStep / 2 { return nil }
        return bar
    }

    /// How a line of the 40 went.
    public enum Verdict: String, Sendable {
        case passed, failed
        /// Expected to be let go by Apple's model, which this iPhone didn't have when it was said.
        case needsModel
    }

    /// Whether a line's result is what it should be, with the voice threshold at `threshold`: taken or let go as
    /// expected, and taken as the kind expected when the iPhone could read one (the rules' kind, or Apple's model's
    /// when the rules couldn't tell).
    public static func verdict(_ result: Result, for line: Line, threshold: Double) -> Verdict {
        let taken = result.taken(at: threshold)
        switch line.expected {
        case .taken(let kind):
            guard taken else { return .failed }
            guard let kind, let read = result.kindRead else { return .passed }
            return read == kind ? .passed : .failed
        case .letGo(let why):
            guard taken else { return .passed }
            return why == .notMeant && result.model == "unavailable" ? .needsModel : .failed
        }
    }

    /// The voice: scores of 2-5 s clips against the print you have now.
    public struct Voice: Equatable, Sendable {
        /// The threshold now.
        public var threshold: Double
        /// Yours (your phrases and the 40 lines) and other voices' (someone else's and the TV's).
        public var yours: [Double]
        public var others: [Double]
        /// Things you marked Not me that had a score.
        public var notMe: [Double]
        /// The threshold for about 1% of others through, when there are any.
        public var suggestion: Threshold?

        /// At a threshold: yours that pass, others' and Not me's that get through.
        public func yoursPassing(at threshold: Double) -> Int { yours.filter { $0 >= threshold }.count }
        public func othersThrough(at threshold: Double) -> Int { others.filter { $0 >= threshold }.count }
        public func notMeThrough(at threshold: Double) -> Int { notMe.filter { $0 >= threshold }.count }
    }

    /// Read right out of those there were to check, and those read where none was asked for.
    public struct Score: Equatable, Sendable {
        public var right: Int
        public var total: Int
        public var unasked: Int

        public init(right: Int = 0, total: Int = 0, unasked: Int = 0) {
            self.right = right
            self.total = total
            self.unasked = unasked
        }

        mutating func add(_ read: Read?) {
            switch read {
            case .right?: right += 1; total += 1
            case .wrong?: total += 1
            case .unasked?: unasked += 1
            case nil: break
            }
        }
    }

    /// What the bench found, from all its results.
    public struct Report: Equatable, Sendable {
        /// The voice threshold it's counted at.
        public var threshold: Double
        /// Your phrases and someone else's, per group: taken out of all.
        public var yours: [Group: Tally]
        public var others: [Group: Tally]
        /// TV and podcasts: clips heard and taken (every one a false accept), and the time listened.
        public var media: Tally
        public var mediaSeconds: TimeInterval
        /// Your phrases not meant for Binders and your chatter that were taken.
        public var yourFalseAccepts: Tally
        /// Someone else's phrases that were taken, whatever the group: the gate took another voice.
        public var otherFalseAccepts: Tally
        public var voice: Voice
        /// The 40 lines, by id, from the latest time each was said.
        public var script: [String: Verdict]
        /// Results scored against an earlier voice print, left out of the voice's numbers.
        public var earlierPrint: Int
        /// What the rules read from your phrases and the 40 lines, as written down: the kind, the binder named, the day
        /// it's due.
        public var kinds = Score()
        public var binders = Score()
        public var dues = Score()
        /// Lane Y2: what the gate in Auto would do with what's said without a cue.
        public var auto = AutoRow()

        /// Lines passed, and lines said.
        public var scriptPassed: Int { script.values.filter { $0 == .passed }.count }
        public var scriptSaid: Int { script.count }
    }

    /// Lane Y2's row: of the group without a cue, how many Auto would take; of chatter, the phrases not meant for Binders,
    /// other voices and media, how many it would keep that weren't meant; and how often Apple's model didn't answer.
    public struct AutoRow: Equatable, Sendable {
        public var taken = Tally()
        public var falseKeeps = Tally()
        public var unanswered = 0

        public init() {}

        /// "In Auto: 28 of 30 said without a cue taken · 1 kept that weren't meant · Apple's model didn't answer for 2".
        public var summary: String {
            "In Auto: \(taken.taken) of \(taken.total) said without a cue taken · \(falseKeeps.taken) kept that weren't meant · "
                + "Apple's model didn't answer for \(unanswered)"
        }
    }

    /// The Auto row on `store`, at the voice threshold and the start bar.
    public static func autoRow(_ store: Store, threshold: Double, startBar: Double?) -> AutoRow {
        var row = AutoRow()
        for result in store.results {
            if result.uncued?.isEmpty == false, result.uncuedModel == "" { row.unanswered += 1 }
            let taken = result.taken(at: threshold, auto: true, startBar: startBar)
            switch result.run {
            case .phrases:
                guard let group = result.group else { continue }
                if group == .uncued { row.taken.add(taken) } else if !group.shouldBeTaken { row.falseKeeps.add(taken) }
            case .otherVoices, .media:
                row.falseKeeps.add(taken)
            case .script:
                break
            }
        }
        return row
    }

    /// The report on `store`, counted at the voice threshold `threshold`. Only clips scored against the print you have now
    /// (`voicePrint`, VoicePrint's fingerprint) count towards the voice; `notMe` are the scores of things you marked Not me.
    public static func report(_ store: Store, threshold: Double, voicePrint: String?, notMe: [Double] = [],
                              calendar: Calendar = .current, startBar: Double? = nil) -> Report {
        var yours: [Group: Tally] = [:], others: [Group: Tally] = [:]
        var media = Tally(), yourFalse = Tally(), otherFalse = Tally()
        var yourScores: [Double] = [], otherScores: [Double] = []
        var earlier = 0
        var kinds = Score(), binders = Score(), dues = Score()
        for result in store.results {
            let taken = result.taken(at: threshold)
            if result.run.isYours, shouldBeTaken(result) {
                kinds.add(kindRead(result))
                binders.add(binderRead(result))
                dues.add(dueRead(result, calendar: calendar))
            }
            switch result.run {
            case .phrases:
                if let group = result.group {
                    yours[group, default: Tally()].add(taken)
                    if !group.shouldBeTaken, group != .uncued { yourFalse.add(taken) }
                }
            case .otherVoices:
                if let group = result.group { others[group, default: Tally()].add(taken) }
                otherFalse.add(taken)
            case .media:
                media.add(taken)
            case .script:
                break
            }
            guard let score = result.voice, let seconds = result.seconds, clipSeconds.contains(seconds) else { continue }
            guard result.voicePrint == voicePrint else {
                earlier += 1
                continue
            }
            if result.run.isYours { yourScores.append(score) } else { otherScores.append(score) }
        }
        let listened = store.sessions.filter { $0.run == .media }.reduce(0.0) { total, session in
            total + max(0, (session.ended ?? session.started).timeIntervalSince(session.started))
        }
        var script: [String: Verdict] = [:]
        var latest: [String: Result] = [:]
        for result in store.results where result.run == .script {
            guard let id = result.phrase, MomentBench.line(id) != nil else { continue }
            if let known = latest[id], known.heard > result.heard { continue }
            latest[id] = result
        }
        for (id, result) in latest {
            if let line = MomentBench.line(id) { script[id] = verdict(result, for: line, threshold: threshold) }
        }
        let voice = Voice(threshold: threshold, yours: yourScores, others: otherScores, notMe: notMe,
                          suggestion: Self.threshold(others: otherScores))
        return Report(threshold: threshold, yours: yours, others: others, media: media, mediaSeconds: listened, yourFalseAccepts: yourFalse,
                      otherFalseAccepts: otherFalse, voice: voice, script: script, earlierPrint: earlier, kinds: kinds, binders: binders, dues: dues,
                      auto: autoRow(store, threshold: threshold, startBar: startBar))
    }

    // MARK: CSV

    /// Every result as CSV, one row each, for the share sheet: numbers, kinds and labels, never audio or what was said.
    /// The phrase's text is the script's, as it was shown. Times are ISO 8601; taken is counted at `threshold`. New columns
    /// go at the end, so a sheet made from an older export still lines up: the binder and the due day expected, read and
    /// scored (right, wrong, unasked).
    public static func csv(_ store: Store, threshold: Double, calendar: Calendar = .current) -> String {
        let sessions = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, $0) })
        let header = ["run", "speaker", "pass", "pass_started", "reader", "heard", "phrase", "group", "text", "expected", "detector", "seconds",
                      "speech_seconds", "endpoint_ms", "asr_ms", "voice_ms", "model_ms", "gate_ms", "engine", "words", "word_accuracy",
                      "wake", "cue", "voice", "threshold_then", "rules", "model", "failed_checks", "taken_then", "taken_now",
                      "threshold_now", "line_verdict", "voice_print", "scored_later", "kind_score", "expected_binder", "binder_read",
                      "binder_score", "expected_due", "due_read", "due_score", "uncued", "uncued_model"]
        // The one parser the iPhone has (BoardRules.isoParser), writing as it reads.
        let dates = BoardRules.isoParser
        var rows = [header.joined(separator: ",")]
        for result in store.results.sorted(by: { $0.heard < $1.heard }) {
            let session = sessions[result.session]
            let phrase = MomentBench.phrase(result.phrase)
            let line = MomentBench.line(result.phrase)
            let expects = expectations[result.phrase ?? ""]
            let fields: [String?] = [
                result.run.rawValue, result.run.speaker, result.session.uuidString, session.map { dates.string(from: $0.started) }, session?.reader.map(String.init),
                dates.string(from: result.heard), result.phrase, phrase?.group.rawValue, phrase?.text ?? line?.text, line?.expected.summary,
                result.detector?.rawValue, decimal(result.seconds, 2), decimal(result.speech, 2), result.endpointMillis.map(String.init),
                result.asrMillis.map(String.init), result.voiceMillis.map(String.init), result.modelMillis.map(String.init),
                result.gateMillis.map(String.init), result.engine, result.words.map(String.init), decimal(result.accuracy, 2),
                result.wake.map { $0 ? "yes" : "no" }, result.cue, decimal(result.voice, 3), decimal(result.threshold, 2), result.rules,
                result.model, result.failures?.map(\.rawValue).joined(separator: " "),
                result.detector == nil ? nil : (result.taken(at: result.threshold ?? threshold) ? "yes" : "no"),
                result.detector == nil ? nil : (result.taken(at: threshold) ? "yes" : "no"), decimal(threshold, 2),
                line.map { verdict(result, for: $0, threshold: threshold).rawValue }, result.voicePrint, result.scoredLater.map { $0 ? "yes" : "no" },
                result.run.isYours ? kindRead(result)?.rawValue : nil, expects?.binder, result.binder, binderRead(result)?.rawValue,
                expects?.due?.summary, result.due, dueRead(result, calendar: calendar)?.rawValue, result.uncued, result.uncuedModel,
            ]
            rows.append(fields.map { escaped($0 ?? "") }.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func decimal(_ value: Double?, _ places: Int) -> String? {
        value.map { String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), $0) }
    }

    /// A field as CSV has it: quoted when it holds a comma, a quote or a line break, with quotes doubled.
    static func escaped(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension MomentBench.Tally {
    mutating func add(_ taken: Bool) {
        total += 1
        if taken { self.taken += 1 }
    }
}
