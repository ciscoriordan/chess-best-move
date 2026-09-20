import ChessCore
import SwiftUI
import UIKit

/// Marks drawn over a board (design.md 9.5, 9.6, 12):
/// - low-confidence squares: 2 pt dashed `markLowConfidence` outline and a "?" badge in the
///   top trailing corner (14 pt, `r1`, 1.5 pt white ring);
/// - squares with a blocking issue: 2 pt solid `markIssue` outline and an "!" badge in the top
///   leading corner, so the two marks differ in shape and not only in hue;
/// - the selected square: 2 pt `markSelection` outline, inset inside any issue outline so a
///   square that is both still shows both.
///
/// The three colors are fixed rather than theme-following, because the diagram board under
/// them is a warm paper board in both appearances (`Palette` "Board marks"). Drawn in the
/// theme-following `caution`, `danger` and `accent`, the selection outline measured 1.04:1 in
/// dark mode, which is invisible, and the editor's whole interaction rests on it.
struct CaptureBoardMarks: View {
    var whiteAtBottom: Bool
    var lowConfidence: Set<Square> = []
    var danger: Set<Square> = []
    var selected: Square?

    static let badgeSide: CGFloat = 14
    static let badgeRing: CGFloat = 1.5

    var body: some View {
        // Fixed size: the badge is 14 pt square whatever the Dynamic Type setting, so the "?"
        // inside it cannot scale either (the board it sits on does not scale).
        let badgeFont = Font.system(size: 11, weight: .bold)
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
                    with: .color(Palette.markLowConfidence),
                    style: StrokeStyle(lineWidth: LineWidth.lowConfidence, dash: LineWidth.lowConfidenceDash)
                )
            }
            for square in danger.sorted() {
                let rect = BoardGeometry.rect(of: square, side: side, whiteAtBottom: whiteAtBottom)
                let inset = rect.insetBy(dx: LineWidth.selection / 2, dy: LineWidth.selection / 2)
                context.stroke(Path(inset), with: .color(Palette.markIssue), lineWidth: LineWidth.selection)
            }
            if let selected {
                let rect = BoardGeometry.rect(of: selected, side: side, whiteAtBottom: whiteAtBottom)
                // A selected square that also has a blocking issue keeps both outlines: the
                // selection is drawn one line width further in rather than over the issue.
                let offset = danger.contains(selected) ? LineWidth.selection * 1.5 : LineWidth.selection / 2
                let inset = rect.insetBy(dx: offset, dy: offset)
                context.stroke(Path(inset), with: .color(Palette.markSelection), lineWidth: LineWidth.selection)
            }
            // Badges last, so outlines never cross them. A "?" in the top trailing corner asks
            // the user to check the square; an "!" in the top leading corner says the position
            // is not legal until it is fixed. The two marks are told apart by corner and glyph
            // as well as by color, which is what Differentiate Without Color needs and what a
            // reader with any color vision deficiency needs whether or not it is switched on.
            for square in lowConfidence.sorted() {
                let rect = BoardGeometry.rect(of: square, side: side, whiteAtBottom: whiteAtBottom)
                badge("?", in: rect, corner: .topTrailing, fill: Palette.markLowConfidence, font: badgeFont, context: &context)
            }
            for square in danger.sorted() {
                let rect = BoardGeometry.rect(of: square, side: side, whiteAtBottom: whiteAtBottom)
                badge("!", in: rect, corner: .topLeading, fill: Palette.markIssue, font: badgeFont, context: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private enum BadgeCorner { case topLeading, topTrailing }

    /// One corner badge: a rounded square in `fill` with a white ring, so it reads on any
    /// square, and one character in white on it.
    private func badge(
        _ text: String,
        in rect: CGRect,
        corner: BadgeCorner,
        fill: Color,
        font: Font,
        context: inout GraphicsContext
    ) {
        let side = min(Self.badgeSide, rect.width * 0.4)
        let x = corner == .topTrailing ? rect.maxX - side - 2 : rect.minX + 2
        let box = CGRect(x: x, y: rect.minY + 2, width: side, height: side)
        let ring = box.insetBy(dx: -Self.badgeRing, dy: -Self.badgeRing)
        context.fill(
            Path(roundedRect: ring, cornerRadius: Radius.r1 + Self.badgeRing, style: .continuous),
            with: .color(Palette.piecePaper)
        )
        context.fill(Path(roundedRect: box, cornerRadius: Radius.r1, style: .continuous), with: .color(fill))
        context.draw(
            // White, not `canvas`: the badge is drawn on the diagram, which does not follow the
            // theme, so a `canvas` glyph was near-black on a dark amber badge in dark mode.
            Text(text).font(font).foregroundStyle(Palette.piecePaper),
            at: CGPoint(x: box.midX, y: box.midY),
            anchor: .center
        )
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

    /// The custom action that stands in for pressing and holding the board to compare it with
    /// the user's screenshot. VoiceOver swallows a touch and hold before it reaches the view,
    /// and a quarter-second hold within 30 pt is not something every hand can do, so the
    /// comparison is an action as well as a gesture (design.md 9.4, 9.5, 12).
    static let compareAction = "Compare with your screenshot"
    /// The same action once the screenshot is showing.
    static let hideScreenshotAction = "Show the recognized board"

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
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// The size a child takes on a line `width` points wide.
    ///
    /// A chip wider than the line has to be measured again at that width, because the height
    /// it gave at its ideal width is the height of one line and the chip will wrap to two. The
    /// earlier version clamped only the width and kept the unwrapped height, which squeezed
    /// the chip horizontally while holding it one line tall: SwiftUI answered that by
    /// truncating the label. At AccessibilityXXXL the side-to-move chip needs about 421 pt
    /// against a 370 pt card, and the chip the user is on Check position to settle read
    /// "White to m...".
    private func size(of subview: Subviews.Element, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = size(of: subviews[index], width: width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
            current.sizes.append(size)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
