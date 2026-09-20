import SwiftUI

/// The evaluation bar (design.md section 8): 10 pt wide, the board's height, square ends,
/// 1 px `evalOutline`. White's share sits at the bottom when White is at the bottom of the
/// displayed board, at the top when the board is flipped. Updates animate over 240 ms at most
/// 5 times per second; Reduce Motion jumps to the value.
///
/// Before the engine reports anything the bar is an empty `evalEmpty` track rather than a
/// half-and-half bar at 40% opacity. The faded bar was a claim the app could not make: in
/// light mode its white half measured 1.02:1 against the background, so what a reader saw was
/// a half-height dark bar, which is what "Black is far ahead" looks like.
///
/// The track is a mid tone of its own and not `sunken`, because it has to be read as neither
/// half rather than as one of them. `sunken` measures 1.18:1 against `evalWhite` in light mode
/// and 1.02:1 against `evalBlack` in dark, so an empty track was a full White bar in one theme
/// and a full Black bar in the other - and a full bar is a real reading, the one a forced mate
/// gives. `evalEmpty` is 3.7:1 or more from both halves under every trait combination
/// (`AccessibilityContrastTests`), so nothing that is not a reading can be mistaken for one.
struct AnalysisEvalBar: View {
    /// White's share, 0...1 (`AnalysisScore.whiteShare`).
    let whiteShare: Double
    /// Before the first engine report: an empty mid-tone track, not a 50/50 bar.
    let isPlaceholder: Bool
    let whiteAtBottom: Bool
    /// "White is ahead by 2.4 pawns", "Equal", "White mates in 3".
    let accessibilityValueText: String

    static let width: CGFloat = 10
    static let spacing: CGFloat = 6
    /// At most 5 updates per second.
    static let minimumUpdateInterval: Duration = .milliseconds(200)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var displayedShare: Double?
    @State private var lastUpdate: ContinuousClock.Instant?

    var body: some View {
        GeometryReader { proxy in
            let segment = Self.whiteSegment(share: displayedShare ?? whiteShare, height: proxy.size.height, whiteAtBottom: whiteAtBottom)
            ZStack(alignment: .topLeading) {
                if isPlaceholder {
                    Rectangle().fill(Palette.evalEmpty)
                } else {
                    Rectangle().fill(Palette.evalBlack)
                    Rectangle()
                        .fill(Palette.evalWhite)
                        .frame(height: segment.upperBound - segment.lowerBound)
                        .offset(y: segment.lowerBound)
                }
            }
            .overlay(Rectangle().strokeBorder(Palette.evalOutline, lineWidth: LineWidth.hairline(displayScale: displayScale)))
        }
        .frame(width: Self.width)
        .task(id: whiteShare) { await update(to: whiteShare) }
        .accessibilityElement()
        // "Evaluation bar", not "Evaluation": the readout beside the board carries the same
        // number under the label "Evaluation", and a reader swiping down the screen heard the
        // identical sentence twice with nothing to tell the two apart (design.md section 8).
        .accessibilityLabel("Evaluation bar")
        .accessibilityValue(accessibilityValueText)
        .accessibilityIgnoresInvertColors()
    }

    /// The vertical extent of White's segment, measured from the top of a bar `height` tall:
    /// anchored at the bottom when White is at the bottom of the board, at the top when flipped.
    nonisolated static func whiteSegment(share: Double, height: CGFloat, whiteAtBottom: Bool) -> ClosedRange<CGFloat> {
        let whiteHeight = height * CGFloat(min(max(share, 0), 1))
        return whiteAtBottom ? (height - whiteHeight)...height : 0...whiteHeight
    }

    private func update(to target: Double) async {
        guard let current = displayedShare, current != target else {
            displayedShare = target
            lastUpdate = .now
            return
        }
        if let lastUpdate {
            let earliest = lastUpdate.advanced(by: Self.minimumUpdateInterval)
            if earliest > .now {
                // A newer value cancels this task; only the latest value is applied.
                do { try await Task.sleep(until: earliest, clock: .continuous) } catch { return }
            }
        }
        lastUpdate = .now
        if reduceMotion {
            displayedShare = target
        } else {
            withAnimation(.easeOut(duration: Motion.stateLong)) { displayedShare = target }
        }
    }
}
