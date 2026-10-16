import XCTest
@testable import BindersKit

final class WikiLinksTests: XCTestCase {
    func testReadsLinksWithAndWithoutWhatToShow() {
        let links = WikiLinks.links(in: "See [[Launch readiness review]] and [[Maya Okafor|Maya]]. Not [this](https://example.com).")
        XCTAssertEqual(links.map(\.target), ["Launch readiness review", "Maya Okafor"])
        XCTAssertEqual(links.map(\.label), ["Launch readiness review", "Maya"])
        XCTAssertTrue(WikiLinks.text("Ask [[maya  okafor]] first", linksTo: "Maya Okafor"), "case and spaces don't matter")
        XCTAssertFalse(WikiLinks.text("Ask Maya Okafor first", linksTo: "Maya Okafor"))
    }

    func testFindsPlainMentionsAsWholePhrasesOutsideLinks() {
        XCTAssertNotNil(WikiLinks.plainMention(of: "Pricing page", in: "The pricing page needs a second pass."))
        XCTAssertNil(WikiLinks.plainMention(of: "Pricing page", in: "The pricing pages are done."), "whole words only")
        XCTAssertNil(WikiLinks.plainMention(of: "Pricing page", in: "See [[Pricing page]]."), "already a link")
        XCTAssertNil(WikiLinks.plainMention(of: "Al", in: "Al said so"), "too short to mean anything")
    }

    func testLinksTheFirstPlainMention() {
        XCTAssertEqual(WikiLinks.linkingFirstMention(of: "Pricing page", in: "Fix the Pricing page, then the pricing page copy."),
                       "Fix the [[Pricing page]], then the pricing page copy.")
        XCTAssertEqual(WikiLinks.linkingFirstMention(of: "Pricing page", in: "the pricing page"), "the [[Pricing page|pricing page]]")
        XCTAssertNil(WikiLinks.linkingFirstMention(of: "Pricing page", in: "nothing here"))
    }

    func testKnowsWhenTheCursorIsInAnUnfinishedLink() {
        let text = "Notes from [[Laun"
        XCTAssertEqual(WikiLinks.partialLink(before: (text as NSString).length, in: text), NSRange(location: 13, length: 4))
        XCTAssertEqual(WikiLinks.partialLink(before: 13, in: text), NSRange(location: 13, length: 0), "right after [[")
        XCTAssertNil(WikiLinks.partialLink(before: 10, in: text))
        let done = "[[Launch]] and more"
        XCTAssertNil(WikiLinks.partialLink(before: (done as NSString).length, in: done))
        let alias = "[[Launch|the la"
        XCTAssertNil(WikiLinks.partialLink(before: (alias as NSString).length, in: alias))
    }

    func testReadsHeadingsAndBlocksAfterTheName() {
        XCTAssertEqual(WikiTarget("Launch plan#Risks"), WikiTarget(page: "Launch plan", heading: "Risks", block: nil))
        XCTAssertEqual(WikiTarget("#Risks"), WikiTarget(page: "", heading: "Risks", block: nil), "a heading in the same note")
        XCTAssertEqual(WikiTarget("Launch plan#^c3f1"), WikiTarget(page: "Launch plan", heading: nil, block: "c3f1"))
        XCTAssertEqual(WikiTarget("#^c3f1").place, "^c3f1")
        XCTAssertEqual(WikiTarget("Plan#Risks#Open").heading, "Open", "nested headings: the last one")
        XCTAssertEqual(WikiTarget("Launch plan.md#Risks").page, "Launch plan", "Obsidian's .md is left off")
        XCTAssertEqual(WikiTarget("Issue #42 follow-up"), WikiTarget(page: "Issue #42 follow-up", heading: nil, block: nil),
                       "a # after a space is part of the name")
        XCTAssertEqual(WikiTarget("Issue #42 follow-up#Notes").heading, "Notes")
        XCTAssertNil(WikiTarget("Launch plan").place)
    }

    func testKnowsFilesFromNotes() {
        XCTAssertTrue(WikiTarget("minutes v2.pdf").isFile)
        XCTAssertTrue(WikiTarget("call.m4a").isFile)
        XCTAssertTrue(WikiTarget("board.png").isFile)
        XCTAssertFalse(WikiTarget("Binders 0.7.0").isFile, "a version number isn't an extension")
        XCTAssertFalse(WikiTarget("Launch plan").isFile)
    }

    func testFindsTheHeadingOrBlockALinkPointsAt() {
        let text = "# Launch plan\n\nIntro.\n\n## Risks: what could slip\n\nVendor is late. ^vendor\n\n```\n# Not a heading\n```\n"
        let risks = (text as NSString).range(of: "## Risks").location
        XCTAssertEqual(WikiTarget.location(of: "Risks what could slip", in: text), risks, "Obsidian drops the colon")
        XCTAssertEqual(WikiTarget.location(of: "risks: WHAT could slip", in: text), risks)
        XCTAssertEqual(WikiTarget.location(of: "^vendor", in: text), (text as NSString).range(of: "Vendor is late").location)
        XCTAssertNil(WikiTarget.location(of: "Not a heading", in: text), "code isn't headings")
        XCTAssertNil(WikiTarget.location(of: "Budget", in: text))
        XCTAssertNil(WikiTarget.location(of: "^nope", in: text))
    }

    func testHeadingLinksCountAsLinksToTheirNote() {
        let text = "See [[Launch plan#Risks]], [[#Intro]], [[report.pdf]] and ![[minutes.pdf]]."
        XCTAssertEqual(WikiLinks.targets(in: text), ["Launch plan"], "not \"Launch plan#Risks\", the same note, or files")
        XCTAssertTrue(WikiLinks.text(text, linksTo: "launch PLAN"))
        XCTAssertTrue(WikiLinks.text("[[Issue #42 follow-up]]", linksTo: "Issue #42 follow-up"))
    }

    func testRenamingPointsLinksAtTheNewTitle() {
        let text = "See [[Launch plan]], [[launch  PLAN|the plan]], [[Launch plan#Risks]], [[ Launch plan.md#^vendor|why]] and ![[Launch plan]].\n"
            + "Not [[Launch planning]], [[Plan]], [[#Launch plan]] or `[[Launch plan]]`.\n```\n[[Launch plan]]\n```\n"
        let renamed = WikiLinks.renaming(from: "Launch plan", to: "Rollout plan", in: text)
        XCTAssertEqual(renamed?.links, 5)
        XCTAssertEqual(renamed?.text, "See [[Rollout plan]], [[Rollout plan|the plan]], [[Rollout plan#Risks]], [[ Rollout plan.md#^vendor|why]] and ![[Rollout plan]].\n"
            + "Not [[Launch planning]], [[Plan]], [[#Launch plan]] or `[[Launch plan]]`.\n```\n[[Launch plan]]\n```\n",
            "what links show, headings and code stay as they were")
        XCTAssertNil(WikiLinks.renaming(from: "Launch plan", to: "Rollout plan", in: "No links here, just Launch plan"))
        XCTAssertNil(WikiLinks.renaming(from: "Launch plan", to: "Plan [draft]", in: "[[Launch plan]]"), "brackets can't go in a link")
        XCTAssertNil(WikiLinks.renaming(from: "Launch plan", to: "  ", in: "[[Launch plan]]"))
        XCTAssertEqual(WikiLinks.renaming(from: "Issue #42", to: "Issue #43", in: "[[Issue #42]] and [[Issue #42#Notes]]")?.text,
                       "[[Issue #43]] and [[Issue #43#Notes]]")
        XCTAssertEqual(WikiLinks.renameEdits(from: "Plan", to: "Roadmap", in: "a [[Plan]] b").map(\.range), [NSRange(location: 4, length: 4)])
        XCTAssertTrue(WikiLinks.canLink("Issue #42"))
        XCTAssertFalse(WikiLinks.canLink("#"), "an emptied heading")
        XCTAssertFalse(WikiLinks.canLink("Plan#Risks"))
    }

    func testANotesTitleIsItsFirstLine() {
        XCTAssertEqual(MarkdownSyntax.noteTitle("## **Launch** plan\n\nBody"), "Launch plan")
        XCTAssertEqual(MarkdownSyntax.noteTitle(""), "")
        XCTAssertEqual(MarkdownSyntax.noteTitle(String(repeating: "a", count: 100)).count, 80)
    }

    func testTheEditorSeesLinks() {
        let spans = MarkdownSyntax.spans(in: "See [[Maya Okafor|Maya]] today")
        XCTAssertTrue(spans.contains(MarkdownSpan(NSRange(location: 18, length: 4), .wikiLink(target: "Maya Okafor"))))
        XCTAssertEqual(spans.filter { $0.style == .syntax }.count, 3, "[[, the title and |, and ]]")
    }
}
