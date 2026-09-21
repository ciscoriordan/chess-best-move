import ChessCore
import SwiftUI

/// The Analysis result readout (design.md 9.4), shown unchanged while the engine thinks (9.3).
///
/// The move sits in a badge centered across the card, with the same move in words at the
/// bottom of the badge. The pill and the evaluation are to the right of the badge, right-
/// aligned to the card's trailing edge and vertically centered against it; at the largest text
/// sizes `AnalysisReadoutHeaderLayout` stacks them under the badge instead of letting anything
/// collide, clip or shrink. When the screenshot caught the turn of the player at the top, the
/// badge leads with the answer and the move it answers follows underneath, in muted ink.
struct AnalysisResultReadout: View {
    let content: AnalysisReadoutContent
    /// The evaluation from White's point of view, once the engine reports one.
    let score: WhiteScore?
    /// The search has finished: the move is drawn in full ink.
    let isFinal: Bool
    /// What is going on, when the badge does not already say it: an error, a stop, no legal
    /// moves, or the engine still loading. Nil while the badge's move says the same thing.
    var detail: String?
    var detailIsCaution = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            AnalysisReadoutHeaderLayout {
                badge
                    // VoiceOver reads the pill first (it says what the readout is), then the
                    // move, then the evaluation; the layout's own order is visual.
                    .accessibilitySortPriority(2)
                    // The trait belongs on the elements that change while the engine searches,
                    // not on the container around them: a `children: .contain` container is not
                    // itself focusable, so the trait never reaches the move or the evaluation
                    // and VoiceOver re-reads them at every depth (design.md 12).
                    .accessibilityAddTraits(isFinal ? [] : .updatesFrequently)
                AnalysisStatusPill(title: content.pill.title, isAccent: content.pill.isAccent)
                    .accessibilitySortPriority(3)
                if let score {
                    evaluation(score)
                        .accessibilitySortPriority(1)
                        .accessibilityAddTraits(isFinal ? [] : .updatesFrequently)
                }
            }
            .frame(maxWidth: .infinity)

            // What the badge's move depends on comes first, right under the badge; what the
            // screen is doing (an error, a stop) follows it.
            if let guessed = content.guessedMove {
                guessedMoveLine(guessed)
                Text(AnalysisReadoutContent.guessedMoveNote)
                    .typography(.caption)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail)
                    .typography(.callout)
                    .foregroundStyle(detailIsCaution ? Palette.caution : Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: The badge

    private var badge: some View {
        VStack(spacing: Spacing.s1) {
            move
            if let move = content.move {
                AnalysisGlyphLine(piece: move.piece, text: move.words, spoken: move.words)
                    .typography(.callout)
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    // The move above it carries the same words as its VoiceOver label, and
                    // design.md 12 has the move read once.
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.s4)
        .padding(.vertical, Spacing.s3)
        .background(
            RoundedRectangle(cornerRadius: Radius.r3, style: .continuous)
                .fill(Palette.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.r3, style: .continuous)
                .strokeBorder(Palette.rule2, lineWidth: LineWidth.control)
        )
    }

    @ViewBuilder
    private var move: some View {
        if let move = content.move {
            AnalysisHeroMove(
                san: move.san,
                spokenDescription: content.spokenMove ?? move.words,
                isFinal: isFinal,
                isReply: content.moveIsReply
            )
            .id(move.san)
            .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: Motion.valueChange)))
        } else if content.placeholderIsResult {
            // Checkmate and Stalemate are the result itself: full ink, and read out.
            Text(content.placeholder)
                .typography(.moveHero, width: 75)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Palette.ink)
        } else {
            Text(content.placeholder)
                .typography(.moveHero)
                .lineLimit(1)
                .foregroundStyle(Palette.ink3)
                .accessibilityHidden(true)
        }
    }

    private func evaluation(_ score: WhiteScore) -> some View {
        Text(AnalysisScore.text(score))
            .typography(.dataLarge)
            .foregroundStyle(isFinal ? Palette.ink : Palette.ink2)
            .lineLimit(1)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .easeOut(duration: Motion.valueChange), value: score)
            .accessibilityLabel("Evaluation")
            .accessibilityValue(AnalysisScore.spoken(score))
    }

    /// "if they play (glyph) e4": the move of the player at the top that the badge answers,
    /// in muted ink so the cobalt answer above it stays the answer (design.md 9.4).
    private func guessedMoveLine(_ guessed: AnalysisReadoutContent.MoveText) -> some View {
        AnalysisGlyphLine(
            prefix: AnalysisReadoutContent.guessedMovePrefix,
            piece: guessed.piece,
            text: guessed.san,
            spoken: AnalysisReadoutContent.spokenGuessedMove(guessed)
        )
        .typography(.callout)
        .foregroundStyle(Palette.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("analysis.guessedMove")
    }
}

// MARK: - Pieces of the readout

/// The move in the badge, in `move.hero`. Long moves switch to the narrow width (a second
/// layout, not a shrink); only then may the text scale down to 70%.
struct AnalysisHeroMove: View {
    let san: String
    let spokenDescription: String
    let isFinal: Bool
    /// The move answers a guessed move of the player at the top, so it is drawn in the accent:
    /// cobalt is the answer (design.md 9.4, item 2).
    var isReply = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(san)
                .typography(.moveHero)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(san)
                .typography(.moveHero, width: 75)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(isFinal ? (isReply ? Palette.accent : Palette.ink) : Palette.ink2)
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.stateShort), value: isFinal)
        .accessibilityLabel(spokenDescription)
        .accessibilityIdentifier(AccessibilityID.analysisBestMove)
    }
}

/// The pill that replaced the cobalt swatch and the BEST MOVE label (design.md 9.4): the
/// `label` token on an accent fill while the answer belongs to the player at the bottom, and
/// on a muted ink fill otherwise.
struct AnalysisStatusPill: View {
    let title: String
    let isAccent: Bool

    var body: some View {
        Text(title)
            .typography(.label)
            .foregroundStyle(isAccent ? Palette.onAccent : Palette.canvas)
            .padding(.horizontal, Spacing.s2)
            .padding(.vertical, Spacing.s1)
            .background(Capsule(style: .continuous).fill(isAccent ? Palette.accent : Palette.ink2))
            // Uppercase is the token's doing; VoiceOver reads the sentence-case words.
            .accessibilityLabel(title)
    }
}

/// A line of text with a chess piece's glyph in it (design.md 9.4, item 3): "(glyph) Pawn to
/// b3", "if they play (glyph) e4".
///
/// The glyph comes from Noto Sans Symbols 2, which is in the bundle because the system font
/// has no chess pieces. VoiceOver reads `spoken` and nothing else, so a symbol's name is never
/// read out.
struct AnalysisGlyphLine: View {
    /// Text before the glyph.
    var prefix = ""
    /// The piece whose glyph is drawn. Without one the line is the text alone.
    let piece: Piece?
    /// Text after the glyph.
    let text: String
    /// What VoiceOver reads instead of the line: words, never a symbol name.
    let spoken: String

    /// The glyph grows with the `callout` text it sits in.
    @ScaledMetric(relativeTo: .callout) private var glyphSize: CGFloat = 16

    var body: some View {
        composed
            .accessibilityLabel(spoken)
    }

    /// One `Text` in two faces: the piece glyph comes from the symbols font and the rest from
    /// the token the line is set in. Built as an `AttributedString` with the font set on the
    /// glyph run, because adding `Text` values together is deprecated from iOS 26.
    private var composed: Text {
        guard let piece else { return Text(prefix + text) }
        var line = AttributedString(prefix)
        var glyph = AttributedString(GlyphOutlines.text(for: piece))
        glyph.font = Font(Typography.symbols(size: glyphSize) as CTFont)
        line.append(glyph)
        // A no-break space keeps the glyph and the move it belongs to on one line.
        line.append(AttributedString("\u{00A0}" + text))
        return Text(line)
    }
}

#Preview("Result readout") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.s5) {
            AnalysisResultReadout(
                content: AnalysisReadoutContent(
                    pill: .init(title: "Best move", isAccent: true),
                    move: .init(move: Move(uci: "b2b3")!, san: "b3", words: "Pawn to b3", piece: Piece(color: .white, kind: .pawn)),
                    placeholder: "\u{2014}",
                    placeholderIsResult: false,
                    guessedMove: nil
                ),
                score: .centipawns(35),
                isFinal: true
            )
            Hairline()
            AnalysisResultReadout(
                content: AnalysisReadoutContent(
                    pill: .init(title: "Their move", isAccent: false),
                    move: .init(move: Move(uci: "g8f6")!, san: "Nf6", words: "Knight to f6", piece: Piece(color: .black, kind: .knight)),
                    placeholder: "\u{2014}",
                    placeholderIsResult: false,
                    guessedMove: .init(move: Move(uci: "e2e4")!, san: "e4", words: "Pawn to e4", piece: Piece(color: .white, kind: .pawn))
                ),
                score: .centipawns(-20),
                isFinal: true
            )
            Hairline()
            AnalysisResultReadout(
                content: AnalysisReadoutContent(
                    pill: .init(title: "Thinking", isAccent: true),
                    move: nil,
                    placeholder: "\u{2026}",
                    placeholderIsResult: false,
                    guessedMove: nil
                ),
                score: nil,
                isFinal: false,
                detail: "Thinking."
            )
        }
        .padding(Spacing.s4)
    }
    .background(Palette.canvas)
}
