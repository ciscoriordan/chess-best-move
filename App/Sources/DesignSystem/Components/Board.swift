import ChessCore
import CoreText
import SwiftUI

/// Maps squares to display cells and back. Row 0 is the top of the displayed board.
/// With White at the bottom, a8 is top-left; flipped, h1 is top-left.
enum BoardGeometry {
    /// The display cell (row from the top, column from the left) of `square`.
    static func cell(of square: Square, whiteAtBottom: Bool) -> (row: Int, column: Int) {
        whiteAtBottom ? (7 - square.rank, square.file) : (square.rank, 7 - square.file)
    }

    /// The square shown at a display cell.
    static func square(row: Int, column: Int, whiteAtBottom: Bool) -> Square? {
        whiteAtBottom ? Square(file: column, rank: 7 - row) : Square(file: 7 - column, rank: row)
    }

    /// The rectangle of `square` on a board of side `side` points.
    static func rect(of square: Square, side: CGFloat, whiteAtBottom: Bool) -> CGRect {
        let cell = cell(of: square, whiteAtBottom: whiteAtBottom)
        let size = side / 8
        return CGRect(x: CGFloat(cell.column) * size, y: CGFloat(cell.row) * size, width: size, height: size)
    }

    /// The center of `square` on a board of side `side` points.
    static func center(of square: Square, side: CGFloat, whiteAtBottom: Bool) -> CGPoint {
        let rect = rect(of: square, side: side, whiteAtBottom: whiteAtBottom)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// The square under `point` on a board of side `side`, or nil outside the board.
    static func square(at point: CGPoint, side: CGFloat, whiteAtBottom: Bool) -> Square? {
        guard side > 0, point.x >= 0, point.y >= 0, point.x < side, point.y < side else { return nil }
        let size = side / 8
        return square(row: Int(point.y / size), column: Int(point.x / size), whiteAtBottom: whiteAtBottom)
    }
}

/// The board frame: square, 1 px `rule2` hairline border, `r1` radius, excluded from Smart
/// Invert. Holds the user's cropped screenshot or the diagram board, plus overlays (arrow,
/// low-confidence marks) sized to the same square.
struct BoardFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.r1, style: .continuous)
        content()
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: Layout.maximumBoardSide)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.rule2, lineWidth: LineWidth.hairline(displayScale: displayScale)))
            .accessibilityIgnoresInvertColors()
    }
}

/// The user's cropped board screenshot in a `BoardFrame`, drawn so each of the detected
/// board's 8 x 8 cells is one eighth of the frame, where overlays (arrow, marks) expect it.
///
/// A board that runs past the edge of the screenshot gives a crop narrower or shorter than
/// the board. Pass the board rectangle (`BoardSnapshot.boardRect`) and the crop is placed at
/// its true offset, with the part outside the screenshot left in `sunken`, instead of being
/// stretched to a square.
struct BoardScreenshot: View {
    let image: CGImage
    /// Where the crop sits in the board square, in fractions of the board side.
    let placement: CGRect

    /// - Parameter boardRect: the whole board in the source image's pixels, possibly
    ///   extending past the image; the crop is that rectangle, rounded out to whole pixels and
    ///   clipped to the image. Nil draws the crop over the whole frame.
    init(image: CGImage, boardRect: CGRect? = nil) {
        self.image = image
        placement = Self.placement(imageWidth: image.width, imageHeight: image.height, boardRect: boardRect)
    }

    /// `image` (the snapshot's `boardImage`) placed by the snapshot's board rectangle.
    init(image: CGImage, snapshot: BoardSnapshot) {
        self.init(image: image, boardRect: snapshot.boardRect)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack(alignment: .topLeading) {
                if placement != Self.wholeBoard {
                    Palette.sunken
                }
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side * placement.width, height: side * placement.height)
                    .offset(x: side * placement.minX, y: side * placement.minY)
            }
            .frame(width: side, height: side, alignment: .topLeading)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityIgnoresInvertColors()
    }

    static let wholeBoard = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The crop's rectangle in fractions of the board side. The whole board when the rectangle
    /// is unknown or does not match the crop's size.
    static func placement(imageWidth: Int, imageHeight: Int, boardRect: CGRect?) -> CGRect {
        guard let board = boardRect?.standardized, board.width > 0, board.height > 0,
              imageWidth > 0, imageHeight > 0
        else { return wholeBoard }
        // The recognizer crops `board.integral` clipped to the image, so the crop starts at
        // the rounded board origin, or at 0 where the board runs past the top or left edge.
        let rounded = board.integral
        let cropX = max(rounded.minX, 0)
        let cropY = max(rounded.minY, 0)
        let placement = CGRect(
            x: (cropX - board.minX) / board.width,
            y: (cropY - board.minY) / board.height,
            width: CGFloat(imageWidth) / board.width,
            height: CGFloat(imageHeight) / board.height
        )
        // A crop that is not part of this board (or barely any of it) is drawn as before.
        let plausible = CGRect(x: -0.01, y: -0.01, width: 1.02, height: 1.02)
        guard plausible.contains(placement), placement.width > 0.25, placement.height > 0.25 else { return wholeBoard }
        // Within a pixel of the whole board: draw it as the whole board.
        let tolerance = 1 / max(board.width, board.height) + 0.0001
        if abs(placement.minX) <= tolerance, abs(placement.minY) <= tolerance,
           abs(placement.width - 1) <= 2 * tolerance, abs(placement.height - 1) <= 2 * tolerance {
            return wholeBoard
        }
        return placement
    }
}

/// The app's own book-diagram board: `diagramLight` / `diagramDark` squares, `PieceGlyph`
/// pieces, and coordinates in `dataSmall` / `boardCoordinate` inside the edge squares.
struct DiagramBoard: View {
    /// 64 entries in `Square.index` order.
    let board: [Piece?]
    var whiteAtBottom = true
    var showsCoordinates = true

    var body: some View {
        let labels = showsCoordinates ? DiagramBoardLabels(font: Typography.resolve(.dataSmall).uiFont) : nil
        let board = board
        let whiteAtBottom = whiteAtBottom
        Canvas { context, size in
            let side = min(size.width, size.height)
            let cellSize = side / 8
            for row in 0..<8 {
                for column in 0..<8 {
                    guard let square = BoardGeometry.square(row: row, column: column, whiteAtBottom: whiteAtBottom) else { continue }
                    let rect = CGRect(x: CGFloat(column) * cellSize, y: CGFloat(row) * cellSize, width: cellSize, height: cellSize)
                    let squareColor = (square.file + square.rank).isMultiple(of: 2) ? Palette.diagramDark : Palette.diagramLight
                    context.fill(Path(rect), with: .color(squareColor))
                    if board.indices.contains(square.index), let piece = board[square.index] {
                        PieceGlyphRenderer.draw(piece, in: rect, context: &context)
                    }
                    guard let labels else { continue }
                    if column == 0 {
                        labels.draw(rank: square.rank, topLeading: CGPoint(x: rect.minX + 2, y: rect.minY + 1),
                                    squareColor: squareColor, context: &context)
                    }
                    if row == 7 {
                        labels.draw(file: square.file, bottomTrailing: CGPoint(x: rect.maxX - 2, y: rect.maxY - 1),
                                    squareColor: squareColor, context: &context)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityIgnoresInvertColors()
    }
}

/// The board coordinates as glyph outlines. A piece fills 0.82 of its square, which leaves no
/// free corner for a label, so each label is drawn over the piece with a 1.5 pt outline in the
/// square's color: the label reads as a label and the piece stops cleanly short of it.
private struct DiagramBoardLabels {
    /// The width of the square-colored outline around a label.
    static let outlineWidth: CGFloat = 1.5

    private struct Label {
        /// Glyph outlines with y down, the origin at the start of the baseline.
        let path: Path
        let width: CGFloat
    }

    private let ranks: [Label]
    private let files: [Label]
    private let ascent: CGFloat
    private let descent: CGFloat

    init(font: UIFont) {
        let ctFont = font as CTFont
        ascent = CTFontGetAscent(ctFont)
        descent = CTFontGetDescent(ctFont)
        ranks = (1...8).map { Self.label("\($0)", font: ctFont) }
        files = "abcdefgh".map { Self.label(String($0), font: ctFont) }
    }

    /// Draws the rank number (0-based `rank`) with the text's top-leading corner at `point`.
    func draw(rank: Int, topLeading point: CGPoint, squareColor: Color, context: inout GraphicsContext) {
        guard ranks.indices.contains(rank) else { return }
        let label = ranks[rank]
        draw(label, baselineStart: CGPoint(x: point.x, y: point.y + ascent), squareColor: squareColor, context: &context)
    }

    /// Draws the file letter (0-based `file`) with the text's bottom-trailing corner at `point`.
    func draw(file: Int, bottomTrailing point: CGPoint, squareColor: Color, context: inout GraphicsContext) {
        guard files.indices.contains(file) else { return }
        let label = files[file]
        draw(label, baselineStart: CGPoint(x: point.x - label.width, y: point.y - descent), squareColor: squareColor, context: &context)
    }

    private func draw(_ label: Label, baselineStart: CGPoint, squareColor: Color, context: inout GraphicsContext) {
        let placed = label.path.applying(CGAffineTransform(translationX: baselineStart.x, y: baselineStart.y))
        context.stroke(placed, with: .color(squareColor),
                       style: StrokeStyle(lineWidth: 2 * Self.outlineWidth, lineCap: .round, lineJoin: .round))
        // `boardCoordinate`, not `ink3`: the label sits on the diagram, which does not follow
        // the theme, and `ink3` measured 1.86:1 on a dark square (`Palette` "Board marks").
        context.fill(placed, with: .color(Palette.boardCoordinate))
    }

    private static func label(_ text: String, font: CTFont) -> Label {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var path = Path()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            // SF Mono has every digit and lowercase letter, so no run falls back to another font.
            for (glyph, position) in zip(glyphs, positions) {
                guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                // Font outlines have y up; the canvas has y down.
                let transform = CGAffineTransform(translationX: position.x, y: -position.y).scaledBy(x: 1, y: -1)
                path.addPath(Path(outline), transform: transform)
            }
        }
        return Label(path: path, width: width)
    }
}

/// The accent legend square (8 pt) that ties the move text to the arrow color.
struct AccentLegendSquare: View {
    var body: some View {
        Rectangle().fill(Palette.accent).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

#Preview("Boards") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            BoardFrame { DiagramBoard(board: Position.start.board) }
            BoardFrame { DiagramBoard(board: Position.start.board, whiteAtBottom: false) }
        }
        .sideGutter()
    }
    .background(Palette.canvas)
}
