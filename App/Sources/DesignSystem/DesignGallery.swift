#if DEBUG
import ChessCore
import SwiftUI

/// Every token and shared component on one scrolling screen, for checking fonts, colors and
/// components on a simulator or device (launch with `-debugGallery YES`). DEBUG builds only.
struct DesignGalleryView: View {
    @State private var thinkTime = ThinkTime.defaultValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Type scale")
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    Text("Nxf7+").typography(.moveHero)
                    Text("exd8=Q#").typography(.moveHero, width: 75)
                    Text("Best Move").typography(.display)
                    Text("No board found").typography(.title)
                    Text("Yearly").typography(.headline)
                    Text(AppCopy.homeIntro).typography(.body)
                    Text("Think longer: 10\u{00A0}s").typography(.button)
                    Text("Knight takes f7, check").typography(.callout)
                    Text("This didn't use a free analysis.").typography(.caption)
                    Text("Best move").typography(.label)
                    Text("+2.35  \u{2212}1.20  M3").typography(.dataLarge)
                    Text("depth 24    3.0\u{00A0}s    2.3 M n/s").typography(.data)
                    Text("1. Nxf7+ Kxf7 2. Qh5+ g6 3. Qxe5").typography(.line)
                    Text("a b c d e f g h  1.0 (1)").typography(.dataSmall)
                }
                .foregroundStyle(Palette.ink)

                SectionLabel("Colors")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Spacing.s2, alignment: .leading)],
                          alignment: .leading, spacing: Spacing.s2) {
                    ForEach(Self.swatches, id: \.0) { name, color in
                        HStack(spacing: Spacing.s2) {
                            Rectangle().fill(color).frame(width: 20, height: 20)
                                .overlay(Rectangle().strokeBorder(Palette.rule2, lineWidth: 1))
                            Text(name).typography(.dataSmall).foregroundStyle(Palette.ink2)
                        }
                    }
                }

                SectionLabel("Buttons")
                VStack(alignment: .leading, spacing: Spacing.s3) {
                    PrimaryButton("Analyze", systemImage: "sparkle.magnifyingglass") {}
                    PrimaryButton("Analyze") {}.disabled(true)
                    SecondaryButton("Choose another image") {}
                    HStack(spacing: Spacing.s2) {
                        TextLink("Restore purchases") {}
                        TextLink("Terms") {}
                        TextLink("Privacy") {}
                    }
                }

                SectionLabel("Chips")
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    HStack(spacing: Spacing.s2) {
                        Chip("White to move", glyph: .piece(Piece(color: .white, kind: .king))) {}
                        Chip("Flip", glyph: .systemImage("arrow.up.arrow.down")) {}
                        Chip("Edit", glyph: .systemImage("square.grid.3x3")) {}
                    }
                    Chip("Black to move", glyph: .piece(Piece(color: .black, kind: .king)), state: .attention,
                         attentionCaption: "assumed: you are at the bottom") {}
                    Chip("W O-O", state: .on) {}
                }

                SectionLabel("Think")
                ThinkTimeControl(selection: $thinkTime)

                SectionLabel("Credits")
                HStack(spacing: Spacing.s4) {
                    CreditsIndicator(freeRemaining: 3, isPro: false) {}
                    CreditsIndicator(freeRemaining: 1, isPro: false) {}
                    CreditsIndicator(freeRemaining: 0, isPro: false) {}
                }

                SectionLabel("Rows")
                Hairline()
                ListRow("Choose from Photos", systemImage: "photo.on.rectangle", showsChevron: true)
                ListRowHairline()
                ListRow("Chess engine", systemImage: "cpu", value: "Stockfish 19", showsChevron: true)
                Hairline()

                SectionLabel("Pieces and board")
                HStack(spacing: 0) {
                    ForEach(PieceKind.allCases, id: \.self) { kind in
                        VStack(spacing: 0) {
                            PieceGlyph(piece: Piece(color: .white, kind: kind)).frame(width: 44, height: 44)
                                .background(Palette.diagramDark)
                            PieceGlyph(piece: Piece(color: .black, kind: kind)).frame(width: 44, height: 44)
                                .background(Palette.diagramLight)
                        }
                    }
                }
                BoardFrame { DiagramBoard(board: Position.start.board) }
                    .padding(.top, Spacing.s3)
            }
            .sideGutter()
            .padding(.bottom, Spacing.s7)
        }
        .background(Palette.canvas)
    }

    private static let swatches: [(String, Color)] = [
        ("canvas", Palette.canvas), ("raised", Palette.raised), ("sunken", Palette.sunken),
        ("ink", Palette.ink), ("ink2", Palette.ink2), ("ink3", Palette.ink3),
        ("rule", Palette.rule), ("rule2", Palette.rule2), ("accent", Palette.accent),
        ("accentPressed", Palette.accentPressed), ("accentSubtle", Palette.accentSubtle),
        ("onAccent", Palette.onAccent), ("caution", Palette.caution), ("danger", Palette.danger),
        ("diagramLight", Palette.diagramLight), ("diagramDark", Palette.diagramDark),
        ("evalWhite", Palette.evalWhite), ("evalBlack", Palette.evalBlack), ("arrowFill", Palette.arrowFill),
    ]
}

#Preview("Design gallery") {
    DesignGalleryView()
}
#endif
