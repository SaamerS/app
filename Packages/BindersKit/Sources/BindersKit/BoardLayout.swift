import Foundation

/// How a board's six columns share the width they're given. All six sit side by side while each still gets a readable
/// width. When space is short, Done and then Backlog fold to narrow strips with their counts, so Ready, In progress,
/// Blocked and Review, the work that moves and the work that waits on you, stay in view without scrolling sideways. A
/// strip opens with a click, and a column you opened stays open: then the board scrolls if it has to. The order of the
/// columns never changes.
public struct BoardLayout: Equatable, Sendable {
    /// The width of each open column's content, inside its padding.
    public var columnWidth: Double
    /// The columns drawn as strips.
    public var folded: Set<BoardColumn>
    /// The space either side of the columns, and between two of them.
    public var margin: Double
    public var spacing: Double

    /// A folded column, from edge to edge.
    public static let stripWidth = 36.0
    /// An open column's padding, on each side.
    public static let inset = 10.0
    /// The widest an open column gets, the narrowest it reads comfortably at (below it a column folds), and the narrowest
    /// it gets before the board scrolls.
    public static let widest = 250.0, comfortable = 150.0, narrowest = 120.0
    /// The columns that may fold, in the order they fold: finished work, then work for later.
    public static let foldable: [BoardColumn] = [.done, .backlog]

    public init(columnWidth: Double, folded: Set<BoardColumn>, margin: Double, spacing: Double) {
        self.columnWidth = columnWidth
        self.folded = folded
        self.margin = margin
        self.spacing = spacing
    }

    /// The width the columns take, margins included.
    public var width: Double {
        let count = BoardColumn.allCases.count
        return fixedWidth + Double(count - folded.count) * (columnWidth + 2 * Self.inset)
    }

    /// Whether the columns are wider than `available`, so the board scrolls sideways.
    public func scrolls(in available: Double) -> Bool { width > available + 0.5 }

    /// Where a column sits, from the board's left edge, before any scrolling.
    public func span(of column: BoardColumn) -> Range<Double> {
        var x = margin
        for each in BoardColumn.allCases {
            let width = folded.contains(each) ? Self.stripWidth : columnWidth + 2 * Self.inset
            if each == column { return x..<(x + width) }
            x += width + spacing
        }
        return x..<x
    }

    /// The layout for a board `available` wide. `opened` holds the folded columns you opened, which stay open.
    public static func fit(width available: Double, opened: Set<BoardColumn> = []) -> BoardLayout {
        // All six with room to spare, then one strip, then two, with a little less space around the columns once any fold.
        var candidates = [BoardLayout(columnWidth: 0, folded: [], margin: 24, spacing: 12)]
        var folded: Set<BoardColumn> = []
        for column in foldable where !opened.contains(column) {
            folded.insert(column)
            candidates.append(BoardLayout(columnWidth: 0, folded: folded, margin: 16, spacing: 10))
        }
        for var candidate in candidates {
            let room = candidate.room(in: available)
            if room >= comfortable {
                candidate.columnWidth = min(widest, room)
                return candidate
            }
        }
        // Short of room even so: every column that may fold is folded, and the rest narrow down to `narrowest`.
        var tight = candidates[candidates.count - 1]
        tight.margin = 16
        tight.spacing = 10
        tight.columnWidth = max(narrowest, tight.room(in: available))
        return tight
    }

    /// Margins, gaps and strips: everything that isn't an open column.
    private var fixedWidth: Double {
        let count = BoardColumn.allCases.count
        return 2 * margin + Double(count - 1) * spacing + Double(folded.count) * Self.stripWidth
    }

    /// How wide each open column's content can be, with the columns filling `available`.
    private func room(in available: Double) -> Double {
        let open = Double(BoardColumn.allCases.count - folded.count)
        return (available - fixedWidth) / open - 2 * Self.inset
    }
}
