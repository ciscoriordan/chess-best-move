import CoreGraphics
import Foundation

/// Geometry of the Recognizing screen's "found board" moment (design.md 9.2 and 11): where
/// the imported screenshot rests, where the recognized board sits inside it, and where the
/// board lands on the next screen, so the screenshot can scale and crop into that frame and
/// the next screen can take over without a visible jump.
///
/// Every rect is in points. `boardFrame(for:containerWidth:)` is in the coordinates of the
/// screen's safe area (both Recognizing and the destination lay out inside it, under the same
/// inline navigation bar).
enum CaptureBoardLanding {
    /// The screen that takes over after the board lands.
    enum Destination: Sendable, Hashable {
        /// Analysis (design.md 9.3): the user's board crop, right of the evaluation bar.
        case analysis
        /// Check position (design.md 9.5): the recognized pieces on the diagram board.
        case checkPosition
    }

    /// Recognition within this time of the Recognizing screen appearing skips the outline and
    /// goes straight to the crop (design.md 9.2).
    static let skipOutlineWithin: Duration = .milliseconds(150)
    /// The board outline trace (`Motion.stateLong`).
    static let outlineDuration: Duration = .milliseconds(240)
    /// The Reduce Motion crossfade from the screenshot to the board.
    static let reducedMotionCrossfade: Double = 0.2
    /// How long the handoff waits for the crop spring (`Motion.boardCropSpring`, response
    /// 0.32 s, no bounce). The spring is 98.6% of the way at 320 ms and 99.6% at 400 ms, so the
    /// next screen takes over less than a point from where the board came to rest.
    static let cropSettle: Duration = .milliseconds(400)

    /// The board frame of `destination` for a safe area `containerWidth` points wide: Analysis
    /// from `AnalysisLayout` (side gutter, top padding, evaluation bar on the leading side, two
    /// columns on wide screens), and a mirror of `CheckPositionView` (side gutter, 16 pt top
    /// padding, full content width, capped at `Layout.maximumBoardSide`).
    @MainActor
    static func boardFrame(for destination: Destination, containerWidth: CGFloat) -> CGRect {
        let gutter = Layout.sideGutter(forWidth: containerWidth)
        let contentWidth = max(0, containerWidth - 2 * gutter)
        switch destination {
        case .analysis:
            let side = AnalysisLayout.boardSide(contentWidth: contentWidth)
            return CGRect(x: gutter + AnalysisLayout.evalBarColumn, y: AnalysisLayout.topPadding, width: side, height: side)
        case .checkPosition:
            let side = min(contentWidth, Layout.maximumBoardSide)
            return CGRect(x: gutter, y: Spacing.s4, width: side, height: side)
        }
    }

    /// The whole screenshot fitted into `slot` (aspect fit, top aligned, centered
    /// horizontally), in the slot's coordinates.
    static func restingImageFrame(imageSize: CGSize, in slot: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, slot.width > 0, slot.height > 0 else {
            return .zero
        }
        let scale = min(slot.width / imageSize.width, slot.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (slot.width - size.width) / 2, y: 0, width: size.width, height: size.height)
    }

    /// `pixelRect` (in the screenshot's pixels) inside the screenshot drawn at `imageFrame`.
    static func boardFrame(pixelRect: CGRect, imageSize: CGSize, imageFrame: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scaleX = imageFrame.width / imageSize.width
        let scaleY = imageFrame.height / imageSize.height
        return CGRect(
            x: imageFrame.minX + pixelRect.minX * scaleX,
            y: imageFrame.minY + pixelRect.minY * scaleY,
            width: pixelRect.width * scaleX,
            height: pixelRect.height * scaleY
        )
    }

    /// The screenshot's frame once the board inside it (`board`, while the screenshot is at
    /// `imageFrame`) has been scaled and moved onto `landing`. The scale is uniform, taken
    /// from the widths.
    static func landedImageFrame(imageFrame: CGRect, board: CGRect, landing: CGRect) -> CGRect {
        guard board.width > 0 else { return imageFrame }
        let scale = landing.width / board.width
        return CGRect(
            x: landing.minX - (board.minX - imageFrame.minX) * scale,
            y: landing.minY - (board.minY - imageFrame.minY) * scale,
            width: imageFrame.width * scale,
            height: imageFrame.height * scale
        )
    }

    /// The recognized board rect when it is usable for the animation: non-empty and inside
    /// the image (allowing half a pixel of rounding).
    static func usableBoardRect(_ rect: CGRect?, imageSize: CGSize) -> CGRect? {
        guard let rect, rect.width >= 1, rect.height >= 1 else { return nil }
        let bounds = CGRect(origin: .zero, size: imageSize).insetBy(dx: -0.5, dy: -0.5)
        return bounds.contains(rect) ? rect : nil
    }
}
