import XCTest
@testable import BindersKit

final class InboxTests: XCTestCase {
    func testRequestsAndResultsRoundTrip() throws {
        let request = InboxRequest(action: "add_note", fields: ["text": "Call Sam\n\nabout the deck", "binder": "Work"])
        let decoded = try JSONDecoder().decode(InboxRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)

        let result = InboxResult(ok: true, id: "ABC", message: "Note added")
        XCTAssertEqual(try JSONDecoder().decode(InboxResult.self, from: JSONEncoder().encode(result)), result)
        XCTAssertEqual(InboxResult.failure("nope").error, "nope")
        XCTAssertFalse(InboxResult.failure("nope").ok)
    }

    func testSeveralItemsRoundTripAndOldResultsStillRead() throws {
        let result = InboxResult(ok: true, id: "F", message: "Moved 1 of 2", items: [
            InboxResult.Item(id: "A", done: true, title: "Booth plan"),
            InboxResult.Item(id: "B", done: false, why: "Nothing has that id."),
        ])
        XCTAssertEqual(try JSONDecoder().decode(InboxResult.self, from: JSONEncoder().encode(result)), result)
        XCTAssertEqual(result.items?.first?.reply["moved"] as? Bool, true)
        XCTAssertEqual(result.items?.last?.reply["why"] as? String, "Nothing has that id.")
        XCTAssertNil(result.items?.last?.reply["title"])
        // A result from a Mac before 0.10.0 has no items, and reads as it always did.
        let old = try JSONDecoder().decode(InboxResult.self, from: Data(#"{"ok":true,"id":"X","message":"Moved"}"#.utf8))
        XCTAssertEqual(old, InboxResult(ok: true, id: "X", message: "Moved"))
        XCTAssertNil(old.items)
    }

    func testAListParameterIsAListOfStrings() {
        let tool = MCPTool(name: "move_item", description: "Move", parameters: [
            MCPToolParameter(name: "ids", type: "array", description: "Several ids"),
            MCPToolParameter(name: "to", description: "Where", required: true),
        ])
        let properties = tool.schema["inputSchema"].flatMap { ($0 as? [String: Any])?["properties"] as? [String: Any] }
        let ids = properties?["ids"] as? [String: Any]
        XCTAssertEqual(ids?["type"] as? String, "array")
        XCTAssertEqual((ids?["items"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertNil((properties?["to"] as? [String: Any])?["items"])
    }

    func testOnlyUUIDNamesAreAccepted() {
        let name = UUID().uuidString
        XCTAssertTrue(Inbox.isValidName(name))
        XCTAssertEqual(Inbox.requestFile(name), name + ".request.json")
        XCTAssertEqual(Inbox.resultFile(name), name + ".result.json")
        XCTAssertFalse(Inbox.isValidName("../../etc/passwd"))
        XCTAssertFalse(Inbox.isValidName("note"))
        XCTAssertFalse(Inbox.isValidName(""))
    }
}
