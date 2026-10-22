import XCTest
@testable import BindersKit

final class DistillReadingTests: XCTestCase {
    private func spec(_ name: String) -> DistillBench.Spec { DistillBench.specs.first { $0.name == name }! }
    private func headings(_ spec: DistillBench.Spec) -> [String] { DistillSections.sections(of: spec.text).compactMap(\.heading) }

    func testACleanReplyReadsWhole() {
        let spec = spec("Checkout redesign")
        let result = DistillReading.read(DistillFixtures.checkoutClean, headings: headings(spec))
        XCTAssertEqual(result.items.count, 8)
        XCTAssertFalse(result.cutOff)
        XCTAssertNil(result.note, "nothing was left out")
        XCTAssertEqual(result.items[0].title, "Combine checkout into one page")
        XCTAssertEqual(result.items[0].section, "Payment form")
        XCTAssertEqual(result.items[0].size, .medium)
        XCTAssertEqual(result.items[6].waitsFor, [0, 3, 5], "the rollout waits for the form, retry and summary, by their numbers from 1")
        XCTAssertEqual(result.items[7].hint, .person)
        XCTAssertEqual(result.items[7].waitsFor, [6])
        let score = DistillBench.score(result, spec: spec)
        XCTAssertEqual(score.found, 8)
        XCTAssertEqual(score.rightSection, 8)
        XCTAssertEqual(score.madeUp, 0)
        XCTAssertEqual(score.waitsFound, score.waitsPossible)
    }

    func testAFencedReplyWithLooseKeysAndTrailingCommas() {
        let spec = spec("New starter onboarding")
        let result = DistillReading.read(DistillFixtures.onboardingFenced, headings: headings(spec))
        XCTAssertEqual(result.items.count, 7, "\(result)")
        XCTAssertEqual(result.items[1].section, "Before day one", "a heading in other case still matches")
        XCTAssertEqual(result.items[2].section, "First week")
        XCTAssertEqual(result.items[4].section, "Handbook", "a numbered heading matches the note's")
        XCTAssertEqual(result.items[1].waitsFor, [0], "a wait written as a string number")
        XCTAssertEqual(result.items[6].waitsFor, [5], "a wait written as a title")
        XCTAssertEqual(result.items[0].hint, .person, "human reads as a person")
        XCTAssertEqual(result.items[3].hint, .either)
        XCTAssertEqual(result.items[0].doneWhen, "Laptop and accounts are ready a week ahead.", "doneWhen as camel case")
        XCTAssertEqual(result.items[1].doneWhen, "The new starter has the plan before day one.", "done alone")
        XCTAssertEqual(result.items[0].brief, "Order them a week before the start date.", "description reads as the brief")
        XCTAssertEqual(result.items[0].size, .small, "S is small")
        XCTAssertEqual(result.items[4].size, .medium)
        let score = DistillBench.score(result, spec: spec)
        XCTAssertEqual(score.found, 7)
        XCTAssertEqual(score.madeUp, 0)
        XCTAssertEqual(score.personSaid, score.personFound)
    }

    func testACutOffReplyKeepsTheWholeItemsBeforeTheCut() {
        let spec = spec("Summit booth")
        let result = DistillReading.read(DistillFixtures.boothCutOff, headings: headings(spec))
        XCTAssertTrue(result.cutOff)
        XCTAssertEqual(result.items.count, 5, "the item cut in the middle is left out, the five before it kept")
        XCTAssertEqual(result.items.last?.title, "Draw up the stand rota")
        XCTAssertEqual(result.note, "The model's reply was cut off, so the last item may be missing.")
        let score = DistillBench.score(result, spec: spec)
        XCTAssertEqual(score.found, 5)
        XCTAssertEqual(score.madeUp, 0)
    }

    func testRepeatsCirclesAndWaitsOnNothingAreLeftOut() {
        let spec = spec("Offline mode")
        let result = DistillReading.read(DistillFixtures.offlineMessy, headings: headings(spec))
        XCTAssertEqual(result.items.map(\.title), ["Store the last 7 days of jobs, encrypted", "Queue offline changes and send them in order",
                                                   "Ask which version to keep when a job changed on both sides", "Show an offline banner",
                                                   "Mark jobs that haven't synced", "Test an hour offline and a flaky connection",
                                                   "Write down what happens to photos", "Offline maps"],
                       "the repeat of the banner goes, after the thinking and out of the object it's in")
        XCTAssertEqual(result.repeats, 1)
        // Storage waits for sync and sync for storage: the first wait is kept, the one that closes the circle goes.
        XCTAssertEqual(result.items[0].waitsFor, [1])
        XCTAssertEqual(result.items[1].waitsFor, [], "sync waiting for storage would close the circle")
        XCTAssertEqual(result.items[2].waitsFor, [1], "a wait on itself goes; the other stays")
        XCTAssertEqual(result.items[3].waitsFor, [], "a wait past the end goes")
        XCTAssertEqual(result.items[3].section, "Interface")
        XCTAssertEqual(result.items[4].waitsFor, [1])
        XCTAssertEqual(result.items[6].waitsFor, [5], "numbered as the reply had them: 7 is the test, the repeat still counting")
        XCTAssertNil(result.items[7].section, "a section the note doesn't have")
        XCTAssertEqual(result.items[7].unknownSection, "Offline maps")
        XCTAssertEqual(result.droppedWaits, 3)
        XCTAssertTrue(CardWaits.order(result.items.map(\.waitsFor)) != nil, "what's kept never waits in a circle")
        let score = DistillBench.score(result, spec: spec)
        XCTAssertEqual(score.found, 7)
        XCTAssertEqual(score.madeUp, 1, "offline maps was out of scope")
    }

    func testANoteWithNoWorkAndRepliesWithNoList() {
        let spec = spec("Release names")
        let empty = DistillReading.read(DistillFixtures.releaseNamesEmpty, headings: headings(spec))
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertFalse(empty.noList)
        XCTAssertEqual(DistillBench.score(empty, spec: spec).recall, 1)
        let none = DistillReading.read(DistillFixtures.noList, headings: [])
        XCTAssertTrue(none.noList)
        XCTAssertEqual(none.note, "The model's reply had no list of work items in it.")
    }

    func testItemsThatDontReadAreLeftOutWithWhy() {
        let result = DistillReading.read(DistillFixtures.brokenItems, headings: ["Design"])
        XCTAssertEqual(result.items.map(\.title), ["Fix the header"])
        XCTAssertEqual(result.skipped.count, 4, "\(result.skipped)")
        XCTAssertTrue(result.skipped.contains("it has no title"))
        XCTAssertEqual(result.note, "4 items couldn't be read.")
    }

    func testTheWaitNumbersCountSkippedItems() {
        // The second item doesn't read, so the third is still number 3 for the fourth's wait.
        let reply = #"[{"title": "A"}, {"nope": 1}, {"title": "C"}, {"title": "D", "waits_for": [3, 2]}]"#
        let result = DistillReading.read(reply, headings: [])
        XCTAssertEqual(result.items.map(\.title), ["A", "C", "D"])
        XCTAssertEqual(result.items[2].waitsFor, [1], "3 is C; 2 didn't read, so that wait goes")
    }

    func testTitlesAreTidiedAndNamesInForAreKept() {
        let reply = #"[{"title": "1. Add the retry button", "for": "Claude Code"}, {"title": "- Write the copy", "for": "you"}]"#
        let result = DistillReading.read(reply, headings: [])
        XCTAssertEqual(result.items.map(\.title), ["Add the retry button", "Write the copy"])
        XCTAssertEqual(result.items[0].forName, "Claude Code")
        XCTAssertEqual(result.items[0].hint, .either)
        XCTAssertEqual(result.items[1].hint, .person)
        XCTAssertNil(result.items[1].forName)
    }

    func testTheReadingBecomesItemsWithTheirSectionsVersions() {
        let spec = spec("Checkout redesign")
        let sections = DistillSections.sections(of: spec.text)
        let items = DistillReading.read(DistillFixtures.checkoutClean, headings: headings(spec)).items(sections: sections)
        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(items[0].sectionHash, sections.first { $0.heading == "Payment form" }?.hash)
        XCTAssertEqual(items[6].waitsFor, [items[0].id, items[3].id, items[5].id])
    }

    func testThePromptNamesTheSectionsAndAsksForJSON() {
        let spec = spec("Checkout redesign")
        let user = DistillPrompt.user(title: "Checkout redesign", sections: headings(spec), text: spec.text)
        XCTAssertTrue(user.contains("\"Payment form\", \"Retry after a failed payment\""))
        XCTAssertTrue(user.hasSuffix(spec.text))
        XCTAssertTrue(DistillPrompt.system.contains("Reply with a JSON list and nothing else"))
        XCTAssertTrue(DistillPrompt.system.contains("waits_for"))
        let long = String(repeating: "word ", count: 10_000)
        XCTAssertTrue(DistillPrompt.user(title: "Long", sections: [], text: long).hasSuffix("…"), "a long note is cut")
    }

    func testAModelRepeatingItselfIsStopped() {
        let line = #"  {"title": "Show an offline banner", "section": "Interface"},"# + "\n"
        XCTAssertTrue(DistillReading.isLooping("[\n" + String(repeating: line, count: 3)))
        XCTAssertFalse(DistillReading.isLooping("[\n" + line + line))
        // Pretty-printed items repeat their lines; a good list isn't stopped for it, as LoopGuard on its lines would be.
        let pretty = DistillFixtures.checkoutClean.replacingOccurrences(of: ", \"", with: ",\n    \"")
        XCTAssertTrue(LoopGuard.isLooping(pretty + "\n"), "the lines repeat")
        XCTAssertFalse(DistillReading.isLooping(pretty), "the titles don't")
        XCTAssertTrue(DistillReading.isLooping((0..<60).map { #"{"title": "Item \#($0)"},"# }.joined()), "far more than asked for")
    }

    /// Every canned reply, scored: the reader's measure (LANE-NOTES has the numbers).
    func testTheReaderOnEveryFixture() {
        let replies = ["Checkout redesign": DistillFixtures.checkoutClean, "New starter onboarding": DistillFixtures.onboardingFenced,
                       "Summit booth": DistillFixtures.boothCutOff, "Offline mode": DistillFixtures.offlineMessy,
                       "Release names": DistillFixtures.releaseNamesEmpty]
        let scores = DistillBench.specs.map { spec in
            DistillBench.score(DistillReading.read(replies[spec.name]!, headings: headings(spec)), spec: spec)
        }
        let found = scores.map(\.found).reduce(0, +), gold = scores.map(\.gold).reduce(0, +)
        XCTAssertEqual(gold, 30)
        XCTAssertEqual(found, 27, DistillBench.summary(scores).joined(separator: "\n"))
        XCTAssertEqual(scores.map(\.rightSection).reduce(0, +), found)
        XCTAssertEqual(scores.map(\.madeUp).reduce(0, +), 1)
    }
}
