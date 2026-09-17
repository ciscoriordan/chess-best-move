// Sanity checks that decide whether a recognized or edited position can go to the engine.

public enum PositionIssue: Sendable, Hashable {
    case missingKing(PieceColor)
    case extraKings(PieceColor)
    case pawnOnBackRank(Square)
    case sideNotToMoveInCheck
    /// One color has more pieces than a game can produce, which Stockfish refuses:
    /// - more than 16 pieces or more than 8 pawns;
    /// - more promoted-type pieces than missing pawns, counting each knight, bishop or rook
    ///   beyond two and each queen beyond one (for example 8 pawns and a third knight);
    /// - the color gives check with more than two pieces at once.
    case tooManyPieces(PieceColor)
    /// Checkmate or stalemate: the side to move has no legal move.
    case noLegalMoves
}

extension PositionIssue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingKing(let color): return "\(color == .white ? "White" : "Black") has no king"
        case .extraKings(let color): return "\(color == .white ? "White" : "Black") has more than one king"
        case .pawnOnBackRank(let square): return "Pawn on \(square.algebraic) (first or last rank)"
        case .sideNotToMoveInCheck: return "The side that is not to move is in check"
        case .tooManyPieces(let color): return "\(color == .white ? "White" : "Black") has too many pieces"
        case .noLegalMoves: return "The side to move has no legal moves"
        }
    }
}

extension Position {
    /// Problems that make the position unusable for analysis. An empty result means the
    /// position is legal enough for the engine: every board Stockfish's FEN parser or the
    /// engine bridge refuses (wrong king count, pawns on the back ranks, too many pieces or
    /// promoted pieces, the side not to move in check, more than two checkers) has an issue.
    ///
    /// Issues come in this order: missing kings, extra kings, pawns on the first or last
    /// rank (by square index), too many pieces, side not to move in check, no legal moves.
    /// `noLegalMoves` is only reported when both sides have exactly one king.
    /// `sideNotToMoveInCheck` considers every king of that color. More than two pieces giving
    /// check to a king of the side to move is reported as `tooManyPieces` of the checking color.
    public func validate() -> [PositionIssue] {
        let state = BoardState(self)
        var issues: [PositionIssue] = []

        for color in PieceColor.allCases {
            if state.pieces(color.code, 5) == 0 { issues.append(.missingKing(color)) }
        }
        for color in PieceColor.allCases {
            if state.pieces(color.code, 5).nonzeroBitCount > 1 { issues.append(.extraKings(color)) }
        }

        let backRanks: Bitboard = 0xFF | (0xFF << 56)
        var misplacedPawns = state.kind(0) & backRanks
        while misplacedPawns != 0 {
            let index = misplacedPawns.trailingZeroBitCount
            misplacedPawns &= misplacedPawns - 1
            issues.append(.pawnOnBackRank(Square(uncheckedIndex: index)))
        }

        let occupied = state.occupied
        for color in PieceColor.allCases {
            let code = color.code
            let pawns = state.pieces(code, 0).nonzeroBitCount
            // Stockfish's rule (position.cpp): every knight, bishop or rook beyond two and every
            // queen beyond one needs a promotion, and each promotion uses up one of the 8 pawns.
            let promoted = max(state.pieces(code, 1).nonzeroBitCount - 2, 0)
                + max(state.pieces(code, 2).nonzeroBitCount - 2, 0)
                + max(state.pieces(code, 3).nonzeroBitCount - 2, 0)
                + max(state.pieces(code, 4).nonzeroBitCount - 1, 0)
            // The engine bridge refuses more than two checkers: a single move gives at most two.
            var tooManyCheckers = false
            if color == sideToMove.opposite {
                var kings = state.pieces(sideToMove.code, 5)
                while kings != 0, !tooManyCheckers {
                    let king = kings.trailingZeroBitCount
                    kings &= kings - 1
                    tooManyCheckers = (state.attackers(to: king, occupied: occupied) & state.color(code)).nonzeroBitCount > 2
                }
            }
            if state.color(code).nonzeroBitCount > 16 || pawns > 8 || promoted > 8 - pawns || tooManyCheckers {
                issues.append(.tooManyPieces(color))
            }
        }

        if state.isInCheck(sideToMove.opposite.code) {
            issues.append(.sideNotToMoveInCheck)
        }

        let oneKingEach = state.pieces(0, 5).nonzeroBitCount == 1 && state.pieces(1, 5).nonzeroBitCount == 1
        if oneKingEach && state.legalMoves().isEmpty {
            issues.append(.noLegalMoves)
        }

        return issues
    }
}
