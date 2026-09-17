import ChessCore
import Foundation
import Observation

/// One cell of the editor's piece palette.
enum CapturePaletteItem: Hashable, Sendable, Identifiable {
    case piece(Piece)
    case empty

    var id: String {
        switch self {
        case .piece(let piece): String(piece.fenCharacter)
        case .empty: "empty"
        }
    }

    var piece: Piece? {
        if case .piece(let piece) = self { return piece }
        return nil
    }

    /// Palette column order: king, queen, rook, bishop, knight, pawn.
    static let kindOrder: [PieceKind] = [.king, .queen, .rook, .bishop, .knight, .pawn]

    static func row(_ color: PieceColor) -> [CapturePaletteItem] {
        kindOrder.map { .piece(Piece(color: color, kind: $0)) }
    }

    /// The VoiceOver adjustable order (design.md 12): Empty, White K, Q, R, B, N, P,
    /// Black K, Q, R, B, N, P.
    static let cycleOrder: [Piece?] = [nil]
        + kindOrder.map { Piece(color: .white, kind: $0) }
        + kindOrder.map { Piece(color: .black, kind: $0) }

    init(_ piece: Piece?) {
        self = piece.map(CapturePaletteItem.piece) ?? .empty
    }
}

/// The state and rules of the position editor (design.md 9.6), kept apart from the view so
/// they can be tested.
@MainActor
@Observable
final class CaptureEditorModel {
    /// Two taps on the same square within this interval are a double tap.
    static let doubleTapInterval: TimeInterval = 0.35
    /// Undo keeps this many steps.
    static let undoLimit = 100

    private struct UndoStep {
        var snapshot: BoardSnapshot
        var usedBoardReset: Bool
        var selectedSquare: Square?
    }

    let purpose: EditorContext.Purpose
    /// The snapshot the editor was opened with.
    let original: BoardSnapshot

    private(set) var snapshot: BoardSnapshot
    /// The square the palette edits.
    private(set) var selectedSquare: Square?
    /// Brush mode: with no square selected, the armed palette item is placed on every tapped
    /// square.
    private(set) var armedItem: CapturePaletteItem?
    /// Start position or Clear board was used, so Analyze counts as a board set up by hand.
    private(set) var usedBoardReset = false
    /// Issues of the current position, in `PositionIssue` order.
    private(set) var issues: [PositionIssue] = []
    /// Incremented on every piece placement, to trigger the placement animation and haptic.
    private(set) var placementCount = 0
    /// The square of the most recent placement.
    private(set) var lastPlacedSquare: Square?
    private(set) var canUndo = false

    @ObservationIgnored private var undoStack: [UndoStep] = []
    @ObservationIgnored private var lastTap: (square: Square, time: Date)?

    init(context: EditorContext) {
        purpose = context.purpose
        original = context.snapshot
        snapshot = context.snapshot
        selectedSquare = context.selectedSquare
        refreshIssues()
    }

    // MARK: Derived state

    var position: Position { snapshot.position }

    var blockingIssues: [PositionIssue] { issues.filter(CapturePositionIssues.isBlocking) }

    /// Analyze is enabled only without blocking issues.
    var canAnalyze: Bool { blockingIssues.isEmpty }

    /// The position differs from the one the editor was opened with.
    var hasUnsavedChanges: Bool { snapshot.position != original.position }

    /// `.handSetup` for "Set up the position by hand" and after Start position or Clear
    /// board; `.editor` otherwise.
    var analysisOrigin: AnalysisOrigin {
        purpose == .handSetup || usedBoardReset ? .handSetup : .editor
    }

    var canResetToRecognized: Bool { original.recognizedBoard?.count == 64 }

    func piece(at square: Square) -> Piece? {
        snapshot.position.board[square.index]
    }

    func isLowConfidence(_ square: Square) -> Bool {
        snapshot.lowConfidenceSquares.contains(square)
    }

    /// The palette cell showing the selected square's occupant.
    var occupantItem: CapturePaletteItem? {
        selectedSquare.map { CapturePaletteItem(piece(at: $0)) }
    }

    /// Squares outlined in `danger` (pawns on the back rank).
    var dangerSquares: Set<Square> { CapturePositionIssues.dangerSquares(in: issues) }

    // MARK: Board interaction

    /// A tap on a board square.
    ///
    /// - Brush armed: places the armed item.
    /// - A second tap on a low-confidence square within `doubleTapInterval`: confirms it as
    ///   recognized and keeps it selected.
    /// - The selected square again: deselects it.
    /// - Any other square: selects it.
    func tap(_ square: Square, at time: Date = Date()) {
        defer { lastTap = (square, time) }
        if let armedItem, selectedSquare == nil {
            set(armedItem.piece, on: square)
            return
        }
        if let lastTap, lastTap.square == square, time.timeIntervalSince(lastTap.time) < Self.doubleTapInterval,
           isLowConfidence(square) {
            confirm(square)
            selectedSquare = square
            return
        }
        selectedSquare = selectedSquare == square ? nil : square
    }

    /// Selects `square` for the palette (VoiceOver's activate action).
    func select(_ square: Square?) {
        selectedSquare = square
        if square != nil { armedItem = nil }
    }

    /// A tap on a palette cell. With a square selected, places the item there (the occupant
    /// again, or Empty, clears the square). Without one, arms or disarms the brush.
    func choose(_ item: CapturePaletteItem) {
        if let square = selectedSquare {
            let occupant = piece(at: square)
            if item.piece == nil || item.piece == occupant {
                set(nil, on: square)
            } else {
                set(item.piece, on: square)
            }
        } else {
            armedItem = armedItem == item ? nil : item
        }
    }

    /// Puts `piece` (or nothing) on `square`. Removes the square's low-confidence mark even
    /// when the content does not change, because the user looked at it.
    func set(_ piece: Piece?, on square: Square) {
        let changes = self.piece(at: square) != piece
        guard changes || isLowConfidence(square) else { return }
        pushUndo()
        snapshot.lowConfidenceSquares.remove(square)
        if changes {
            changeBoard { $0[square.index] = piece }
            if piece != nil {
                lastPlacedSquare = square
                placementCount += 1
            }
        }
        refreshIssues()
    }

    /// Moves the piece on `from` to `to` (long press and drag).
    func move(from: Square, to: Square) {
        guard from != to, let moving = piece(at: from) else { return }
        pushUndo()
        snapshot.lowConfidenceSquares.remove(from)
        snapshot.lowConfidenceSquares.remove(to)
        changeBoard { board in
            board[to.index] = moving
            board[from.index] = nil
        }
        lastPlacedSquare = to
        placementCount += 1
        if selectedSquare == from { selectedSquare = to }
        refreshIssues()
    }

    /// Removes the piece on `square` (dragged off the board).
    func remove(at square: Square) {
        set(nil, on: square)
    }

    /// Confirms a low-confidence square as recognized, without changing it.
    func confirm(_ square: Square) {
        guard isLowConfidence(square) else { return }
        pushUndo()
        snapshot.lowConfidenceSquares.remove(square)
    }

    /// VoiceOver adjustable action: the next or previous item in `CapturePaletteItem.cycleOrder`.
    func cycle(_ square: Square, forward: Bool) {
        let order = CapturePaletteItem.cycleOrder
        let current = order.firstIndex(of: piece(at: square)) ?? 0
        let next = (current + (forward ? 1 : order.count - 1)) % order.count
        set(order[next], on: square)
    }

    // MARK: Side to move and castling

    func setSideToMove(_ color: PieceColor) {
        guard color != snapshot.position.sideToMove || snapshot.sideToMoveOrigin != .user else { return }
        pushUndo()
        snapshot = snapshot.withSideToMove(color)
        refreshIssues()
    }

    func switchSideToMove() {
        setSideToMove(snapshot.position.sideToMove.opposite)
    }

    /// The king and rook of `right` stand on their home squares.
    func isCastlingAvailable(_ right: CastlingRights) -> Bool {
        snapshot.position.inferredCastlingRights.contains(right)
    }

    func hasCastlingRight(_ right: CastlingRights) -> Bool {
        snapshot.position.castlingRights.contains(right)
    }

    func toggleCastling(_ right: CastlingRights) {
        guard isCastlingAvailable(right) else { return }
        pushUndo()
        if snapshot.position.castlingRights.contains(right) {
            snapshot.position.castlingRights.remove(right)
        } else {
            snapshot.position.castlingRights.insert(right)
        }
        snapshot.confirmCastlingRight(right)
        snapshot.position.removeInvalidEnPassant()
        refreshIssues()
    }

    // MARK: Whole-board commands

    /// The standard start position, White to move, all castling rights.
    func setStartPosition() {
        pushUndo()
        let whiteAtBottom = snapshot.whiteAtBottom
        snapshot.position = .start
        snapshot.whiteAtBottom = whiteAtBottom
        snapshot.sideToMoveOrigin = .user
        // The user chose the start position: castling there is not an assumption.
        snapshot.assumedCastlingRights = []
        snapshot.lowConfidenceSquares = []
        snapshot.lastMove = nil
        usedBoardReset = true
        selectedSquare = nil
        refreshIssues()
    }

    /// An empty board, keeping the side to move.
    func clearBoard() {
        pushUndo()
        let side = snapshot.position.sideToMove
        snapshot.position = .empty
        snapshot.position.sideToMove = side
        snapshot.assumedCastlingRights = []
        snapshot.lowConfidenceSquares = []
        snapshot.lastMove = nil
        usedBoardReset = true
        refreshIssues()
    }

    /// Back to the pieces as recognized, with the recognized side to move and marks.
    func resetToRecognized() {
        guard let recognized = original.recognizedBoard, recognized.count == 64 else { return }
        pushUndo()
        var position = original.position
        position.board = recognized
        position.removeInconsistentCastlingRights()
        position.removeInvalidEnPassant()
        snapshot.position = position
        snapshot.assumedCastlingRights = original.assumedCastlingRights
        snapshot.sideToMoveOrigin = original.sideToMoveOrigin
        snapshot.lowConfidenceSquares = original.lowConfidenceSquares
        snapshot.lastMove = original.lastMove
        usedBoardReset = false
        refreshIssues()
    }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        snapshot = step.snapshot
        usedBoardReset = step.usedBoardReset
        selectedSquare = step.selectedSquare
        canUndo = !undoStack.isEmpty
        refreshIssues()
    }

    /// The snapshot handed to `AppModel.finishEditing`: castling rights and en passant made
    /// consistent with the board. The screenshot crop, orientation and recognized pieces are
    /// kept, so Analysis can show the diagram with EDITED and peek at the original.
    func finishedSnapshot() -> BoardSnapshot {
        var result = snapshot
        result.position.removeInconsistentCastlingRights()
        result.position.removeInvalidEnPassant()
        return result
    }

    // MARK: Helpers

    /// Applies a board change. Castling rights the user had stay as long as they are still
    /// possible; a right that the change makes newly possible (king and rook back on their
    /// home squares) is granted, as `inferCastlingRights()` would, and counts as assumed. En
    /// passant is dropped unless still capturable.
    private func changeBoard(_ change: (inout [Piece?]) -> Void) {
        let before = snapshot.position.inferredCastlingRights
        change(&snapshot.position.board)
        let after = snapshot.position.inferredCastlingRights
        let granted = after.subtracting(before)
        snapshot.position.castlingRights = snapshot.position.castlingRights
            .intersection(after)
            .union(granted)
        snapshot.assumedCastlingRights.formUnion(granted)
        snapshot.position.removeInvalidEnPassant()
        if snapshot.lastMove != nil { snapshot.lastMove = nil }
    }

    private func pushUndo() {
        undoStack.append(UndoStep(snapshot: snapshot, usedBoardReset: usedBoardReset, selectedSquare: selectedSquare))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        canUndo = true
    }

    private func refreshIssues() {
        issues = snapshot.position.validate()
    }
}
