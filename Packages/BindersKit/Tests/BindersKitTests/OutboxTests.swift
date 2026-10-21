import Foundation
import XCTest
@testable import BindersKit

/// The iPhone's outbox, the parts that are rules: a list read one item at a time, the id a resent item carries, an
/// answer known to have arrived, and a Give to kept while it's tried at once. The outbox's own records and files are
/// checked by the iPhone's debug builds (Phone/Link/OutboxCheck.swift), as the iPhone has no unit-test target.
final class OutboxTests: XCTestCase {
    private struct Item: Codable, Equatable {
        let id: UUID
        let text: String
        let created: Date
        var payload: Data? = nil
    }

    private static func read(_ json: String) -> JSONItems.Read<Item>? {
        JSONItems.decode(Item.self, from: Data(json.utf8))
    }

    // MARK: A list read one item at a time

    func testEveryItemReads() throws {
        let items = [Item(id: UUID(), text: "Call Sam", created: Date(timeIntervalSinceReferenceDate: 782_300_000.25)),
                     Item(id: UUID(), text: "Ignite booth plan", created: Date(timeIntervalSinceReferenceDate: 782_300_100), payload: Data("{}".utf8))]
        let read = try XCTUnwrap(JSONItems.decode(Item.self, from: JSONEncoder().encode(items)))
        XCTAssertEqual(read.items, items)
        XCTAssertEqual(read.skipped, [])
    }

    func testOneItemThatDoesntReadLeavesOnlyItselfOut() throws {
        let first = UUID().uuidString, last = UUID().uuidString
        let read = try XCTUnwrap(Self.read("""
        [{"id":"\(first)","text":"Call Sam","created":782300000},
         {"id":"\(UUID().uuidString)","created":782300001},
         {"id":"\(UUID().uuidString)","text":"Book the dentist","created":"yesterday"},
         "not an item",
         null,
         {"id":"\(last)","text":"Ignite booth plan","created":782300002}]
        """))
        XCTAssertEqual(read.items.map(\.id.uuidString), [first, last])
        XCTAssertEqual(read.skipped.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(read.skipped.map(\.reason), ["it has no text", "created isn't the right kind of value",
                                                    "it isn't the right kind of value", "it is empty"])
    }

    func testFieldsItDoesntKnowAreLetGo() throws {
        let id = UUID().uuidString
        let read = try XCTUnwrap(Self.read("""
        [{"id":"\(id)","text":"Call Sam","created":782300000,"handoff":{"agent":"Claude Code"},"attempts":2}]
        """))
        XCTAssertEqual(read.items.map(\.id.uuidString), [id])
        XCTAssertEqual(read.items.first?.text, "Call Sam")
        XCTAssertEqual(read.skipped, [])
    }

    func testDataThatIsntAListReadsAsNothing() throws {
        XCTAssertNil(Self.read(#"{"id":"x"}"#))
        XCTAssertNil(Self.read("[{\"id\":"))
        XCTAssertNil(Self.read(""))
        let empty = try XCTUnwrap(Self.read("[]"))
        XCTAssertTrue(empty.items.isEmpty && empty.skipped.isEmpty)
    }

    func testWhyAnItemWasLeftOutNeverQuotesIt() throws {
        let read = try XCTUnwrap(Self.read("""
        [{"id":"what Sam said about pricing","text":"Call Sam","created":782300000},
         {"id":"\(UUID().uuidString)","text":"Call Sam","created":782300000,"payload":"not base64 at all, said by Sam"}]
        """))
        XCTAssertEqual(read.items.count, 0)
        XCTAssertEqual(read.skipped.map(\.reason), ["id is damaged", "payload is damaged"])
        XCTAssertFalse(read.skipped.contains { $0.reason.contains("Sam") })
    }

    // MARK: The id a resent item carries

    func testTheIdGoesOnlyToAMacThatRemembersIt() {
        let id = UUID()
        let deduped = OutboxRules.arguments(["text": "Call Sam", "binder": "Events"], id: id, dedupe: true)
        XCTAssertEqual(deduped[OutboxRules.requestKey] as? String, id.uuidString)
        XCTAssertEqual(deduped["text"] as? String, "Call Sam")
        XCTAssertEqual(deduped["binder"] as? String, "Events")
        XCTAssertEqual(OutboxRules.requestKey, "request_id")

        let plain = OutboxRules.arguments(["text": "Call Sam"], id: id, dedupe: false)
        XCTAssertNil(plain[OutboxRules.requestKey])
        XCTAssertEqual(plain.count, 1)
    }

    // MARK: An answer that already arrived

    private let card = UUID().uuidString
    private let asked = "2026-10-16T09:00:00Z"

    private func timeline(_ events: [OutboxRules.Event]) -> [OutboxRules.Event] {
        [(kind: "created", when: "2026-10-16T08:00:00Z", agent: false, text: "")] + events
    }

    func testAnAnswerOnTheCardAfterItsQuestionHasArrived() {
        let events = timeline([(kind: "question", when: asked, agent: true, text: "Light or dark?"),
                               (kind: "answer", when: "2026-10-16T09:05:00Z", agent: false, text: "Dark, please.")])
        XCTAssertTrue(OutboxRules.answerArrived("Dark, please.", card: card, asked: asked, in: events))
        XCTAssertTrue(OutboxRules.answerArrived("  Dark, please.\n", card: card, asked: asked, in: events), "as typed, with spaces around")
        // The same question, its time written in another time zone.
        XCTAssertTrue(OutboxRules.answerArrived("Dark, please.", card: card, asked: "2026-10-16T05:00:00-04:00", in: events))
        // A comment counts too: the card had left Blocked when it came.
        let comment = timeline([(kind: "question", when: asked, agent: true, text: "Light or dark?"),
                                (kind: "comment", when: "2026-10-16T09:05:00Z", agent: false, text: "Dark, please.")])
        XCTAssertTrue(OutboxRules.answerArrived("Dark, please.", card: card, asked: asked, in: comment))
    }

    func testOtherWordsOrSomeoneElsesHaventArrived() {
        let events = timeline([(kind: "question", when: asked, agent: true, text: "Light or dark?"),
                               (kind: "answer", when: "2026-10-16T09:05:00Z", agent: false, text: "Light.")])
        XCTAssertFalse(OutboxRules.answerArrived("Dark, please.", card: card, asked: asked, in: events))
        XCTAssertFalse(OutboxRules.answerArrived("", card: card, asked: asked, in: events))
        let agent = timeline([(kind: "question", when: asked, agent: true, text: "Light or dark?"),
                              (kind: "comment", when: "2026-10-16T09:05:00Z", agent: true, text: "Dark, please.")])
        XCTAssertFalse(OutboxRules.answerArrived("Dark, please.", card: card, asked: asked, in: agent), "an agent's words aren't your answer")
    }

    func testOnlyAnAnswerAfterThatQuestionCounts() {
        let earlier = "2026-10-16T07:00:00Z"
        let events = [(kind: "question", when: earlier, agent: true, text: "Ship it?"),
                      (kind: "answer", when: "2026-10-16T07:05:00Z", agent: false, text: "Yes."),
                      (kind: "question", when: asked, agent: true, text: "Tag it too?")]
        XCTAssertTrue(OutboxRules.answerArrived("Yes.", card: card, asked: earlier, in: events))
        XCTAssertFalse(OutboxRules.answerArrived("Yes.", card: card, asked: asked, in: events), "the same words before the question don't answer it")
        XCTAssertFalse(OutboxRules.answerArrived("Yes.", card: card, asked: "2026-10-16T10:00:00Z", in: events), "a question the card doesn't have")
    }

    // MARK: A Give to kept while it's tried at once

    /// A Give to kept for the Mac, by the card it's for.
    private struct GiveTo: Identifiable, Equatable {
        let id = UUID()
        let card: String
    }

    func testAGiveToIsKeptBeforeItsTryInPlaceOfTheOneForTheSameCard() {
        let older = GiveTo(card: "booth"), other = GiveTo(card: "flyer"), tapped = GiveTo(card: "booth")
        let outbox = OutboxRules.beforeTrying(tapped, in: [older, other], keeps: true) { $0.card == tapped.card }
        XCTAssertEqual(outbox, [other, tapped], "kept before it's tried, in place of the older one, and the rest left as they were")
        // Tapped again while the first is still tried: the newest stands, once, rather than one each.
        let again = GiveTo(card: "booth")
        XCTAssertEqual(OutboxRules.beforeTrying(again, in: outbox, keeps: true) { $0.card == again.card }, [other, again])
        // One that wouldn't be kept if its try failed (Give to on a moment, for a Mac too old to take it later) isn't kept
        // now either, and the older one still goes.
        XCTAssertEqual(OutboxRules.beforeTrying(tapped, in: [older, other], keeps: false) { $0.card == tapped.card }, [other])
        XCTAssertEqual(OutboxRules.beforeTrying(tapped, in: [], keeps: true) { $0.card == tapped.card }, [tapped], "into an empty outbox")
    }

    func testAnOutboxRunPassesOverAGiveToBeingTriedAtOnce() {
        let giving = GiveTo(card: "booth"), waiting = GiveTo(card: "flyer")
        let everything: (GiveTo) -> Bool = { _ in true }
        XCTAssertEqual(OutboxRules.next(in: [giving, waiting], tried: [], trying: [giving.id], sends: everything), waiting,
                       "a run while it's tried sends the rest")
        XCTAssertNil(OutboxRules.next(in: [giving, waiting], tried: [waiting.id], trying: [giving.id], sends: everything),
                     "and not it, even with nothing else left")
        XCTAssertEqual(OutboxRules.next(in: [giving, waiting], tried: [], trying: [], sends: everything), giving,
                       "its try over without getting through, the next run sends it, in its place")
        XCTAssertEqual(OutboxRules.next(in: [giving, waiting], tried: [giving.id], trying: [], sends: everything), waiting, "each item once a run")
        XCTAssertEqual(OutboxRules.next(in: [giving, waiting], tried: [], trying: [], sends: { $0.card != "booth" }), waiting,
                       "what can't go yet (a conversation, to a Mac that doesn't take them) waits")
    }
}
