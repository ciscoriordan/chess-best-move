import CoreText
import SwiftUI
import UIKit

/// Text tokens from docs/design.md section 4.
///
/// Apply with `.typography(.headline)`. The modifier builds the font for the current
/// Dynamic Type size: it scales the base size with the token's text style, caps it at the
/// token's maximum, and then sets Bricolage Grotesque's variation axes (`wght`, `opsz`,
/// `wdth`) explicitly for the final size, because Core Text does not apply optical size
/// automatically (design.md section 2).
enum TypeToken: String, CaseIterable, Sendable {
    /// The best move. Bricolage 88/84, 800 / opsz 96 fixed / wdth 90.
    case moveHero
    /// Home wordmark, paywall headline. Bricolage 40/42, 750 / auto / 95.
    case display
    /// Screen titles. Bricolage 28/32, 700.
    case title
    /// Row titles, paywall option titles. Bricolage 20/24, 650.
    case headline
    /// Paragraphs, instructions. Bricolage 17/23, 420.
    case body
    /// Button labels. Bricolage 17/22, 650.
    case button
    /// Chips, list secondary text, spoken move. Bricolage 15/20, 500.
    case callout
    /// Fine print, hints. Bricolage 13/17, 520.
    case caption
    /// Uppercase instrument labels (BEST MOVE, LINE, THINK). Bricolage 12/16, 650, `case`
    /// feature, +6% tracking. Short labels only.
    case label
    /// Eval next to the hero move. IBM Plex Mono SemiBold 22/26.
    case dataLarge
    /// Depth, clock, nodes per second, prices. IBM Plex Mono Medium 15/20.
    case data
    /// Engine line. IBM Plex Mono Regular 15/22.
    case line
    /// Board coordinates, version numbers. IBM Plex Mono Regular 12/16.
    case dataSmall

    var spec: TypeSpec {
        switch self {
        case .moveHero:
            TypeSpec(face: .bricolage(weight: 800, opticalSize: .fixed(96), width: 90), size: 88, lineHeight: 84,
                     textStyle: .largeTitle, maximumSize: 110, trackingEm: -0.01)
        case .display:
            TypeSpec(face: .bricolage(weight: 750, opticalSize: .automatic, width: 95), size: 40, lineHeight: 42,
                     textStyle: .largeTitle, maximumSize: 64)
        case .title:
            TypeSpec(face: .bricolage(weight: 700, opticalSize: .automatic, width: 100), size: 28, lineHeight: 32,
                     textStyle: .title1, maximumSize: 44)
        case .headline:
            TypeSpec(face: .bricolage(weight: 650, opticalSize: .automatic, width: 100), size: 20, lineHeight: 24,
                     textStyle: .title3, maximumSize: 34)
        case .body:
            TypeSpec(face: .bricolage(weight: 420, opticalSize: .automatic, width: 100), size: 17, lineHeight: 23,
                     textStyle: .body, maximumSize: nil)
        case .button:
            TypeSpec(face: .bricolage(weight: 650, opticalSize: .automatic, width: 100), size: 17, lineHeight: 22,
                     textStyle: .body, maximumSize: 28)
        case .callout:
            TypeSpec(face: .bricolage(weight: 500, opticalSize: .automatic, width: 100), size: 15, lineHeight: 20,
                     textStyle: .callout, maximumSize: nil)
        case .caption:
            TypeSpec(face: .bricolage(weight: 520, opticalSize: .automatic, width: 100), size: 13, lineHeight: 17,
                     textStyle: .caption1, maximumSize: nil)
        case .label:
            TypeSpec(face: .bricolage(weight: 650, opticalSize: .automatic, width: 100), size: 12, lineHeight: 16,
                     textStyle: .caption2, maximumSize: 20, trackingEm: 0.06, uppercase: true)
        case .dataLarge:
            TypeSpec(face: .plexMono(.semiBold), size: 22, lineHeight: 26, textStyle: .title3, maximumSize: 34)
        case .data:
            TypeSpec(face: .plexMono(.medium), size: 15, lineHeight: 20, textStyle: .callout, maximumSize: nil)
        case .line:
            TypeSpec(face: .plexMono(.regular), size: 15, lineHeight: 22, textStyle: .callout, maximumSize: nil)
        case .dataSmall:
            TypeSpec(face: .plexMono(.regular), size: 12, lineHeight: 16, textStyle: .caption2, maximumSize: 18)
        }
    }
}

/// The definition of one text token.
struct TypeSpec: Sendable, Hashable {
    enum OpticalSize: Sendable, Hashable {
        /// `opsz` follows the final (Dynamic Type scaled) point size, clamped to 12...96.
        case automatic
        /// `opsz` stays at this value at every size.
        case fixed(CGFloat)
    }

    enum PlexWeight: String, Sendable, Hashable {
        case regular = "IBMPlexMono-Regular"
        case medium = "IBMPlexMono-Medium"
        case semiBold = "IBMPlexMono-SemiBold"
    }

    enum Face: Sendable, Hashable {
        case bricolage(weight: CGFloat, opticalSize: OpticalSize, width: CGFloat)
        case plexMono(PlexWeight)
    }

    var face: Face
    /// Base size at the default Dynamic Type size (Large).
    var size: CGFloat
    /// Line height at the base size; scales proportionally.
    var lineHeight: CGFloat
    /// The text style whose Dynamic Type curve this token follows.
    var textStyle: UIFont.TextStyle
    /// The largest point size at accessibility sizes, or nil for no cap.
    var maximumSize: CGFloat?
    /// Tracking as a fraction of the point size (-0.01 is -1%).
    var trackingEm: CGFloat = 0
    /// Uppercase text with the `case` feature (label token).
    var uppercase: Bool = false
}

/// A resolved font for one token at one Dynamic Type size.
struct ResolvedType {
    var uiFont: UIFont
    var pointSize: CGFloat
    var lineHeight: CGFloat
    var tracking: CGFloat
    var uppercase: Bool

    var font: Font { Font(uiFont as CTFont) }
    /// Extra spacing between lines to approach the token's line height (SwiftUI cannot
    /// reduce line spacing below the font's natural line height).
    var lineSpacing: CGFloat { max(0, lineHeight - uiFont.lineHeight) }
    /// Negative padding for the top and the bottom when the font's natural line height is
    /// taller than the token's (Bricolage at display sizes: `moveHero` is 105.6 pt natural
    /// against 84 pt). It trims the excess evenly, like CSS half-leading, so a single line
    /// takes exactly the token's line height. Lines inside wrapped text keep the natural
    /// spacing, because SwiftUI's `lineSpacing` cannot be negative.
    var verticalTrim: CGFloat { min(0, (lineHeight - uiFont.lineHeight) / 2) }
}

@MainActor
enum Typography {
    /// PostScript name of the variable font's default instance ("96pt ExtraBold"). The
    /// named instances have no PostScript names; every weight comes from variation axes.
    nonisolated static let bricolagePostScriptName = "BricolageGrotesque-96ptExtraBold"
    nonisolated static let symbolsPostScriptName = "NotoSansSymbols2-Regular"

    /// Variation axis tags as integers.
    enum AxisTag {
        static let weight = 0x7767_6874  // 'wght'
        static let opticalSize = 0x6F70_737A  // 'opsz'
        static let width = 0x7764_7468  // 'wdth'
    }

    private struct CacheKey: Hashable {
        var token: TypeToken
        var category: String
        var width: CGFloat?
    }

    private static var cache: [CacheKey: ResolvedType] = [:]

    /// The font for `token` at `sizeCategory`. `width` overrides the `wdth` axis of a
    /// Bricolage token (for example 75 for the hero move's second layout).
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
        case .bricolage(let weight, let opticalSize, let defaultWidth):
            let opsz: CGFloat
            switch opticalSize {
            case .automatic: opsz = pointSize
            case .fixed(let value): opsz = value
            }
            uiFont = bricolage(
                size: pointSize,
                weight: weight,
                opticalSize: opsz,
                width: width ?? defaultWidth,
                uppercaseForms: spec.uppercase
            )
        case .plexMono(let weight):
            uiFont = UIFont(name: weight.rawValue, size: pointSize) ?? .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        }
        let resolved = ResolvedType(
            uiFont: uiFont,
            pointSize: pointSize,
            lineHeight: spec.lineHeight * pointSize / spec.size,
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

    /// Bricolage Grotesque with every variation axis set explicitly.
    static func bricolage(
        size: CGFloat,
        weight: CGFloat,
        opticalSize: CGFloat,
        width: CGFloat,
        uppercaseForms: Bool = false
    ) -> UIFont {
        let variations: [Int: CGFloat] = [
            AxisTag.weight: min(max(weight, 200), 800),
            AxisTag.opticalSize: min(max(opticalSize, 12), 96),
            AxisTag.width: min(max(width, 75), 100),
        ]
        var attributes: [UIFontDescriptor.AttributeName: Any] = [
            .name: bricolagePostScriptName,
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variations,
        ]
        if uppercaseForms {
            attributes[.featureSettings] = [[
                UIFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureTag as String): "case",
                UIFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureValue as String): 1,
            ]]
        }
        return UIFont(descriptor: UIFontDescriptor(fontAttributes: attributes), size: size)
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
    /// `width` overrides the Bricolage `wdth` axis (75...100).
    func typography(_ token: TypeToken, width: CGFloat? = nil) -> some View {
        modifier(TypographyModifier(token: token, width: width))
    }
}

#Preview("Type scale") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            Text("Nxf7+").typography(.moveHero)
            Text("exd8=Q#").typography(.moveHero, width: 75)
            Text("Best Move").typography(.display)
            Text("No board found").typography(.title)
            Text("Yearly").typography(.headline)
            Text(AppCopy.homeIntro).typography(.body)
            Text("Think longer: 10 s").typography(.button)
            Text("Knight takes f7, check").typography(.callout)
            Text("This didn't use a free analysis.").typography(.caption)
            Text("Best move").typography(.label)
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
