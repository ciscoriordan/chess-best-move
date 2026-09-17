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
struct CaptureEditorBoard: View {
    let model: CaptureEditorModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragSource: Square?
    @State private var dragLocation: CGPoint?

    var body: some View {
        let snapshot = model.snapshot
        let whiteAtBottom = snapshot.whiteAtBottom
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
                .simultaneousGesture(dragGesture(side: side, whiteAtBottom: whiteAtBottom))
                .accessibilityElement(children: .contain)
            }
        }
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
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
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
                if let target = BoardGeometry.square(at: drag.location, side: side, whiteAtBottom: whiteAtBottom) {
                    model.move(from: source, to: target)
                } else {
                    model.remove(at: source)
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

/// The piece palette tray (design.md 9.6): White and Black rows of king, queen, rook,
/// bishop, knight, pawn, and an Empty cell. The selected square's occupant, or the armed
/// brush item, has an `accent` border; the occupant also gets an `accentSubtle` fill. Pieces
/// sit on a `diagramLight` tile so both colors stay legible in dark mode.
struct CapturePieceTray: View {
    let model: CaptureEditorModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0

    private static let maximumCell: CGFloat = 52
    private static let minimumCell: CGFloat = 40

    var body: some View {
        let spacing: CGFloat = width >= 7 * Self.minimumCell + 6 * 6 + Spacing.s2 ? 6 : 4
        let cell = max(Self.minimumCell, min(Self.maximumCell, ((width - 5 * spacing - Spacing.s2) / 7).rounded(.down)))
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
