import SwiftUI

/// Where the three parts of the result readout's top row go (design.md 9.4): the move badge,
/// the pill and the evaluation.
///
/// The badge is centered across the card and the pill and the evaluation sit to its right,
/// right-aligned to the card's trailing edge and vertically centered against the badge (owner
/// decision of 2026-09-20, `build/ui-requests.md` item 1). The badge is centered across the
/// card in both of the two arrangements, and it gives way by moving the pill and the
/// evaluation rather than by moving off center:
///
/// 1. Side by side: the badge is centered across the whole card while the pill and the
///    evaluation keep their room on both sides of it (a short move such as `b3`).
/// 2. Stacked: a badge too wide to be centered with room for them beside it keeps the center
///    of the card and the size it asked for, so the move is never clipped or shrunk, and the
///    pill and the evaluation move under it. A four-character move at the default text size
///    already stacks, and every move does at the largest Dynamic Type sizes.
///
/// There is no third, left-of-center placement. The owner was shown a centered badge and a
/// left-aligned one and picked the centered one, and a badge centered in the room left beside
/// the pill is a left-aligned badge by another name.
///
/// The math is kept apart from the `Layout` so it can be checked directly
/// (`AnalysisReadoutGeometryTests`).
enum AnalysisReadoutGeometry {
    /// The width used when the parent proposes none (a `Layout` is asked for its ideal size
    /// before it is given a width).
    static let fallbackWidth: CGFloat = 320

    struct Placement: Sendable, Equatable {
        var badge: CGRect
        var pill: CGRect
        /// Nil until the engine reports a score.
        var evaluation: CGRect?
        var size: CGSize
        /// The badge and the pill-and-evaluation stack did not fit side by side.
        var isStacked: Bool
    }

    /// Whether the pill and the evaluation fit beside a badge that is centered across the
    /// whole card. The room a centered badge may take is the card minus the column and its
    /// gap on both sides, because the badge takes the same room on each side of the center.
    /// A badge wider than that stacks; it is never moved off center to make it fit.
    static func badgeFitsCenteredOnTheCard(width: CGFloat, badgeWidth: CGFloat, room: CGFloat) -> Bool {
        badgeWidth <= 2 * room - width
    }

    /// - Parameters:
    ///   - spacing: the smallest gap between the badge and what sits beside or below it.
    ///   - sideSpacing: the gap between the pill and the evaluation when they are one above
    ///     the other.
    static func place(
        width: CGFloat,
        badge: CGSize,
        pill: CGSize,
        evaluation: CGSize?,
        spacing: CGFloat,
        sideSpacing: CGFloat
    ) -> Placement {
        let columnWidth = max(pill.width, evaluation?.width ?? 0)
        let columnHeight = pill.height + (evaluation.map { sideSpacing + $0.height } ?? 0)
        // What is left of the card beside the pill and the evaluation.
        let room = width - columnWidth - spacing
        if badgeFitsCenteredOnTheCard(width: width, badgeWidth: badge.width, room: room) {
            let badgeX = (width - badge.width) / 2
            let height = max(badge.height, columnHeight)
            let columnY = (height - columnHeight) / 2
            return Placement(
                badge: CGRect(x: badgeX, y: (height - badge.height) / 2, width: badge.width, height: badge.height),
                pill: CGRect(x: width - pill.width, y: columnY, width: pill.width, height: pill.height),
                evaluation: evaluation.map {
                    CGRect(
                        x: width - $0.width,
                        y: columnY + pill.height + sideSpacing,
                        width: $0.width,
                        height: $0.height
                    )
                },
                size: CGSize(width: width, height: height),
                isStacked: false
            )
        }

        // Stacked: the badge keeps the size it asked for, centered on the card, and the pill
        // and the evaluation move under it.
        let badgeRect = CGRect(
            x: max(0, (width - badge.width) / 2),
            y: 0,
            width: badge.width,
            height: badge.height
        )
        let below = badgeRect.maxY + spacing
        guard let evaluation else {
            return Placement(
                badge: badgeRect,
                pill: centered(pill, in: width, y: below),
                evaluation: nil,
                size: CGSize(width: width, height: below + pill.height),
                isStacked: true
            )
        }
        // Under the badge the pill and the evaluation read as one line while they fit.
        let rowWidth = pill.width + spacing + evaluation.width
        guard rowWidth <= width else {
            return Placement(
                badge: badgeRect,
                pill: centered(pill, in: width, y: below),
                evaluation: centered(evaluation, in: width, y: below + pill.height + sideSpacing),
                size: CGSize(width: width, height: below + pill.height + sideSpacing + evaluation.height),
                isStacked: true
            )
        }
        let rowHeight = max(pill.height, evaluation.height)
        let rowX = max(0, (width - rowWidth) / 2)
        return Placement(
            badge: badgeRect,
            pill: CGRect(
                x: rowX,
                y: below + (rowHeight - pill.height) / 2,
                width: pill.width,
                height: pill.height
            ),
            evaluation: CGRect(
                x: rowX + pill.width + spacing,
                y: below + (rowHeight - evaluation.height) / 2,
                width: evaluation.width,
                height: evaluation.height
            ),
            size: CGSize(width: width, height: below + rowHeight),
            isStacked: true
        )
    }

    private static func centered(_ size: CGSize, in width: CGFloat, y: CGFloat) -> CGRect {
        CGRect(x: max(0, (width - size.width) / 2), y: y, width: size.width, height: size.height)
    }
}

/// The layout that places what `AnalysisReadoutGeometry` computes. Its subviews are, in this
/// order: the move badge, the pill, and the evaluation, which is left out entirely until the
/// engine reports a score.
///
/// `SwiftUI.Layout` is spelled out because the design system has a `Layout` of its own
/// (`Metrics.swift`); `LayoutSubviews` is named directly for the same reason.
struct AnalysisReadoutHeaderLayout: SwiftUI.Layout {
    var spacing: CGFloat = Spacing.s3
    var sideSpacing: CGFloat = Spacing.s1

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        placement(width: width(from: proposal), subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        let placement = placement(width: bounds.width, subviews: subviews)
        place(subviews.first, at: placement.badge, in: bounds)
        if subviews.count > 1 { place(subviews[1], at: placement.pill, in: bounds) }
        if subviews.count > 2, let evaluation = placement.evaluation {
            place(subviews[2], at: evaluation, in: bounds)
        }
    }

    private func placement(width: CGFloat, subviews: LayoutSubviews) -> AnalysisReadoutGeometry.Placement {
        let proposal = ProposedViewSize(width: width, height: nil)
        return AnalysisReadoutGeometry.place(
            width: width,
            badge: subviews.first?.sizeThatFits(proposal) ?? .zero,
            pill: subviews.count > 1 ? subviews[1].sizeThatFits(proposal) : .zero,
            evaluation: subviews.count > 2 ? subviews[2].sizeThatFits(proposal) : nil,
            spacing: spacing,
            sideSpacing: sideSpacing
        )
    }

    private func width(from proposal: ProposedViewSize) -> CGFloat {
        guard let proposed = proposal.width, proposed.isFinite, proposed > 0 else {
            return AnalysisReadoutGeometry.fallbackWidth
        }
        return proposed
    }

    private func place(_ subview: LayoutSubviews.Element?, at rect: CGRect, in bounds: CGRect) {
        subview?.place(
            at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(rect.size)
        )
    }
}
