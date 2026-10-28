import SwiftUI

/// Fit the complete result below the measured controls. If readable text leaves less
/// than a 64-point board, report the larger height so the caller can offer scrolling.
struct WatchResultMetrics: Equatable {
    let width: CGFloat
    let buttonHeight: CGFloat
    let moveHeight: CGFloat
    let boardSide: CGFloat
    let spacing: CGFloat
    let bottomInset: CGFloat

    init(viewport: CGSize, button: CGSize, move: CGSize) {
        width = max(0, viewport.width)
        buttonHeight = button.height
        moveHeight = move.height
        spacing = 8
        bottomInset = 8
        let remaining = viewport.height - buttonHeight - moveHeight - 2 * spacing - bottomInset
        boardSide = min(width, max(64, min(88, remaining.rounded(.down))))
    }

    var moveY: CGFloat { buttonHeight + spacing }
    var boardY: CGFloat { moveY + moveHeight + spacing }
    var height: CGFloat { boardY + boardSide + bottomInset }
}

struct WatchResultLayout: SwiftUI.Layout {
    let viewport: CGSize

    private func metrics(width: CGFloat, subviews: Subviews) -> WatchResultMetrics {
        let proposal = ProposedViewSize(width: width, height: nil)
        return WatchResultMetrics(viewport: CGSize(width: width, height: viewport.height),
                                  button: subviews[0].sizeThatFits(proposal),
                                  move: subviews[1].sizeThatFits(proposal))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let sizes = metrics(width: proposal.width ?? viewport.width, subviews: subviews)
        return CGSize(width: sizes.width, height: sizes.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let sizes = metrics(width: bounds.width, subviews: subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: sizes.buttonHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + sizes.moveY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: sizes.moveHeight))
        subviews[2].place(at: CGPoint(x: bounds.midX, y: bounds.minY + sizes.boardY), anchor: .top,
                          proposal: ProposedViewSize(width: sizes.boardSide, height: sizes.boardSide))
    }
}
