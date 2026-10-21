import XCTest
@testable import BindersKit

final class WidgetSnapshotTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }()
    /// 15:00 on a Tuesday in Lisbon.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 15))! }

    func testASnapshotFromBeforeTodayStillReads() throws {
        // As iPhone 2.0 (6) to (16) wrote it: no today, no stream.
        let json = #"{"capture":"listening","questions":1,"reviews":2,"handOffs":0,"captures":1,"filedToday":3,"updated":782300000}"#
        let old = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(old.capture, "listening")
        XCTAssertEqual(old.needsYou, 4)
        XCTAssertEqual(old.filedToday, 3)
        XCTAssertNil(old.today)
        XCTAssertNil(old.stream)
        XCTAssertNil(old.moments, "nothing you said waits in a snapshot from before it")
        let today = old.today(at: now, calendar: calendar)
        XCTAssertEqual([today.heard, today.acted, today.done], [0, 0, 0], "nothing heard or done shows until the app says")
        XCTAssertEqual(today.day, calendar.startOfDay(for: now))
    }

    func testANewSnapshotReadsBackAndAnOlderBuildStillReadsIt() throws {
        let snapshot = WidgetSnapshot(capture: "muted", questions: 0, reviews: 1, handOffs: 0, captures: 0, filedToday: 2, updated: now,
                                      today: .init(day: calendar.startOfDay(for: now), heard: 5, acted: 2, finished: 3),
                                      stream: .init(who: "Claude Code", isAgent: true, cards: 2))
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data), snapshot)

        // The widgets of the build before this one, during the update, read it with the fields they knew.
        struct FirstSnapshot: Decodable {
            var capture: String
            var questions: Int
            var reviews: Int
            var handOffs: Int
            var captures: Int
            var filedToday: Int
            var updated: Date
        }
        let read = try JSONDecoder().decode(FirstSnapshot.self, from: data)
        XCTAssertEqual(read.capture, "muted")
        XCTAssertEqual(read.reviews, 1)
        XCTAssertEqual(read.filedToday, 2)

        // And a later build's keys don't stop this one reading it.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["somethingNewer"] = ["kind": "unknown"]
        var today = try XCTUnwrap(object["today"] as? [String: Any])
        today["alsoNewer"] = 7
        object["today"] = today
        let newer = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(newer, snapshot)
    }

    func testTheSnapshotCountsWhatTodaysNeedsYouCountsAndWhatWasFiled() throws {
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9))!
        let heard: [(at: Date, state: String?)] = [
            (morning, "acted"),                              // "Binders, book the dentist": a to-do added
            (morning, "acted"),                              // an idea put on a board
            (morning, "offered"),                            // waits for Add or Not Now
            (morning, CaptureOutcome.States.filed),          // a conversation, filed
            (morning, CaptureOutcome.States.notKept),        // small talk
        ]
        let needs = NeedsYou(questions: 1, moments: 1, captures: 1)
        let snapshot = WidgetSnapshot(capture: "listening", needs: needs, heard: heard, finished: 2, stream: nil, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.needsYou, needs.total, "the widget and the Live Activity count what Today's Needs you counts")
        XCTAssertEqual(snapshot.needsYou, 3, "the offer waiting for Add or Not Now among them")
        XCTAssertEqual(snapshot.moments, 1)
        XCTAssertEqual(snapshot.filedToday, 3, "what Binders did with what it heard: the moments it acted on, and the capture it filed")
        XCTAssertEqual(snapshot.filedToday, snapshot.today(at: now, calendar: calendar).acted, "the same as done on the Today widget, less the cards")
        XCTAssertEqual(snapshot.today(at: now, calendar: calendar).done, 5)

        // The widgets of the build before this one read it, with the counts they knew.
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data), snapshot)
        let earlier = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(earlier["questions"] as? Int, 1)
        XCTAssertEqual(earlier["filedToday"] as? Int, 3)
    }

    func testYesterdaysNumbersDontShowToday() {
        let yesterday = WidgetSnapshot.Today(day: calendar.startOfDay(for: now.addingTimeInterval(-86_400)), heard: 9, acted: 4, finished: 2)
        var snapshot = WidgetSnapshot.empty
        snapshot.today = yesterday
        XCTAssertEqual(snapshot.today(at: now.addingTimeInterval(-86_400), calendar: calendar), yesterday)
        let today = snapshot.today(at: now, calendar: calendar)
        XCTAssertEqual([today.heard, today.acted, today.done], [0, 0, 0])
        XCTAssertNil(today.finished, "the Mac hasn't said what was finished today yet")
    }

    func testHeardAndDoneToday() {
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9))!
        let lastNight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 23, minute: 30))!
        let heard: [(at: Date, state: String?)] = [
            (morning, "acted"),                              // "Binders, book the dentist": added, with Undo
            (morning, "offered"),                            // offered, not added yet
            (morning, "answered"),                           // a question: answered, nothing done
            (morning, "undone"),                             // added, then taken back
            (morning, nil),                                  // still with the Mac
            (morning, CaptureOutcome.States.filed),          // a conversation, filed
            (morning, CaptureOutcome.States.notKept),        // small talk
            (lastNight, "acted"),                            // yesterday's
        ]
        let today = WidgetSnapshot.Today.counting(heard, finished: 3, now: now, calendar: calendar)
        XCTAssertEqual(today.heard, 7)
        XCTAssertEqual(today.acted, 2)
        XCTAssertEqual(today.done, 5, "what was done with what was heard, and the cards finished")
        XCTAssertEqual(today.day, calendar.startOfDay(for: now))
        XCTAssertEqual(WidgetSnapshot.Today.counting([], finished: nil, now: now, calendar: calendar).done, 0)
    }

    func testTheStreamIsNamesAndCountsUnlessYouAllowWords() throws {
        let cards = [
            WorkStreams.Card(title: "Write the release notes", binder: "Binders", column: .inProgress, assignee: "Claude Code",
                             assigneeIsAgent: true, updated: now.addingTimeInterval(-600)),
            WorkStreams.Card(title: "Fix the login bug", binder: "Binders", column: .inProgress, assignee: "Claude Code",
                             assigneeIsAgent: true, updated: now),
            WorkStreams.Card(title: "Plan the Ignite booth", binder: "Events", column: .inProgress, assignee: "You", updated: now),
        ]
        let digest = WorkStreams.digest(cards, now: now, calendar: calendar)
        let counted = try XCTUnwrap(WidgetSnapshot.Stream(digest, words: false))
        XCTAssertEqual(counted, .init(who: "Claude Code", isAgent: true, cards: 2), "agents first, and no card's title")
        XCTAssertEqual(counted.line(words: false), "Claude Code on 2 cards")
        XCTAssertEqual(counted.line(words: true), "Claude Code on 2 cards", "a title not kept can't show")

        let named = try XCTUnwrap(WidgetSnapshot.Stream(digest, words: true))
        XCTAssertEqual(named.card, "Fix the login bug", "the newest")
        XCTAssertEqual(named.line(words: true), "Claude Code on “Fix the login bug” and 1 more")
        XCTAssertEqual(named.line(words: false), "Claude Code on 2 cards", "words turned off since it was written")

        XCTAssertEqual(WidgetSnapshot.Stream(who: "You", isAgent: false, cards: 1).line(words: false), "You're on 1 card")
        XCTAssertEqual(WidgetSnapshot.Stream(who: "Sam", isAgent: false, cards: 1, card: "Book the venue").line(words: true), "Sam on “Book the venue”")
        let long = WidgetSnapshot.Stream(who: "Pennant", isAgent: true, cards: 1, card: String(repeating: "Look into the quarterly numbers ", count: 4))
        XCTAssertLessThanOrEqual(long.line(words: true).count, "Pennant on “”".count + 60, "an agent's long title is clipped")
    }

    func testNobodyWorkingIsNoStream() {
        let waiting = [WorkStreams.Card(title: "Check the copy", binder: "Binders", column: .review, assignee: "Claude Code",
                                        assigneeIsAgent: true, updated: now)]
        XCTAssertNil(WidgetSnapshot.Stream(WorkStreams.digest(waiting, now: now, calendar: calendar), words: false))
        XCTAssertNil(WidgetSnapshot.Stream(WorkStreams.digest([], now: now, calendar: calendar), words: true))
    }
}

final class CaptureIndicatorTests: XCTestCase {
    func testALossWhileListeningIsSaidOnce() {
        var indicator = CaptureIndicator()
        indicator.ended(captureOn: true)
        XCTAssertTrue(indicator.lost)
        XCTAssertTrue(indicator.couldNotShow(listening: true, allowed: true), "the first failed try says so")
        XCTAssertFalse(indicator.couldNotShow(listening: true, allowed: true), "and only once")
        XCTAssertTrue(indicator.told)
        indicator.settled()
        XCTAssertFalse(indicator.lost || indicator.told, "shown again: nothing more to say")
        XCTAssertFalse(indicator.couldNotShow(listening: true, allowed: true))
        // Eight hours on, it ends again: said again.
        indicator.ended(captureOn: true)
        XCTAssertTrue(indicator.couldNotShow(listening: true, allowed: true))
    }

    func testOnlyAnEndWhileCaptureIsOnIsALoss() {
        var indicator = CaptureIndicator()
        indicator.ended(captureOn: false)
        XCTAssertFalse(indicator.lost)
        XCTAssertFalse(indicator.couldNotShow(listening: true, allowed: true), "a request that fails without a loss stays on the capture screen")
    }

    func testMutedOrWithLiveActivitiesOffNothingIsSaid() {
        var indicator = CaptureIndicator()
        indicator.ended(captureOn: true)
        XCTAssertFalse(indicator.couldNotShow(listening: false, allowed: true), "muted, the microphone is off")
        XCTAssertFalse(indicator.couldNotShow(listening: true, allowed: false), "Live Activities off: the capture screen says so")
        XCTAssertTrue(indicator.lost, "still lost: listening again, it's said")
        XCTAssertTrue(indicator.couldNotShow(listening: true, allowed: true))
    }
}
