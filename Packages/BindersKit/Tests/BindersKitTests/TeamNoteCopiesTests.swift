import XCTest
@testable import BindersKit

/// Lane DB9: telling an edit made here from a merge or a move's bringing in, and finding the copies an earlier Binders made
/// when teammates joined.
final class TeamNoteCopiesTests: XCTestCase {
    let binder = UUID()
    let sam = UUID(), robin = UUID(), kim = UUID()

    private func note(_ title: String, _ text: String, by maker: UUID?, seen: Int64?, at minutes: Double = 0) -> TeamNoteCopies.Note {
        TeamNoteCopies.Note(id: UUID(), binder: binder, title: title, text: text, maker: maker,
                            createdAt: Date(timeIntervalSince1970: 1_000_000 + minutes * 60), firstSeen: seen)
    }

    func testThreeExactCopiesKeepTheOwnersAndRemoveTheJoiners() {
        let mine = note("Plan", "# Plan\n\nShip it.\n", by: sam, seen: 10)
        let robins = note("Plan", "# Plan\n\nShip it.\n", by: robin, seen: 20)
        let kims = note("Plan", "# Plan\n\nShip it.\n", by: kim, seen: 30)
        let found = TeamNoteCopies.find([kims, mine, robins], owner: sam)
        XCTAssertEqual(found.copies.map(\.note.id), [robins.id, kims.id])
        XCTAssertTrue(found.copies.allSatisfy { $0.keeps.id == mine.id })
        XCTAssertTrue(found.near.isEmpty)
        // Run again once they're gone: nothing.
        XCTAssertTrue(TeamNoteCopies.find([mine], owner: sam).isEmpty)
    }

    func testTheOwnersStaysEvenWhenAJoinersCameFirst() {
        let robins = note("Plan", "Same words", by: robin, seen: 5)
        let mine = note("Plan", "Same words", by: sam, seen: 9)
        let found = TeamNoteCopies.find([robins, mine], owner: sam)
        XCTAssertEqual(found.copies.map(\.note.id), [robins.id])
        XCTAssertEqual(found.copies.first?.keeps.id, mine.id)
    }

    func testWithoutTheOwnersTheFirstStays() {
        let robins = note("Plan", "Same words", by: robin, seen: 5)
        let kims = note("Plan", "Same words", by: kim, seen: 9)
        let found = TeamNoteCopies.find([kims, robins], owner: sam)
        XCTAssertEqual(found.copies.map(\.note.id), [kims.id])
        XCTAssertEqual(found.copies.first?.keeps.id, robins.id)
    }

    func testAPrunedFeedCountsAsOlder() {
        let old = note("Plan", "Same words", by: robin, seen: nil, at: 50)
        let newer = note("Plan", "Same words", by: kim, seen: 1, at: 0)
        XCTAssertEqual(TeamNoteCopies.find([newer, old], owner: nil).copies.map(\.note.id), [newer.id])
    }

    func testOneCharacterOfDifferenceIsNeverACopy() {
        let mine = note("Plan", "# Plan\n\nShip it.\n", by: sam, seen: 1)
        let robins = note("Plan", "# Plan\n\nShip it!\n", by: robin, seen: 2)
        let found = TeamNoteCopies.find([mine, robins], owner: sam)
        XCTAssertTrue(found.copies.isEmpty)
        XCTAssertEqual(Set(found.near.map(\.id)), [mine.id, robins.id])
    }

    func testTheSameMembersTwinsAndBlankNotesAreLeft() {
        let one = note("Checklist", "- a\n- b\n", by: sam, seen: 1)
        let two = note("Checklist", "- a\n- b\n", by: sam, seen: 2)
        let blank = note("", "  \n", by: robin, seen: 3)
        let otherBlank = note("", "  \n", by: kim, seen: 4)
        let found = TeamNoteCopies.find([one, two, blank, otherBlank], owner: sam)
        XCTAssertTrue(found.copies.isEmpty)
        XCTAssertTrue(found.near.isEmpty)
    }

    func testOnlyTheOtherMembersCopiesGoWhenTheOwnerHasTwo() {
        let one = note("Plan", "Same", by: sam, seen: 1)
        let two = note("Plan", "Same", by: sam, seen: 2)
        let robins = note("Plan", "Same", by: robin, seen: 3)
        let found = TeamNoteCopies.find([one, two, robins], owner: sam)
        XCTAssertEqual(found.copies.map(\.note.id), [robins.id])
        XCTAssertEqual(found.copies.first?.keeps.id, one.id)
    }

    func testCopiesInAnotherBinderArentThisOnes() {
        let mine = note("Plan", "Same", by: sam, seen: 1)
        var elsewhere = note("Plan", "Same", by: robin, seen: 2)
        elsewhere.binder = UUID()
        XCTAssertTrue(TeamNoteCopies.find([mine, elsewhere], owner: sam).copies.isEmpty)
    }

    // MARK: Which calls are edits made here

    func testAnEditIsntAMergeOrAMovesBringingIn() throws {
        let id = UUID(), member = UUID()
        let change = TeamNoteChange(hash: "abc123", deps: [], bytes: Data([1, 2, 3]))
        let edit = TeamCall.addNoteChanges(id, changes: [change])
        let merge = TeamCall.addNoteChanges(id, changes: [change], operation: TeamNoteOperations.merge(note: id, hash: "abc123"))
        let bringIn = TeamCall.addNoteChanges(id, changes: [change], operation: TeamNoteOperations.bringIn(note: id, member: member, hash: "abc123"))
        XCTAssertTrue(TeamNoteOperations.isEditMadeHere(edit, member: member))
        XCTAssertFalse(TeamNoteOperations.isEditMadeHere(merge, member: member))
        XCTAssertFalse(TeamNoteOperations.isEditMadeHere(bringIn, member: member))
        XCTAssertFalse(TeamNoteOperations.isEditMadeHere(.moveNote(id, binder: UUID(), folder: nil), member: member))
        // The ids are the ones build 39 made, so a merge waiting in an outbox it saved is still told apart.
        XCTAssertEqual(TeamNoteOperations.merge(note: id, hash: "abc123"), TeamOperationID.derived("merge note \(id.uuidString.lowercased()) abc123"))
        XCTAssertEqual(TeamNoteOperations.bringIn(note: id, member: member, hash: "abc123"),
                       TeamOperationID.derived("move note \(id.uuidString.lowercased()) by \(member.uuidString.lowercased()) abc123"))
    }

    func testAnUndeleteIsTold() {
        let id = UUID()
        let change = TeamNoteChange(hash: "s", deps: [], bytes: Data([1]))
        XCTAssertTrue(TeamNoteOperations.isUndelete(.createNote(id, binder: UUID(), fields: [:], changes: [change], undelete: true)))
        XCTAssertFalse(TeamNoteOperations.isUndelete(.createNote(id, binder: UUID(), fields: [:], changes: [change])))
    }
}
