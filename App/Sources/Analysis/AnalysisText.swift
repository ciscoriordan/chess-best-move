// Text the Analysis screen shows and speaks: the spoken form of moves (design.md 12), the
// engine line with move numbers (9.4), and the data tokens for time and speed (section 4).

import ChessCore
import Foundation

// MARK: - Spoken moves

/// The captured piece and its square before a legal move is played. En passant removes a
/// pawn from a different square than the moving pawn's destination.
struct AnalysisCapture: Sendable, Hashable {
    var piece: Piece
    var square: Square

    static func find(for move: Move, in position: Position) -> Self? {
        guard position.board.count == 64, let moving = position.board[move.from.index] else { return nil }
        if let target = position.board[move.to.index], target.color != moving.color {
            return Self(piece: target, square: move.to)
        }
        guard moving.kind == .pawn, move.to == position.enPassant,
              abs(move.from.file - move.to.file) == 1,
              position.board[move.to.index] == nil,
              let square = Square(file: move.to.file, rank: move.from.rank),
              let target = position.board[square.index],
              target.kind == .pawn, target.color != moving.color
        else { return nil }
        return Self(piece: target, square: square)
    }
}

enum AnalysisSpeech {
    /// The spoken form of a SAN move, which is also the visible line under the hero move:
    /// "Knight takes f7, check", "Pawn to e8 promotes to queen, checkmate", "Castles kingside".
    ///
    /// The from-square is spoken when the SAN disambiguates (and for pawn captures, whose SAN
    /// names the file), or always when `alwaysIncludeFromSquare` is true (the board's VoiceOver
    /// value: "knight from g5 takes f7, check"). `move` supplies the full from-square; without
    /// it the SAN's disambiguation letters are spoken.
    static func moveDescription(
        san: String, move: Move? = nil, capture: AnalysisCapture? = nil,
        alwaysIncludeFromSquare: Bool = false
    ) -> String {
        var text = san.trimmingCharacters(in: .whitespaces)
        var checkmate = false
        var check = false
        if text.hasSuffix("#") {
            checkmate = true
            text.removeLast()
        } else if text.hasSuffix("+") {
            check = true
            text.removeLast()
        }
        while let last = text.last, "!?".contains(last) { text.removeLast() }

        func withCheck(_ words: String) -> String {
            if checkmate { return String(localized: "\(words), checkmate") }
            if check { return String(localized: "\(words), check") }
            return words
        }
        if text == "O-O-O" || text == "0-0-0" { return withCheck(String(localized: "Castles queenside")) }
        if text == "O-O" || text == "0-0" { return withCheck(String(localized: "Castles kingside")) }

        var promotion: PieceKind?
        if let equals = text.lastIndex(of: "=") {
            promotion = text[text.index(after: equals)...].first.flatMap { PieceKind(letter: $0) }
            text = String(text[..<equals])
        }

        let kind: PieceKind
        if let first = text.first, "KQRBN".contains(first), let parsed = PieceKind(letter: first) {
            kind = parsed
            text.removeFirst()
        } else {
            kind = .pawn
        }

        let isCapture = text.contains("x")
        text.removeAll { $0 == "x" }
        guard text.count >= 2 else { return san }
        let destination = String(text.suffix(2))
        let disambiguation = String(text.dropLast(2))

        var movingPiece = pieceName(kind)
        if alwaysIncludeFromSquare || !disambiguation.isEmpty {
            let origin = move?.from.algebraic ?? disambiguation
            movingPiece = String(localized: "\(movingPiece) from \(origin)", comment: "A chess piece with its origin square; this becomes the subject of a move description.")
        }
        var words: String
        if isCapture, let capture {
            let captured = capturePieceName(capture.piece.kind)
            if let move, capture.square != move.to {
                words = String(localized: "\(movingPiece) takes \(captured) on \(capture.square.algebraic) and moves to \(destination), en passant")
            } else {
                words = String(localized: "\(movingPiece) takes \(captured) on \(destination)")
            }
        } else if isCapture {
            words = String(localized: "\(movingPiece) takes \(destination)", comment: "Capture when the captured piece is unknown; second value is a square.")
        } else {
            words = String(localized: "\(movingPiece) to \(destination)")
        }
        if let promotion {
            let promoted = promotionPieceName(promotion)
            words = String(localized: "\(words) promotes to \(promoted)")
        }
        return withCheck(words)
    }

    /// "Best move: knight takes f7, check. White is ahead by 2.35 pawns." (design.md 9.4)
    static func completionAnnouncement(moveDescription: String, score: WhiteScore?) -> String {
        var text = String(localized: "Best move: \(lowercasingFirstLetter(moveDescription)).")
        if let score {
            text += " " + AnalysisScore.spoken(score) + "."
        }
        return text
    }

    /// "Their likely move: pawn to e4. Best reply: knight to f6. White is ahead by 0.35 pawns."
    /// (design.md 9.4). Said when the screenshot caught the turn of the player at the top: the
    /// screen shows the move the engine expects above the answer to it, and the announcement
    /// names them in the same order and with the same words as the heading and the pill, so
    /// the reply is never called the best move (owner decision 2026-09-21).
    static func replyAnnouncement(guessedMove: String, reply: String, score: WhiteScore?) -> String {
        var text = String(localized: "Their likely move: \(lowercasingFirstLetter(guessedMove)). Best reply: \(lowercasingFirstLetter(reply)).")
        if let score {
            text += " " + AnalysisScore.spoken(score) + "."
        }
        return text
    }

    /// What the board reads out when it carries both arrows (design.md section 7 and 12).
    ///
    /// The board is one accessibility element whose value is what is drawn on it, so with two
    /// arrows it has to say which move is whose, which order they happen in, and that the
    /// second one is conditional. A reader who cannot see the two colors or the two heads gets
    /// the whole of it from this sentence: "Two arrows. Their likely move first: pawn from e7
    /// to e5. Then your best reply, which holds only if they play it: knight from g8 to f6."
    /// It says "best reply" because the pill beside the badge does (owner decision 2026-09-21).
    ///
    /// Words only, never a symbol name, and never SAN letters.
    static func boardArrowPair(theirMove: String, reply: String, isFinal: Bool) -> String {
        if isFinal {
            return String(localized: "Two arrows. Their likely move first: \(lowercasingFirstLetter(theirMove)). Then your best reply, which holds only if they play it: \(lowercasingFirstLetter(reply)).")
        }
        return String(localized: "Two arrows so far. Their likely move first: \(lowercasingFirstLetter(theirMove)). Then your best reply, which holds only if they play it: \(lowercasingFirstLetter(reply)).")
    }

    /// What the board reads out when the only arrow on it is the other player's move: the
    /// engine's line stopped after one move, so there is no reply to draw (design.md 9.4).
    /// The arrow is not the cobalt one and the value does not call it a best move.
    static func boardTheirMoveOnly(theirMove: String, isFinal: Bool) -> String {
        isFinal
            ? String(localized: "Their likely move: \(lowercasingFirstLetter(theirMove)).")
            : String(localized: "Their likely move so far: \(lowercasingFirstLetter(theirMove)).")
    }

    /// The engine line for VoiceOver: the spoken form of the first `plies` moves, and "and so
    /// on" when the line runs longer than that.
    static func line(sanMoves: [String], plies: Int = 6) -> String {
        let spoken = sanMoves.prefix(plies).map { moveDescription(san: $0) }.joined(separator: "; ")
        return sanMoves.count > plies ? String(localized: "\(spoken); and so on") : spoken
    }

    /// What the engine's figures say in words, for the one element the depth, clock and speed
    /// are combined into. On screen they are abbreviated and set in a fixed monospaced column;
    /// spoken, "depth 20, 1.4 s slash 3 s, 2.1 M n slash s" names none of the three.
    static func engineFigures(depth: Int?, elapsed: Duration?, thinkTime: ThinkTime, nodesPerSecond: Int?) -> String {
        var parts: [String] = []
        parts.append(depth.map { String(localized: "depth \($0)") } ?? String(localized: "depth not reported yet"))
        if let elapsed {
            let seconds = AnalysisDataText.seconds(of: elapsed)
            parts.append(String(localized: "\(seconds, specifier: "%.1f") of \(thinkTime.spokenLabel)"))
        } else {
            parts.append(thinkTime.spokenLabel)
        }
        if let nodesPerSecond {
            parts.append(String(localized: "\(nodesPerSecond.formatted()) positions a second"))
        }
        return parts.joined(separator: ", ")
    }

    static func pieceName(_ kind: PieceKind) -> String {
        switch kind {
        case .pawn: String(localized: "Pawn", comment: "Chess piece, subject of a move description.")
        case .knight: String(localized: "Knight", comment: "Chess piece, subject of a move description.")
        case .bishop: String(localized: "Bishop", comment: "Chess piece, subject of a move description.")
        case .rook: String(localized: "Rook", comment: "Chess piece, subject of a move description.")
        case .queen: String(localized: "Queen", comment: "Chess piece, subject of a move description.")
        case .king: String(localized: "King", comment: "Chess piece, subject of a move description.")
        }
    }

    /// The object of "takes", including any article or case required by the language.
    /// Kept separate from the subject so both text and the captured-piece glyph use it.
    static func capturePieceName(_ kind: PieceKind) -> String {
        switch kind {
        case .pawn: String(localized: "pawn", comment: "Captured chess piece: object of takes. Include the appropriate definite article and accusative case where required.")
        case .knight: String(localized: "knight", comment: "Captured chess piece: object of takes. Include the appropriate definite article and accusative case where required.")
        case .bishop: String(localized: "bishop", comment: "Captured chess piece: object of takes. Include the appropriate definite article and accusative case where required.")
        case .rook: String(localized: "rook", comment: "Captured chess piece: object of takes. Include the appropriate definite article and accusative case where required.")
        case .queen: String(localized: "queen", comment: "Captured chess piece: object of takes. Include the appropriate definite article and accusative case where required.")
        case .king: String(localized: "king", comment: "Captured chess piece: object of takes. Include the appropriate definite article and accusative case where required.")
        }
    }

    static func promotionPieceName(_ kind: PieceKind) -> String {
        switch kind {
        case .pawn: String(localized: "promotion.pawn", defaultValue: "pawn", comment: "Chess piece after promotes to. Use the grammatical form after the translated promotion verb.")
        case .knight: String(localized: "promotion.knight", defaultValue: "knight", comment: "Chess piece after promotes to. Use the grammatical form after the translated promotion verb.")
        case .bishop: String(localized: "promotion.bishop", defaultValue: "bishop", comment: "Chess piece after promotes to. Use the grammatical form after the translated promotion verb.")
        case .rook: String(localized: "promotion.rook", defaultValue: "rook", comment: "Chess piece after promotes to. Use the grammatical form after the translated promotion verb.")
        case .queen: String(localized: "promotion.queen", defaultValue: "queen", comment: "Chess piece after promotes to. Use the grammatical form after the translated promotion verb.")
        case .king: String(localized: "promotion.king", defaultValue: "king", comment: "Chess piece after promotes to. Use the grammatical form after the translated promotion verb.")
        }
    }

    static func colorName(_ color: PieceColor) -> String {
        color == .white ? String(localized: "White") : String(localized: "Black")
    }

    static func lowercasingFirstLetter(_ text: String) -> String {
        // German nouns and other languages must retain their grammatical capitalization.
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("en") != false,
              let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// Pieces by square for the board's VoiceOver custom content: "White: king g1, queen d1; ...".
    static func pieceList(_ board: [Piece?]) -> String {
        PieceColor.allCases.map { color in
            let pieces = Square.all.compactMap { square -> (PieceKind, Square)? in
                guard board.indices.contains(square.index), let piece = board[square.index], piece.color == color
                else { return nil }
                return (piece.kind, square)
            }
            .sorted { lhs, rhs in
                let order: [PieceKind] = [.king, .queen, .rook, .bishop, .knight, .pawn]
                let left = order.firstIndex(of: lhs.0) ?? 0, right = order.firstIndex(of: rhs.0) ?? 0
                return left == right ? lhs.1.index < rhs.1.index : left < right
            }
            .map { "\(lowercasingFirstLetter(pieceName($0.0))) \($0.1.algebraic)" }
            let list = pieces.isEmpty ? String(localized: "no pieces") : pieces.joined(separator: ", ")
            return "\(colorName(color)): \(list)"
        }
        .joined(separator: "; ")
    }
}

// MARK: - Engine line

/// One token of the engine line: a move number ("12." or "12...") or a SAN move.
struct AnalysisLineToken: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case moveNumber
        case move
    }

    var text: String
    var kind: Kind
    /// The first move of the line, drawn in `accent`.
    var isFirstMove: Bool
}

enum AnalysisLine {
    /// Collapsed LINE row shows at most this many plies (design.md 9.4).
    static let collapsedPlies = 8

    /// "1. Nxf7+ Kxf7 2. Qh5+ g6"; with Black to move, "12... Nf6 13. Bd3". When `plies` cuts
    /// the line short, `isTruncated` is true and the view appends an ellipsis.
    static func tokens(sanMoves: [String], position: Position, plies: Int? = nil) -> (tokens: [AnalysisLineToken], isTruncated: Bool) {
        let limit = plies.map { min($0, sanMoves.count) } ?? sanMoves.count
        var tokens: [AnalysisLineToken] = []
        var moveNumber = max(1, position.fullmoveNumber)
        var color = position.sideToMove
        for (index, san) in sanMoves.prefix(limit).enumerated() {
            if color == .white {
                tokens.append(AnalysisLineToken(text: "\(moveNumber).", kind: .moveNumber, isFirstMove: false))
            } else if index == 0 {
                tokens.append(AnalysisLineToken(text: "\(moveNumber)...", kind: .moveNumber, isFirstMove: false))
            }
            tokens.append(AnalysisLineToken(text: san, kind: .move, isFirstMove: index == 0))
            if color == .black { moveNumber += 1 }
            color = color.opposite
        }
        return (tokens, limit < sanMoves.count)
    }

    /// The tokens joined with spaces, a no-break space after each move number.
    static func plainText(_ tokens: [AnalysisLineToken], isTruncated: Bool) -> String {
        var text = ""
        for token in tokens {
            if !text.isEmpty { text += text.hasSuffix(".") ? "\u{00A0}" : " " }
            text += token.text
        }
        return isTruncated ? text + " \u{2026}" : text
    }
}

// MARK: - Data tokens

enum AnalysisDataText {
    /// "1.4 s" with a no-break space (SF Mono has no narrow no-break space, U+202F).
    static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f\u{00A0}s", seconds(of: duration))
    }

    /// "1.4 s / 3 s" while thinking.
    static func clock(elapsed: Duration, thinkTime: ThinkTime) -> String {
        let clamped = min(seconds(of: elapsed), Double(thinkTime.seconds))
        return String(format: "%.1f\u{00A0}s / ", clamped) + thinkTime.label
    }

    /// "2.1 M n/s", "850 k n/s", "900 n/s".
    static func nodesPerSecond(_ nps: Int) -> String {
        if nps >= 1_000_000 {
            return String(format: "%.1f\u{00A0}M n/s", Double(nps) / 1_000_000)
        }
        if nps >= 1_000 {
            return "\(nps / 1_000)\u{00A0}k n/s"
        }
        return "\(nps)\u{00A0}n/s"
    }

    static func depth(_ depth: Int) -> String {
        String(localized: "depth \(depth)")
    }

    static func seconds(of duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
