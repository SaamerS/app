import SwiftUI

/// Its content, said to want at most `cap` points of width (nil: no cap), which is what `ViewThatFits` goes by when it
/// picks the first of its forms that fits; laid out, it's given what room there is, up to its whole length. So a long
/// label lets a row keep its other words, truncating only as far as it must.
struct IdealWidthCap: ViewModifier {
    let cap: CGFloat?

    func body(content: Content) -> some View {
        if let cap {
            CappedIdealWidth(cap: cap) { content }
        } else {
            content
        }
    }
}

private struct CappedIdealWidth: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        // Asked how wide it would like to be: no wider than the cap. Asked to fit a width: whatever it takes of it.
        return child.sizeThatFits(proposal.width == nil ? ProposedViewSize(width: cap, height: proposal.height) : proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Its views in a row, carried onto the next line when the row runs out of room: chips and the like, which then never
/// need more width than the widest of them.
struct Wrapping: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 8

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(within: proposal.width ?? .infinity, subviews: subviews)
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(within: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func lines(within width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !line.items.isEmpty, line.width + spacing + size.width > width {
                lines.append(line)
                line = Line()
            }
            line.width += (line.items.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.items.append((index, size))
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}
