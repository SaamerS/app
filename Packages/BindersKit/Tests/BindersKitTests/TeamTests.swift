import XCTest
@testable import BindersKit

final class TeamFormatTests: XCTestCase {
    func testFrontmatterRoundTripsTrickyValues() {
        let text = Frontmatter.render([("title", "Q3: \"launch\" plan"), ("author", "Dana")], body: "Line one\n---\nLine three")
        let parsed = Frontmatter.parse(text)
        XCTAssertEqual(parsed.fields["title"], "Q3: \"launch\" plan")
        XCTAssertEqual(parsed.fields["author"], "Dana")
        XCTAssertEqual(parsed.body, "Line one\n---\nLine three")
    }

    func testParsesHandWrittenYamlAndPlainNotes() {
        let parsed = Frontmatter.parse("---\ntags: [a, b]\nauthor: 'Lee'\n---\nBody")
        XCTAssertEqual(parsed.fields["author"], "Lee")
        XCTAssertEqual(parsed.fields["tags"], "[a, b]")
        XCTAssertEqual(parsed.body, "Body")

        let plain = TeamFiles.parseNote("Hiring plan\n- Two engineers")
        XCTAssertNil(plain.id)
        XCTAssertNil(plain.author)
        XCTAssertEqual(plain.body, "Hiring plan\n- Two engineers")

        let obsidian = TeamFiles.parseNote("---\nbinders_id: \"n1\"\n---\n\nBody after a blank line")
        XCTAssertEqual(obsidian.id, "n1")
        XCTAssertEqual(obsidian.body, "Body after a blank line")
    }

    func testNoteRoundTrip() {
        let note = TeamNote(id: "abc", author: TeamAuthor(id: "u1", name: "Maya"), editedBy: "Dana",
                            createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
                            body: "Launch checklist\n- item")
        XCTAssertEqual(TeamFiles.parseNote(TeamFiles.noteMarkdown(note)), note)
    }

    /// An agent's edit to a shared note goes in the file with the note: who and when, read back exactly, next to what
    /// other tools keep there.
    func testAnAgentsEditTravelsWithTheNote() {
        let edited = Date(timeIntervalSince1970: 1_800_000_000)
        let mark = TeamNoteMark(madeBy: "Claude Code · app", editedBy: "Codex \"exec\" \\ run", editedAt: edited)
        let note = TeamNote(id: "n1", author: TeamAuthor(id: "u1", name: "Maya"), body: "Booth rota\n- Sam on Monday",
                            extraFrontmatter: ["tags: [launch]"] + mark.lines)
        let parsed = TeamFiles.parseNote(TeamFiles.noteMarkdown(note))
        XCTAssertEqual(TeamNoteMark(lines: parsed.extraFrontmatter), mark)
        XCTAssertEqual(TeamNoteMark.removing(from: parsed.extraFrontmatter), ["tags: [launch]"], "taking the mark out leaves the rest")
        XCTAssertEqual(parsed.body, note.body)
        XCTAssertEqual(mark.lines, ["binders_made_by: \"Claude Code · app\"", "binders_edited_by: \"Codex \\\"exec\\\" \\\\ run\"",
                                    "binders_edited_at: \"2027-01-15T08:00:00Z\""])
    }

    /// Files from before edits were marked, and a note that's all yours, carry no mark; an agent's own note hashes as it
    /// always did, so updating makes no shared note look changed.
    func testAMarkIsAddedOnlyWhereThereIsOne() {
        let plain = TeamFiles.parseNote("---\nbinders_id: \"n1\"\nauthor: \"Maya\"\ntags: [launch]\n---\nBooth rota")
        XCTAssertTrue(TeamNoteMark(lines: plain.extraFrontmatter).isEmpty)
        XCTAssertEqual(TeamNoteMark().lines, [])
        XCTAssertEqual(TeamNoteMark().hashSuffix, "")
        XCTAssertEqual(TeamNoteMark(madeBy: "Claude Code").hashSuffix, "\n\u{1}made by Claude Code", "as before edits were marked")
        XCTAssertNotEqual(TeamNoteMark(madeBy: "Claude Code", editedBy: "Codex").hashSuffix, TeamNoteMark(madeBy: "Claude Code").hashSuffix,
                          "an agent's edit, or taking it off, is a change to sync")
        XCTAssertEqual(TeamNoteMark(editedBy: "Codex", editedAt: Date()).hashSuffix, TeamNoteMark(editedBy: "Codex").hashSuffix,
                       "the time isn't in the hash, which a file keeps only to the second")
        XCTAssertEqual(TeamNoteMark(madeBy: "", editedBy: "", editedAt: Date()), TeamNoteMark(), "empty names count as none")
        XCTAssertTrue(TeamNoteMark(lines: ["binders_edited_by: \"\"", "binders_edited_at: \"2027-01-15T08:00:00Z\""]).isEmpty,
                      "a time without an agent is no mark")
    }

    /// A Binders from before edits were marked writes a shared note back keeping every line it doesn't know, but its own
    /// `binders_made_by`, which it writes again: an agent's edit stays marked through a teammate's edit there.
    func testAnOlderBuildKeepsTheEditMark() {
        let mark = TeamNoteMark(editedBy: "Claude Code", editedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let file = TeamNote(id: "n1", author: TeamAuthor(id: "u1", name: "Maya"), body: "Booth rota", extraFrontmatter: mark.lines)
        let read = TeamFiles.parseNote(TeamFiles.noteMarkdown(file))
        let olderExtra = read.extraFrontmatter.filter { !$0.hasPrefix("binders_made_by:") }
        let rewritten = TeamNote(id: "n1", author: read.author, editedBy: "Dana", body: read.body + "\n- Dana on Tuesday", extraFrontmatter: olderExtra)
        XCTAssertEqual(TeamNoteMark(lines: TeamFiles.parseNote(TeamFiles.noteMarkdown(rewritten)).extraFrontmatter), mark)
    }

    func testMeetingHashIgnoresWriteTimeAndSegmentOrderAndSurvivesJson() throws {
        let first = TranscriptSegment(channel: .microphone, start: 1, end: 2, text: "Hi")
        let second = TranscriptSegment(channel: .system, start: 3, end: 4, text: "Hello", speaker: "Speaker 1")
        var file = TeamMeetingFile(id: "m1", author: TeamAuthor(id: "u1", name: "Maya"), title: "Sync",
                                   createdAt: Date(timeIntervalSince1970: 1_800_000_000.25), updatedAt: Date(), duration: 60,
                                   appName: nil, attendees: [], templateID: "general", summary: "S", notes: "",
                                   speakerNames: ["Speaker 1": "Dana"], segments: [first, second])
        let hash = TeamFiles.contentHash(file)
        file.updatedAt = Date().addingTimeInterval(500)
        file.segments = [second, first]
        XCTAssertEqual(TeamFiles.contentHash(file), hash)

        let decoded = try TeamCoding.decoder().decode(TeamMeetingFile.self, from: TeamCoding.encoder().encode(file))
        XCTAssertEqual(TeamFiles.contentHash(decoded), hash)

        file.summary = "Changed"
        XCTAssertNotEqual(TeamFiles.contentHash(file), hash)
    }

    func testMeetingMarkdownAndFileNames() {
        XCTAssertEqual(TeamFiles.safeFileName("Q3/Q4: plan?"), "Q3 Q4 plan.md")
        XCTAssertEqual(TeamFiles.safeFileName("  ...  "), "Untitled.md")
        XCTAssertEqual(TeamFiles.safeFileName("Sync", date: Date(timeIntervalSince1970: 1_800_014_400)), "2027-01-15 Sync.md")

        let file = TeamMeetingFile(id: "m1", author: TeamAuthor(id: "u1", name: "Maya"), title: "Pricing sync",
                                   createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(), duration: 1200, appName: "Zoom",
                                   attendees: ["Dana"], templateID: "general", summary: "## Decisions\n- $49 one-time", notes: "",
                                   speakerNames: [:], segments: [TranscriptSegment(channel: .microphone, start: 5, end: 6, text: "Deal.")])
        let markdown = TeamFiles.meetingMarkdown(file)
        let parsed = Frontmatter.parse(markdown)
        XCTAssertEqual(parsed.fields["binders_id"], "m1")
        XCTAssertEqual(parsed.fields["author"], "Maya")
        XCTAssertTrue(parsed.body.hasPrefix("# Pricing sync"))
        // In the shared copy, "You" is the meeting's author.
        XCTAssertTrue(parsed.body.contains("**[00:05] Maya:** Deal."))
    }

    func testObsidianFrontmatterIsPreserved() {
        let original = "---\ntags:\n  - hiring\naliases: [Plan]\n---\n# Hiring plan\nTwo engineers"
        let withID = Frontmatter.setting("binders_id", to: "n1", in: original)
        XCTAssertEqual(withID, "---\nbinders_id: \"n1\"\ntags:\n  - hiring\naliases: [Plan]\n---\n# Hiring plan\nTwo engineers")
        XCTAssertEqual(Frontmatter.setting("binders_id", to: "n2", in: withID), withID.replacingOccurrences(of: "\"n1\"", with: "\"n2\""))
        XCTAssertEqual(Frontmatter.setting("binders_id", to: "n3", in: "Plain"), "---\nbinders_id: \"n3\"\n---\nPlain")

        var note = TeamFiles.parseNote(withID)
        XCTAssertEqual(note.id, "n1")
        XCTAssertEqual(note.extraFrontmatter, ["tags:", "  - hiring", "aliases: [Plan]"])
        note.body += "\nOne designer"
        note.author = TeamAuthor(id: "u2", name: "Dana")
        let rewritten = TeamFiles.noteMarkdown(note)
        XCTAssertTrue(rewritten.contains("tags:\n  - hiring\naliases: [Plan]\n---\n# Hiring plan"))
        XCTAssertEqual(TeamFiles.parseNote(rewritten), note)
    }

    func testStableIDs() {
        let id = TeamFiles.stableID(forPath: "Notes/Hiring plan.md")
        XCTAssertEqual(id, TeamFiles.stableID(forPath: "Notes/Hiring plan.md"))
        XCTAssertNotEqual(id, TeamFiles.stableID(forPath: "Notes/Hiring plan 2.md"))
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(TeamFiles.stableID(forPath: "Notes/Cafe\u{301}.md"), TeamFiles.stableID(forPath: "Notes/Café.md"))
    }

    func testSyncDecisions() {
        XCTAssertEqual(SyncDecision.decide(local: "a", remote: "a", lastSynced: nil), .upToDate)
        XCTAssertEqual(SyncDecision.decide(local: "b", remote: "a", lastSynced: "a"), .pushLocal)
        XCTAssertEqual(SyncDecision.decide(local: "a", remote: "b", lastSynced: "a"), .pullRemote)
        XCTAssertEqual(SyncDecision.decide(local: "b", remote: "c", lastSynced: "a"), .conflict)
        XCTAssertEqual(SyncDecision.decide(local: "b", remote: "c", lastSynced: nil), .conflict)
        XCTAssertEqual(SyncDecision.decide(local: "a", remote: nil, lastSynced: nil), .pushLocal)
        XCTAssertEqual(SyncDecision.decide(local: nil, remote: "a", lastSynced: nil), .pullRemote)
    }
}


final class TeamBinderFieldTests: XCTestCase {
    func testNoteFrontmatterCarriesTheBinder() {
        let note = TeamNote(id: "N1", author: TeamAuthor(id: "u1", name: "Dana"), createdAt: Date(timeIntervalSince1970: 0),
                            body: "Call the venue", binderID: "B1", binderName: "Ignite 2026")
        let markdown = TeamFiles.noteMarkdown(note)
        XCTAssertTrue(markdown.contains("binder_id: \"B1\""))
        XCTAssertTrue(markdown.contains("binder: \"Ignite 2026\""))
        let parsed = TeamFiles.parseNote(markdown)
        XCTAssertEqual(parsed.binderID, "B1")
        XCTAssertEqual(parsed.binderName, "Ignite 2026")
        XCTAssertEqual(parsed.body, "Call the venue")
        XCTAssertTrue(parsed.extraFrontmatter.isEmpty)
        // Files from before binders existed still parse.
        XCTAssertNil(TeamFiles.parseNote("---\nbinders_id: N2\n---\nold note").binderID)
    }

    func testMeetingFileDecodesWithoutBinderFields() throws {
        let file = TeamMeetingFile(id: "M1", author: TeamAuthor(id: "u1", name: "Dana"), title: "Sync", createdAt: Date(), updatedAt: Date(),
                                   duration: 60, appName: nil, attendees: [], templateID: "general", summary: "", notes: "",
                                   speakerNames: [:], segments: [], binderID: "B1", binderName: "Ignite")
        var data = try TeamCoding.encoder().encode(file)
        var json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"binderID\""))
        json = json.replacingOccurrences(of: "\"binderID\"", with: "\"oldKey\"")
        data = Data(json.utf8)
        let decoded = try TeamCoding.decoder().decode(TeamMeetingFile.self, from: data)
        XCTAssertNil(decoded.binderID)
        XCTAssertNotEqual(TeamFiles.contentHash(file), TeamFiles.contentHash(decoded))
    }

    func testFindsTheTeamSpaceNearTheFolderPicked() {
        let drive = URL(fileURLWithPath: "/Users/sam/Library/CloudStorage/OneDrive-Example")
        let space = drive.appendingPathComponent("Example Binder")
        let other = drive.appendingPathComponent("Budgets")
        var spaces: Set<String> = [space.path]
        func locate(_ picked: URL) -> TeamLocator.Result {
            TeamLocator.locate(near: picked, isTeamSpace: { spaces.contains($0.path) }, children: { folder in
                folder == drive ? [other, space] : [folder.appendingPathComponent("Notes"), folder.appendingPathComponent("Meetings")]
            })
        }
        XCTAssertEqual(locate(space), .found(space))
        XCTAssertEqual(locate(space.appendingPathComponent("Notes")), .found(space), "a folder inside it")
        XCTAssertEqual(locate(space.appendingPathComponent("_binders/members")), .found(space), "two levels in")
        XCTAssertEqual(locate(drive), .found(space), "the drive the shared folder sits in")
        XCTAssertEqual(locate(other), .none)
        spaces.insert(other.path)
        XCTAssertEqual(locate(drive), .several([other, space]))
    }

    func testRecognizesADataFolderSyncedOnItsOwn() {
        // OneDrive syncs a shared folder as "<owner> - <folder>" under its shared libraries; here, only _binders was shared.
        let libraries = URL(fileURLWithPath: "/Users/sam/Library/CloudStorage/OneDrive-SharedLibraries-Example")
        let data = libraries.appendingPathComponent("Alex Doe - _binders")
        func locate(_ picked: URL) -> TeamLocator.Result {
            TeamLocator.locate(near: picked, isTeamSpace: { _ in false }, isDataFolder: { $0 == data },
                               children: { $0 == libraries ? [data] : [] })
        }
        XCTAssertEqual(locate(data), .dataFolderOnly(data))
        XCTAssertEqual(locate(libraries), .dataFolderOnly(data))
    }

    func testKnowsTheTopOfADrive() {
        let home = URL(fileURLWithPath: "/Users/sam")
        XCTAssertTrue(TeamLocator.isDriveRoot(URL(fileURLWithPath: "/Users/sam/Library/CloudStorage/OneDrive-Example"), home: home))
        XCTAssertFalse(TeamLocator.isDriveRoot(URL(fileURLWithPath: "/Users/sam/Library/CloudStorage/OneDrive-Example/Team"), home: home))
        XCTAssertFalse(TeamLocator.isDriveRoot(URL(fileURLWithPath: "/Users/sam/Dropbox"), home: home))
    }
}
