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
            return "\(name(color)) has no king."
        case .extraKings(let color):
            return "\(name(color)) has more than one king."
        case .pawnOnBackRank(let square):
            return "The pawn on \(square.algebraic) can't stand on the back rank."
        case .sideNotToMoveInCheck:
            let inCheck = position.sideToMove.opposite
            return "\(name(inCheck)) is in check but it's \(name(position.sideToMove))'s move."
        case .tooManyPieces(let color):
            // ChessCore reports four causes under this case (Position.validate()).
            let own = position.board.compactMap { $0 }.filter { $0.color == color }
            func count(_ kind: PieceKind) -> Int { own.filter { $0.kind == kind }.count }
            let pawns = count(.pawn)
            if pawns > 8 { return "\(name(color)) has more than 8 pawns." }
            if own.count > 16 { return "\(name(color)) has more than 16 pieces." }
            let promoted = max(count(.knight) - 2, 0) + max(count(.bishop) - 2, 0)
                + max(count(.rook) - 2, 0) + max(count(.queen) - 1, 0)
            if promoted > 8 - pawns {
                return "\(name(color)) has more queens, rooks, bishops or knights than its missing pawns could have promoted to."
            }
            return "\(name(color.opposite)) is in check from more than two pieces."
        case .noLegalMoves:
            return "No legal moves: checkmate or stalemate."
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
        color == .white ? "White" : "Black"
    }

    /// "White king", "Black pawn".
    static func name(_ piece: Piece) -> String {
        "\(name(piece.color)) \(kindName(piece.kind))"
    }

    static func kindName(_ kind: PieceKind) -> String {
        switch kind {
        case .pawn: "pawn"
        case .knight: "knight"
        case .bishop: "bishop"
        case .rook: "rook"
        case .queen: "queen"
        case .king: "king"
        }
    }

    /// The caption naming how the side to move was decided (design.md 9.4), or nil when the
    /// user chose it.
    static func sideToMoveCaption(_ origin: SideToMoveOrigin) -> String? {
        switch origin {
        case .lastMoveHighlight: "from last-move highlight"
        case .runningClock: "from the clock"
        case .checkRule: "from check"
        case .startPosition: "the game has not started"
        case .assumedBottomPlayer: "assumed: you are at the bottom"
        case .user: nil
        }
    }
}
