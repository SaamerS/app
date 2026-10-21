import XCTest
@testable import BindersKit

/// The Lock Screen shows titles and counts by default, never what you said: what moments' and conversations'
/// notifications say, by how iOS shows previews and whether you asked for your words there.
final class LockScreenTextTests: XCTestCase {
    private let id = UUID(uuidString: "7A1C2E3D-4B5F-4061-9C8D-0E1F2A3B4C5D")!
    private let said = ["dentist", "Ignite", "booth", "plan", "pricing", "Sam"]

    /// None of what was said in any part of it.
    private func assertNoWords(_ text: NotificationText?, file: StaticString = #filePath, line: UInt = #line) {
        guard let text else { return XCTFail("no notification", file: file, line: line) }
        for word in said {
            for part in [text.title, text.subtitle, text.body] {
                XCTAssertFalse(part.localizedCaseInsensitiveContains(word), "“\(part)” holds “\(word)”", file: file, line: line)
            }
        }
    }

    func testWordsShowOnlyWhereIOSHidesPreviewsOrYouAsked() {
        XCTAssertFalse(LockScreenText.showsWords(.always, allowed: false), "Always, the default with Touch ID: no words")
        XCTAssertTrue(LockScreenText.showsWords(.always, allowed: true), "unless you turned them on")
        XCTAssertTrue(LockScreenText.showsWords(.whenUnlocked, allowed: false), "hidden until you unlock: they can be there")
        XCTAssertTrue(LockScreenText.showsWords(.never, allowed: false))
        XCTAssertTrue(LockScreenText.showsWords(.never, allowed: true))
    }

    func testAToDoAddedSaysWhereNotWhat() {
        let added = CaptureOutcome(id: id, state: "acted", line: "Added to Personal: Book the dentist · Tue", title: "Added to Personal",
                                   binder: "Personal", actions: ["undo", "assign"], agent: "Claude Code · app", todo: "T1", kind: "todo")
        XCTAssertEqual(LockScreenText.moment(added, showsWords: false), NotificationText(title: "Added to Personal", body: "To-do added in Personal"))
        assertNoWords(LockScreenText.moment(added, showsWords: false))
        XCTAssertEqual(LockScreenText.moment(added, showsWords: true)?.body, "Added to Personal: Book the dentist · Tue")
    }

    func testOffersIdeasAndNotes() {
        let offer = CaptureOutcome(id: id, state: "offered", line: "Book the dentist", title: "Add to Personal?", binder: "Personal",
                                   actions: ["add", "not-now"], kind: "todo")
        XCTAssertEqual(LockScreenText.moment(offer, showsWords: false)?.body, "1 to-do for Personal")
        assertNoWords(LockScreenText.moment(offer, showsWords: false))
        let idea = CaptureOutcome(id: id, state: "offered", line: "A booth plan for Ignite", title: "Put this on the Events board?", binder: "Events",
                                  kind: "idea")
        XCTAssertEqual(LockScreenText.moment(idea, showsWords: false)?.body, "1 idea for the Events board")
        let put = CaptureOutcome(id: id, state: "acted", line: "Put on the Events board: A booth plan for Ignite", title: "An idea for Events",
                                 binder: "Events", card: "C1", kind: "idea")
        XCTAssertEqual(LockScreenText.moment(put, showsWords: false)?.body, "1 idea for the Events board")
        assertNoWords(LockScreenText.moment(put, showsWords: false))
        let note = CaptureOutcome(id: id, state: "acted", line: "Kept in Personal: the booth is 12B", title: "Kept in Personal", binder: "Personal",
                                  kind: "note")
        XCTAssertEqual(LockScreenText.moment(note, showsWords: false)?.body, "Note kept in Personal")
    }

    func testAnswersAndStatus() {
        let answer = CaptureOutcome(id: id, state: "answered", line: "Booth 12B, by the main entrance [1].\nIgnite booth plan · Venue call",
                                    title: "From your binders", settled: true, sources: ["Ignite booth plan", "Venue call"], kind: "question")
        XCTAssertEqual(LockScreenText.moment(answer, showsWords: false), NotificationText(title: "From your binders", body: "Binders answered your question"))
        assertNoWords(LockScreenText.moment(answer, showsWords: false))
        XCTAssertEqual(LockScreenText.moment(answer, showsWords: true)?.body, "Booth 12B, by the main entrance.", "the answer, without its sources' titles")
        let status = CaptureOutcome(id: id, state: "answered", line: "Claude Code on 2 cards. 1 finished today.", title: "Your work streams",
                                    sources: [], kind: "status")
        XCTAssertEqual(LockScreenText.moment(status, showsWords: false)?.body, "Claude Code on 2 cards. 1 finished today.",
                       "the boards' digest is counts and names")
        // A card's title can be what you said ("Book the dentist", from a moment): the digest names none.
        let titled = CaptureOutcome(id: id, state: "answered",
                                    line: "Claude Code asks about “Book the dentist”, and 1 more question. “Plan the Ignite booth” is ready for you to check. Claude Code on 2 cards.",
                                    title: "Your work streams", sources: [], kind: "status")
        XCTAssertEqual(LockScreenText.moment(titled, showsWords: false)?.body,
                       "Claude Code asks about a card, and 1 more question. A card is ready for you to check. Claude Code on 2 cards.")
        assertNoWords(LockScreenText.moment(titled, showsWords: false))
        XCTAssertEqual(LockScreenText.moment(titled, showsWords: true)?.body, titled.line, "where your words may show, the titles do too")
        let nothing = CaptureOutcome(id: id, state: "nothing", line: "Nothing in your binders about the Ignite dates.", title: "Nothing in your binders",
                                     settled: true, kind: "question")
        XCTAssertEqual(LockScreenText.moment(nothing, showsWords: false), NotificationText(title: "Nothing in your binders", body: ""))
        let shared = CaptureOutcome(id: id, state: "answered", line: "Every binder is shared with your team, so it wasn't kept as a note.",
                                    title: "Not kept", kind: "note")
        XCTAssertEqual(LockScreenText.moment(shared, showsWords: false)?.body, shared.line, "the Mac's reason holds none of your words")
    }

    func testACardsTitleIsKeptForTheAppAsYourWordsAre() {
        // An agent's question on a card made from "I need to book the dentist", its progress, a request for approval.
        let title = "Book the dentist"
        XCTAssertEqual(LockScreenText.card(title, binder: "Personal", showsWords: false), "On the Personal board", "where it is, not what it says")
        XCTAssertEqual(LockScreenText.card(title, showsWords: false), "", "nothing, when its binder isn't known")
        XCTAssertEqual(LockScreenText.card(title, binder: "  ", showsWords: false), "")
        XCTAssertEqual(LockScreenText.card(title, binder: "Personal", showsWords: true), title, "previews hidden until you unlock, or your words on")
        XCTAssertEqual(LockScreenText.yourAnswer(on: title, showsWords: true), "Your answer on “Book the dentist”")
        XCTAssertEqual(LockScreenText.yourAnswer(on: title, showsWords: false), "Your answer")
        XCTAssertEqual(LockScreenText.yourAnswer(on: " ", showsWords: true), "Your answer")
        for previews in NotificationPreviews.allCases {
            let shows = LockScreenText.showsWords(previews, allowed: false)
            XCTAssertEqual(LockScreenText.card(title, binder: "Personal", showsWords: shows).contains("dentist"), previews != .always,
                           "with previews \(previews.rawValue), by default")
        }
    }

    func testNothingToSayAndUnknownStates() {
        XCTAssertNil(LockScreenText.moment(CaptureOutcome(id: id, state: "nothing", line: ""), showsWords: false))
        let newer = CaptureOutcome(id: id, state: "pondered", line: "Booked the dentist for Sam", title: "Thought about it")
        XCTAssertEqual(LockScreenText.moment(newer, showsWords: false), NotificationText(title: "Thought about it", body: ""),
                       "a state from a newer Mac shows its title, never its line")
        let late = CaptureOutcome(id: id, state: "nothing", line: "Heard too long ago to answer now.", title: "Heard too long ago to answer now.")
        XCTAssertEqual(LockScreenText.moment(late, showsWords: true)?.body, "", "a line that repeats the title isn't said twice")
    }

    func testAMacBeforeKindsIsReadFromWhatItMade() {
        func kind(_ state: String, _ title: String, card: String? = nil, todo: String? = nil) -> MomentKind? {
            LockScreenText.kind(of: CaptureOutcome(id: id, state: state, line: "", title: title, card: card, todo: todo))
        }
        XCTAssertEqual(kind("acted", "Added to Personal", todo: "T1"), .todo)
        XCTAssertEqual(kind("acted", "An idea for Events", card: "C1"), .idea)
        XCTAssertEqual(kind("offered", "Put this on the Events board?"), .idea)
        XCTAssertEqual(kind("offered", "Add to Events?"), .todo)
        XCTAssertEqual(kind("acted", "Kept in Personal"), .note)
        XCTAssertEqual(kind("offered", "Keep in Personal?"), .note)
        XCTAssertEqual(kind("answered", "Not kept"), .note)
        XCTAssertEqual(kind("answered", "Your work streams"), .status)
        XCTAssertEqual(kind("answered", "From your binders"), .question)
        let older = CaptureOutcome(id: id, state: "answered", line: "Booth 12B.\nIgnite booth plan", title: "From your binders")
        assertNoWords(LockScreenText.moment(older, showsWords: false))
    }

    func testANoteHeardOnItsOwnIsOfferedWithoutItsWords() {
        let note = CaptureOutcome(id: id, state: "offered", line: "The Ignite booth is 12B", title: "Keep in Personal?", binder: "Personal",
                                  actions: ["add", "not-now"], kind: "note")
        XCTAssertEqual(LockScreenText.moment(note, showsWords: false), NotificationText(title: "Keep in Personal?", body: "1 note for Personal"))
        assertNoWords(LockScreenText.moment(note, showsWords: false))
        XCTAssertEqual(LockScreenText.moment(note, showsWords: true)?.body, "The Ignite booth is 12B")
    }

    func testGivenToAnAgentSaysWhereItsCardIs() {
        let given = CaptureOutcome(id: id, state: "acted", line: "Gave “Book the dentist” to Pennant, in Personal", title: "Given to Pennant",
                                   binder: "Personal", actions: ["undo"], card: "C2", todo: "T1", kind: "todo")
        XCTAssertEqual(LockScreenText.moment(given, showsWords: false)?.body, "On the Personal board")
        assertNoWords(LockScreenText.moment(given, showsWords: false))
    }

    func testConversationSuggestions() {
        let conversation = UUID()
        let card = ConversationSuggestion(conversation: conversation, kind: .card, text: "Send Sam the pricing", binder: "Events", todo: "M1")
        XCTAssertEqual(LockScreenText.suggestion(card, heard: "3:10 PM", showsWords: false),
                       NotificationText(title: "Put this on the Events board?", body: "1 to-do from your conversation at 3:10 PM"))
        XCTAssertEqual(LockScreenText.suggestion(card, heard: nil, showsWords: true).body, "Send Sam the pricing")
        let idea = ConversationSuggestion(conversation: conversation, kind: .idea, text: "A raffle at the booth", binder: "Events")
        let quiet = LockScreenText.suggestion(idea, heard: "3:10 PM", showsWords: false)
        XCTAssertEqual(quiet, NotificationText(title: "An idea for the Events board?", body: "1 idea from your conversation at 3:10 PM"))
        assertNoWords(quiet)
        XCTAssertEqual(LockScreenText.suggestion(idea, heard: nil, showsWords: true).body, "A raffle at the booth")
        let answer = ConversationSuggestion(conversation: conversation, kind: .answer, text: "When is the Ignite booth set up?", binder: "Events",
                                            answer: "On the 14th, from 8 [1].", sources: ["Ignite booth plan"])
        let hidden = LockScreenText.suggestion(answer, heard: "3:10 PM", showsWords: false)
        XCTAssertEqual(hidden, NotificationText(title: "Binders answered your question", body: "From your conversation at 3:10 PM"))
        assertNoWords(hidden)
        XCTAssertEqual(LockScreenText.suggestion(answer, heard: nil, showsWords: true).title, "You asked: When is the Ignite booth set up?",
                       "with previews hidden until you unlock, your question can be its title")
    }

    func testGiveToNamesTheAgentInFewWords() {
        XCTAssertEqual(LockScreenText.giveTo("Claude Code · app"), "Give to Claude Code · app")
        XCTAssertEqual(LockScreenText.giveTo("Pennant"), "Give to Pennant")
        let long = LockScreenText.giveTo("Claude Code · binders-public-app-allday")
        XCTAssertEqual(long, "Give to Claude Code · binders-p…")
        XCTAssertLessThanOrEqual(long.count, 32)
        let oneLongName = LockScreenText.giveTo("The research assistant for the Ignite booth")
        XCTAssertTrue(oneLongName.hasSuffix("…") && oneLongName.count <= 32, oneLongName)
        XCTAssertEqual(LockScreenText.shortName("A very long agent name · x", longest: 12), "A very long…", "no room for the rest: the name, cut")
    }

    func testEachPlaceholderHasOneCount() {
        for placeholder in [LockScreenText.waitingPlaceholder, LockScreenText.keptPlaceholder, LockScreenText.answeredPlaceholder,
                            LockScreenText.aboutPlaceholder, LockScreenText.boardsPlaceholder, LockScreenText.capturePlaceholder,
                            LockScreenText.handedPlaceholder] {
            XCTAssertEqual(placeholder.components(separatedBy: "%u").count, 2, placeholder)
            XCTAssertEqual(placeholder.filter { $0 == "%" }.count, 1, "nothing else for iOS to fill in: \(placeholder)")
        }
    }

    func testAnOutcomesKindTravelsAndOlderOnesRead() throws {
        let outcome = CaptureOutcome(id: id, state: "acted", line: "Added to Personal: Book the dentist", title: "Added to Personal", kind: "todo")
        XCTAssertEqual(CaptureOutcome.decodeEach([outcome.jsonObject]).first, outcome)
        let json = #"{"id":"\#(id.uuidString)","state":"acted","line":"Added to Personal: Book the dentist","title":"Added to Personal"}"#
        let older = try XCTUnwrap(CaptureOutcome.decodeEach([JSONSerialization.jsonObject(with: Data(json.utf8))]).first)
        XCTAssertNil(older.kind)
    }

    // MARK: Auto's hand-overs

    func testAHandOverSaysWhereNotWhat() {
        let todo = CaptureOutcome(id: id, state: "acted", line: "Added to Website and handed to Claude Code · app: Fix the pricing table.",
                                  title: "Handed to Claude Code · app", binder: "Website", actions: ["stop", "undo", "not-me"], agent: "Claude Code · app",
                                  card: "C1", todo: "T1", kind: "todo", handedOver: "auto")
        XCTAssertEqual(LockScreenText.moment(todo, showsWords: false), NotificationText(title: "Handed to Claude Code · app", body: "On the Website board"))
        assertNoWords(LockScreenText.moment(todo, showsWords: false))
        XCTAssertEqual(LockScreenText.moment(todo, showsWords: true)?.body, todo.line)
        let idea = CaptureOutcome(id: id, state: "acted", line: "Put on the Website board and handed to Grok Bot to look into: Pricing for the booth.",
                                  title: "Handed to Grok Bot", binder: "Website", actions: ["stop", "undo", "not-me"], agent: "Grok Bot", card: "C2",
                                  kind: "idea", handedOver: "auto")
        XCTAssertEqual(LockScreenText.moment(idea, showsWords: false), NotificationText(title: "Handed to Grok Bot", body: "1 idea for the Website board"))
        assertNoWords(LockScreenText.moment(idea, showsWords: false))
        XCTAssertEqual(LockScreenText.handedPlaceholder, "%u handed to agents from what you said")
    }

    func testAHandOverOpensItsOwnPage() {
        let handed = CaptureOutcome(id: id, state: "acted", line: "Added to Website and handed to Claude Code · app: Fix it.", title: "Handed to Claude Code · app",
                                    binder: "Website", actions: ["stop", "undo", "not-me"], card: "C1", todo: "T1", kind: "todo", handedOver: "auto")
        XCTAssertEqual(MomentPlace.of(outcome: handed), .moment(id), "where Stop, Undo, Not Me and Turn Off Auto are")
        var started = handed
        started.handedOver = "start"
        XCTAssertEqual(MomentPlace.of(outcome: started), .moment(id), "a Binders, … the start rule handed over too")
        var waiting = handed
        waiting.waiting = "wake"
        XCTAssertEqual(MomentPlace.of(outcome: waiting), .moment(id))
        // As today otherwise.
        let idea = CaptureOutcome(id: id, state: "acted", line: "Put on the Website board: Pricing", title: "An idea for Website", binder: "Website",
                                  actions: ["undo", "assign"], card: "C2", kind: "idea")
        XCTAssertEqual(MomentPlace.of(outcome: idea), .card("C2"), "an idea not handed over opens its card")
        let todo = CaptureOutcome(id: id, state: "acted", line: "Added to Personal: Book the dentist", title: "Added to Personal", binder: "Personal",
                                  todo: "T1", kind: "todo")
        XCTAssertEqual(MomentPlace.of(outcome: todo), .todos(binder: "Personal"))
        XCTAssertEqual(MomentPlace.of(outcome: CaptureOutcome(id: id, state: "offered", line: "Book the dentist", card: "C3")), .moment(id))
        XCTAssertEqual(MomentPlace.of(outcome: CaptureOutcome(id: id, state: "acted", line: "Kept in Personal: x", card: "")), .moment(id))
    }
}
