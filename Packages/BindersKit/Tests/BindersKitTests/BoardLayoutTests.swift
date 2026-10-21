import XCTest
@testable import BindersKit

final class BoardLayoutTests: XCTestCase {
    /// The hub window opens 1,020 pt wide; its sidebar is 220 to 290 pt wide, 240 at first.
    private let defaultBoards: [Double] = [1020 - 290, 1020 - 240, 1020 - 220]

    private func fullyVisible(_ column: BoardColumn, in layout: BoardLayout, width: Double) -> Bool {
        let span = layout.span(of: column)
        return span.lowerBound >= 0 && span.upperBound <= width + 0.5
    }

    func testTheDefaultWindowShowsEveryColumnWithoutScrolling() {
        for width in defaultBoards {
            let layout = BoardLayout.fit(width: width)
            XCTAssertEqual(layout.folded, [.backlog, .done], "at \(width) pt")
            XCTAssertFalse(layout.scrolls(in: width), "at \(width) pt the board is \(layout.width) pt")
            XCTAssertGreaterThanOrEqual(layout.columnWidth, BoardLayout.narrowest)
            // About 150 pt a column, padding included.
            XCTAssertGreaterThanOrEqual(layout.columnWidth + 2 * BoardLayout.inset, 140, "at \(width) pt")
            for column in [BoardColumn.ready, .inProgress, .blocked, .review, .backlog, .done] {
                XCTAssertTrue(fullyVisible(column, in: layout, width: width), "\(column) at \(width) pt: \(layout.span(of: column))")
            }
        }
    }

    func testWideBoardsKeepAllSixOpen() {
        let roomy = BoardLayout.fit(width: 1368)
        XCTAssertEqual(roomy.folded, [])
        XCTAssertEqual(roomy.columnWidth, 190, accuracy: 0.01, "as wide as 0.8.0's columns at this width")
        XCTAssertEqual(roomy.margin, 24)
        XCTAssertEqual(roomy.spacing, 12)
        XCTAssertFalse(roomy.scrolls(in: 1368))
        XCTAssertEqual(BoardLayout.fit(width: 2080).columnWidth, BoardLayout.widest, "never wider than 250 pt")
        // Narrower than 0.8.0 allowed, rather than scrolling: six of 150 pt fit from 1,128 pt.
        let six = BoardLayout.fit(width: 1128)
        XCTAssertEqual(six.folded, [])
        XCTAssertFalse(six.scrolls(in: 1128))
    }

    func testDoneFoldsFirst() {
        // The default window with the sidebar hidden.
        let layout = BoardLayout.fit(width: 1020)
        XCTAssertEqual(layout.folded, [.done])
        XCTAssertGreaterThanOrEqual(layout.columnWidth, BoardLayout.comfortable)
        XCTAssertFalse(layout.scrolls(in: 1020))
        XCTAssertTrue(fullyVisible(.review, in: layout, width: 1020))
    }

    func testOnlyBacklogAndDoneEverFold() {
        for width in stride(from: 300.0, through: 2400, by: 7) {
            let layout = BoardLayout.fit(width: width)
            XCTAssertTrue(layout.folded.isSubset(of: [.backlog, .done]), "at \(width) pt")
            XCTAssertGreaterThanOrEqual(layout.columnWidth, BoardLayout.narrowest)
            XCTAssertLessThanOrEqual(layout.columnWidth, BoardLayout.widest)
            // What's open fills the board unless it's too narrow, when it scrolls.
            if !layout.scrolls(in: width), layout.columnWidth < BoardLayout.widest {
                XCTAssertEqual(layout.width, width, accuracy: 0.01, "at \(width) pt")
            }
            // Spans run left to right in the board's order.
            let spans = BoardColumn.allCases.map(layout.span(of:))
            XCTAssertEqual(spans, spans.sorted { $0.lowerBound < $1.lowerBound })
        }
    }

    func testAnOpenedColumnStaysOpen() {
        let width = 1020.0 - 240
        let layout = BoardLayout.fit(width: width, opened: [.backlog])
        XCTAssertEqual(layout.folded, [.done])
        XCTAssertEqual(layout.columnWidth, BoardLayout.narrowest, "it makes room down to the narrowest, then scrolls")
        XCTAssertTrue(layout.scrolls(in: width))
        let both = BoardLayout.fit(width: width, opened: [.backlog, .done])
        XCTAssertEqual(both.folded, [])
        XCTAssertTrue(both.scrolls(in: width))
        // With room to spare, nothing is folded whatever was opened.
        XCTAssertEqual(BoardLayout.fit(width: 1500, opened: [.done]).folded, [])
    }

    func testANarrowBoardScrollsAtTheNarrowestColumns() {
        let layout = BoardLayout.fit(width: 600)
        XCTAssertEqual(layout.folded, [.backlog, .done])
        XCTAssertEqual(layout.columnWidth, BoardLayout.narrowest)
        XCTAssertTrue(layout.scrolls(in: 600))
    }
}
