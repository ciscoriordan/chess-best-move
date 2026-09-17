import SwiftUI

/// Spacing scale in points (docs/design.md section 5).
enum Spacing {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32
    static let s7: CGFloat = 48
}

/// Corner radii in points. Nothing in app content goes above `r3`.
enum Radius {
    /// Rules and eval bar ends.
    static let r0: CGFloat = 0
    /// Board crop, diagram board, low-confidence badge squares.
    static let r1: CGFloat = 4
    /// Buttons, chips, segmented track, palette cells.
    static let r2: CGFloat = 8
    /// Paywall option rows.
    static let r3: CGFloat = 12
}

/// Line widths.
enum LineWidth {
    /// 1 pt `rule2` border of controls.
    static let control: CGFloat = 1
    /// 2 pt `accent` selection outline.
    static let selection: CGFloat = 2
    /// 2 pt dashed `caution` outline of low-confidence squares.
    static let lowConfidence: CGFloat = 2
    /// Dash pattern of the low-confidence outline (dash 4, gap 3).
    static let lowConfidenceDash: [CGFloat] = [4, 3]

    /// A true 1 px hairline for the given display scale.
    static func hairline(displayScale: CGFloat) -> CGFloat {
        1 / max(displayScale, 1)
    }
}

/// Layout constants.
enum Layout {
    /// Minimum hit target for every control.
    static let minimumHitTarget: CGFloat = 44
    /// Primary and secondary button height.
    static let buttonHeight: CGFloat = 52
    /// Secondary button height in dense rows.
    static let denseButtonHeight: CGFloat = 44
    /// Visual chip height (the hit target stays 44).
    static let chipHeight: CGFloat = 36
    /// Minimum list row height.
    static let listRowHeight: CGFloat = 56
    /// Maximum board side on iPad and in landscape.
    static let maximumBoardSide: CGFloat = 600

    /// Side gutter: 16 on phones up to 402 pt wide, 20 above.
    static func sideGutter(forWidth width: CGFloat) -> CGFloat {
        width > 402 ? 20 : 16
    }
}

/// Animation durations (docs/design.md section 11). Every animation must also respect
/// Reduce Motion as described in that section.
enum Motion {
    /// Button press.
    static let press: Double = 0.09
    /// Value changes (SAN crossfade, editor piece placement).
    static let valueChange: Double = 0.12
    /// Element state changes, short (analysis complete).
    static let stateShort: Double = 0.16
    /// Element state changes, long (eval bar, board rect outline).
    static let stateLong: Double = 0.24
    /// Screenshot to board crop: the response of `boardCropSpring`.
    static let boardCrop: Double = 0.32

    /// The board crop spring: no bounce.
    static let boardCropSpring = Animation.spring(response: boardCrop, dampingFraction: 1.0)
}

private struct SideGutterModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, gutter)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                // The measured view includes the padding, so this is the full width.
                gutter = Layout.sideGutter(forWidth: width)
            }
    }

    @State private var gutter: CGFloat = 16
}

extension View {
    /// Applies the screen side gutter (16 or 20 pt depending on the available width).
    func sideGutter() -> some View {
        modifier(SideGutterModifier())
    }
}
