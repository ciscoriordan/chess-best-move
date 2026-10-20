import Foundation
import ChessCore
import SwiftUI

/// The Analysis result readout (design.md 9.4), shown unchanged while the engine thinks (9.3).
///
/// The move sits in a badge centered across the card, with the same move in words at the
/// bottom of the badge. The pill and the evaluation are to the right of the badge, right-
/// aligned to the card's trailing edge and vertically centered against it; at the largest text
/// sizes `AnalysisReadoutHeaderLayout` stacks them under the badge instead of letting anything
/// collide, clip or shrink.
///
/// When the screenshot caught the turn of the player at the top and the engine's line holds a
/// reply, the move that player is expected to make comes first, above the badge, under a THEIR
/// LIKELY MOVE heading and in muted ink; the badge holds the reply in the accent, with BEST
/// REPLY in the pill, and a caption under it says the answer depends on the guess (owner
/// decision 2026-09-21, design.md 9.4). The order on screen is the order the moves are played.
/// While the engine searches and its line holds no reply yet, the heading keeps that place over
/// a waiting mark, so the badge does not drop when the reply arrives.
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
            // 12 pt between the guessed move and the badge, a step more than the 8 pt inside
            // each, so the two moves read as two things (design.md 5).
            VStack(alignment: .leading, spacing: Spacing.s3) {
                if let guessed = content.guessedMove {
                    guessedMoveBlock(guessed)
                        // Read before everything else in the readout, as it is seen: the move
                        // the answer depends on, then the pill, the answer and the evaluation.
                        .accessibilitySortPriority(4)
                } else if content.guessedMoveIsPending {
                    pendingGuessedMoveBlock
                }
                if let title = content.checkBannerTitle {
                    Text(title)
                        .typography(content.move == nil ? .title : .callout)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(content.move == nil ? Palette.ink : Palette.ink2)
                        .accessibilityAddTraits(.isHeader)
                        // The hero already speaks the move's check or checkmate, including
                        // its condition when it is a reply. Read it only once.
                        .accessibilityHidden(content.move != nil)
                }
                // On a finished, checkmated board the status heading is the result itself.
                // There is no move or evaluation to repeat in another badge below it.
                if content.move != nil || content.checkBannerTitle == nil {
                    header
                }
            }

            // The condition on the badge's move comes first, right under the badge; what the
            // screen is doing (an error, a stop) follows it.
            if content.guessedMove != nil {
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

    /// The badge, with the pill and the evaluation beside it or under it.
    private var header: some View {
        AnalysisReadoutHeaderLayout {
            badge
                // VoiceOver reads the pill (after the guessed move above the badge, when there
                // is one), then the move, then the evaluation; the layout's own order is visual.
                .accessibilitySortPriority(2)
                // The trait belongs on the elements that change while the engine searches, not
                // on the container around them: a `children: .contain` container is not itself
                // focusable, so the trait never reaches the move or the evaluation and
                // VoiceOver re-reads them at every depth (design.md 12).
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
    }

    // MARK: The badge

    private var badge: some View {
        VStack(spacing: Spacing.s1) {
            move
            if let move = content.move {
                AnalysisGlyphLine(
                    piece: move.piece, text: move.words,
                    spoken: content.spokenMove ?? move.words,
                    capturedPiece: move.capture?.piece, glyphToken: .title
                )
                    .typography(.title)
                    .foregroundStyle(isFinal ? (content.moveIsReply ? Palette.accent : Palette.ink) : Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.analysisBestMove)
                    .multilineTextAlignment(.center)
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
            Text(move.san)
                .typography(.data)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
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

    /// THEIR LIKELY MOVE over "(glyph) e4  Pawn to e4": the move of the player at the top that
    /// the badge answers, above the badge because it is played first, and in muted ink so the
    /// cobalt answer under it stays the answer (owner decision 2026-09-21, design.md 9.4).
    ///
    /// The heading takes `sectionLabel`, not `label`: it names the line under it and is part of
    /// what is read, so it grows with that line instead of stopping at 20 pt (design.md 4).
    ///
    /// The two are one VoiceOver element, "Their likely move: pawn to e4.", so the heading is
    /// never heard apart from the move it names and neither the glyph nor the notation is read.
    private func guessedMoveBlock(_ guessed: AnalysisReadoutContent.MoveText) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            guessedMoveTitle
            Text(guessed.san)
                .typography(.data)
                .foregroundStyle(Palette.ink2)
            AnalysisGlyphLine(
                piece: guessed.piece, text: guessed.words,
                spoken: AnalysisReadoutContent.spokenGuessedMove(guessed),
                capturedPiece: guessed.capture?.piece, glyphToken: .headline
            )
            .typography(.headline)
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AnalysisReadoutContent.spokenGuessedMove(guessed))
        .accessibilityAddTraits(.isStaticText)
        // The engine's expected move can change while it searches, like the badge's move.
        .accessibilityAddTraits(isFinal ? [] : .updatesFrequently)
        .accessibilityIdentifier("analysis.guessedMove")
    }

    /// The guessed move's place while the engine's line holds no reply yet
    /// (`AnalysisReadoutContent.guessedMoveIsPending`): the same heading over a waiting mark in
    /// `ink3`. Without it the badge would drop by the height of the heading and the line a
    /// moment into the search, when the first line long enough to hold a reply arrives, and
    /// the badge is what the reader is watching (design.md 9.3). Like the badge's own waiting
    /// mark it is silent: there is nothing to read yet, and the pill says the engine is
    /// thinking.
    private var pendingGuessedMoveBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            guessedMoveTitle
            ZStack(alignment: .topLeading) {
                // Holds the height the move's own line is about to take, laid out the same way
                // with a typical move: small notation above larger words. Longer moves may
                // wrap to additional lines, including at accessibility text sizes.
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    Text("Nf6").typography(.data)
                    AnalysisGlyphLine(
                        piece: Piece(color: .black, kind: .knight),
                        text: String(localized: "Knight to f6"), spoken: "", glyphToken: .headline
                    )
                    .typography(.headline)
                }
                .hidden()
                Text("\u{2026}")
                    .foregroundStyle(Palette.ink3)
            }
            .typography(.callout)
        }
        .accessibilityHidden(true)
    }

    private var guessedMoveTitle: some View {
        Text(AnalysisReadoutContent.guessedMoveTitle)
            .typography(.sectionLabel)
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

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
/// b3", "(glyph) e4  Pawn to e4", "A longer search preferred (glyph) Nf3, now shown."
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

    /// Both glyphs follow the surrounding text token at every Dynamic Type size.
    var capturedPiece: Piece? = nil
    var glyphToken: TypeToken = .callout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        composed
            .accessibilityLabel(spoken)
    }

    /// One `Text` in two faces: the piece glyph comes from the symbols font and the rest from
    /// the token the line is set in. Built as an `AttributedString` with the font set on the
    /// glyph run, because adding `Text` values together is deprecated from iOS 26.
    private var composed: Text {
        let size = Typography.resolve(glyphToken, sizeCategory: UIContentSizeCategory(dynamicTypeSize)).pointSize
        func symbol(_ piece: Piece) -> AttributedString {
            var glyph = AttributedString(GlyphOutlines.text(for: piece))
            glyph.font = Font(Typography.symbols(size: size) as CTFont)
            glyph.append(AttributedString("\u{00A0}"))
            return glyph
        }
        var line = AttributedString(prefix)
        if let piece { line.append(symbol(piece)) }
        if let capturedPiece, let captured = text.range(of: AnalysisSpeech.capturePieceName(capturedPiece.kind)) {
            line.append(AttributedString(String(text[..<captured.lowerBound])))
            line.append(symbol(capturedPiece))
            line.append(AttributedString(String(text[captured.lowerBound...])))
        } else {
            line.append(AttributedString(text))
        }
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
                    pill: .init(title: "Best reply", isAccent: true),
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
                    pill: .init(title: "Thinking", isAccent: false),
                    move: nil,
                    placeholder: "\u{2026}",
                    placeholderIsResult: false,
                    guessedMove: nil
                ),
                score: nil,
                isFinal: false,
                detail: "Thinking."
            )
            Hairline()
            // The other player's turn, before the engine's line holds a reply.
            AnalysisResultReadout(
                content: AnalysisReadoutContent(
                    pill: .init(title: "Thinking", isAccent: false),
                    move: nil,
                    placeholder: "\u{2026}",
                    placeholderIsResult: false,
                    guessedMove: nil,
                    answersForThePlayerAtTheTop: true,
                    guessedMoveIsPending: true
                ),
                score: nil,
                isFinal: false
            )
        }
        .padding(Spacing.s4)
    }
    .background(Palette.canvas)
}
