import CoreText
import SwiftUI
import UIKit

/// Text tokens from docs/design.md section 4.
///
/// Apply with `.typography(.headline)`. Every token is set in a system face: SF Pro for text,
/// SF Mono for notation and numbers. The system font carries its own optical sizing (it swaps
/// between the Text and the Display cut as the point size crosses 20 pt), a full weight range
/// and three widths, so the tokens ask for those rather than driving variation axes by hand.
///
/// The modifier builds the font for the current Dynamic Type size: it scales the base size with
/// the token's text style and caps it at the token's maximum. A token may also ask for a line
/// height of its own; most do not, and take the font's natural one.
///
/// One bundled typeface is left: Noto Sans Symbols 2, for the chess piece glyphs, because the
/// system has no chess glyphs (`Typography.symbols`).
enum TypeToken: String, CaseIterable, Sendable {
    /// The best move. SF Pro Heavy 80, trimmed to an 80 pt box so the badge around it is tight.
    case moveHero
    /// Home wordmark, paywall headline. SF Pro Bold 34.
    case display
    /// Screen titles. SF Pro Bold 28.
    case title
    /// Row titles, paywall option titles. SF Pro Semibold 20.
    case headline
    /// Paragraphs, instructions. SF Pro Regular 17.
    case body
    /// Button labels. SF Pro Semibold 17.
    case button
    /// Chips, list secondary text, spoken move. SF Pro Regular 15.
    case callout
    /// Fine print, hints. SF Pro Regular 13.
    case caption
    /// Uppercase instrument labels on a fixed-geometry readout (BEST MOVE, LINE, THINK, PRO,
    /// EDITED). SF Pro Semibold 12, +6% tracking. Short labels only, and the one text token
    /// that still stops growing: see `TypeSpec.maximumSize`.
    case label
    /// Uppercase section headings (HOW IT WORKS, PURCHASES, CASTLING). The same lettering as
    /// `label`, with no maximum size, because a heading is part of the reading order and must
    /// stay larger than nothing in the section it names.
    case sectionLabel
    /// Eval next to the hero move. SF Mono Semibold 22.
    case dataLarge
    /// Depth, clock, nodes per second, prices. SF Mono Medium 15.
    case data
    /// Engine line. SF Mono Regular 15, opened up to a 21 pt line height because a wrapped
    /// principal variation is dense.
    case line
    /// Board coordinates, version numbers. SF Mono Regular 12.
    case dataSmall

    var spec: TypeSpec {
        switch self {
        case .moveHero:
            TypeSpec(face: .text(weight: .heavy), size: 80, lineHeight: 80,
                     textStyle: .largeTitle, maximumSize: 100)
        case .display:
            TypeSpec(face: .text(weight: .bold), size: 34, textStyle: .largeTitle, maximumSize: nil)
        case .title:
            TypeSpec(face: .text(weight: .bold), size: 28, textStyle: .title1, maximumSize: nil)
        case .headline:
            TypeSpec(face: .text(weight: .semibold), size: 20, textStyle: .title3, maximumSize: nil)
        case .body:
            TypeSpec(face: .text(weight: .regular), size: 17, textStyle: .body, maximumSize: nil)
        case .button:
            TypeSpec(face: .text(weight: .semibold), size: 17, textStyle: .body, maximumSize: nil)
        case .callout:
            TypeSpec(face: .text(weight: .regular), size: 15, textStyle: .subheadline, maximumSize: nil)
        case .caption:
            TypeSpec(face: .text(weight: .regular), size: 13, textStyle: .footnote, maximumSize: nil)
        case .label:
            TypeSpec(face: .text(weight: .semibold), size: 12, textStyle: .caption1, maximumSize: 20,
                     trackingEm: 0.06, uppercase: true)
        case .sectionLabel:
            TypeSpec(face: .text(weight: .semibold), size: 12, textStyle: .caption1, maximumSize: nil,
                     trackingEm: 0.06, uppercase: true)
        case .dataLarge:
            TypeSpec(face: .mono(weight: .semibold), size: 22, textStyle: .title3, maximumSize: nil)
        case .data:
            TypeSpec(face: .mono(weight: .medium), size: 15, textStyle: .subheadline, maximumSize: nil)
        case .line:
            TypeSpec(face: .mono(weight: .regular), size: 15, lineHeight: 21,
                     textStyle: .subheadline, maximumSize: nil)
        case .dataSmall:
            TypeSpec(face: .mono(weight: .regular), size: 12, textStyle: .caption1, maximumSize: 18)
        }
    }
}

/// The definition of one text token.
struct TypeSpec: Sendable, Hashable {
    /// The weights this app draws from the system font's range.
    enum Weight: Sendable, Hashable {
        case regular, medium, semibold, bold, heavy

        var uiWeight: UIFont.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            case .heavy: .heavy
            }
        }
    }

    /// The system font's widths. Only the hero move asks for a narrow one, and only when a long
    /// move would otherwise not fit its line.
    enum Width: Sendable, Hashable {
        case standard, condensed, compressed

        var uiWidth: UIFont.Width {
            switch self {
            case .standard: .standard
            case .condensed: .condensed
            case .compressed: .compressed
            }
        }

        /// The width for a value on the 75...100 scale the design document uses for the hero
        /// move's second layout: 100 is the token's own width, below 100 is condensed and 80 or
        /// less is compressed.
        static func forDesignWidth(_ value: CGFloat) -> Width {
            if value <= 80 { return .compressed }
            if value < 100 { return .condensed }
            return .standard
        }
    }

    enum Face: Sendable, Hashable {
        /// SF Pro, the system text face.
        case text(weight: Weight, width: Width = .standard)
        /// SF Mono, for notation, evaluations and other figures that must not jitter.
        case mono(weight: Weight)
    }

    var face: Face
    /// Base size at the default Dynamic Type size (Large).
    var size: CGFloat
    /// The line height at the base size, scaling proportionally, or nil to take the font's
    /// natural line height. Only the two tokens whose layout depends on it set a value.
    var lineHeight: CGFloat?
    /// The text style whose Dynamic Type curve this token follows.
    var textStyle: UIFont.TextStyle
    /// The largest point size at accessibility sizes, or nil for no cap.
    ///
    /// A cap is a refusal: the reader asked for larger text and the app declined. Owner
    /// decision of 2026-09-20 (docs/design.md section 4): only three tokens keep one, and
    /// each is a fixed-geometry instrument rather than something to read.
    ///
    /// - `moveHero` stops at 100 pt because it is already the largest type in the app by a
    ///   factor of two and it sits in a badge the board's width has to hold.
    /// - `label` stops at 20 pt because it letters instruments that are drawn at a fixed size
    ///   (the status pill beside the move, the LINE and THINK column labels, the PRO tag, the
    ///   EDITED badge on the board). Every one of them is one or two words whose meaning does
    ///   not depend on size, and every one is also spoken by VoiceOver.
    /// - `dataSmall` stops at 18 pt because its only shipping use is the rank and file
    ///   coordinates drawn inside the board's edge squares, which are one eighth of a board
    ///   whose side comes from the window, not from the text size.
    ///
    /// Everything a reader reads - titles, headings, button labels, section headings,
    /// paragraphs, captions, prices and engine figures - scales without a cap, and the
    /// layouts give way instead.
    var maximumSize: CGFloat?
    /// Tracking as a fraction of the point size (0.06 is +6%).
    var trackingEm: CGFloat = 0
    /// Uppercase text (label token).
    var uppercase: Bool = false

    init(
        face: Face,
        size: CGFloat,
        lineHeight: CGFloat? = nil,
        textStyle: UIFont.TextStyle,
        maximumSize: CGFloat?,
        trackingEm: CGFloat = 0,
        uppercase: Bool = false
    ) {
        self.face = face
        self.size = size
        self.lineHeight = lineHeight
        self.textStyle = textStyle
        self.maximumSize = maximumSize
        self.trackingEm = trackingEm
        self.uppercase = uppercase
    }
}

/// A resolved font for one token at one Dynamic Type size.
struct ResolvedType {
    var uiFont: UIFont
    var pointSize: CGFloat
    /// The line height the token asked for, or nil when it takes the font's own.
    var requestedLineHeight: CGFloat?
    var tracking: CGFloat
    var uppercase: Bool

    var font: Font { Font(uiFont as CTFont) }
    /// The line height this token lays out on.
    var lineHeight: CGFloat { requestedLineHeight ?? uiFont.lineHeight }
    /// Extra spacing between lines to reach the token's line height (SwiftUI cannot reduce line
    /// spacing below the font's natural line height).
    var lineSpacing: CGFloat { max(0, lineHeight - uiFont.lineHeight) }
    /// Negative padding for the top and the bottom when the font's natural line height is taller
    /// than the token's. The system font leaves generous leading at display sizes (`moveHero` is
    /// 95.4 pt natural against 80 pt), which would put air inside the badge around the move. This
    /// trims the excess evenly, like CSS half-leading, so a single line takes exactly the token's
    /// line height. Lines inside wrapped text keep the natural spacing, because SwiftUI's
    /// `lineSpacing` cannot be negative.
    var verticalTrim: CGFloat { min(0, (lineHeight - uiFont.lineHeight) / 2) }
}

@MainActor
enum Typography {
    /// The one typeface the app still bundles: chess piece glyphs (U+2654 to U+265F), which the
    /// system font does not have.
    nonisolated static let symbolsPostScriptName = "NotoSansSymbols2-Regular"

    private struct CacheKey: Hashable {
        var token: TypeToken
        var category: String
        var width: CGFloat?
    }

    private static var cache: [CacheKey: ResolvedType] = [:]

    /// The font for `token` at `sizeCategory`. `width` narrows a text token for one use, on the
    /// 75...100 scale of design.md section 4 (the hero move's second layout passes 75). It is
    /// ignored by the monospaced tokens, which have one width.
    static func resolve(
        _ token: TypeToken,
        sizeCategory: UIContentSizeCategory = .large,
        width: CGFloat? = nil
    ) -> ResolvedType {
        let key = CacheKey(token: token, category: sizeCategory.rawValue, width: width)
        if let cached = cache[key] { return cached }

        let spec = token.spec
        let pointSize = scaledSize(spec, sizeCategory: sizeCategory)
        let uiFont: UIFont
        switch spec.face {
        case .text(let weight, let defaultWidth):
            let resolvedWidth = width.map(TypeSpec.Width.forDesignWidth) ?? defaultWidth
            uiFont = .systemFont(ofSize: pointSize, weight: weight.uiWeight, width: resolvedWidth.uiWidth)
        case .mono(let weight):
            uiFont = .monospacedSystemFont(ofSize: pointSize, weight: weight.uiWeight)
        }
        let resolved = ResolvedType(
            uiFont: uiFont,
            pointSize: pointSize,
            requestedLineHeight: spec.lineHeight.map { $0 * pointSize / spec.size },
            tracking: spec.trackingEm * pointSize,
            uppercase: spec.uppercase
        )
        cache[key] = resolved
        return resolved
    }

    /// The Dynamic Type scaled size of a token, capped at its maximum.
    static func scaledSize(_ spec: TypeSpec, sizeCategory: UIContentSizeCategory) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: sizeCategory)
        let scaled = UIFontMetrics(forTextStyle: spec.textStyle).scaledValue(for: spec.size, compatibleWith: traits)
        let capped = spec.maximumSize.map { min(scaled, $0) } ?? scaled
        return (capped * 2).rounded() / 2
    }

    /// Noto Sans Symbols 2 (chess glyphs) at `size`.
    static func symbols(size: CGFloat) -> UIFont {
        UIFont(name: symbolsPostScriptName, size: size) ?? .systemFont(ofSize: size)
    }
}

private struct TypographyModifier: ViewModifier {
    let token: TypeToken
    let width: CGFloat?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let resolved = Typography.resolve(token, sizeCategory: UIContentSizeCategory(dynamicTypeSize), width: width)
        content
            .font(resolved.font)
            .lineSpacing(resolved.lineSpacing)
            .tracking(resolved.tracking)
            .textCase(resolved.uppercase ? .uppercase : nil)
            .padding(.vertical, resolved.verticalTrim)
    }
}

extension View {
    /// Sets the font, line spacing, tracking and case of a design-system text token.
    /// `width` narrows the face for this one use, on the 75...100 scale of design.md section 4.
    func typography(_ token: TypeToken, width: CGFloat? = nil) -> some View {
        modifier(TypographyModifier(token: token, width: width))
    }
}

#Preview("Type scale") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            Text("Nxf7+").typography(.moveHero)
            Text("exd8=Q#").typography(.moveHero, width: 75)
            Text("Chess Best Move").typography(.display)
            Text("No board found").typography(.title)
            Text("Yearly").typography(.headline)
            Text(AppCopy.homeIntro).typography(.body)
            Text("Think longer: 10 s").typography(.button)
            Text("Knight takes f7, check").typography(.callout)
            Text("This didn't use a free analysis.").typography(.caption)
            Text("Best move").typography(.label)
            Text("How it works").typography(.sectionLabel)
            Text("+2.35").typography(.dataLarge)
            Text("depth 24    3.0\u{00A0}s    2.3 M n/s").typography(.data)
            Text("1. Nxf7+ Kxf7 2. Qh5+ g6 3. Qxe5").typography(.line)
            Text("a b c d e f g h").typography(.dataSmall)
        }
        .foregroundStyle(Palette.ink)
        .padding(Spacing.s4)
    }
    .background(Palette.canvas)
}
