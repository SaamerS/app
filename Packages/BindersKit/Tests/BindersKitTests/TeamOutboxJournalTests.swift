import XCTest
@testable import BindersKit

/// Lane DB10: the outbox kept as a file plus a journal of what happened since, and note rows read without their documents.
final class TeamOutboxJournalTests: XCTestCase {
    private func calls(_ count: Int) -> [TeamCall] { (0..<count).map { TeamCall.report(UUID(), progress: "Step \($0)") } }

    func testTheJournalReplayedOnTheFileGivesTheOutboxBack() throws {
        var outbox = TeamOutbox()
        let list = calls(6)
        for call in list.prefix(3) { outbox.add(call) }
        let file = try outbox.encoded(journal: 4)
        var journal = Data()
        func record(_ entry: TeamOutboxEntry) throws {
            outbox.apply(entry)
            journal.append(try TeamOutbox.line(entry))
        }
        for call in list.suffix(3) { try record(.add(TeamOutboxItem(call: call, added: Date(timeIntervalSinceReferenceDate: 800_000_000)))) }
        try record(.settle(list[0].operation))
        try record(.attempted(list[1].operation, error: "The connection closed"))
        try record(.settle(list[4].operation))

        var read = try TeamOutbox(data: file)
        XCTAssertEqual(TeamOutbox.journal(after: file), 4)
        let (entries, unread) = TeamOutbox.entries(in: journal)
        XCTAssertEqual(unread, 0)
        XCTAssertEqual(entries.count, 6)
        for entry in entries { read.apply(entry) }
        XCTAssertEqual(read, outbox, "the same items, in order, with their attempts and errors")
        XCTAssertEqual(read.items.map(\.id), [list[1], list[2], list[3], list[5]].map(\.operation))
        XCTAssertEqual(read.items.first?.attempts, 1)
        XCTAssertEqual(read.items.first?.lastError, "The connection closed")

        // Replayed twice (a Mac that stopped between writing the file whole and removing the journal): the same outbox.
        for entry in entries { read.apply(entry) }
        XCTAssertEqual(read.items.map(\.id), outbox.items.map(\.id))
    }

    func testALineCutShortByACrashIsSkipped() throws {
        let call = calls(1)[0]
        var journal = try TeamOutbox.line(.add(TeamOutboxItem(call: call, added: Date())))
        let second = try TeamOutbox.line(.settle(call.operation))
        journal.append(second.prefix(second.count / 2))
        let (entries, unread) = TeamOutbox.entries(in: journal)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(unread, 1)
    }

    func testAnEarlierOutboxFileHasNoJournalAndAnEarlierBindersReadsANewOne() throws {
        var outbox = TeamOutbox()
        for call in calls(2) { outbox.add(call) }
        // As an earlier Binders wrote it: version and items, nothing else.
        let earlier = try JSONSerialization.data(withJSONObject: ["version": 1, "items": try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(outbox.items))])
        XCTAssertEqual(TeamOutbox.journal(after: earlier), 0)
        XCTAssertEqual(try TeamOutbox(data: earlier), outbox)
        // A new file read as an earlier Binders reads it (its own File, which ignores what it doesn't know).
        struct EarlierFile: Decodable { var version: Int; var items: [TeamOutboxItem] }
        let read = try JSONDecoder().decode(EarlierFile.self, from: outbox.encoded(journal: 9))
        XCTAssertEqual(read.items, outbox.items)
    }

    func testPasswordCallsNeverComeBackFromAJournal() throws {
        let add = TeamCall.addMember(UUID(), login: "alex", name: "Alex", verifier: TeamPassword.verifier(for: "k7Rf-29xQ"))
        var outbox = TeamOutbox()
        outbox.apply(.add(TeamOutboxItem(call: add, added: Date())))
        XCTAssertTrue(outbox.isEmpty)
    }

    func testBytesGoAsPostgresWritesThemAndComeBack() {
        let bytes = Data((0..<4096).map { UInt8($0 % 256) })
        let json = TeamJSON(bytes: bytes)
        XCTAssertEqual(json.string?.prefix(8), "\\x000102")
        XCTAssertEqual(json.bytes, bytes)
        XCTAssertEqual(TeamJSON.string("\\x0A1bFF").bytes, Data([0x0A, 0x1B, 0xFF]), "either case, as Postgres may write it")
        XCTAssertNil(TeamJSON.string("\\x0g").bytes)
        XCTAssertNil(TeamJSON.string("\\x0").bytes, "an odd number of digits")
        XCTAssertNil(TeamJSON.string("0a").bytes, "not bytea")
        XCTAssertEqual(TeamJSON.string("\\x").bytes, Data())
        XCTAssertEqual(TeamJSON(bytes: nil), .null)
    }

    func testFeedReadsLeaveANotesDocumentAndBodyOut() {
        let light = TeamQueries.rows(byID: .notes, leaving: TeamQueries.noteRowHeavyColumns)
        XCTAssertTrue(light.contains("to_jsonb(t) - 'tsv' - 'document' - 'body'"), light)
        XCTAssertEqual(TeamQueries.rows(byID: .cards), TeamQueries.rows(byID: .cards, leaving: []))
        let id = UUID(), binder = UUID()
        let whole: TeamRow = ["id": .string(id.uuidString), "binder_id": .string(binder.uuidString), "document": .null, "body": .string("Hi")]
        var stripped = whole
        stripped["document"] = nil
        stripped["body"] = nil
        XCTAssertTrue(TeamNoteRow.isWhole(whole), "a note never saved whole has a null document, and is whole")
        XCTAssertFalse(TeamNoteRow.isWhole(stripped))
        XCTAssertEqual(TeamNoteRow(row: stripped)?.body, "")
    }
}
