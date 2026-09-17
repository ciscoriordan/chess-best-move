import ChessCore
import CoreText
import SwiftUI

/// PieceGlyph (design.md section 6): a piece from Noto Sans Symbols 2 at 0.82 of the
/// square size, centered on the glyph's bounding box (not on text metrics).
///
/// White piece: the solid glyph (U+265A...U+265F) filled with `piecePaper`, then the outline
/// glyph (U+2654...U+2659) in `pieceInk` on top, so white pieces are opaque on dark squares.
/// Black piece: the solid glyph in `pieceInk`. The glyphs are drawn as outlines taken from
/// the font, so emoji presentation can never apply.
struct PieceGlyph: View {
    let piece: Piece
    /// Fraction of the frame's shorter side that the glyph's bounding box fills.
    var scale: CGFloat = 0.82

    var body: some View {
        Canvas { context, size in
            PieceGlyphRenderer.draw(piece, in: CGRect(origin: .zero, size: size), scale: scale, context: &context)
        }
        .accessibilityIgnoresInvertColors()
        .accessibilityHidden(true)
    }
}

/// Draws piece glyph outlines into a `GraphicsContext`. Shared by `PieceGlyph` and
/// `DiagramBoard`; feature code can use it for arrows' promotion badges and drag previews.
enum PieceGlyphRenderer {
    /// Draws `piece` centered in `rect`.
    static func draw(_ piece: Piece, in rect: CGRect, scale: CGFloat = 0.82, context: inout GraphicsContext) {
        guard let outline = GlyphOutlines.shared.path(for: piece.kind, solid: piece.color == .black),
              let solid = GlyphOutlines.shared.path(for: piece.kind, solid: true)
        else { return }
        // Center both layers on the visible glyph's box so they stay registered.
        let reference = piece.color == .white ? outline : solid
        let bounds = reference.boundingRect
        guard bounds.width > 0, bounds.height > 0 else { return }
        let target = min(rect.width, rect.height) * scale
        let factor = target / max(bounds.width, bounds.height)
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: factor, y: -factor)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)

        if piece.color == .white {
            context.fill(solid.applying(transform), with: .color(Palette.piecePaper))
            context.fill(outline.applying(transform), with: .color(Palette.pieceInk))
        } else {
            context.fill(solid.applying(transform), with: .color(Palette.pieceInk))
        }
    }
}

/// Glyph outlines from Noto Sans Symbols 2, extracted once at a 100 pt reference size.
final class GlyphOutlines: Sendable {
    static let shared = GlyphOutlines()

    /// Glyph outlines in font units at 100 pt, y axis up.
    private let paths: [String: Path]

    private init() {
        let font = CTFontCreateWithName(Typography.symbolsPostScriptName as CFString, 100, nil)
        var paths: [String: Path] = [:]
        for kind in PieceKind.allCases {
            for solid in [false, true] {
                var character = UniChar(Self.scalar(for: kind, solid: solid))
                var glyph = CGGlyph()
                guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0,
                      let path = CTFontCreatePathForGlyph(font, glyph, nil)
                else { continue }
                paths[Self.key(kind, solid)] = Path(path)
            }
        }
        self.paths = paths
    }

    func path(for kind: PieceKind, solid: Bool) -> Path? {
        paths[Self.key(kind, solid)]
    }

    /// U+2654...U+2659 outline (white) glyphs, U+265A...U+265F solid (black) glyphs.
    static func scalar(for kind: PieceKind, solid: Bool) -> UInt32 {
        let offset: UInt32 = switch kind {
        case .king: 0
        case .queen: 1
        case .rook: 2
        case .bishop: 3
        case .knight: 4
        case .pawn: 5
        }
        return (solid ? 0x265A : 0x2654) + offset
    }

    /// The text form with U+FE0E (text presentation selector), for strings shown as text.
    static func text(for piece: Piece) -> String {
        let scalar = Unicode.Scalar(scalar(for: piece.kind, solid: piece.color == .black))!
        return String(Character(scalar)) + "\u{FE0E}"
    }

    private static func key(_ kind: PieceKind, _ solid: Bool) -> String {
        "\(kind.rawValue)-\(solid)"
    }
}

#Preview("Piece glyphs") {
    VStack(spacing: 0) {
        ForEach(PieceColor.allCases, id: \.self) { color in
            HStack(spacing: 0) {
                ForEach(Array(PieceKind.allCases.enumerated()), id: \.offset) { index, kind in
                    PieceGlyph(piece: Piece(color: color, kind: kind))
                        .frame(width: 52, height: 52)
                        .background((index + (color == .white ? 0 : 1)).isMultiple(of: 2) ? Palette.diagramLight : Palette.diagramDark)
                }
            }
        }
    }
    .padding(Spacing.s4)
    .background(Palette.canvas)
}
