import ChessCore
import SwiftUI

/// Chip (toggle), design.md section 6: visual height 36 (hit target 44), `r2`, 1 pt
/// `rule2` border, leading glyph and `callout` label in `ink`.
struct Chip: View {
    enum Appearance: Sendable, Hashable {
        /// Plain chip.
        case normal
        /// 2 pt dashed `caution` border, with the caption below in `caution`.
        case attention
        /// `ink` fill, `canvas` label.
        case on
    }

    enum Glyph: Sendable, Hashable {
        case systemImage(String)
        /// A chess piece drawn with `PieceGlyph` (for example the side-to-move king).
        case piece(Piece)
    }

    let title: String
    var glyph: Glyph?
    var state: Appearance = .normal
    /// Shown under the chip in `caution` when `state == .attention`.
    var attentionCaption: String?
    let action: () -> Void

    /// The glyph grows with the `callout` label at larger text sizes.
    ///
    /// The curve is `.subheadline`, which is the one the `callout` token itself follows
    /// (Typography.swift). SwiftUI's built-in `.callout` style is a different, steeper curve
    /// (16 to 51 against the token's 15 to 49), so a glyph scaled by it ran ahead of the words
    /// it belongs to and pushed the chip wider than the label needed.
    @ScaledMetric(relativeTo: .subheadline) private var pieceSide: CGFloat = 22
    @ScaledMetric(relativeTo: .subheadline) private var symbolSize: CGFloat = 15

    init(
        _ title: String,
        glyph: Glyph? = nil,
        state: Appearance = .normal,
        attentionCaption: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.glyph = glyph
        self.state = state
        self.attentionCaption = attentionCaption
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s1) {
            Button(action: action) {
                HStack(spacing: Spacing.s2) {
                    switch glyph {
                    case .systemImage(let name):
                        // Decorative: the chip's words are its VoiceOver label, and a symbol
                        // left in the tree is read by its own name (design.md 12).
                        Image(systemName: name)
                            .font(.system(size: symbolSize, weight: .medium))
                            .accessibilityHidden(true)
                    case .piece(let piece):
                        // A piece is drawn on a small diagram square, as in a printed diagram:
                        // a black piece in `pieceInk` would vanish on the dark canvas, and a
                        // piece on the `on` state's `ink` fill in light mode.
                        PieceGlyph(piece: piece, scale: 0.8)
                            .frame(width: pieceSide, height: pieceSide)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.r1 - 1, style: .continuous)
                                    .fill(Palette.diagramLight)
                            )
                    case nil:
                        EmptyView()
                    }
                    Text(title)
                        .multilineTextAlignment(.leading)
                }
                .typography(.callout)
            }
            .buttonStyle(ChipButtonStyle(state: state))

            if state == .attention, let attentionCaption {
                Text(attentionCaption)
                    .typography(.caption)
                    .foregroundStyle(Palette.caution)
            }
        }
    }
}

private struct ChipButtonStyle: ButtonStyle {
    let state: Chip.Appearance

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.r2, style: .continuous)
        configuration.label
            .foregroundStyle(state == .on ? Palette.canvas : Palette.ink)
            .padding(.horizontal, Spacing.s3)
            .frame(minHeight: Layout.chipHeight)
            .background(shape.fill(state == .on ? Palette.ink : (configuration.isPressed ? Palette.sunken : Color.clear)))
            .overlay {
                switch state {
                case .normal:
                    shape.strokeBorder(Palette.rule2, lineWidth: LineWidth.control)
                case .attention:
                    shape.strokeBorder(
                        Palette.caution,
                        style: StrokeStyle(lineWidth: LineWidth.lowConfidence, dash: LineWidth.lowConfidenceDash)
                    )
                case .on:
                    shape.strokeBorder(Palette.ink, lineWidth: LineWidth.control)
                }
            }
            .frame(minHeight: Layout.minimumHitTarget)
            .contentShape(Rectangle())
    }
}

#Preview("Chips") {
    VStack(alignment: .leading, spacing: Spacing.s3) {
        HStack(spacing: Spacing.s2) {
            Chip("White to move", glyph: .piece(Piece(color: .white, kind: .king))) {}
            Chip("Flip", glyph: .systemImage("arrow.up.arrow.down")) {}
            Chip("Edit", glyph: .systemImage("square.grid.3x3")) {}
        }
        Chip(
            "Black to move",
            glyph: .piece(Piece(color: .black, kind: .king)),
            state: .attention,
            attentionCaption: "assumed: you are at the bottom"
        ) {}
        Chip("W O-O", state: .on) {}
    }
    .padding(Spacing.s4)
    .background(Palette.canvas)
}
