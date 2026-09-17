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
    /// Disabled text, placeholders, coordinates. Never for essential text.
    static let ink3 = dynamic(light: 0x8A8475, dark: 0x6F6A5F)
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

    /// Best-move arrow fill, both themes.
    static let arrowFill = fixed(0x2350E6)
    /// Halo stroke around the arrow.
    static let arrowHalo = fixed(0xFFFFFF, opacity: 0.92)
    /// 1 px outer edge outside the halo.
    static let arrowEdge = fixed(0x000000, opacity: 0.28)
    /// White share of the evaluation bar.
    static let evalWhite = dynamic(light: 0xF7F5EF, dark: 0xEDEAE2)
    /// Black share of the evaluation bar.
    static let evalBlack = dynamic(light: 0x1B1915, dark: 0x050504)
    /// 1 px outline of the evaluation bar.
    static let evalOutline = rule2
    /// Light squares of the app's own diagram board.
    static let diagramLight = dynamic(light: 0xEFE9DC, dark: 0xD6CFBF)
    /// Dark squares of the app's own diagram board.
    static let diagramDark = dynamic(light: 0xC2B8A3, dark: 0xA1977F)
    /// Piece outlines and black piece fill.
    static let pieceInk = fixed(0x17150F)
    /// White piece fill.
    static let piecePaper = fixed(0xFFFFFF)

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
