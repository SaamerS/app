import XCTest
@testable import BindersKit

/// The card window: how big and where a card opens, and when Details sit beside the conversation.
final class CardLayoutTests: XCTestCase {
    /// A 13.6-inch MacBook Air's screen, the menu bar and the Dock taken off.
    private let laptop = CardLayout.Frame(x: 0, y: 70, width: 1470, height: 860)
    private let large = CardLayout.Frame(x: 0, y: 0, width: 2560, height: 1400)

    private func size(_ saved: (Double, Double)? = nil, over window: CardLayout.Frame? = nil, screen: CardLayout.Frame? = nil) -> [Double] {
        let opened = CardLayout.openingSize(saved: saved.map { (width: $0.0, height: $0.1) }, over: window, screen: screen ?? large)
        return [opened.width, opened.height]
    }

    func testTheFirstCardOpensAtTheDefault() {
        XCTAssertEqual(size(), [1100, 760])
        XCTAssertEqual(size(screen: laptop), [1100, 760], "it fits a 13-inch MacBook Air")
    }

    func testASizeYouLeftItAtIsKept() {
        XCTAssertEqual(size((1300, 900)), [1300, 900])
        XCTAssertEqual(size((900, 640)), [900, 640])
    }

    func testNeverLargerThanTheBindersWindowItOpensOver() {
        // The Binders window at its default size: the card opens exactly over it.
        XCTAssertEqual(size(over: CardLayout.Frame(x: 100, y: 100, width: 1020, height: 720)), [1020, 720])
        XCTAssertEqual(size((1300, 900), over: CardLayout.Frame(x: 0, y: 0, width: 1200, height: 800)), [1200, 800])
        // A larger Binders window doesn't make the card larger than you left it.
        XCTAssertEqual(size(over: CardLayout.Frame(x: 0, y: 0, width: 2000, height: 1300)), [1100, 760])
    }

    func testABindersWindowUnderTheSmallestGivesTheSmallest() {
        XCTAssertEqual(size(over: CardLayout.Frame(x: 0, y: 0, width: 840, height: 560)), [880, 600])
        XCTAssertEqual(size((500, 400)), [880, 600], "never smaller than the smallest")
    }

    func testNeverLargerThanTheScreen() {
        XCTAssertEqual(size((1600, 1000), screen: laptop), [1470, 860])
        let tiny = CardLayout.Frame(x: 0, y: 0, width: 800, height: 560)
        XCTAssertEqual(size(screen: tiny), [800, 560], "the screen wins, whatever the rest says")
    }

    func testItOpensCentredOnTheBindersWindowAndOnTheScreen() {
        let window = CardLayout.Frame(x: 200, y: 100, width: 1020, height: 720)
        let origin = CardLayout.openingOrigin(size: (width: 1020, height: 720), over: window, screen: laptop)
        XCTAssertEqual([origin.x, origin.y], [200, 100], "exactly over it")
        let centred = CardLayout.openingOrigin(size: (width: 1100, height: 760), over: nil, screen: laptop)
        XCTAssertEqual([centred.x, centred.y], [185, 120])
        // A Binders window near the screen's edge: the card stays on the screen.
        let edge = CardLayout.Frame(x: 1200, y: 600, width: 900, height: 600)
        let kept = CardLayout.openingOrigin(size: (width: 1100, height: 760), over: edge, screen: laptop)
        XCTAssertEqual([kept.x, kept.y], [370, 170])
    }

    func testDetailsSitBesideTheConversationFrom1000Wide() {
        XCTAssertTrue(CardLayout.detailsDocked(width: 1100, open: true))
        XCTAssertTrue(CardLayout.detailsDocked(width: 1000, open: true))
        XCTAssertFalse(CardLayout.detailsDocked(width: 999, open: true), "narrower, they start hidden and lie over the conversation")
        XCTAssertFalse(CardLayout.detailsDocked(width: 880, open: true))
        XCTAssertFalse(CardLayout.detailsDocked(width: 1400, open: false), "hidden when you hid them")
    }

    func testAMessageStaysReadable() {
        XCTAssertEqual(CardLayout.messageWidth(conversation: 623), 623 * 0.82, accuracy: 0.001, "1000 wide, Details docked")
        XCTAssertEqual(CardLayout.messageWidth(conversation: 723), 560, "1100 wide, Details docked")
        XCTAssertEqual(CardLayout.messageWidth(conversation: 878), 560, "880 wide, Details hidden")
    }

    func testTheReadingWidthLeavesTheDefaultCardAsItWas() {
        let docked = CardLayout.defaultWidth - CardLayout.detailsWidth - 1
        XCTAssertLessThan(docked, CardLayout.readingWidth, "at 1100 wide with Details beside it, the column is narrower than the reading width")
        XCTAssertLessThan(CardLayout.readingWidth, CardLayout.defaultWidth, "with Details hidden it keeps to it, centred")
        XCTAssertEqual(CardLayout.messageWidth(conversation: CardLayout.readingWidth - 40), 560, "and a message is as wide as ever")
    }

    func testTheSavedSizeReadsBack() {
        XCTAssertEqual(CardLayout.sizeString(width: 1100, height: 760), "1100x760")
        XCTAssertEqual(CardLayout.size(from: "1240x812").map { [$0.width, $0.height] }, [1240, 812])
        XCTAssertNil(CardLayout.size(from: "wide"))
        XCTAssertNil(CardLayout.size(from: nil))
        XCTAssertNil(CardLayout.size(from: "0x760"))
    }
}
