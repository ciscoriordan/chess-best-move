import ChessCore
import CoreGraphics
import Foundation

/// Where `RecognitionResult.suggestedSideToMove` came from.
public enum SideToMoveSource: Sendable, Hashable {
    /// The last-move highlight was found: the side that did not make that move is to move.
    case lastMoveHighlight
    /// No highlight decided it, and the clock icon marks whose clock is running: that side is to
    /// move (`RunningClockReader`).
    case runningClock
    /// The side that would otherwise be to move gives check, so the other side must be to move.
    case checkRule
    /// The board is the start position, where White moves first by the rules of chess. It is not
    /// an assumption, so nothing is doubted and the app does not offer it as a guess.
    case startPosition
    /// No other evidence: the player at the bottom of the screen (who took the screenshot).
    case bottomPlayerDefault
}

/// One reason a recognition result is not confident. `RecognitionError.lowConfidence` carries a
/// result whose `doubts` are never empty; a confident result has none. Callers use the case to
/// tell the user what to do about it (the app's Check position screen), and `description` for
/// logs and the evaluation.
public enum RecognitionDoubt: Sendable, Hashable {
    /// The detected board's checkerboard verification score is below
    /// `BoardRecognizer.confidentBoardScore`: the image may not show a board at all.
    case weakBoard(score: Float)
    /// These squares are less than `BoardReadability.minimumVisibleFraction` inside the image,
    /// because the screenshot cuts the board off or the pixels are transparent. Nothing is known
    /// about them and their `squareConfidences` entry is 0.
    case squaresOutsideImage([Square])
    /// These squares are under something opaque drawn over the board (a banner, a card, a menu,
    /// a keyboard). Their `squareConfidences` entry is 0.
    case squaresCovered([Square])
    /// The board's squares are smaller than `BoardReadability.minimumCellSize`, where the
    /// classifier confuses piece colors and kinds with high probability. `cellPixels` is the
    /// square size in source-image pixels.
    case squaresTooSmall(cellPixels: Double)
    /// The image holds `count` boards (2 or more), so the wrong one may have been recognized.
    /// Only boards at least a quarter of the image's short side are counted.
    case severalBoards(count: Int)
    /// The board's light and dark squares are the other way round: an unusual theme, or a
    /// mirrored screenshot, which pixels alone cannot tell apart.
    case invertedSquareColors
    /// The calibrated probability of these squares' content is below
    /// `BoardRecognizer.confidentSquareProbability`.
    case uncertainSquares([Square])
    /// The recognized position breaks a rule of chess (`Position.validate`), so at least one
    /// square is misread. `reason` names the problems.
    case impossiblePosition(reason: String)
    /// These squares were relabeled to make the position possible (`PieceConsistency`).
    /// `detail` lists each square's old and new content.
    case relabeledSquares([Square], detail: String)
    /// No coordinate label confirms the orientation and the placement alone is not decisive.
    /// `reason` is the whole line, naming the evidence that is missing or disagrees.
    case orientation(reason: String)
    /// The side to move rests on evidence that may mislead, such as a highlighted move the piece
    /// standing there cannot have made. `reason` is the whole line, naming that evidence.
    case sideToMove(reason: String)
    /// The board's art (its square colors, or how colored its piece ink is) falls outside the
    /// range the classifier was trained on (`ThemeFamiliarity`), so its probabilities are not
    /// calibrated. `reason` names the statistics that are out of range.
    case unfamiliarBoardArt(reason: String)

    /// One line naming the doubt, as the logs and the evaluation print it.
    public var description: String {
        func names(_ squares: [Square]) -> String {
            squares.sorted { $0.index < $1.index }.map(\.algebraic).joined(separator: " ")
        }
        switch self {
        case .weakBoard(let score):
            return String(format: "weak board verification %.2f", score)
        case .squaresOutsideImage(let squares):
            return "squares outside the image: " + names(squares)
        case .squaresCovered(let squares):
            return "squares covered by something drawn over the board: " + names(squares)
        case .squaresTooSmall(let cellPixels):
            return String(format: "squares too small to read reliably: %.0f px", cellPixels)
        case .severalBoards(let count):
            return "more than one board in the image (\(count) found)"
        case .invertedSquareColors:
            return "square colors inverted (dark top-left square): unusual theme or mirrored image"
        case .uncertainSquares(let squares):
            return "uncertain squares: " + names(squares)
        case .impossiblePosition(let reason):
            return "impossible position: " + reason
        case .relabeledSquares(_, let detail):
            return "relabeled to make the position possible: " + detail
        case .orientation(let reason), .sideToMove(let reason):
            return reason
        case .unfamiliarBoardArt(let reason):
            return "board art outside the trained range: " + reason
        }
    }
}

/// Everything recognized from one screenshot.
public struct RecognitionResult: Sendable {
    /// The board in source-image pixels. It can extend slightly past the image edge when the
    /// screenshot cuts the board off.
    public var boardRect: CGRect
    /// The board cropped from the source image as displayed (not rotated).
    public var boardImage: CGImage
    public var whiteAtBottom: Bool
    /// 0.5...1: how strongly the evidence in `orientationEvidence` favors `whiteAtBottom`, as the
    /// logistic of `OrientationEstimator.combinedLogOdds`.
    ///
    /// It is a probability for the population its parts were fitted and measured on — real game
    /// positions whose board was read correctly — and not for everything a screenshot can hold.
    /// Measured over the 3,468 evaluated boards (2026-09-18, classifier 1.1.0): below 0.7 it is
    /// right 56% of the time (35 of 62), 0.7 to 0.9 55% (29 of 53), 0.9 to 0.99 71% (25 of 35),
    /// 0.99 to 0.999 88% (43 of 49), and from 0.999 up 99.5% (3,253 of 3,269).
    ///
    /// The optimism between 0.7 and 0.99 is 88 boards and comes from the input, not from the
    /// arithmetic: a slope fitted to remove it is 0.27 over all the sets and 0.53 over the four
    /// realistic ones, so no one factor fits both. Two populations produce it. All 34 wrong
    /// readings in those bands are boards whose pieces were misread, and the placement model is
    /// calibrated only for a board read correctly; and 22% of the rendered positions scatter
    /// pieces at random, which carries no orientation signal at all. The decisive-coordinate
    /// weight is not the cause: no board in those bands read coordinate evidence of 4 or more,
    /// and 77 of the 88 had nothing but the placement to go on.
    ///
    /// Do not use it as a threshold for accepting an orientation. `doubts` is the contract for
    /// that: `recognize` refuses any result that carries one, and every wrong orientation in the
    /// 0.7-to-0.99 bands carries one. Of the 2,420 results returned without a doubt, 2,419 have
    /// the right orientation.
    public var orientationConfidence: Float
    /// 64 entries indexed by `Square.index`, already corrected for orientation.
    public var pieces: [Piece?]
    /// Calibrated classifier probability (`SquareCalibration`) of the recognized content of each
    /// square, by `Square.index`; 0 for squares outside the image or covered.
    public var squareConfidences: [Float]
    /// The highlighted squares the last move was read from (castling: as highlighted, e.g. king
    /// and rook start squares), plus a selected piece of the side to move in the same tint.
    /// Empty when no last move was found; tints that form no move (a premove, a square mark)
    /// are not listed.
    public var highlightedSquares: [Square]
    /// The last move derived from the highlight (castling as the king's move, e.g. e1g1).
    public var lastMove: (from: Square, to: Square)?
    public var suggestedSideToMove: PieceColor
    public var sideToMoveSource: SideToMoveSource
    /// Why the result is not confident, in the order they were found; empty for a confident
    /// result. `recognize` throws `RecognitionError.lowConfidence` whenever this is not empty.
    public var doubts: [RecognitionDoubt]

    // Diagnostics beyond the architecture contract.

    /// Checkerboard verification score of the detected board, -1...1 (real boards: above 0.5).
    public var boardScore: Float
    /// Orientation evidence as log-odds for white at the bottom, split by source.
    public var orientationEvidence: OrientationEvidence
    /// Time spent in `recognize`, in seconds, by stage.
    public var timings: [String: Double]

    public init(
        boardRect: CGRect,
        boardImage: CGImage,
        whiteAtBottom: Bool,
        orientationConfidence: Float,
        pieces: [Piece?],
        squareConfidences: [Float],
        highlightedSquares: [Square],
        lastMove: (from: Square, to: Square)?,
        suggestedSideToMove: PieceColor,
        sideToMoveSource: SideToMoveSource,
        doubts: [RecognitionDoubt] = [],
        boardScore: Float = 1,
        orientationEvidence: OrientationEvidence = OrientationEvidence(),
        timings: [String: Double] = [:]
    ) {
        self.boardRect = boardRect
        self.boardImage = boardImage
        self.whiteAtBottom = whiteAtBottom
        self.orientationConfidence = orientationConfidence
        self.pieces = pieces
        self.squareConfidences = squareConfidences
        self.highlightedSquares = highlightedSquares
        self.lastMove = lastMove
        self.suggestedSideToMove = suggestedSideToMove
        self.sideToMoveSource = sideToMoveSource
        self.doubts = doubts
        self.boardScore = boardScore
        self.orientationEvidence = orientationEvidence
        self.timings = timings
    }

    /// Pieces plus the suggested side to move, castling rights granted wherever king and rook
    /// stand on their home squares (except a right the last move proves lost: the king or that
    /// rook just arrived on its home square), and the en passant square when the last move was a
    /// double pawn push that the side to move can capture. Halfmove clock 0, fullmove number 1.
    public func position() -> Position {
        PositionAssembler.position(pieces: pieces, sideToMove: suggestedSideToMove, lastMove: lastMove)
    }
}

/// Orientation evidence as log-odds in favor of white at the bottom (positive) or black at the
/// bottom (negative). Zero means no evidence from that source.
public struct OrientationEvidence: Sendable, Hashable {
    /// Coordinate labels read with Vision text recognition.
    public var textRecognition: Double = 0
    /// Coordinate label glyph shapes (ascenders of b, d, f, h; the narrow "1"), from labels in
    /// either inside-board corner or outside the board.
    public var glyphShapes: Double = 0
    /// Piece placement: a model of where pieces stand in real games, calibrated per piece count
    /// (`OrientationEstimator.pieceLogOdds`).
    public var piecePlacement: Double = 0
    /// Direction of a highlighted pawn move, castling geometry, or the legal-move dots of a
    /// selected pawn.
    public var lastMove: Double = 0
    /// The board shows the standard start position for one orientation.
    public var startPosition: Double = 0

    public init() {}

    public var total: Double { textRecognition + glyphShapes + piecePlacement + lastMove + startPosition }
}

public enum RecognitionError: Error, Sendable {
    /// No chessboard was found in the image.
    case boardNotFound
    /// A board was found but some part of the recognition is doubtful (weak board
    /// verification, a low-confidence square, a position that cannot be right such as a missing
    /// king, an orientation no coordinates confirm on a sparse board, or a side to move read from
    /// a highlighted move the piece cannot make). The result is still complete and can be shown
    /// for confirmation.
    case lowConfidence(RecognitionResult)
    /// The image could not be read.
    case invalidImage
}

/// Errors from loading the piece classifier (thrown by `BoardRecognizer.init()`).
public enum ModelLoadError: LocalizedError, Sendable, CustomStringConvertible {
    /// `Model/PieceClassifier.mlmodelc` is not in the package bundle.
    case modelNotFound
    /// The model exists but does not match the contract in docs/ARCHITECTURE.md.
    case incompatibleModel(String)

    public var description: String {
        switch self {
        case .modelNotFound:
            return "PieceClassifier.mlmodelc is missing from ChessVision's Model folder; train and compile it with training/ first"
        case .incompatibleModel(let reason):
            return "PieceClassifier.mlmodelc does not match the model contract: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}

/// Builds the engine position from recognized pieces.
@_spi(Testing)
public enum PositionAssembler {
    public static func position(pieces: [Piece?], sideToMove: PieceColor, lastMove: (from: Square, to: Square)?) -> Position {
        var position = Position(board: pieces, sideToMove: sideToMove)
        position.inferCastlingRights()
        position.removeInconsistentCastlingRights()
        if let lastMove {
            position.castlingRights.subtract(rightsLost(board: pieces, lastMove: lastMove))
            position.enPassant = position.enPassantSquare(lastMoveFrom: lastMove.from, to: lastMove.to)
        }
        return position
    }

    /// Castling rights the last move proves lost: a king that just arrived on its home square
    /// has moved (both rights), and so has a rook that just arrived on its corner (that side's
    /// right). Castling itself is reported as the king's move (e1g1), which never ends on a home
    /// square.
    static func rightsLost(board: [Piece?], lastMove: (from: Square, to: Square)) -> CastlingRights {
        guard let piece = board[lastMove.to.index] else { return [] }
        let homeRank = piece.color == .white ? 0 : 7
        guard lastMove.to.rank == homeRank else { return [] }
        let kingside: CastlingRights = piece.color == .white ? .whiteKingside : .blackKingside
        let queenside: CastlingRights = piece.color == .white ? .whiteQueenside : .blackQueenside
        switch (piece.kind, lastMove.to.file) {
        case (.king, 4): return [kingside, queenside]
        case (.rook, 7): return kingside
        case (.rook, 0): return queenside
        default: return []
        }
    }
}
