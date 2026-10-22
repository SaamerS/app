import XCTest
@testable import BindersKit

/// Lane DB3's pure parts: what changed from one text to another (as Automerge's splices, in scalars), the three-way
/// merge an editor uses when a teammate's change lands on its typing, where a cursor goes, what travels with a note, the
/// version rule, presence, Distill's rows, the calls and migration 6. The Mac's `--selftest-teamdb-notes` runs them against
/// a real Postgres and real Automerge documents.
final class TeamNotesTests: XCTestCase {
    // MARK: Edits and splices

    func testTypingIsOneSpliceInScalars() {
        let old = "# Launch\n\nShip on Friday.\n"
        let new = "# Launch\n\nShip on Friday, after the review.\n"
        let splices = TextEdits.splices(from: old, to: new)
        XCTAssertEqual(splices, [TextSplice(start: 24, delete: 0, insert: ", after the review")])
        XCTAssertEqual(TextEdits.apply(splices, to: old), new)
        // Counted in Unicode scalars, as Automerge counts: a flag is two, an accent typed apart is one more.
        let flag = "🇬🇧 Plan\n", accent = "Cafe\u{301} plan\n"
        XCTAssertEqual(TextEdits.splices(from: flag, to: flag + "More\n"), [TextSplice(start: 8, delete: 0, insert: "More\n")])
        XCTAssertEqual(TextEdits.splices(from: accent, to: accent.replacingOccurrences(of: "plan", with: "menu")),
                       [TextSplice(start: 6, delete: 4, insert: "menu")])
        XCTAssertEqual(TextEdits.splices(from: "same", to: "same"), [])
    }

    func testEditsFarApartStayApartSoTypingElsewhereSurvives() {
        let old = (1...30).map { "Line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...30).map { "Line \($0)" }
        lines[2] = "Line 3, changed"
        lines[25] = "Line 26 too"
        lines.insert("A new line", at: 15)
        let new = lines.joined(separator: "\n") + "\n"
        let splices = TextEdits.splices(from: old, to: new)
        XCTAssertEqual(splices.count, 3, "three places, three splices: \(splices)")
        XCTAssertEqual(splices.map(\.insert), [", changed", "A new line\n", " too"])
        XCTAssertEqual(TextEdits.apply(splices, to: old), new)
        // A whole note replaced by an agent's update_note touches only what it changed.
        let whole = old.replacingOccurrences(of: "Line 20\n", with: "Line twenty\n")
        XCTAssertEqual(TextEdits.splices(from: old, to: whole).count, 1)
    }

    func testSplicesTurnAnyTextIntoAnyOther() {
        var generator = SeededGenerator(seed: 42)
        let words = ["alpha", "beta", "## Heading", "- item", "🇬🇧", "e\u{301}", "\n", "\n\n", " ", "x", "Café", "日本"]
        func random(_ count: Int) -> String { (0..<count).map { _ in words.randomElement(using: &generator)! }.joined() }
        for _ in 0..<300 {
            let old = random(Int.random(in: 0...40, using: &generator))
            var new = old
            for _ in 0..<Int.random(in: 0...4, using: &generator) {
                let scalars = Array(new.unicodeScalars)
                let at = Int.random(in: 0...scalars.count, using: &generator)
                let cut = Int.random(in: 0...min(6, scalars.count - at), using: &generator)
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[..<at])
                view.append(contentsOf: random(Int.random(in: 0...3, using: &generator)).unicodeScalars)
                view.append(contentsOf: scalars[(at + cut)...])
                new = String(view)
            }
            XCTAssertEqual(TextEdits.apply(TextEdits.splices(from: old, to: new), to: old), new)
        }
    }

    func testACursorMovesWithTheWordsAroundIt() {
        let old = "Hello world"
        let edits = TextEdits.utf16(from: old, to: "Hello there world")
        XCTAssertEqual(TextEdits.map(3, through: edits), 3, "before what came in, it stays")
        XCTAssertEqual(TextEdits.map(5, through: edits), 5, "right where words came in, it stays before them")
        XCTAssertEqual(TextEdits.map(8, through: edits), 14, "after, it moves along")
        let replaced = TextEdits.utf16(from: "Ship on Friday now", to: "Ship on Monday now")
        XCTAssertEqual(TextEdits.map(10, through: replaced), 11, "inside what was replaced (Fri): the end of what replaced it (Mon)")
        XCTAssertEqual(TextEdits.map(18, through: replaced), 18)
    }

    // MARK: The editor's three-way merge

    func testBothSidesKeepTheirWords() {
        let base = "# Plan\n\nWe ship Friday.\n\n## Risks\n\nNone yet.\n"
        let mine = base.replacingOccurrences(of: "None yet.", with: "None yet. The venue may move.")
        let theirs = base.replacingOccurrences(of: "We ship Friday.", with: "We ship Friday, after the review.")
        let merged = TextMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged, "# Plan\n\nWe ship Friday, after the review.\n\n## Risks\n\nNone yet. The venue may move.\n")
        XCTAssertEqual(TextMerge.merge(base: base, mine: base, theirs: theirs), theirs)
        XCTAssertEqual(TextMerge.merge(base: base, mine: mine, theirs: base), mine)
        // Typing at the same place: theirs first, then what was typed here.
        let one = TextMerge.merge(base: "Hello", mine: "Hello Sam", theirs: "Hello Dana")
        XCTAssertEqual(one, "Hello Dana Sam")
        // Both changed the same words: theirs stay, what was typed here follows. Nothing typed is lost.
        XCTAssertEqual(TextMerge.merge(base: "Ship on Friday.", mine: "Ship on Monday.", theirs: "Ship on Tuesday."), "Ship on Tuesday Monday.")
        // Typed right after letters the other side changed: both, where each put them.
        XCTAssertEqual(TextMerge.merge(base: "Ship on Friday.", mine: "Ship on Fri-day.", theirs: "Ship on Monday."), "Ship on Mon-day.")
        // Typed inside letters the other side replaced: both, as whole words.
        XCTAssertEqual(TextMerge.merge(base: "Ship on Friday.", mine: "Ship on Frriday.", theirs: "Ship on Monday."), "Ship on Monday Frriday.")
        // Changes in different words of one line stay as they are.
        XCTAssertEqual(TextMerge.merge(base: "one two three", mine: "one 2 three", theirs: "one two 3"), "one 2 3")
    }

    // MARK: What travels with a note

    func testPropertiesAndTheAgentsMarkRoundTripThroughTheDocument() {
        let due = Date(timeIntervalSince1970: 1_790_000_000)
        let props = TeamNoteProps(properties: NoteProperties(status: "Draft", owner: "Dana", due: due, distill: true),
                                  mark: TeamNoteMark(madeBy: nil, editedBy: "Claude Code (Sam)", editedAt: due))
        let values = props.values
        XCTAssertEqual(Set(values.keys), Set(TeamNoteProps.keys), "every key, so taking one away is a change too")
        XCTAssertEqual(values["made_by"], .null)
        XCTAssertEqual(TeamNoteProps(values: values), props)
        XCTAssertNil(props.rowProperties["distill"])
        XCTAssertNil(props.rowProperties["made_by"])
        XCTAssertEqual(props.rowProperties["status"], "Draft")
        // A key a later Binders writes is let be; missing ones are none.
        XCTAssertEqual(TeamNoteProps(values: ["status": "Idea", "colour": "teal"]).properties, NoteProperties(status: "Idea"))
        XCTAssertEqual(TeamNoteProps(values: [:]), TeamNoteProps())
    }

    func testStatsCountLinesAndSections() {
        let old = "# Spec\n\n## Auth\n\nTokens.\n\n## Billing\n\nInvoices.\n"
        let new = old.replacingOccurrences(of: "Tokens.", with: "Tokens.\nRefresh them hourly.")
        let stats = TeamNoteStats.between(old, new)
        XCTAssertEqual(stats.added, 1)
        XCTAssertEqual(stats.removed, 0)
        XCTAssertEqual(stats.sections, ["Auth"])
    }

    // MARK: Versions and presence

    func testAVersionTakesTheSameAuthorsNextChangeForFiveMinutes() {
        let member = UUID(), agent = UUID(), now = Date()
        var version = TeamNoteVersionRow(row: ["id": TeamJSON(UUID()), "binder_id": TeamJSON(UUID()), "note_id": TeamJSON(UUID()),
                                               "member_id": TeamJSON(member), "ended_at": TeamJSON(now.addingTimeInterval(-60))])!
        XCTAssertTrue(version.takes(member: member, agent: nil, at: now))
        XCTAssertFalse(version.takes(member: member, agent: agent, at: now), "the same person's agent starts its own")
        XCTAssertFalse(version.takes(member: UUID(), agent: nil, at: now), "another person starts their own")
        XCTAssertFalse(version.takes(member: member, agent: nil, at: now.addingTimeInterval(300)), "five minutes later, a new one")
        version.name = "Approved"
        XCTAssertFalse(version.takes(member: member, agent: nil, at: now), "a named version stays as it was named")
        version.name = nil
        version.distillID = UUID()
        XCTAssertFalse(version.takes(member: member, agent: nil, at: now), "and the version a distill read")
    }

    func testPresenceLastsWhileItsMacSaysSo() {
        let now = Date()
        var row = TeamPresenceRow(row: ["id": TeamJSON(UUID()), "binder_id": TeamJSON(UUID()), "note_id": TeamJSON(UUID()),
                                        "member_id": TeamJSON(UUID()), "kind": "reviewing", "seen_at": TeamJSON(now.addingTimeInterval(-30))])!
        XCTAssertEqual(row.kind, .reviewing)
        XCTAssertTrue(row.isHere(at: now))
        XCTAssertFalse(row.isHere(at: now.addingTimeInterval(TeamPresenceRow.lasts)), "a Mac that went quiet goes")
        row.deletedAt = now
        XCTAssertFalse(row.isHere(at: now), "one that left goes at once")
        XCTAssertEqual(TeamPresenceRow.line(["Dana"]), "Dana is in this note")
        XCTAssertEqual(TeamPresenceRow.line(["Dana", "Robin"]), "Dana and Robin are in this note")
        XCTAssertEqual(TeamPresenceRow.reviewingLine(["Dana"]), "Dana is reviewing these items")
        XCTAssertNil(TeamPresenceRow.line([]))
        XCTAssertLessThan(TeamPresenceRow.heartbeat * 2, TeamPresenceRow.lasts, "two beats can be missed before someone goes")
    }

    // MARK: Distill's rows

    func testADistillGoesToTheTeamAndComesBackWithTheTeamsNames() {
        let note = UUID(), binder = UUID(), first = UUID(), second = UUID(), card = UUID()
        let record = DistillRecord(note: note, ranBy: "You", readBy: "Claude Code", readByAgent: true, at: Date(timeIntervalSince1970: 1_790_000_000),
                                   version: UUID().uuidString, status: .proposed,
                                   items: [DistillItem(id: first, title: "Write the auth flow", brief: "Tokens", doneWhen: "Tests pass", section: "Auth",
                                                       sectionHash: "ab12", size: .medium, meantFor: "Claude Code", meantForHow: "model", hint: .agent),
                                           DistillItem(id: second, title: "Pick a vendor", section: nil, waitsFor: [first], meantFor: "You",
                                                       hint: .person, card: card, dropped: true)],
                                   updates: [DistillUpdate(kind: .close, card: card)], requestCard: UUID(), placedByAgent: false)
        func team(_ name: String) -> String { name == "You" ? "Sam" : name == "Claude Code" ? "Claude Code (Sam)" : name }
        func local(_ name: String) -> String { name == "Sam" ? "You" : name == "Claude Code (Sam)" ? "Claude Code" : name }
        let rows = TeamDistillRows.rows(record, binder: binder, teamName: team)
        XCTAssertEqual(rows.distill["reader"], "Claude Code (Sam)")
        XCTAssertEqual(rows.distill["extra"]?["ran_by"], "Sam")
        XCTAssertEqual(rows.items.map { $0["meant_for"] }, ["Claude Code (Sam)", "Sam"])
        XCTAssertEqual(rows.items.map { $0["binder_id"]?.uuid }, [binder, binder], "every row says its binder, for row-level security")
        let back = TeamDistillRows.record(rows.distill, items: rows.items.reversed(), localName: local)
        XCTAssertEqual(back, record, "read back as it was, items in their order")
        // A dropped row (deleted in the database) isn't an item any more.
        var deleted = rows.items
        deleted[1]["deleted_at"] = TeamJSON(Date())
        XCTAssertEqual(TeamDistillRows.record(rows.distill, items: deleted, localName: local)?.items.map(\.id), [first])
        XCTAssertNil(TeamDistillRows.record(["id": "not a uuid"], items: [], localName: local))
    }

    // MARK: Calls and migration 6

    func testNoteCallsCarryTheirChangesAndOperationIDsFirst() throws {
        let note = UUID(), binder = UUID()
        let change = TeamNoteChange(hash: String(repeating: "a", count: 64), deps: [String(repeating: "b", count: 64)], bytes: Data([0x85, 0x6f]),
                                    stats: TeamNoteStats(added: 1, sections: ["Auth"]))
        let created = try XCTUnwrap(TeamCall.createNote(note, binder: binder, fields: ["title": "Plan"], changes: [change]).statement)
        XCTAssertTrue(created.sql.hasPrefix("SELECT binders.create_note(p_op => $1::uuid, p_note => $2::uuid"), created.sql)
        XCTAssertTrue(created.values[4]?.contains(#""change":"\\x856f""#) == true, created.values[4] ?? "")
        XCTAssertFalse(created.values[4]?.contains("version_first") == true, "no version expected, none said")
        var extending = change
        extending.versionFirst = String(repeating: "c", count: 64)
        extending.versionStats = TeamNoteStats(added: 3, removed: 1)
        let added = try XCTUnwrap(TeamCall.addNoteChanges(note, changes: [extending], restores: nil).statement)
        XCTAssertTrue(added.values[2]?.contains(#""version_added":3"#) == true, added.values[2] ?? "")
        XCTAssertEqual(TeamCall.addNoteChanges(note, changes: [change]).note, note)
        XCTAssertEqual(TeamCall.beInNote(note, here: false).argument("p_here"), "false")
        XCTAssertNil(TeamCall.putFolder(UUID(), binder: binder, fields: [:]).note)
        // Moving a folder team over: each item once per member, whoever runs it.
        let member = UUID()
        XCTAssertEqual(TeamMoveIDs.note(note, member: member), TeamMoveIDs.note(note, member: member))
        XCTAssertNotEqual(TeamMoveIDs.note(note, member: member), TeamMoveIDs.note(note, member: UUID()))
        XCTAssertNotEqual(TeamMoveIDs.note(note, member: member), TeamMoveIDs.meeting(note, member: member))
    }

    func testMigrationSixAddsWhatTheNotesNeed() {
        let sql = TeamSchema.migration6.sql
        XCTAssertEqual(TeamSchema.migrations.first { $0.version == 6 }?.sql, sql, "listed as number 6, before the meetings' 7")
        XCTAssertTrue(TeamTable.binderTables.contains(.notePresence))
        for function in ["create_note", "add_note_changes", "save_note", "move_note", "name_note_version", "mark_note_version", "be_in_note",
                         "put_folder", "delete_folder", "import_binder", "import_meeting"] {
            XCTAssertTrue(sql.contains("CREATE FUNCTION binders.\(function)(p_op uuid"), function)
        }
        XCTAssertTrue(sql.contains("_track('note_presence', 'binder_id')") && sql.contains("_guard('note_presence', 'binder_id')"))
        // Presence carries who, where and when: nothing about what they type.
        let presence = sql.components(separatedBy: "CREATE TABLE binders.note_presence (")[1].components(separatedBy: ");")[0]
        for word in ["cursor", "selection", "body", "content", "typed"] { XCTAssertFalse(presence.contains(word), word) }
        XCTAssertFalse(sql.contains("ALTER TABLE binders.cards"), "the board is DB2's")
        XCTAssertFalse(sql.contains("CREATE OR REPLACE FUNCTION"), "nothing earlier is replaced")
    }
}

/// A small seeded random number generator, so a test that tries many texts tries the same ones every time.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
