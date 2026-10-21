import XCTest
@testable import BindersKit

final class LinkFeaturesTests: XCTestCase {
    func testAPhoneThatListsNothingIsTheFirstOne() {
        XCTAssertEqual(LinkFeatures.phone(nil), LinkFeatures.firstPhone)
        XCTAssertEqual(LinkFeatures.phone([]), LinkFeatures.firstPhone)
        XCTAssertEqual(LinkFeatures.firstPhone, ["suggestion:card", "suggestion:answer", "notification:binders/changed"])
    }

    func testThisPhoneReadsAtLeastWhatTheFirstOneDid() {
        XCTAssertTrue(LinkFeatures.firstPhone.isSubset(of: Set(LinkFeatures.thisPhone)))
    }

    /// This phone sends its mode for what you say on your own; the first phone, and one that lists nothing, don't.
    func testThisPhoneSendsItsMode() {
        XCTAssertTrue(LinkFeatures.thisPhone.contains("momentAuto"))
        XCTAssertTrue(LinkFeatures.thisPhone.contains(MomentPayload.agreedFeature), "beside the yes it sends")
        XCTAssertFalse(LinkFeatures.firstPhone.contains(MomentPayload.autoFeature))
        XCTAssertFalse(LinkFeatures.phone(nil).contains(MomentPayload.autoFeature))
        XCTAssertEqual(Set(LinkFeatures.thisPhone).count, LinkFeatures.thisPhone.count, "each once")
    }

    /// The Mac's addresses go only to a phone that says it reads them: in the hello and as a notice.
    func testThisPhoneReadsTheMacsAddresses() {
        XCTAssertTrue(LinkFeatures.thisPhone.contains(LinkFeatures.addresses))
        XCTAssertTrue(LinkFeatures.thisPhone.contains("notification:binders/addresses"))
        XCTAssertEqual(LinkFeatures.notification(LinkFeatures.addressesMethod), "notification:binders/addresses")
        XCTAssertFalse(LinkFeatures.firstPhone.contains(LinkFeatures.addresses))
        XCTAssertFalse(LinkFeatures.phone(nil).contains(LinkFeatures.notification(LinkFeatures.addressesMethod)))
    }

    /// A comment wakes the agent holding a card only on a Mac that says so, and from a phone that says it asks first.
    func testThisPhoneAsksFirstBeforeAComment() {
        XCTAssertTrue(LinkFeatures.thisPhone.contains(LinkFeatures.commentsAskFirst))
        XCTAssertEqual(LinkFeatures.commentsAskFirst, "commentsAskFirst")
        XCTAssertEqual(LinkFeatures.commentWakes, "commentWakes")
        XCTAssertFalse(LinkFeatures.firstPhone.contains(LinkFeatures.commentsAskFirst), "iPhone 2.0 doesn't ask")
        XCTAssertFalse(LinkFeatures.phone(nil).contains(LinkFeatures.commentsAskFirst))
        XCTAssertFalse(LinkFeatures.thisPhone.contains(LinkFeatures.commentWakes), "the Mac's feature, not the phone's")
        XCTAssertTrue(LinkFeatures.phone(LinkFeatures.thisPhone).contains(LinkFeatures.commentsAskFirst))
    }

    /// iPhone 2.0 decoded the list whole, so one kind it didn't know lost them all. Now only that one is skipped.
    func testASuggestionOfAKindThisBuildDoesntKnowIsSkippedAlone() throws {
        let known = ConversationSuggestion(conversation: UUID(), kind: .card, text: "Book the venue", binder: "Harbor launch")
        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any])
        unknown["kind"] = "something-new"
        unknown["id"] = "something-new-1"
        let data = try JSONSerialization.data(withJSONObject: [try JSONSerialization.jsonObject(with: JSONEncoder().encode(known)), unknown])
        XCTAssertEqual(ConversationSuggestion.decodeEach(data).map(\.text), ["Book the venue"])
        XCTAssertEqual(ConversationSuggestion.decodeList(String(decoding: data, as: UTF8.self)).count, 1)
    }
}
