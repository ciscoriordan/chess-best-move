import ChessCore
import SwiftUI
import UIKit

/// The editor's board (design.md 9.6): the diagram board with the selected square, low
/// confidence and issue marks.
///
/// - Tap a square: `CaptureEditorModel.tap`.
/// - Long press and drag a piece: move it; drop outside the board to remove it.
/// - A placed piece scales from 0.9 to 1.0 over 120 ms (not with Reduce Motion).
/// - VoiceOver: 64 elements in rows from the top of the displayed board, labeled with the
///   square ("e4") and valued with its content ("White pawn"); swipe up or down cycles the
///   content and VoiceOver reads the new value; double tap selects the square for the palette.
/// - Keyboard: the whole board is one keyboard stop (`BoardKeyboardControl`). An arrow key
///   summons a cursor and the arrow keys move it square by square, Space or Return does what a
///   tap on that square does, and Escape puts it away. The 64 VoiceOver elements are a separate
///   model and are not keyboard stops, because 64 Tab presses to cross one screen is not access.
struct CaptureEditorBoard: View {
    let model: CaptureEditorModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragSource: Square?
    @State private var dragLocation: CGPoint?
    /// The keyboard cursor, or nil until a key summons it, so a touch user never sees one.
    @State private var keyboardCursor: Square?

    var body: some View {
        let snapshot = model.snapshot
        let whiteAtBottom = snapshot.whiteAtBottom
        BoardKeyboardControl(
            whiteAtBottom: whiteAtBottom,
            home: { BoardKeyboard.home(selected: model.selectedSquare, flagged: snapshot.lowConfidenceSquares, whiteAtBottom: whiteAtBottom) },
            // The same call a tap makes, so the keyboard and the finger cannot diverge.
            activate: { model.tap($0) },
            cursor: $keyboardCursor
        ) {
            board(snapshot: snapshot, whiteAtBottom: whiteAtBottom)
        }
    }

    private func board(snapshot: BoardSnapshot, whiteAtBottom: Bool) -> some View {
        BoardFrame {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let cell = side / 8
                let animatedSquare = reduceMotion ? nil : model.lastPlacedSquare
                ZStack(alignment: .topLeading) {
                    DiagramBoard(board: displayedBoard(hiding: [dragSource, animatedSquare]), whiteAtBottom: whiteAtBottom)
                    CaptureBoardMarks(
                        whiteAtBottom: whiteAtBottom,
                        lowConfidence: snapshot.lowConfidenceSquares,
                        danger: model.dangerSquares,
                        selected: model.selectedSquare
                    )
                    if let animatedSquare, animatedSquare != dragSource, let piece = model.piece(at: animatedSquare) {
                        let rect = BoardGeometry.rect(of: animatedSquare, side: side, whiteAtBottom: whiteAtBottom)
                        PieceGlyph(piece: piece)
                            .frame(width: cell, height: cell)
                            .id(model.placementCount)
                            .transition(.asymmetric(insertion: .scale(scale: 0.9), removal: .identity))
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: side, height: side)
                .animation(reduceMotion ? nil : .easeOut(duration: Motion.valueChange), value: model.placementCount)
                .overlay(alignment: .topLeading) {
                    squareGrid(cell: cell, whiteAtBottom: whiteAtBottom)
                }
                .overlay(alignment: .topLeading) {
                    if let dragSource, let dragLocation, let piece = model.piece(at: dragSource) {
                        PieceGlyph(piece: piece)
                            .frame(width: cell * 1.3, height: cell * 1.3)
                            .position(dragLocation)
                            .allowsHitTesting(false)
                    }
                }
                // Last, so nothing on the board can cover the keyboard cursor.
                .overlay(alignment: .topLeading) {
                    if let keyboardCursor {
                        BoardKeyboardCursorRing(square: keyboardCursor, whiteAtBottom: whiteAtBottom)
                            .frame(width: side, height: side)
                    }
                }
                .simultaneousGesture(dragGesture(side: side, whiteAtBottom: whiteAtBottom))
                .accessibilityElement(children: .contain)
            }
        }
        .boardTapTargetRelief()
        .sensoryFeedback(.selection, trigger: model.placementCount)
        .accessibilityIdentifier(CaptureAccessibilityID.editorBoard)
    }

    private func displayedBoard(hiding squares: [Square?]) -> [Piece?] {
        var board = model.snapshot.position.board
        for square in squares.compactMap({ $0 }) {
            board[square.index] = nil
        }
        return board
    }

    // MARK: Gestures

    private func dragGesture(side: CGFloat, whiteAtBottom: Bool) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: CaptureBoardDrag.minimumDistance, coordinateSpace: .local))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if dragSource == nil,
                   let square = BoardGeometry.square(at: drag.startLocation, side: side, whiteAtBottom: whiteAtBottom),
                   model.piece(at: square) != nil {
                    dragSource = square
                }
                if dragSource != nil { dragLocation = drag.location }
            }
            .onEnded { value in
                defer {
                    dragSource = nil
                    dragLocation = nil
                }
                guard case .second(true, let drag?) = value, let source = dragSource else { return }
                switch CaptureBoardDrag.outcome(from: source, to: drag.location, side: side, whiteAtBottom: whiteAtBottom) {
                case .move(let target): model.move(from: source, to: target)
                case .remove: model.remove(at: source)
                case .cancel: break
                }
            }
    }

    // MARK: Squares

    /// One view per square, in rows from the top of the displayed board: the tap target and
    /// the VoiceOver element of that square.
    private func squareGrid(cell: CGFloat, whiteAtBottom: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { column in
                        if let square = BoardGeometry.square(row: row, column: column, whiteAtBottom: whiteAtBottom) {
                            squareCell(square, cell: cell)
                        }
                    }
                }
            }
        }
    }

    private func squareCell(_ square: Square, cell: CGFloat) -> some View {
        let lowConfidence = model.isLowConfidence(square)
        let selected = model.selectedSquare == square
        return Color.clear
            .frame(width: cell, height: cell)
            .contentShape(Rectangle())
            .onTapGesture { model.tap(square) }
            .accessibilityElement()
            .accessibilityLabel(CaptureBoardSpeech.squareLabel(square))
            // The occupant is the value, so VoiceOver announces the new piece after each
            // adjustable swipe.
            .accessibilityValue(CaptureBoardSpeech.squareValue(piece: model.piece(at: square), lowConfidence: lowConfidence))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityHint("Swipe up or down to change the piece. Double tap to select it for the palette.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.cycle(square, forward: true)
                case .decrement: model.cycle(square, forward: false)
                @unknown default: break
                }
            }
            .accessibilityAction { model.select(square) }
            .accessibilityActions {
                if lowConfidence {
                    Button("Mark as correct") { model.confirm(square) }
                }
                if model.piece(at: square) != nil {
                    Button("Remove piece") { model.remove(at: square) }
                }
            }
    }
}

/// What a piece drag in the editor does when the finger lifts.
///
/// The drag used to have a minimum distance of zero, which made the release point alone decide
/// the outcome once the 0.3 s press had succeeded: a few points of drift turned a slow tap into
/// a move, and a release a hair outside the board deleted the piece. Neither is recoverable by
/// noticing, because a piece that is quietly gone is exactly what the editor exists to catch.
/// So a drag has to travel before it is a drag, a release back on the square it started from
/// is a cancel, and a release outside the board only removes the piece when it is clearly
/// outside (design.md 9.6).
enum CaptureBoardDrag {
    /// How far the finger travels before a press becomes a drag, in points.
    static let minimumDistance: CGFloat = 10
    /// How far outside the board a release has to be before it removes the piece, in squares.
    static let removalMargin: CGFloat = 0.5

    enum Outcome: Equatable, Sendable {
        case move(to: Square)
        case remove
        case cancel
    }

    static func outcome(from source: Square, to location: CGPoint, side: CGFloat, whiteAtBottom: Bool) -> Outcome {
        if let target = BoardGeometry.square(at: location, side: side, whiteAtBottom: whiteAtBottom) {
            return target == source ? .cancel : .move(to: target)
        }
        guard side > 0 else { return .cancel }
        let margin = side / 8 * removalMargin
        let outside = max(
            max(-location.x, location.x - side),
            max(-location.y, location.y - side)
        )
        return outside > margin ? .remove : .cancel
    }
}

/// The piece palette tray (design.md 9.6): White and Black rows of king, queen, rook,
/// bishop, knight, pawn, and an Empty cell. The selected square's occupant, or the armed
/// brush item, has an `accent` border; the occupant also gets an `accentSubtle` fill. Pieces
/// sit on a `diagramLight` tile so both colors stay legible in dark mode.
struct CapturePieceTray: View {
    let model: CaptureEditorModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0

    static let maximumCell: CGFloat = 52
    /// A tray cell is a hit target, so it never goes under the 44 pt minimum. The width formula
    /// has to solve for that same number: it used to size the row for a 40 pt floor, land on
    /// 43 on a 375 pt screen, and then have `cellButton` force each cell to 44, which put the
    /// Empty cell about 3 pt past the trailing gutter.
    static let minimumCell: CGFloat = Layout.minimumHitTarget

    /// The cell side and the gap between cells for a tray `width` points wide.
    ///
    /// Seven cells sit across the tray (six pieces, then Empty), with five gaps inside the
    /// piece rows and one `Spacing.s2` gap before the Empty cell. The wider gap is only taken
    /// when seven full hit targets still fit with it.
    static func metrics(width: CGFloat) -> (cell: CGFloat, spacing: CGFloat) {
        let spacing: CGFloat = width >= 7 * minimumCell + 5 * 6 + Spacing.s2 ? 6 : 4
        let cell = max(minimumCell, min(maximumCell, ((width - 5 * spacing - Spacing.s2) / 7).rounded(.down)))
        return (cell, spacing)
    }

    /// The width seven cells of `cell` points with `spacing` between them take.
    static func trayWidth(cell: CGFloat, spacing: CGFloat) -> CGFloat {
        7 * cell + 5 * spacing + Spacing.s2
    }

    var body: some View {
        let (cell, spacing) = Self.metrics(width: width)
        HStack(alignment: .top, spacing: Spacing.s2) {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(PieceColor.allCases, id: \.self) { color in
                    HStack(spacing: spacing) {
                        ForEach(CapturePaletteItem.row(color)) { item in
                            cellButton(item, side: cell)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(CapturePositionIssues.name(color)) pieces")
                }
            }
            cellButton(.empty, side: cell, height: cell * 2 + spacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func cellButton(_ item: CapturePaletteItem, side: CGFloat, height: CGFloat? = nil) -> some View {
        let isOccupant = model.occupantItem == item
        let isArmed = model.selectedSquare == nil && model.armedItem == item
        let shape = RoundedRectangle(cornerRadius: Radius.r2, style: .continuous)
        return Button {
            model.choose(item)
        } label: {
            ZStack {
                shape.fill(isOccupant ? Palette.accentSubtle : Color.clear)
                switch item {
                case .piece(let piece):
                    RoundedRectangle(cornerRadius: Radius.r1, style: .continuous)
                        .fill(Palette.diagramLight)
                        .padding(5)
                    PieceGlyph(piece: piece, scale: 0.7)
                        .padding(5)
                case .empty:
                    if Self.emptyTitleFits(cellWidth: side, sizeCategory: UIContentSizeCategory(dynamicTypeSize)) {
                        Text(Self.emptyTitle)
                            .typography(.caption)
                            .foregroundStyle(Palette.ink)
                            .minimumScaleFactor(Self.emptyTitleMinimumScale)
                            .lineLimit(1)
                            .padding(.horizontal, Self.emptyTitlePadding)
                    } else {
                        // The cell keeps its width at large text sizes, where the word no longer
                        // fits even scaled down: a symbol instead, with the word in the
                        // accessibility label and the Large Content Viewer.
                        Image(systemName: Self.emptySymbol)
                            .font(.system(size: side * 0.42, weight: .regular))
                            .foregroundStyle(Palette.ink)
                    }
                }
            }
            .frame(width: side, height: height ?? side)
            .overlay {
                if isOccupant || isArmed {
                    shape.strokeBorder(Palette.accent, lineWidth: LineWidth.selection)
                } else {
                    shape.strokeBorder(Palette.rule2, lineWidth: LineWidth.control)
                }
            }
            .frame(minWidth: Layout.minimumHitTarget, minHeight: Layout.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.piece.map(CapturePositionIssues.name) ?? Self.emptyTitle)
        .accessibilityShowsLargeContentViewer {
            if let piece = item.piece {
                Text(CapturePositionIssues.name(piece))
            } else {
                Label(Self.emptyTitle, systemImage: Self.emptySymbol)
            }
        }
        .accessibilityAddTraits(isOccupant || isArmed ? .isSelected : [])
        .accessibilityHint(hint(for: item))
    }

    static let emptyTitle = "Empty"
    static let emptySymbol = "eraser"
    static let emptyTitleMinimumScale: CGFloat = 0.7
    static let emptyTitlePadding: CGFloat = 2

    /// Whether "Empty" fits on one line in a cell `cellWidth` wide at the `caption` size for
    /// `sizeCategory`, scaled down as far as `emptyTitleMinimumScale`. The `caption` token has
    /// no maximum size, so from about AX1 it no longer fits a 40 to 52 pt cell.
    static func emptyTitleFits(cellWidth: CGFloat, sizeCategory: UIContentSizeCategory) -> Bool {
        let resolved = Typography.resolve(.caption, sizeCategory: sizeCategory)
        let attributes: [NSAttributedString.Key: Any] = [.font: resolved.uiFont, .kern: resolved.tracking]
        let width = (emptyTitle as NSString).size(withAttributes: attributes).width
        return width * emptyTitleMinimumScale <= cellWidth - 2 * emptyTitlePadding
    }

    private func hint(for item: CapturePaletteItem) -> String {
        if let square = model.selectedSquare {
            return item.piece == nil ? "Clears \(square.algebraic)" : "Places it on \(square.algebraic)"
        }
        return "Arms it: then every square you tap gets it"
    }
}
