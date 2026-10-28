import Foundation
import ChessCore

/// What the Analysis result (design.md 9.4) and Check position (9.5) say about whose move the
/// app is analyzing.
///
/// Routine seat and detection-source captions were removed by the owner on October 27, 2026.
/// Preserve the uncertainty warning and the one-tap switch when the result answers for the
/// player at the top.
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
        isAtBottom(side: side, whiteAtBottom: whiteAtBottom) ? String(localized: "the player at the bottom") : String(localized: "the player at the top")
    }

    /// Only show a caption when the side was assumed, rather than detected or chosen.
    static func caption(side: PieceColor, whiteAtBottom: Bool, origin: SideToMoveOrigin) -> String? {
        origin == .assumedBottomPlayer ? String(localized: "assumed: you are at the bottom") : nil
    }

    /// The board's "Side to move" custom content and the chip's VoiceOver value.
    static func spoken(side: PieceColor, whiteAtBottom: Bool, origin: SideToMoveOrigin) -> String {
        guard let caption = caption(side: side, whiteAtBottom: whiteAtBottom, origin: origin) else {
            return AnalysisSpeech.colorName(side)
        }
        return String(localized: "\(AnalysisSpeech.colorName(side)), \(caption)")
    }

    /// Whether the result answers for the player at the top: the side to move is that player,
    /// and the user has not chosen the side themselves (choosing one sets the origin to
    /// `.user`, which settles the board; a user who picked the side at the top asked for that
    /// player's move and is answered plainly).
    ///
    /// This is the case the screenshot was taken a little early for. Three things follow from
    /// it on the Analysis result (design.md 9.4): the move the engine expects from that player
    /// is shown above the badge under "Their likely move"; the badge holds the answer the
    /// engine's line gives to it, with "Best reply" in the accent pill (or, while the line
    /// holds no reply yet, that player's own move under a muted "Their move" pill); and the
    /// switch below the chips is offered.
    static func answersForThePlayerAtTheTop(side: PieceColor, whiteAtBottom: Bool, origin: SideToMoveOrigin) -> Bool {
        origin != .user && !isAtBottom(side: side, whiteAtBottom: whiteAtBottom)
    }

    /// Whether the Analysis result offers the switch below the chips. It is offered exactly
    /// while the result answers for the player at the top, so the offer goes away as soon as
    /// the user has settled the side, and never comes back on a board they have settled.
    static func offersSwitchToBottomPlayer(side: PieceColor, whiteAtBottom: Bool, origin: SideToMoveOrigin) -> Bool {
        answersForThePlayerAtTheTop(side: side, whiteAtBottom: whiteAtBottom, origin: origin)
    }

    /// The link under the chips. It does what the side-to-move chip does; it is spelled out
    /// because the chip says which side moves, not which player that is.
    static let switchToBottomPlayerTitle = String(localized: "Switch to the player at the bottom")

    /// The VoiceOver hint of that link. `side` is the side to move now, so the link switches to
    /// its opposite. Swapping the side re-runs the same board, which costs nothing
    /// (monetization.md: adjustments of one board are free).
    static func switchToBottomPlayerHint(side: PieceColor) -> String {
        String(localized: "Analyzes \(AnalysisSpeech.colorName(side.opposite)) to move instead. Re-running is free.")
    }
}
