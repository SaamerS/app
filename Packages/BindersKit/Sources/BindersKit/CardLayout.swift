import Foundation

/// The card window's sizes, and where and how big a card opens: a window of its own over the Binders window, where the
/// conversation with whoever works on the card gets the room and the description sits in a panel beside it.
public enum CardLayout {
    public static let defaultWidth = 1100.0, defaultHeight = 760.0
    public static let smallestWidth = 880.0, smallestHeight = 600.0
    /// The Details panel: wide enough for the description's compact toolbar, as the card always had.
    public static let detailsWidth = 376.0
    /// Narrower than this, Details start hidden and lie over the conversation when shown, rather than take close to half
    /// of the card.
    public static let detailsDockedFrom = 1000.0
    /// The conversation keeps at least this much height, whatever waits below it.
    public static let conversationMinHeight = 160.0
    /// A message is at most this wide, or 82% of the conversation, whichever is less, so lines stay readable.
    public static let messageWidth = 560.0
    /// The conversation, what waits on you and the composer are at most this wide, centred in a wider window, so a line's
    /// time stays near its words. At the default size with Details beside them they're narrower than this anyway.
    public static let readingWidth = 760.0
    /// The composer grows with what you write to 6 lines, and to 3 while something waits on you above it.
    public static let composerLines = 1...6, composerLinesWithTray = 1...3

    /// A rectangle in screen points, bottom-left origin as AppKit has it.
    public struct Frame: Equatable, Sendable {
        public var x, y, width, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var midX: Double { x + width / 2 }
        public var midY: Double { y + height / 2 }
    }

    /// How big a card opens: the size you last left a card window at, or the default; no larger than the Binders window it
    /// opens over (unless that window is smaller than the smallest card, which then opens at the smallest), and no smaller
    /// than the smallest; never larger than the screen's visible area, whatever the rest says.
    public static func openingSize(saved: (width: Double, height: Double)?, over window: Frame?, screen: Frame) -> (width: Double, height: Double) {
        var width = saved?.width ?? defaultWidth, height = saved?.height ?? defaultHeight
        if let window {
            width = min(width, max(window.width, smallestWidth))
            height = min(height, max(window.height, smallestHeight))
        }
        width = max(width, smallestWidth)
        height = max(height, smallestHeight)
        return (min(width, screen.width), min(height, screen.height))
    }

    /// Where a card of `size` opens: centred on the Binders window (`window`, only when it's visible, not minimised and on
    /// the Space you're in: the caller checks), else on the screen, and kept on the screen.
    public static func openingOrigin(size: (width: Double, height: Double), over window: Frame?, screen: Frame) -> (x: Double, y: Double) {
        let centre = window ?? screen
        let x = min(max(centre.midX - size.width / 2, screen.x), screen.x + screen.width - size.width)
        let y = min(max(centre.midY - size.height / 2, screen.y), screen.y + screen.height - size.height)
        return (x.rounded(), y.rounded())
    }

    /// Whether Details sit beside the conversation: when you keep them open and the card is `detailsDockedFrom` wide or more.
    public static func detailsDocked(width: Double, open: Bool) -> Bool {
        open && width >= detailsDockedFrom
    }

    /// How wide a message may be in a conversation `width` wide.
    public static func messageWidth(conversation width: Double) -> Double {
        min(messageWidth, width * 0.82)
    }

    /// A saved size as it's kept ("1100x760"), and read back; nil for anything else.
    public static func sizeString(width: Double, height: Double) -> String { "\(Int(width.rounded()))x\(Int(height.rounded()))" }

    public static func size(from string: String?) -> (width: Double, height: Double)? {
        guard let parts = string?.split(separator: "x"), parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
