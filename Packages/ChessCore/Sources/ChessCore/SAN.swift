// Standard algebraic notation (SAN) output and parsing.

extension Position {
    /// SAN for a legal move: piece letter, disambiguation (file, then rank, then both),
    /// "x" for captures (including en passant), "=Q" style promotions, "O-O"/"O-O-O",
    /// and a "+" or "#" suffix. Nil when the move is not legal in this position.
    public func san(for move: Move) -> String? {
        let state = BoardState(self)
        let moves = state.legalMoves()
        guard let internalMove = moves.first(where: { $0.matches(move) }) else { return nil }
        return Position.san(internalMove, in: state, legalMoves: moves)
    }

    /// Converts a UCI principal variation to SAN, stopping at the first move that is
    /// malformed or illegal in the position reached so far.
    public func sanLine(_ uciMoves: [String]) -> [String] {
        var state = BoardState(self)
        var result: [String] = []
        result.reserveCapacity(uciMoves.count)
        for uci in uciMoves {
            guard let move = Move(uci: uci) else { break }
            let moves = state.legalMoves()
            guard let internalMove = moves.first(where: { $0.matches(move) }) else { break }
            result.append(Position.san(internalMove, in: state, legalMoves: moves))
            state.make(internalMove)
        }
        return result
    }

    /// The legal move written as `san`, or nil. Check/mate marks and annotation glyphs
    /// ("+", "#", "!", "?") are ignored, "0-0"/"0-0-0" are accepted for castling, and the
    /// "=" before a promotion piece is optional.
    public func move(fromSAN san: String) -> Move? {
        let target = Position.normalizedSAN(san)
        guard !target.isEmpty else { return nil }
        let state = BoardState(self)
        let moves = state.legalMoves()
        for internalMove in moves where Position.normalizedSAN(Position.san(internalMove, in: state, legalMoves: moves)) == target {
            return internalMove.publicMove
        }
        return nil
    }

    private static func normalizedSAN(_ san: String) -> String {
        var text = san.filter { !$0.isWhitespace && $0 != "=" }
        while let last = text.last, "+#!?".contains(last) { text.removeLast() }
        if text == "0-0" { return "O-O" }
        if text == "0-0-0" { return "O-O-O" }
        return text
    }

    static func san(_ move: InternalMove, in state: BoardState, legalMoves: [InternalMove]) -> String {
        let from = Int(move.from), to = Int(move.to)
        var text: String
        if move.flag == InternalMove.flagCastle {
            text = to > from ? "O-O" : "O-O-O"
        } else {
            let kind = state.kindCode(at: from)
            let isCapture = move.flag == InternalMove.flagEnPassant || state.occupied & bit(to) != 0
            let destination = Square(uncheckedIndex: to).algebraic
            if kind == 0 {
                text = isCapture ? "\(fileLetter(from))x\(destination)" : destination
                if move.promotion != 255 {
                    text += "=" + PieceKind(code: Int(move.promotion)).sanLetter
                }
            } else {
                text = PieceKind(code: kind).sanLetter
                let rivals = legalMoves.filter {
                    Int($0.to) == to && Int($0.from) != from && state.kindCode(at: Int($0.from)) == kind
                }
                if !rivals.isEmpty {
                    let shareFile = rivals.contains { Int($0.from) & 7 == from & 7 }
                    let shareRank = rivals.contains { Int($0.from) >> 3 == from >> 3 }
                    if !shareFile {
                        text.append(fileLetter(from))
                    } else if !shareRank {
                        text.append(String(from >> 3 + 1))
                    } else {
                        text += Square(uncheckedIndex: from).algebraic
                    }
                }
                if isCapture { text.append("x") }
                text += destination
            }
        }
        var after = state
        after.make(move)
        if after.isInCheck(after.side) {
            text.append(after.legalMoves().isEmpty ? "#" : "+")
        }
        return text
    }

    private static func fileLetter(_ square: Int) -> Character {
        Character(Unicode.Scalar(UInt8(97 + square & 7)))
    }
}
