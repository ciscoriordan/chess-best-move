import SwiftUI
import UIKit

/// Color tokens from docs/design.md section 3.
///
/// Every token is a dynamic color that resolves against the current trait collection:
/// light or dark appearance, and Increase Contrast (`colorSchemeContrast == .increased`)
/// for the tokens that have a high-contrast variant. Use them as `Palette.ink` wherever a
/// `Color` or `ShapeStyle` is expected. No other colors belong in app content.
enum Palette {
    // MARK: Core palette

    /// Screen background: warm paper / warm near-black.
    static let canvas = dynamic(light: 0xF3F0E8, dark: 0x12110E)
    /// Pinned bottom action bar, sheet body, selected paywall row fill.
    static let raised = dynamic(light: 0xFBF9F4, dark: 0x1C1A16)
    /// Segmented-control track, loading placeholders.
    static let sunken = dynamic(light: 0xE7E3D8, dark: 0x0A0907)
    /// Primary text, the big move, icons.
    static let ink = dynamic(light: 0x17150F, dark: 0xEEEAE0)
    /// Secondary text and labels.
    static let ink2 = dynamic(light: 0x57524A, dark: 0xA9A396, increasedLight: 0x45413A, increasedDark: 0xC9C3B6)
    /// Disabled text and placeholders. Never for essential text, and never for board
    /// coordinates: those are drawn on the diagram and take `boardCoordinate`.
    static let ink3 = dynamic(light: 0x8A8475, dark: 0x6F6A5F, increasedLight: 0x6B6659, increasedDark: 0x8D887B)
    /// Hairlines between groups.
    static let rule = dynamic(light: 0xD9D3C5, dark: 0x2D2A24, increasedLight: 0x8F8878, increasedDark: 0x6A655B)
    /// Borders of chips, secondary buttons and the board crop.
    static let rule2 = dynamic(light: 0xB3AB9A, dark: 0x4A463E, increasedLight: 0x8F8878, increasedDark: 0x6A655B)
    /// Cobalt "blue pencil". Only for the best-move arrow, the first move of the engine
    /// line, the one primary button on a screen, and selection outlines.
    static let accent = dynamic(light: 0x2350E6, dark: 0x7C94FF)
    /// Pressed primary button.
    static let accentPressed = dynamic(light: 0x1A3DB8, dark: 0xA5B4FF)
    /// Fill behind the highlighted paywall option and the selected editor palette cell.
    static let accentSubtle = dynamic(light: 0xE2E7FA, dark: 0x1B2244)
    /// Text and symbols on `accent` fills.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0E0D0A)
    /// Low-confidence squares, "assumed" side to move.
    static let caution = dynamic(light: 0x94560A, dark: 0xE3A54A)
    /// Blocking editor issues, recognition failure title accent.
    static let danger = dynamic(light: 0xB3261E, dark: 0xFF7B6B)

    // MARK: Theme-invariant tokens (drawn over the screenshot or the diagram)

    /// The answer arrow's fill, both themes: the move the app is telling the user to play.
    static let arrowFill = fixed(0x2350E6)
    /// The other arrow's fill: the move the app expects the player at the top to make first,
    /// which the answer replies to (design.md section 7, "two arrows").
    ///
    /// A warm near-black rather than the muted ink of the text below it, for two reasons that
    /// were measured rather than guessed (`AccessibilityContrastTests`). `ink2` is a dynamic
    /// token chosen as text on the app's own surfaces, and the board is the user's screenshot,
    /// which does not follow the app's theme; and in light mode `ink2` sits 1.24:1 from the
    /// cobalt in luminance, so a reader who cannot separate blue from warm grey by hue would
    /// see the same mark twice.
    ///
    /// The value is forced by the two ratios it has to clear at once. To reach 3:1 against the
    /// cobalt a fill must be either lighter than a relative luminance of 0.454 or darker than
    /// 0.0060, and anything in the light branch falls below 3:1 against the opaque white halo
    /// that wraps every arrow. Only the dark branch satisfies both, so the arrow is a near
    /// black: 3.11:1 from the cobalt and 19.4:1 from the halo.
    static let arrowTheirMoveFill = fixed(0x0E0D0A)
    /// Halo stroke around the arrow. Opaque: at 92% over the dark square of the board themes
    /// the app reads, it fell to between 2.3:1 and 3.1:1 (docs/design.md section 7).
    static let arrowHalo = fixed(0xFFFFFF)
    /// The outer edge outside the halo, and the second of the arrow's two contrast guarantees.
    ///
    /// The halo carries the arrow against a dark square and this edge carries it against a
    /// light one, so between them every board theme has one edge at 3:1 or better
    /// (docs/design.md section 7). At the old 28% the edge carried nothing, and on the dark
    /// square of a blue or a blue-grey board the halo alone does not reach 3:1 either: white
    /// on the darker square of a mid-blue board measures 2.66:1 at full opacity, so no amount
    /// of halo fixes it.
    /// 55% is the lowest value at which every board tested clears 3:1 on one edge or the other
    /// (`AccessibilityContrastTests`); the app's own dark diagram square is the tight one.
    static let arrowEdge = fixed(0x000000, opacity: 0.55)
    /// White share of the evaluation bar.
    static let evalWhite = dynamic(light: 0xF7F5EF, dark: 0xEDEAE2)
    /// Black share of the evaluation bar.
    static let evalBlack = dynamic(light: 0x1B1915, dark: 0x050504)
    /// The empty evaluation track, before the engine has reported anything.
    ///
    /// Fixed, and a mid tone, because a full bar is a real reading - it is what a forced mate
    /// gives - so an empty track drawn in either half's own color IS that reading. `sunken`
    /// measured 1.18:1 against `evalWhite` in light mode and 1.02:1 against `evalBlack` in
    /// dark, which made "the engine has not reported" look like "White has everything" in one
    /// theme and "Black has everything" in the other. The two halves sit at both ends of the
    /// range in both appearances, so one value tells them both apart: this is 3.7:1 or more
    /// from each half, and from the canvas, under every trait combination
    /// (`AccessibilityContrastTests`).
    static let evalEmpty = fixed(0x7A7468)
    /// 1 px outline of the evaluation bar.
    ///
    /// The bar carries no text and its whole meaning is where it starts and stops, so the
    /// outline is the only boundary it has and WCAG 1.4.11 asks 3:1 of it. `rule2` gives 2.0:1
    /// in both themes, which is why this is a token of its own: it is `rule2`'s Increase
    /// Contrast value at all times (3.1:1 light, 3.3:1 dark against `canvas`). Without it the
    /// white half of the bar dissolves into the paper at 1.04:1 in light mode and the black
    /// half into the background at 1.08:1 in dark mode.
    static let evalOutline = dynamic(light: 0x8F8878, dark: 0x6A655B)
    /// Light squares of the app's own diagram board.
    static let diagramLight = dynamic(light: 0xEFE9DC, dark: 0xD6CFBF)
    /// Dark squares of the app's own diagram board.
    static let diagramDark = dynamic(light: 0xC2B8A3, dark: 0xA1977F)
    /// Piece outlines and black piece fill.
    static let pieceInk = fixed(0x17150F)
    /// White piece fill.
    static let piecePaper = fixed(0xFFFFFF)

    // MARK: Board marks (drawn on the diagram, which does not follow the theme)

    // The diagram board is a warm paper board in both appearances: its four square colors span
    // a relative luminance of 0.31 to 0.82. A mark drawn on it therefore has to be chosen
    // against those four squares and not against `canvas`, which is why these are fixed rather
    // than dynamic. Drawn in the theme-following `caution`, `danger` and `accent` they measured
    // between 1.04:1 and 1.80:1 in dark mode - the editor's selection outline, which is the
    // only confirmation that a tap landed, was invisible at 1.04:1.
    //
    // Each of the three clears 3:1 against all four diagram squares, in both appearances.

    /// Low-confidence square outline and its "?" badge: 3.2:1 on the darkest diagram square,
    /// 7.6:1 on the lightest.
    static let markLowConfidence = fixed(0x6B3D05)
    /// Blocking-issue square outline and its "!" badge: 3.6:1 to 8.6:1.
    static let markIssue = fixed(0x7E1710)
    /// Selected square outline: the dark cut of the cobalt, 3.8:1 to 9.0:1.
    static let markSelection = fixed(0x16309A)
    /// Rank and file coordinates inside the board's edge squares. Text, so it needs 4.5:1, and
    /// it clears it on every diagram square (4.8:1 to 11.4:1). `ink3` gave 1.86:1 on a dark
    /// square, which made half of every board's coordinates unreadable.
    static let boardCoordinate = fixed(0x332C22)

    /// Width multiplier for the arrow halo under Increase Contrast.
    static func arrowHaloScale(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 1.5 : 1
    }

    // MARK: Construction

    private static func fixed(_ rgb: UInt32, opacity: CGFloat = 1) -> Color {
        Color(uiColor: uiColor(rgb, alpha: opacity))
    }

    private static func dynamic(
        light: UInt32,
        dark: UInt32,
        increasedLight: UInt32? = nil,
        increasedDark: UInt32? = nil
    ) -> Color {
        let provider = UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isIncreased = traits.accessibilityContrast == .high
            switch (isDark, isIncreased) {
            case (false, false): return uiColor(light)
            case (true, false): return uiColor(dark)
            case (false, true): return uiColor(increasedLight ?? light)
            case (true, true): return uiColor(increasedDark ?? dark)
            }
        }
        return Color(uiColor: provider)
    }

    static func uiColor(_ rgb: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}

#Preview("Palette") {
    let swatches: [(String, Color)] = [
        ("canvas", Palette.canvas), ("raised", Palette.raised), ("sunken", Palette.sunken),
        ("ink", Palette.ink), ("ink2", Palette.ink2), ("ink3", Palette.ink3),
        ("rule", Palette.rule), ("rule2", Palette.rule2), ("accent", Palette.accent),
        ("accentPressed", Palette.accentPressed), ("accentSubtle", Palette.accentSubtle),
        ("onAccent", Palette.onAccent), ("caution", Palette.caution), ("danger", Palette.danger),
        ("diagramLight", Palette.diagramLight), ("diagramDark", Palette.diagramDark),
        ("evalWhite", Palette.evalWhite), ("evalBlack", Palette.evalBlack),
    ]
    return ScrollView {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            ForEach(swatches, id: \.0) { name, color in
                HStack(spacing: Spacing.s3) {
                    Rectangle().fill(color).frame(width: 44, height: 28)
                        .overlay(Rectangle().strokeBorder(Palette.rule2, lineWidth: 1))
                    Text(name).typography(.data).foregroundStyle(Palette.ink)
                }
            }
        }
        .padding(Spacing.s4)
    }
    .background(Palette.canvas)
}
