import ChessCore
import Foundation

extension BoardMovePlayback {
    static func make(position: Position, moves: [Move], whiteAtBottom: Bool) -> BoardMovePlayback? {
        guard (1...2).contains(moves.count) else { return nil }
        var position = position
        var steps: [Step] = []
        func board(_ position: Position) -> [String?] { position.board.map { $0.map { String($0.fenCharacter) } } }
        for move in moves.prefix(2) {
            guard let piece = position.board[move.from.index], let next = position.applying(move) else { return nil }
            var moving = [MovingPiece(piece: String(piece.fenCharacter), from: move.from.index, to: move.to.index)]
            if piece.kind == .king, abs(move.from.file - move.to.file) == 2 {
                let rank = move.from.rank * 8
                let from = rank + (move.to.file > move.from.file ? 7 : 0)
                let to = rank + (move.to.file > move.from.file ? 5 : 3)
                guard let rook = position.board[from] else { return nil }
                moving.append(MovingPiece(piece: String(rook.fenCharacter), from: from, to: to))
            }
            steps.append(Step(before: board(position), after: board(next), moving: moving))
            position = next
        }
        let playback = BoardMovePlayback(steps: steps, whiteAtBottom: whiteAtBottom)
        return playback.isValid ? playback : nil
    }
}
