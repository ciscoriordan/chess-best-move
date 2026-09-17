import ChessCore

/// The side-to-move rule from docs/ARCHITECTURE.md.
@_spi(Testing)
public enum SideToMoveRule {
    /// The side to move, where it came from, and reasons to doubt it.
    public struct Decision: Sendable, Equatable {
        public var side: PieceColor
        public var source: SideToMoveSource
        /// Reasons the side to move is doubtful; each becomes a low-confidence doubt.
        public var doubts: [String]
    }

    /// 1. A resolved last-move highlight: the side that did not make that move is to move.
    /// 2. Otherwise the side at the bottom of the screen, except in the start position, where
    ///    White is to move.
    /// Then, if the side that would not be to move is in check (and the chosen side is not),
    /// the other side must be to move: flip, with source `checkRule`.
    public static func infer(board: [Piece?], lastMover: PieceColor?, whiteAtBottom: Bool) -> (PieceColor, SideToMoveSource) {
        let decision = decide(board: board, lastMove: lastMover.map { LastMove(mover: $0, isPlausible: true) },
                              runningClockAtTop: nil, whiteAtBottom: whiteAtBottom)
        return (decision.side, decision.source)
    }

    /// What the side-to-move rule needs from a resolved last-move highlight.
    public struct LastMove: Sendable, Equatable {
        public var mover: PieceColor
        /// Whether the piece could have made the move (see `LastMoveResolver.Resolution`).
        public var isPlausible: Bool
        /// Printed in doubts, e.g. "g7d8".
        public var description: String

        public init(mover: PieceColor, isPlausible: Bool, description: String = "") {
            self.mover = mover
            self.isPlausible = isPlausible
            self.description = description
        }

        public init(_ resolution: LastMoveResolver.Resolution) {
            self.init(mover: resolution.mover, isPlausible: resolution.isPlausible,
                      description: resolution.from.algebraic + resolution.to.algebraic)
        }
    }

    /// The full rule, with the running clock:
    /// 1. A plausible last-move highlight decides. A running clock that disagrees is ignored: the
    ///    clock follows the live game, while the board may show a stepped-back move or a frozen
    ///    screen, and the highlight belongs to the board shown.
    /// 2. A highlight whose move the piece could not make (spurious tints) still decides when no
    ///    clock disagrees, with a doubt; a running clock that disagrees decides instead, also with
    ///    a doubt.
    /// 3. Without a highlight, the start position is White to move (source `runningClock` when
    ///    White's clock is the running one).
    /// 4. Otherwise the running clock (`runningClockAtTop`: whether the clock marked as running is
    ///    the top player's) decides, and without one the player at the bottom is to move.
    /// Then the check rule: if the side not chosen is in check and the chosen side is not, the
    /// other side must be to move (source `checkRule`, which settles any doubt above).
    public static func decide(board: [Piece?], lastMove: LastMove?, runningClockAtTop: Bool?, whiteAtBottom: Bool) -> Decision {
        let bottom: PieceColor = whiteAtBottom ? .white : .black
        let clockSide = runningClockAtTop.map { $0 ? bottom.opposite : bottom }
        var side: PieceColor
        var source: SideToMoveSource
        var doubts: [String] = []
        if let lastMove, lastMove.isPlausible || clockSide == nil || clockSide == lastMove.mover.opposite {
            side = lastMove.mover.opposite
            source = .lastMoveHighlight
            if !lastMove.isPlausible && clockSide == nil {
                doubts.append("side to move from a highlighted move the piece cannot make (\(lastMove.description))")
            }
        } else if board == Position.start.board {
            // No move has been made: White moves first, whatever a clock of the live game shows
            // (a game viewer stepped back to the start). The contract's sources have no case for
            // the start position, so it is reported as the running clock when White's clock runs
            // and otherwise as the default.
            side = .white
            source = clockSide == .white ? .runningClock : .bottomPlayerDefault
        } else if let clockSide {
            side = clockSide
            source = .runningClock
            if let lastMove {
                doubts.append("running clock contradicts a highlighted move the piece cannot make (\(lastMove.description))")
            }
        } else {
            side = bottom
            source = .bottomPlayerDefault
        }
        let position = Position(board: board, sideToMove: side)
        if position.isInCheck(side.opposite) && !position.isInCheck(side) {
            side = side.opposite
            source = .checkRule
            doubts = []
        }
        return Decision(side: side, source: source, doubts: doubts)
    }
}
