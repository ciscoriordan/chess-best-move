import ChessCore

/// What the Analysis result (design.md 9.4) and Check position (9.5) say about whose move the
/// app is analyzing.
///
/// Naming the side alone is not enough. A screenshot is normally looked at by the player whose
/// own pieces are at the bottom, so "White to move" over a board with White at the top answers
/// for the player across the board without saying so. Every screen that shows the side to move
/// therefore also says where that player sits, and the Analysis result offers a one-tap switch
/// while the side to move is the player at the top.
///
/// The copy rules of design.md section 14 keep this free of words that frame the app as help in
/// a game being played, so the two players are named by where they sit and never by their part
/// in a game.
enum SideToMoveCopy {
    /// Whether `side` is the player at the bottom of the board as it is displayed.
    static func isAtBottom(side: PieceColor, whiteAtBottom: Bool) -> Bool {
        (side == .white) == whiteAtBottom
    }

    /// "the player at the bottom" or "the player at the top".
    static func seat(side: PieceColor, whiteAtBottom: Bool) -> String {
        isAtBottom(side: side, whiteAtBottom: whiteAtBottom) ? "the player at the bottom" : "the player at the top"
    }

    /// The caption under the side-to-move chip: where that player sits, then where the side to
    /// move came from. The chip above it names the side ("White to move"), so the two read as
    /// one statement: "White to move / the player at the top, from last-move highlight".
    ///
    /// The assumed case keeps its own sentence, which already says where the player sits, and
    /// is the only one drawn in `caution` (the chip is then in the attention state).
    static func caption(side: PieceColor, whiteAtBottom: Bool, origin: SideToMoveOrigin) -> String {
        let seat = seat(side: side, whiteAtBottom: whiteAtBottom)
        switch origin {
        case .lastMoveHighlight: return "\(seat), from last-move highlight"
        case .runningClock: return "\(seat), from the clock"
        case .checkRule: return "\(seat), from check"
        case .startPosition: return "\(seat), the game has not started"
        case .assumedBottomPlayer: return "assumed: you are at the bottom"
        case .user: return seat
        }
    }

    /// The VoiceOver value of the side-to-move chip, and of the board's "Side to move" custom
    /// content: "White, the player at the top, from last-move highlight". VoiceOver never sees
    /// the chip and the caption as one statement, so the value says the side itself.
    static func spoken(side: PieceColor, whiteAtBottom: Bool, origin: SideToMoveOrigin) -> String {
        "\(AnalysisSpeech.colorName(side)), \(caption(side: side, whiteAtBottom: whiteAtBottom, origin: origin))"
    }

    /// Whether the result answers for the player at the top: the side to move is that player,
    /// and the user has not chosen the side themselves (choosing one sets the origin to
    /// `.user`, which settles the board; a user who picked the side at the top asked for that
    /// player's move and is answered plainly).
    ///
    /// This is the case the screenshot was taken a little early for. Three things follow from
    /// it on the Analysis result (design.md 9.4): the pill reads "Their move" in muted ink, the
    /// badge leads with the answer the engine's line gives to the move it expects, and the
    /// switch below the caption is offered.
    static func answersForThePlayerAtTheTop(side: PieceColor, whiteAtBottom: Bool, origin: SideToMoveOrigin) -> Bool {
        origin != .user && !isAtBottom(side: side, whiteAtBottom: whiteAtBottom)
    }

    /// Whether the Analysis result offers the switch below the caption. It is offered exactly
    /// while the result answers for the player at the top, so the offer goes away as soon as
    /// the user has settled the side, and never comes back on a board they have settled.
    static func offersSwitchToBottomPlayer(side: PieceColor, whiteAtBottom: Bool, origin: SideToMoveOrigin) -> Bool {
        answersForThePlayerAtTheTop(side: side, whiteAtBottom: whiteAtBottom, origin: origin)
    }

    /// The link under the caption. It does what the side-to-move chip does; it is spelled out
    /// because the chip says which side moves, not which player that is.
    static let switchToBottomPlayerTitle = "Switch to the player at the bottom"

    /// The VoiceOver hint of that link. `side` is the side to move now, so the link switches to
    /// its opposite. Swapping the side re-runs the same board, which costs nothing
    /// (monetization.md: adjustments of one board are free).
    static func switchToBottomPlayerHint(side: PieceColor) -> String {
        "Analyzes \(AnalysisSpeech.colorName(side.opposite)) to move instead. Re-running is free."
    }
}
