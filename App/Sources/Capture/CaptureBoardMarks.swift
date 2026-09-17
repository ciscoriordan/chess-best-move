import ChessCore
import SwiftUI
import UIKit

/// Marks drawn over a board (design.md 9.5, 9.6, 12):
/// - low-confidence squares: 2 pt dashed `caution` outline and a "?" badge in the top
///   trailing corner (14 pt, `r1`, `caution` fill, "?" in `canvas`, 1.5 pt white ring);
/// - squares with a blocking issue: 2 pt `danger` outline;
/// - the selected square: 2 pt `accent` inset outline.
struct CaptureBoardMarks: View {
    var whiteAtBottom: Bool
    var lowConfidence: Set<Square> = []
    var danger: Set<Square> = []
    var selected: Square?

    static let badgeSide: CGFloat = 14
    static let badgeRing: CGFloat = 1.5

    var body: some View {
        let badgeFont = Font(Typography.bricolage(size: 11, weight: 700, opticalSize: 12, width: 100) as CTFont)
        let whiteAtBottom = whiteAtBottom
        let lowConfidence = lowConfidence
        let danger = danger
        let selected = selected
        Canvas { context, size in
            let side = min(size.width, size.height)
            for square in lowConfidence.sorted() {
                let rect = BoardGeometry.rect(of: square, side: side, whiteAtBottom: whiteAtBottom)
                let inset = rect.insetBy(dx: LineWidth.lowConfidence / 2 + 1, dy: LineWidth.lowConfidence / 2 + 1)
                context.stroke(
                    Path(inset),
                    with: .color(Palette.caution),
                    style: StrokeStyle(lineWidth: LineWidth.lowConfidence, dash: LineWidth.lowConfidenceDash)
                )
            }
            for square in danger.sorted() {
                let rect = BoardGeometry.rect(of: square, side: side, whiteAtBottom: whiteAtBottom)
                let inset = rect.insetBy(dx: LineWidth.selection / 2, dy: LineWidth.selection / 2)
                context.stroke(Path(inset), with: .color(Palette.danger), lineWidth: LineWidth.selection)
            }
            if let selected {
                let rect = BoardGeometry.rect(of: selected, side: side, whiteAtBottom: whiteAtBottom)
                let inset = rect.insetBy(dx: LineWidth.selection / 2, dy: LineWidth.selection / 2)
                context.stroke(Path(inset), with: .color(Palette.accent), lineWidth: LineWidth.selection)
            }
            // Badges last, so outlines never cross them.
            for square in lowConfidence.sorted() {
                let rect = BoardGeometry.rect(of: square, side: side, whiteAtBottom: whiteAtBottom)
                let badgeSide = min(Self.badgeSide, rect.width * 0.4)
                let badge = CGRect(x: rect.maxX - badgeSide - 2, y: rect.minY + 2, width: badgeSide, height: badgeSide)
                let ring = badge.insetBy(dx: -Self.badgeRing, dy: -Self.badgeRing)
                context.fill(
                    Path(roundedRect: ring, cornerRadius: Radius.r1 + Self.badgeRing, style: .continuous),
                    with: .color(Palette.piecePaper)
                )
                context.fill(Path(roundedRect: badge, cornerRadius: Radius.r1, style: .continuous), with: .color(Palette.caution))
                context.draw(
                    Text("?").font(badgeFont).foregroundStyle(Palette.canvas),
                    at: CGPoint(x: badge.midX, y: badge.midY),
                    anchor: .center
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Spoken board descriptions shared by Check position and the editor.
enum CaptureBoardSpeech {
    /// The label of an editor square's VoiceOver element: its name, "e4".
    ///
    /// The occupant goes in the value (`squareValue`), not in the label: the square is
    /// adjustable, and after each swipe up or down VoiceOver reads only the element's new
    /// value. On focus VoiceOver still reads "e4, White pawn, adjustable" (design.md 12).
    static func squareLabel(_ square: Square) -> String {
        square.algebraic
    }

    /// The value of an editor square's VoiceOver element: "White pawn" or "empty", plus
    /// ", low confidence" when flagged.
    static func squareValue(piece: Piece?, lowConfidence: Bool) -> String {
        var text = piece.map(CapturePositionIssues.name) ?? "empty"
        if lowConfidence { text += ", low confidence" }
        return text
    }

    /// "Board, White at bottom".
    static func boardLabel(whiteAtBottom: Bool) -> String {
        "Board, \(whiteAtBottom ? "White" : "Black") at bottom"
    }

    /// Pieces grouped by color: "White: king e1, queen d1, ... Black: ...".
    static func pieceList(_ board: [Piece?]) -> String {
        PieceColor.allCases.map { color in
            let pieces = CapturePaletteItem.kindOrder.flatMap { kind in
                Square.all
                    .filter { board[$0.index] == Piece(color: color, kind: kind) }
                    .map { "\(CapturePositionIssues.kindName(kind)) \($0.algebraic)" }
            }
            return "\(CapturePositionIssues.name(color)): " + (pieces.isEmpty ? "no pieces" : pieces.joined(separator: ", "))
        }
        .joined(separator: ". ")
    }
}

/// Places children left to right and wraps onto new lines (chips at large text sizes).
struct CaptureFlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = Spacing.s2
    var lineSpacing: CGFloat = Spacing.s2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let clampedWidth = min(size.width, bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: clampedWidth, height: size.height)
                )
                x += clampedWidth + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            let needed = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
