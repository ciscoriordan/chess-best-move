import Foundation
import ChessCore

/// Plain-language explanations of `PositionIssue`s (design.md 9.6) and which of them block
/// analysis.
enum CapturePositionIssues {
    /// Issues that keep the engine from analyzing the position. `noLegalMoves` is not one of
    /// them: Analysis shows checkmate or stalemate directly.
    static func blocking(in position: Position) -> [PositionIssue] {
        position.validate().filter(isBlocking)
    }

    static func isBlocking(_ issue: PositionIssue) -> Bool {
        issue != .noLegalMoves
    }

    /// The sentence shown for `issue` in `position`.
    static func message(for issue: PositionIssue, in position: Position) -> String {
        switch issue {
        case .missingKing(let color):
            return String(localized: "\(name(color)) has no king.")
        case .extraKings(let color):
            return String(localized: "\(name(color)) has more than one king.")
        case .pawnOnBackRank(let square):
            return String(localized: "The pawn on \(square.algebraic) can't stand on the back rank.")
        case .sideNotToMoveInCheck:
            let inCheck = position.sideToMove.opposite
            return String(localized: "\(name(inCheck)) is in check but it's \(name(position.sideToMove))'s move.")
        case .tooManyPieces(let color):
            // ChessCore reports four causes under this case (Position.validate()).
            let own = position.board.compactMap { $0 }.filter { $0.color == color }
            func count(_ kind: PieceKind) -> Int { own.filter { $0.kind == kind }.count }
            let pawns = count(.pawn)
            if pawns > 8 { return String(localized: "\(name(color)) has more than 8 pawns.") }
            if own.count > 16 { return String(localized: "\(name(color)) has more than 16 pieces.") }
            let promoted = max(count(.knight) - 2, 0) + max(count(.bishop) - 2, 0)
                + max(count(.rook) - 2, 0) + max(count(.queen) - 1, 0)
            if promoted > 8 - pawns {
                return String(localized: "\(name(color)) has more queens, rooks, bishops or knights than its missing pawns could have promoted to.")
            }
            return String(localized: "\(name(color.opposite)) is in check from more than two pieces.")
        case .noLegalMoves:
            return String(localized: "No legal moves: checkmate or stalemate.")
        }
    }

    /// Squares to outline in `danger` on the board.
    static func dangerSquares(in issues: [PositionIssue]) -> Set<Square> {
        Set(issues.compactMap { issue in
            if case .pawnOnBackRank(let square) = issue { return square }
            return nil
        })
    }

    /// "White" or "Black".
    static func name(_ color: PieceColor) -> String {
        color == .white ? String(localized: "White") : String(localized: "Black")
    }

    /// "White king", "Black pawn".
    static func name(_ piece: Piece) -> String {
        switch (piece.color, piece.kind) {
        case (.white, .pawn): String(localized: "White pawn")
        case (.white, .knight): String(localized: "White knight")
        case (.white, .bishop): String(localized: "White bishop")
        case (.white, .rook): String(localized: "White rook")
        case (.white, .queen): String(localized: "White queen")
        case (.white, .king): String(localized: "White king")
        case (.black, .pawn): String(localized: "Black pawn")
        case (.black, .knight): String(localized: "Black knight")
        case (.black, .bishop): String(localized: "Black bishop")
        case (.black, .rook): String(localized: "Black rook")
        case (.black, .queen): String(localized: "Black queen")
        case (.black, .king): String(localized: "Black king")
        }
    }

    static func kindName(_ kind: PieceKind) -> String {
        switch kind {
        case .pawn: String(localized: "piece.pawn", defaultValue: "pawn", comment: "Standalone chess piece name in a board description; no article.")
        case .knight: String(localized: "piece.knight", defaultValue: "knight", comment: "Standalone chess piece name in a board description; no article.")
        case .bishop: String(localized: "piece.bishop", defaultValue: "bishop", comment: "Standalone chess piece name in a board description; no article.")
        case .rook: String(localized: "piece.rook", defaultValue: "rook", comment: "Standalone chess piece name in a board description; no article.")
        case .queen: String(localized: "piece.queen", defaultValue: "queen", comment: "Standalone chess piece name in a board description; no article.")
        case .king: String(localized: "piece.king", defaultValue: "king", comment: "Standalone chess piece name in a board description; no article.")
        }
    }
}
