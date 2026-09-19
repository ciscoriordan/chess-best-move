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

    /// Side gutter: 16 on phones up to 402 pt wide, 20 above (design.md section 5).
    ///
    /// `width` must be a width the gutter itself cannot change, such as the width of the
    /// window (`EnvironmentValues.windowWidth`) or of a container measured before the gutter
    /// is applied. Reading back the width of a view this gutter already padded makes the two
    /// answers chase each other (see `SideGutterModifier`).
    ///
    /// The comparison allows half a point of slack because 402 pt is exactly the width of a
    /// shipping phone (iPhone 17 Pro, iPhone 16 Pro): a width that arrives a fraction of a
    /// point over, as a measured width can, must still answer 16. The next phone width above
    /// 402 pt is 430 pt, so no real device falls in the slack.
    static func sideGutter(forWidth width: CGFloat) -> CGFloat {
        width > narrowScreenWidth + 0.5 ? wideSideGutter : narrowSideGutter
    }

    /// The widest screen that still gets the 16 pt gutter.
    static let narrowScreenWidth: CGFloat = 402
    /// The gutter up to `narrowScreenWidth`, and the gutter used when no width is known.
    static let narrowSideGutter: CGFloat = 16
    /// The gutter above `narrowScreenWidth`.
    static let wideSideGutter: CGFloat = 20
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

extension EnvironmentValues {
    /// The width of the window the app draws in, in points, or nil before it has been measured.
    /// Published once at the root of the scene by `measuresWindowWidth()`; the side gutter reads
    /// it instead of measuring a view of its own.
    @Entry var windowWidth: CGFloat?
}

/// Measures the width of the view it is applied to and publishes it as
/// `EnvironmentValues.windowWidth`. Applied once, at the root of the scene, so the width it
/// publishes is the window's and nothing further down the tree can change it.
private struct WindowWidthModifier: ViewModifier {
    @State private var width: CGFloat?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width = $0 }
            .environment(\.windowWidth, width)
    }
}

/// The screen side gutter, taken from the window width rather than from a measurement of its
/// own view.
///
/// It used to apply its padding and then read the width of the padded view back into the
/// `@State` the padding came from. That is a layout feedback loop: when the content inside
/// stops shrinking, the padded view is wider than the width the parent proposed, so the
/// measured width depends on the gutter, and the gutter depends on the measured width. On an
/// iPhone 17 Pro at `UICTContentSizeCategoryAccessibilityXXXL` the two answers alternated
/// forever (gutter 16 measured 402.333 pt and asked for 20, gutter 20 measured 402.000 pt and
/// asked for 16; 26,363 flips in 12 s, measured 2026-09-18), the app never drew a frame and
/// every accessibility query timed out. The window width cannot be changed by padding applied
/// inside the window, so reading it settles in one pass.
private struct SideGutterModifier: ViewModifier {
    @Environment(\.windowWidth) private var windowWidth

    func body(content: Content) -> some View {
        content.padding(.horizontal, gutter)
    }

    /// Before the first measurement the narrow gutter is used: it is the phone value, and one
    /// layout pass later the measured width decides.
    private var gutter: CGFloat {
        guard let windowWidth else { return Layout.narrowSideGutter }
        return Layout.sideGutter(forWidth: windowWidth)
    }
}

extension View {
    /// Applies the screen side gutter (16 or 20 pt depending on the window width).
    func sideGutter() -> some View {
        modifier(SideGutterModifier())
    }

    /// Publishes this view's width as `EnvironmentValues.windowWidth` for everything inside it.
    /// Apply once, at the root of the scene; `sideGutter()` reads it.
    func measuresWindowWidth() -> some View {
        modifier(WindowWidthModifier())
    }
}
