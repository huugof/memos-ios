import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? 0, subviews: subviews)
        let height = rows.reduce(0.0) { h, row in
            h + (row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
        } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = []
        var currentRow: [LayoutSubview] = []
        var currentWidth: CGFloat = 0

        for subview in subviews {
            let w = subview.sizeThatFits(.unspecified).width
            if !currentRow.isEmpty && currentWidth + spacing + w > maxWidth {
                rows.append(currentRow)
                currentRow = [subview]
                currentWidth = w
            } else {
                currentRow.append(subview)
                currentWidth += (currentRow.count > 1 ? spacing : 0) + w
            }
        }
        if !currentRow.isEmpty { rows.append(currentRow) }
        return rows
    }
}
