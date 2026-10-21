import XCTest
@testable import BindersKit

/// The hashes 0.8.0's index wrote for one item of every kind (the Mac's --selftest-index fixtures), rebuilt here from the
/// same words: if one of these changes, an update would index, embed and extract everything again.
final class KnowledgeContentHashTests: XCTestCase {
    private let binder = "0A0A0A0A-0000-4000-8000-000000000001"

    private func texts(_ chunks: [KnowledgeChunk]) -> [String] { chunks.map(\.text) }

    func testEmptyIsTheHashOfNothing() {
        XCTAssertEqual(KnowledgeContentHash.of([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testNotes() {
        let plain = "# Ignite booth\n\nThe booth needs two monitors and a banner. Sam books the van on Tuesday."
        XCTAssertEqual(KnowledgeContentHash.of(texts(KnowledgeChunker.chunks(plain)) + [binder]),
                       "ab80a6de29bdbfb0da4eb14cab6099de8a1c0af9a257d2d2b090f28c92246f0d")

        let text = "# Booth budget\n\n" + String(repeating: "The banner costs more than planned, so the van is shared with the venue team. ", count: 4)
            + "\n\n- [ ] Ask the dentist to move the appointment"
        let digest = "# Booth budget\n\n## Summary\nThe banner costs more; the van is shared.\n\n## To-dos\n- [ ] Ask the dentist to move the appointment"
        XCTAssertEqual(KnowledgeContentHash.of(texts(KnowledgeChunker.chunks(digest, label: "Digest") + KnowledgeChunker.chunks(text)) + [binder]),
                       "95c65c80647acfb2e93f171daeaa097e619bcd43d14719888538b03584737143")

        // A teammate's: only shared items hash their author.
        let shared = "# Venue notes\n\nThe venue holds two hundred people. Parking is round the back."
        XCTAssertEqual(KnowledgeContentHash.of(texts(KnowledgeChunker.chunks(shared)) + ["author: Alex", binder]),
                       "cf7129fe15a6f3091fcc1c2809214b3cc3bc7c87a7d66da0e96f55006fa4de37")
    }

    func testMeetingAndCapture() {
        let segments = [
            TranscriptSegment(channel: .microphone, start: 2, end: 7, text: "Can the venue take two hundred?"),
            TranscriptSegment(channel: .system, start: 8, end: 14, text: "Yes, and catering can be here by noon."),
            TranscriptSegment(channel: .microphone, start: 15, end: 19, text: "Good. I'll ask about parking."),
        ]
        let meeting = KnowledgeChunker.chunks("## Decisions\n- The venue holds 200.\n- Catering arrives by noon.", label: "Summary")
            + KnowledgeChunker.chunks("Ask about parking.", label: "My notes")
            + KnowledgeChunker.transcriptChunks(TranscriptFormatter.blocks(segments, names: ["Others": "Sam"]))
        XCTAssertEqual(KnowledgeContentHash.of(["Venue walkthrough"] + texts(meeting) + [binder]),
                       "7a9e7d010239be61872123b68c8ba3e7fdb71f90ed2aed2d319d724319ece4a2")

        let capture = KnowledgeChunker.chunks("## Summary\nA chat about the quayside venue.", label: "Summary")
            + KnowledgeChunker.transcriptChunks(TranscriptFormatter.blocks([
                TranscriptSegment(channel: .microphone, start: 1, end: 5, text: "Is the quayside venue still free on Friday?"),
            ]))
        XCTAssertEqual(KnowledgeContentHash.of(["Hallway chat"] + texts(capture) + [binder]),
                       "27910a751b1f5284e19abb90325d84d0e7f7e1deb3d27240b48574923204d014")
    }

    func testWritingDictationAndCommand() {
        let writing = KnowledgeChunker.chunks("Written in Mail to Sam, subject: Venue\n"
                                              + "Thanks for the update on the venue. I'll confirm the catering order by Friday.", label: "Mail")
        XCTAssertEqual(KnowledgeContentHash.of(["To Sam"] + texts(writing) + [binder]),
                       "68884cf0fd69c90f1f3062a206a9cbc9eaf45dfc50566247c32d9f5728f7fec4")
        XCTAssertEqual(KnowledgeContentHash.of(texts(KnowledgeChunker.chunks("Remind the team that the booth opens at nine on Thursday.", label: "Slack"))),
                       "a65336dc3689942a3240bf54f213e872feb974d73c1e3b681e9c23c4dd9dfb7d")
        XCTAssertEqual(KnowledgeContentHash.of(texts(KnowledgeChunker.chunks("Command: make this shorter\nResult: The booth opens at nine on Thursday.",
                                                                              label: "Notes"))),
                       "26cb3ed6f6b20e8a0dba7b344d5d0a1b88234fad27c838f5330c0809da34c30c")
    }
}

final class IndexDeltaTests: XCTestCase {
    func testReadsOnlyNewAndSavedItems() {
        let delta = IndexDelta(live: [1, 2, 3, 4, 5], known: [1, 2, 3, 4, 9], saved: [2, 7])
        XCTAssertEqual(delta.read, [2, 5], "new (5) and saved (2); unchanged ones aren't read")
        XCTAssertEqual(delta.gone, [9], "known but no longer there")
    }

    func testSavedThenDeletedIsGoneNotRead() {
        let delta = IndexDelta(live: [1], known: [1, 2], saved: [2])
        XCTAssertEqual(delta.read, [])
        XCTAssertEqual(delta.gone, [2])
    }

    func testFirstSightReadsEverything() {
        let delta = IndexDelta<Int>(live: [1, 2], known: [], saved: [])
        XCTAssertEqual(delta.read, [1, 2])
        XCTAssertEqual(delta.gone, [])
    }

    func testNothingChangedReadsNothing() {
        let delta = IndexDelta(live: [1, 2, 3], known: [1, 2, 3], saved: [])
        XCTAssertTrue(delta.read.isEmpty && delta.gone.isEmpty)
    }
}

final class DigestQueueTests: XCTestCase {
    func testDueOnceSettledLongestWaitingFirst() {
        let now = Date()
        var queue = DigestQueue<String>()
        queue.update("old", stale: true, words: 120, edited: now.addingTimeInterval(-3_600))
        queue.update("older", stale: true, words: 60, edited: now.addingTimeInterval(-7_200))
        queue.update("just edited", stale: true, words: 200, edited: now.addingTimeInterval(-30))
        queue.update("short", stale: true, words: NoteDigest.minimumWords - 1, edited: now.addingTimeInterval(-7_200))
        queue.update("digested", stale: false, words: 300, edited: now.addingTimeInterval(-7_200))
        XCTAssertEqual(queue.due(at: now), ["older", "old"])
        XCTAssertEqual(queue.count, 4, "short and just-edited notes wait without being due")
        XCTAssertEqual(queue.due(at: now.addingTimeInterval(NoteDigest.settleSeconds)), ["older", "old", "just edited"])
    }

    func testADigestOrADeletionStopsTheWait() {
        let edited = Date().addingTimeInterval(-600)
        var queue = DigestQueue<Int>()
        queue.update(1, stale: true, words: 80, edited: edited)
        queue.update(2, stale: true, words: 80, edited: edited)
        queue.update(1, stale: false, words: 80, edited: edited)
        queue.remove(2)
        XCTAssertEqual(queue.count, 0)
        XCTAssertTrue(queue.due().isEmpty)
    }
}
