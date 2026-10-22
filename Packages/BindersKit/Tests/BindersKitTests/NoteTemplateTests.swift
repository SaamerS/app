import XCTest
@testable import BindersKit

final class NoteTemplateTests: XCTestCase {
    func testFillsInTheDayAndTheBinder() {
        let template = NoteTemplate(name: "Test", body: "# Kickoff\n{{date}} at {{time}} in {{binder}}; see [[{{today}}]]")
        var components = DateComponents(year: 2026, month: 9, day: 28, hour: 14, minute: 30)
        components.timeZone = .current
        let date = Calendar.current.date(from: components)!
        let filled = template.filled(date: date, binder: "Harbor launch", locale: Locale(identifier: "en_US"))
        XCTAssertTrue(filled.contains("Monday, September 28, 2026"), filled)
        XCTAssertTrue(filled.contains("2:30"), filled)
        XCTAssertTrue(filled.contains("in Harbor launch"))
        XCTAssertTrue(filled.contains("[[2026-09-28]]"))
        XCTAssertFalse(filled.contains("{{"))
    }

    func testTodayIsTheLocalDateLateInTheEvening() {
        // West of UTC, 11:30 PM is already tomorrow in UTC.
        var components = DateComponents(year: 2026, month: 9, day: 28, hour: 23, minute: 30)
        components.timeZone = .current
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(NoteTemplate(name: "Test", body: "[[{{today}}]]").filled(date: date, binder: "General"), "[[2026-09-28]]")
    }

    func testBuiltInsHaveUniqueNamesAndStartWithATitle() {
        let names = NoteTemplate.builtIn.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(NoteTemplate.builtIn.allSatisfy { $0.body.hasPrefix("# ") })
        XCTAssertTrue(NoteTemplate.builtIn.contains { $0.name == "Reading notes" })
    }

    func testTheDigestFollowsATemplatesSections() {
        let note = NoteTemplate.builtIn.first { $0.name == "1:1" }!.body
        XCTAssertEqual(NoteTemplate.sections(of: note), ["How things are going", "Updates", "Blockers", "Action items"])
        XCTAssertTrue(NotePrompts.digestUserPrompt(date: nil, text: note).contains("**How things are going**"))
        XCTAssertFalse(NotePrompts.digestUserPrompt(date: nil, text: "Just a thought about pricing.").contains("sections"))
    }

    /// A template's file can name a folder for its notes; that front matter isn't part of the note.
    func testATemplateCanNameAFolder() {
        let social = NoteTemplate.parse(name: "Social post", file: "---\nfolder: \"Social posts\"\n---\n# Social post\n\nWhat it says")
        XCTAssertEqual(social.folder, "Social posts")
        XCTAssertEqual(social.body, "# Social post\n\nWhat it says")
        XCTAssertEqual(NoteTemplate.parse(name: "Nested", file: "---\nbinders_folder: Marketing / Social posts\n---\nBody").folder,
                       "Marketing/Social posts", "the team copy's key, and a path")
        let plain = NoteTemplate.parse(name: "Plain", file: "# Weekly review\n")
        XCTAssertNil(plain.folder)
        XCTAssertEqual(plain.body, "# Weekly review\n")
        let tagged = NoteTemplate.parse(name: "Tagged", file: "---\ntags: [ops]\nfolder: Ops\n---\n# Incident")
        XCTAssertEqual(tagged.folder, "Ops")
        XCTAssertEqual(tagged.body, "---\ntags: [ops]\n---\n# Incident", "other front matter stays in the note")
        XCTAssertNil(NoteTemplate(name: "Top", body: "x", folder: " / ").folder, "the top is no folder")
        XCTAssertEqual(NoteTemplate.parse(name: "Social post", file: social.fileText), social, "its file reads back the same")
        XCTAssertEqual(plain.fileText, plain.body)
        XCTAssertTrue(NoteTemplate.builtIn.allSatisfy { $0.folder == nil })
    }
}

