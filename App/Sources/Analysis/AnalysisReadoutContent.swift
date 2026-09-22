import ChessCore

/// What the Analysis result readout shows (design.md 9.4), derived from the run state, the
/// board and the engine's line and from nothing else, so it can be read and checked without
/// building the view.
///
/// The readout is one badge with the move in it, a pill and the evaluation beside the badge,
/// and, when the screenshot caught the turn of the player at the top, the move of that player
/// which the badge's move answers, shown above the badge because it is played first (owner
/// decisions of 2026-09-20, `build/ui-requests.md` items 1, 2 and 3, and of 2026-09-21).
struct AnalysisReadoutContent: Sendable, Hashable {
    /// What the screen is doing, from `AnalysisScreenModel.RunState`. The readout keeps the
    /// same shape in every one of them, so nothing jumps when the engine finishes.
    enum Status: Sendable, Hashable {
        /// Nothing has run yet (for example while a purchase is pending).
        case notRun
        case thinking
        case done
        /// Stop was pressed, or the app went to the background mid-search.
        case stopped
        case engineError
    }

    /// The pill beside the badge. It replaced the cobalt swatch and the BEST MOVE label (owner
    /// decision, item 1). It is drawn in the accent only while the badge holds an answer for the
    /// player at the bottom: "Best move" on their own turn, "Best reply" when the screenshot
    /// caught the other turn and the badge answers the move shown above it.
    struct Pill: Sendable, Hashable {
        /// Sentence case; the `label` token draws it uppercase and VoiceOver reads this.
        var title: String
        /// Accent fill with `onAccent` text; otherwise the muted ink fill with `canvas` text.
        var isAccent: Bool
    }

    /// One move as the readout shows it: the move itself for the board, the SAN for the eye,
    /// the same move in words for the line under it and for VoiceOver, and the piece whose
    /// glyph is drawn next to the words (item 3). `piece` is nil only when the board has
    /// nothing on the move's from-square, which a legal move cannot do.
    ///
    /// The move travels with its own words so that the arrow on the board and the sentence
    /// under it are read off the same value. Deriving the arrow a second way is how the two
    /// would come to name different moves.
    struct MoveText: Sendable, Hashable {
        var move: Move
        var san: String
        var words: String
        var piece: Piece?
    }

    var pill: Pill
    /// The move in the badge. Nil when there is no move to show: before the first one arrives,
    /// after a failure, and on a board with no legal moves.
    var move: MoveText?
    /// What the badge shows instead of a move.
    var placeholder: String
    /// True when `placeholder` is the result itself ("Checkmate", "Stalemate"), which is read
    /// out and drawn in full ink; false for the waiting marks, which are `ink3` and silent.
    var placeholderIsResult: Bool
    /// The move of the player at the top that `move` answers, when the screenshot caught that
    /// player's turn (item 2). It is shown above the badge under "Their likely move". Nil in
    /// every other case, including a side the user chose and a line too short to hold a reply.
    var guessedMove: MoveText?
    /// The screenshot caught the turn of the player at the top, so the move the engine found
    /// on this board belongs to that player rather than to the user.
    ///
    /// It is stored rather than inferred from `guessedMove`, because the two come apart in the
    /// case that matters to the board: a line with no reply in it yet leaves `guessedMove` nil
    /// and puts THEIR move in the badge, and an arrow for that move must not be cobalt.
    var answersForThePlayerAtTheTop = false
    /// The engine is still searching a board on which the player at the top moves, and its line
    /// holds no reply yet: before its first report, and while that report is the only one on
    /// screen, since `AnalysisReadoutAccumulator` shows the first report at once and its line is
    /// usually one move long. The view keeps the guessed move's place above the badge with a
    /// silent waiting mark, so the badge does not drop when the reply arrives a moment later
    /// (design.md 9.3).
    var guessedMoveIsPending = false

    /// The badge's move answers `guessedMove`, so it is drawn in the accent: cobalt is the
    /// answer, and the guessed move above it is muted ink (item 2).
    var moveIsReply: Bool { guessedMove != nil && move != nil }

    /// The arrows the board draws, in the order the moves are played (design.md section 7).
    ///
    /// Both come from this readout rather than from the engine a second time, so the board and
    /// the words under it always name the same moves. Three shapes come out of it:
    ///
    /// - the ordinary case, the user's own turn: one cobalt arrow, exactly as before;
    /// - the screenshot caught the other turn and the line holds a reply: their move first,
    ///   the reply second;
    /// - the same turn with no reply in the line yet (a mate, or a search that has not gone
    ///   deep enough): one arrow, and because it is their move it is not the cobalt one.
    var boardArrows: [AnalysisBoardArrow] {
        guard let move else { return [] }
        if let guessed = guessedMove {
            return [
                AnalysisBoardArrow(move: guessed.move, role: .theirMove),
                AnalysisBoardArrow(move: move.move, role: .answer),
            ]
        }
        return [AnalysisBoardArrow(move: move.move, role: answersForThePlayerAtTheTop ? .theirMove : .answer)]
    }

    /// What VoiceOver reads for the move in the badge.
    ///
    /// The readout is read one element at a time, and the badge does not always hold the same
    /// player's move: when the screenshot caught the turn of the player at the top it holds the
    /// user's reply if the engine's line has one, and that player's own move if it does not.
    /// Read in order the elements now make a true sentence - "Their likely move: pawn to e4.
    /// Best reply. Knight to f6." - but a reader who lands on the badge alone (touch
    /// exploration, or swiping back to it) hears only the badge, and "Knight to f6" by itself
    /// does not say that it is the reply or that it holds only if the other move is played.
    ///
    /// So the reply carries its own condition, after the move so the move is heard first:
    /// "Knight to f6, if they play pawn to e4." It no longer opens with "Best answer": the pill
    /// read just before it says "Best reply" (owner decision 2026-09-21), and the old prefix
    /// was only there because that pill used to say "Their move".
    var spokenMove: String? {
        guard let move else { return nil }
        guard let guessed = guessedMove else { return move.words }
        return move.words + ", if they play " + AnalysisSpeech.lowercasingFirstLetter(guessed.words) + "."
    }

    // MARK: Copy

    /// The heading above the badge that names the guessed move (owner decision 2026-09-21).
    /// Sentence case: the `sectionLabel` token draws it uppercase and VoiceOver reads this. It
    /// names the player by their move, never by their part in a game (design.md 14).
    static let guessedMoveTitle = "Their likely move"

    /// The line under that heading, after the piece glyph: the move as notation, then the same
    /// move in words, "e4  Pawn to e4", with an em space between them so they read as two
    /// things. Where that does not fit on one line (the accessibility text sizes), the words go
    /// to a line of their own, "Be2" / "Bishop to e2", rather than breaking inside the words,
    /// "Be2  Bishop" / "to e2".
    static func guessedMoveText(_ move: MoveText, onOneLine: Bool = true) -> String {
        guessedMoveText(san: move.san, words: move.words, onOneLine: onOneLine)
    }

    static func guessedMoveText(san: String, words: String, onOneLine: Bool = true) -> String {
        san + (onOneLine ? "\u{2003}" : "\n") + words
    }

    /// The sentence under the badge. The whole point of the readout in this case is that one
    /// move of it is not on the board, so the screen says it in plain words.
    static let guessedMoveNote =
        "Their move is a guess from the engine's own line. This answer holds only if they play it."

    /// What VoiceOver reads for the heading and the line under it, which are one element:
    /// words only, never a symbol name or notation (item 3, design.md 12).
    static func spokenGuessedMove(_ move: MoveText) -> String {
        guessedMoveTitle + ": " + AnalysisSpeech.lowercasingFirstLetter(move.words) + "."
    }

    // MARK: Building it

    static func make(
        status: Status,
        position: Position,
        whiteAtBottom: Bool,
        sideToMoveOrigin: SideToMoveOrigin,
        bestMove: (move: Move, san: String)?,
        principalVariation: [String],
        noLegalMoves: Bool?,
        quickAnswerIsBeaten: Bool = false
    ) -> AnalysisReadoutContent {
        let answersForThePlayerAtTheTop = SideToMoveCopy.answersForThePlayerAtTheTop(
            side: position.sideToMove,
            whiteAtBottom: whiteAtBottom,
            origin: sideToMoveOrigin
        )
        var move: MoveText?
        var guessedMove: MoveText?
        if noLegalMoves == nil, let best = bestMove {
            let onTheBoard = moveText(san: best.san, move: best.move, in: position)
            if answersForThePlayerAtTheTop,
               let reply = reply(to: best.move, in: position, principalVariation: principalVariation) {
                // The player at the top moves on this board, so the engine's best move is
                // theirs. The answer the user came for is the next move of the same line.
                move = reply
                guessedMove = onTheBoard
            } else {
                move = onTheBoard
            }
        }
        return AnalysisReadoutContent(
            pill: pill(
                status: status,
                noLegalMoves: noLegalMoves,
                answersForThePlayerAtTheTop: answersForThePlayerAtTheTop,
                hasReply: guessedMove != nil,
                quickAnswerIsBeaten: quickAnswerIsBeaten
            ),
            move: move,
            placeholder: placeholder(status: status, noLegalMoves: noLegalMoves),
            placeholderIsResult: noLegalMoves != nil,
            guessedMove: guessedMove,
            answersForThePlayerAtTheTop: answersForThePlayerAtTheTop,
            guessedMoveIsPending: status == .thinking && answersForThePlayerAtTheTop
                && noLegalMoves == nil && guessedMove == nil
        )
    }

    /// The pill's words and color. The accent is the answer for the player at the bottom: BEST
    /// MOVE on their own turn, and BEST REPLY when the screenshot caught the turn of the player
    /// at the top and the badge answers the move shown above it. The pill describes the move
    /// beside it; the heading above the badge is what says whose turn it is (owner decision
    /// 2026-09-21). The muted ink covers the same turn when the engine's line holds no reply
    /// yet, where the badge holds that player's own move and the pill says THEIR MOVE, and
    /// every state in which there is no answer to give.
    ///
    /// Once the longer search has beaten the move in the badge, the pill is what says so
    /// (`build/ui-requests.md` item 8): the app never calls a move the best one after it has
    /// found a better one, and QUICK ANSWER is the honest name for what is on screen until the
    /// user takes the deeper move. It is one label rather than a second one somewhere else.
    private static func pill(
        status: Status,
        noLegalMoves: Bool?,
        answersForThePlayerAtTheTop: Bool,
        hasReply: Bool,
        quickAnswerIsBeaten: Bool = false
    ) -> Pill {
        guard noLegalMoves == nil else { return Pill(title: "No legal moves", isAccent: false) }
        if quickAnswerIsBeaten, status == .done {
            return Pill(title: "Quick answer", isAccent: false)
        }
        return switch status {
        case .notRun: Pill(title: "Best move", isAccent: false)
        // The accent is reserved for an answer the app can give (design.md 9.4). While the
        // engine is still searching the badge holds a waiting mark, so the pill is muted ink
        // whichever side the screenshot caught.
        case .thinking: Pill(title: "Thinking", isAccent: false)
        case .done where !answersForThePlayerAtTheTop: Pill(title: "Best move", isAccent: true)
        case .done where hasReply: Pill(title: "Best reply", isAccent: true)
        case .done: Pill(title: "Their move", isAccent: false)
        case .stopped: Pill(title: "Stopped", isAccent: false)
        case .engineError: Pill(title: "Engine error", isAccent: false)
        }
    }

    private static func placeholder(status: Status, noLegalMoves: Bool?) -> String {
        if let checkmate = noLegalMoves { return checkmate ? "Checkmate" : "Stalemate" }
        return status == .thinking ? "\u{2026}" : "\u{2014}"
    }

    private static func moveText(san: String, move: Move, in position: Position) -> MoveText {
        MoveText(
            move: move,
            san: san,
            words: AnalysisSpeech.moveDescription(san: san, move: move),
            piece: position.board.indices.contains(move.from.index) ? position.board[move.from.index] : nil
        )
    }

    /// The answer the engine's own line gives to `theirMove`: the line's second move, read on
    /// the board that follows the first one. Nothing is computed beyond that (item 2), so a
    /// line that does not start with the move shown, or that stops after one move (a mate, or
    /// a search that has not gone deeper yet), simply has no reply to show.
    private static func reply(
        to theirMove: Move,
        in position: Position,
        principalVariation: [String]
    ) -> MoveText? {
        guard principalVariation.first == theirMove.uci,
              principalVariation.count > 1,
              let move = Move(uci: principalVariation[1]),
              let after = position.applying(theirMove),
              let san = after.san(for: move)
        else { return nil }
        return moveText(san: san, move: move, in: after)
    }
}
