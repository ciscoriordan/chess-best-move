import SwiftUI

/// Changes the board's hue while preserving its light and dark structure. Applied below
/// arrows, so their cobalt fill and white halo retain their original colors.
struct AnalysisBoardTint: ViewModifier {
    let status: AnalysisCheckStatus?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let status {
                    Rectangle()
                        .fill(status == .mate ? Palette.boardMateTint : Palette.boardCheckTint)
                        .opacity(0.25)
                        .blendMode(.color)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .compositingGroup()
    }
}
