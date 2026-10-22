import XCTest
@testable import BindersKit

/// Folders in the team copy: a note's folder in its front matter, folder files, member files, and folder names on
/// disk, each read by a Binders from before folders as it always read them.
final class TeamFolderTests: XCTestCase {
    private let author = TeamAuthor(id: "u1", name: "Maya")

    func testANotesFolderRoundTripsInItsFrontMatter() {
        let note = TeamNote(id: "N1", author: author, createdAt: Date(timeIntervalSince1970: 1_800_000_000), body: "Pipeline cleanup\n- logs",
                            extraFrontmatter: ["tags: [ops]"], binderID: "B1", binderName: "Work", folderID: "F1", folderPath: "Ops/DevOps")
        let markdown = TeamFiles.noteMarkdown(note)
        XCTAssertTrue(markdown.contains("binders_folder_id: \"F1\"\nbinders_folder: \"Ops/DevOps\""), markdown)
        XCTAssertEqual(TeamFiles.parseNote(markdown), note)
    }

    func testTheTopOfTheBinderIsToldApartFromNothingSaid() {
        let left = TeamNote(id: "N1", author: author, body: "Moved to the top", folderID: "", folderPath: "Ops")
        let markdown = TeamFiles.noteMarkdown(left)
        XCTAssertTrue(markdown.contains("binders_folder_id: \"\""), "a note that left its folders says so")
        XCTAssertFalse(markdown.contains("binders_folder:"), "with no path")
        XCTAssertEqual(TeamFiles.parseNote(markdown).folderID, "")
        XCTAssertNil(TeamFiles.parseNote("---\nbinders_id: \"N2\"\n---\nFrom before folders").folderID, "a file that says nothing")
        XCTAssertNil(TeamFiles.noteMarkdown(TeamNote(id: "N3", body: "At the top, never in a folder")).range(of: "binders_folder"))
    }

    /// A Binders before folders keeps every top-level line it doesn't know, so its edit keeps a note's folder.
    func testABinderBeforeFoldersKeepsTheFolderThroughItsEdit() {
        let file = TeamFiles.noteMarkdown(TeamNote(id: "N1", author: author, body: "Pipeline cleanup", binderID: "B1", folderID: "F1", folderPath: "DevOps"))
        let olderFields: Set<String> = ["binders_id", "author", "author_id", "edited_by", "created", "updated", "binder_id", "binder",
                                        "status", "owner", "due"]
        let parsed = Frontmatter.parse(file)
        let olderExtra = parsed.entries.filter { !olderFields.contains($0.key) }.flatMap(\.lines)
        XCTAssertEqual(olderExtra, ["binders_folder_id: \"F1\"", "binders_folder: \"DevOps\""], "what an older build keeps as it is")
        let rewritten = Frontmatter.render([("binders_id", "N1"), ("author", "Maya"), ("edited_by", "Dana")], extraLines: olderExtra,
                                           body: parsed.body + "\n- one more line")
        let read = TeamFiles.parseNote(rewritten)
        XCTAssertEqual(read.folderID, "F1")
        XCTAssertEqual(read.folderPath, "DevOps")
        XCTAssertTrue(read.extraFrontmatter.isEmpty)
    }

    func testAMeetingFileFromBeforeFoldersDecodesAndHashesAsBefore() throws {
        let file = TeamMeetingFile(id: "M1", author: author, title: "Sync", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                   updatedAt: Date(), duration: 60, appName: nil, attendees: [], templateID: "general", summary: "",
                                   notes: "", speakerNames: [:], segments: [], binderID: "B1", binderName: "Work")
        let json = try XCTUnwrap(String(data: TeamCoding.encoder().encode(file), encoding: .utf8))
        XCTAssertFalse(json.contains("folder"), "nothing new is written for a meeting at the top, so its hash is as it was")
        let decoded = try TeamCoding.decoder().decode(TeamMeetingFile.self, from: Data(json.utf8))
        XCTAssertNil(decoded.folderID)
        XCTAssertEqual(TeamFiles.contentHash(decoded), TeamFiles.contentHash(file))
        var filed = file
        filed.folderID = "F1"
        filed.folderPath = "DevOps"
        let back = try TeamCoding.decoder().decode(TeamMeetingFile.self, from: TeamCoding.encoder().encode(filed))
        XCTAssertEqual(back.folderID, "F1")
        XCTAssertNotEqual(TeamFiles.contentHash(filed), TeamFiles.contentHash(file), "a move is a change")
    }

    func testAMemberFileFromBeforeFoldersSaysNothingOfThem() throws {
        let old = #"{"id":"u2","lastSeen":"2026-10-01T09:00:00Z","name":"Dana"}"#
        let member = try TeamCoding.decoder().decode(TeamMember.self, from: Data(old.utf8))
        XCTAssertNil(member.features)
        XCTAssertFalse(member.knowsFolders)
        let current = TeamMember(id: "u1", name: "Maya", lastSeen: Date(timeIntervalSince1970: 1_800_000_000), features: TeamFeatures.thisMac)
        XCTAssertTrue(try TeamCoding.decoder().decode(TeamMember.self, from: TeamCoding.encoder().encode(current)).knowsFolders)
    }

    func testFilesMoveOnlyOnceEveryMembersBindersKnowsFolders() {
        let me = TeamMember(id: "u1", name: "Maya", lastSeen: Date())
        let newer = TeamMember(id: "u2", name: "Dana", lastSeen: Date(), features: [TeamFeatures.folders])
        let older = TeamMember(id: "u3", name: "Sam", lastSeen: Date())
        XCTAssertTrue(TeamFeatures.filesMayMove(members: [me, newer], unreadable: 0, me: "u1"), "this Mac's own file may be from before it updated")
        XCTAssertFalse(TeamFeatures.filesMayMove(members: [me, newer, older], unreadable: 0, me: "u1"))
        XCTAssertFalse(TeamFeatures.filesMayMove(members: [me, newer], unreadable: 1, me: "u1"), "a member file not read yet counts as older")
        XCTAssertTrue(TeamFeatures.filesMayMove(members: [], unreadable: 0, me: "u1"))
        XCTAssertEqual(TeamFeatures.waitingForFolders(members: [me, newer, older], me: "u1"), ["Sam"])
    }

    func testAFolderFileRoundTripsAndSyncsOnWhereItIsAndItsName() throws {
        let file = TeamFolderFile(id: "F1", binderID: "B1", parentID: nil, name: "DevOps", editedBy: author,
                                  createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_100))
        let back = try TeamCoding.decoder().decode(TeamFolderFile.self, from: TeamCoding.encoder().encode(file))
        XCTAssertEqual(back, file)
        var later = file
        later.updatedAt = Date()
        later.editedBy = TeamAuthor(id: "u2", name: "Dana")
        XCTAssertEqual(later.syncHash, file.syncHash, "who and when aren't a change")
        var renamed = file
        renamed.name = "Ops"
        var moved = file
        moved.parentID = "F0"
        var deleted = file
        deleted.deletedAt = Date()
        XCTAssertEqual(Set([file.syncHash, renamed.syncHash, moved.syncHash, deleted.syncHash]).count, 4)
    }

    func testFolderNamesOnDisk() {
        XCTAssertEqual(TeamFiles.safeFolderName("DevOps"), "DevOps")
        XCTAssertEqual(TeamFiles.safeFolderName("Q3: plan?"), "Q3 plan")
        XCTAssertEqual(TeamFiles.safeFolderName(".hidden"), "hidden", "a dot in front would hide it from the scan")
        XCTAssertEqual(TeamFiles.safeFolderName("Notes..."), "Notes")
        XCTAssertEqual(TeamFiles.safeFolderName("attachments"), "attachments folder", "a note's files go in attachments")
        XCTAssertEqual(TeamFiles.safeFolderName("_binders"), "_binders folder")
        XCTAssertEqual(TeamFiles.safeFolderName("CON"), "CON folder", "a name Windows keeps")
        XCTAssertEqual(TeamFiles.safeFolderName("  "), "Folder")
        XCTAssertEqual(TeamFiles.safeFolderName(String(repeating: "x", count: 90)).count, 60)
        XCTAssertEqual(TeamFiles.notesDirectory(["Ops", "Dev/Ops"]), "Notes/Ops/Dev Ops")
        XCTAssertEqual(TeamFiles.notesDirectory([]), "Notes")
        XCTAssertEqual(TeamFiles.meetingsDirectory(["Ops"]), "Meetings/Ops")
    }
}
