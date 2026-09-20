// Text the Analysis screen shows and speaks: the spoken form of moves (design.md 12), the
// engine line with move numbers (9.4), and the data tokens for time and speed (section 4).

import ChessCore
import Foundation

// MARK: - Spoken moves

enum AnalysisSpeech {
    /// The spoken form of a SAN move, which is also the visible line under the hero move:
    /// "Knight takes f7, check", "Pawn to e8 promotes to queen, checkmate", "Castles kingside".
    ///
    /// The from-square is spoken when the SAN disambiguates (and for pawn captures, whose SAN
    /// names the file), or always when `alwaysIncludeFromSquare` is true (the board's VoiceOver
    /// value: "knight from g5 takes f7, check"). `move` supplies the full from-square; without
    /// it the SAN's disambiguation letters are spoken.
    static func moveDescription(san: String, move: Move? = nil, alwaysIncludeFromSquare: Bool = false) -> String {
        var text = san.trimmingCharacters(in: .whitespaces)
        var suffix = ""
        if text.hasSuffix("#") {
            suffix = ", checkmate"
            text.removeLast()
        } else if text.hasSuffix("+") {
            suffix = ", check"
            text.removeLast()
        }
        while let last = text.last, "!?".contains(last) { text.removeLast() }

        if text == "O-O-O" || text == "0-0-0" { return "Castles queenside" + suffix }
        if text == "O-O" || text == "0-0" { return "Castles kingside" + suffix }

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

        var words = pieceName(kind)
        if alwaysIncludeFromSquare || !disambiguation.isEmpty {
            words += " from " + (move?.from.algebraic ?? disambiguation)
        }
        words += isCapture ? " takes " : " to "
        words += destination
        if let promotion {
            words += " promotes to " + pieceName(promotion).lowercased()
        }
        return words + suffix
    }

    /// "Best move: knight takes f7, check. White is ahead by 2.35 pawns." (design.md 9.4)
    static func completionAnnouncement(moveDescription: String, score: WhiteScore?) -> String {
        var text = "Best move: " + lowercasingFirstLetter(moveDescription) + "."
        if let score {
            text += " " + AnalysisScore.spoken(score) + "."
        }
        return text
    }

    /// "If they play pawn to e4: best move knight to f6. White is ahead by 0.35 pawns."
    /// (design.md 9.4). Said when the screenshot caught the turn of the player at the top: the
    /// screen leads with the answer, so the announcement names the move it answers first.
    static func replyAnnouncement(guessedMove: String, reply: String, score: WhiteScore?) -> String {
        var text = "If they play " + lowercasingFirstLetter(guessedMove)
            + ": best move " + lowercasingFirstLetter(reply) + "."
        if let score {
            text += " " + AnalysisScore.spoken(score) + "."
        }
        return text
    }

    /// The engine line for VoiceOver: the spoken form of the first `plies` moves, and "and so
    /// on" when the line runs longer than that.
    static func line(sanMoves: [String], plies: Int = 6) -> String {
        let spoken = sanMoves.prefix(plies).map { moveDescription(san: $0) }.joined(separator: "; ")
        return sanMoves.count > plies ? spoken + "; and so on" : spoken
    }

    /// What the engine's figures say in words, for the one element the depth, clock and speed
    /// are combined into. On screen they are abbreviated and set in a fixed monospaced column;
    /// spoken, "depth 20, 1.4 s slash 3 s, 2.1 M n slash s" names none of the three.
    static func engineFigures(depth: Int?, elapsed: Duration?, thinkTime: ThinkTime, nodesPerSecond: Int?) -> String {
        var parts: [String] = []
        parts.append(depth.map { "depth \($0)" } ?? "depth not reported yet")
        if let elapsed {
            let seconds = AnalysisDataText.seconds(of: elapsed)
            parts.append(String(format: "%.1f of %d seconds", seconds, thinkTime.seconds))
        } else {
            parts.append("\(thinkTime.seconds) seconds")
        }
        if let nodesPerSecond {
            parts.append("\(nodesPerSecond.formatted()) positions a second")
        }
        return parts.joined(separator: ", ")
    }

    static func pieceName(_ kind: PieceKind) -> String {
        switch kind {
        case .pawn: "Pawn"
        case .knight: "Knight"
        case .bishop: "Bishop"
        case .rook: "Rook"
        case .queen: "Queen"
        case .king: "King"
        }
    }

    static func colorName(_ color: PieceColor) -> String {
        color == .white ? "White" : "Black"
    }

    static func lowercasingFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
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
            .map { "\(pieceName($0.0).lowercased()) \($0.1.algebraic)" }
            let list = pieces.isEmpty ? "no pieces" : pieces.joined(separator: ", ")
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
        "depth \(depth)"
    }

    static func seconds(of duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
