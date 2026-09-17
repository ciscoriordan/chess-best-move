// The best-move arrow (design.md section 7): geometry in board-square units, and the overlay
// that paints it over the user's board crop or the diagram in the displayed orientation.

import ChessCore
import SwiftUI

// MARK: - Geometry

/// Arrow geometry for one move on a displayed board of side `boardSide` points.
///
/// Squares map through `BoardGeometry`, so with Black at the bottom files and ranks are
/// mirrored (h1 at the top left). A knight move is an L: the first leg runs along the
/// two-square direction to the center of the corner square, the second leg along the
/// one-square direction. Castling is the king's move (e1g1), as UCI reports it.
struct AnalysisArrowGeometry: Sendable, Equatable {
    /// Proportions in units of the square side `S`.
    enum Proportion {
        static let shaftWidth: CGFloat = 0.20
        static let tailOffset: CGFloat = 0.30
        static let tipInset: CGFloat = 0.10
        static let headLength: CGFloat = 0.44
        static let headWidth: CGFloat = 0.56
        static let halo: CGFloat = 0.05
        static let badgeDiameter: CGFloat = 0.42
        static let badgeRing: CGFloat = 0.05
        static let badgeGlyph: CGFloat = 0.30
    }

    /// Side length of one square in points.
    var squareSide: CGFloat
    /// The centerline from the tail through the knight's corner (if any) to the tip.
    var centerline: [CGPoint]
    /// The corner square's center of a knight move.
    var corner: CGPoint?
    var promotion: PieceKind?

    var tail: CGPoint { centerline[0] }
    var tip: CGPoint { centerline[centerline.count - 1] }
    var isKnightMove: Bool { corner != nil }

    /// The center of the head's base.
    var headBase: CGPoint {
        let direction = Self.unit(from: centerline[centerline.count - 2], to: tip)
        return CGPoint(x: tip.x - direction.dx * Proportion.headLength * squareSide,
                       y: tip.y - direction.dy * Proportion.headLength * squareSide)
    }

    /// The two base corners of the head triangle.
    var headBaseCorners: (CGPoint, CGPoint) {
        let direction = Self.unit(from: centerline[centerline.count - 2], to: tip)
        let half = Proportion.headWidth * squareSide / 2
        let base = headBase
        return (CGPoint(x: base.x - direction.dy * half, y: base.y + direction.dx * half),
                CGPoint(x: base.x + direction.dy * half, y: base.y - direction.dx * half))
    }

    /// The promotion badge center (on the tip), when the move promotes.
    var promotionBadgeCenter: CGPoint? { promotion == nil ? nil : tip }

    init?(move: Move, whiteAtBottom: Bool, boardSide: CGFloat) {
        guard boardSide > 0, move.from != move.to else { return nil }
        let side = boardSide / 8
        squareSide = side
        promotion = move.promotion

        let from = BoardGeometry.center(of: move.from, side: boardSide, whiteAtBottom: whiteAtBottom)
        let to = BoardGeometry.center(of: move.to, side: boardSide, whiteAtBottom: whiteAtBottom)
        let fileDelta = move.to.file - move.from.file
        let rankDelta = move.to.rank - move.from.rank

        var cornerSquare: Square?
        if abs(fileDelta) == 1 && abs(rankDelta) == 2 {
            cornerSquare = Square(file: move.from.file, rank: move.to.rank)
        } else if abs(fileDelta) == 2 && abs(rankDelta) == 1 {
            cornerSquare = Square(file: move.to.file, rank: move.from.rank)
        }

        if let cornerSquare {
            let corner = BoardGeometry.center(of: cornerSquare, side: boardSide, whiteAtBottom: whiteAtBottom)
            let first = Self.unit(from: from, to: corner)
            let second = Self.unit(from: corner, to: to)
            self.corner = corner
            centerline = [
                CGPoint(x: from.x + first.dx * Proportion.tailOffset * side, y: from.y + first.dy * Proportion.tailOffset * side),
                corner,
                CGPoint(x: to.x - second.dx * Proportion.tipInset * side, y: to.y - second.dy * Proportion.tipInset * side),
            ]
        } else {
            let direction = Self.unit(from: from, to: to)
            corner = nil
            centerline = [
                CGPoint(x: from.x + direction.dx * Proportion.tailOffset * side, y: from.y + direction.dy * Proportion.tailOffset * side),
                CGPoint(x: to.x - direction.dx * Proportion.tipInset * side, y: to.y - direction.dy * Proportion.tipInset * side),
            ]
        }
    }

    /// Length of the centerline from tail to tip.
    var length: CGFloat {
        zip(centerline, centerline.dropFirst()).reduce(0) { $0 + Self.distance($1.0, $1.1) }
    }

    /// The filled arrow shape (shaft plus head) drawn up to `progress` (0...1) of its length,
    /// for the "draws from tail to tip" animation. At 1 it is the complete arrow.
    func outline(progress: CGFloat = 1) -> Path {
        let total = length
        let drawn = total * min(max(progress, 0), 1)
        guard drawn > 0 else { return Path() }

        let (tipPoint, direction) = point(atDistance: drawn)
        let headLength = min(Proportion.headLength * squareSide, drawn)
        let headScale = headLength / (Proportion.headLength * squareSide)
        let half = Proportion.headWidth * squareSide / 2 * headScale
        let base = CGPoint(x: tipPoint.x - direction.dx * headLength, y: tipPoint.y - direction.dy * headLength)

        var head = Path()
        head.move(to: tipPoint)
        head.addLine(to: CGPoint(x: base.x - direction.dy * half, y: base.y + direction.dx * half))
        head.addLine(to: CGPoint(x: base.x + direction.dy * half, y: base.y - direction.dx * half))
        head.closeSubpath()

        // The shaft runs slightly into the head so the union has no seam at the base.
        let shaftEnd = drawn - headLength + min(0.02 * squareSide, headLength)
        guard shaftEnd > 0 else { return head }
        var shaft = Path()
        shaft.addLines(points(upToDistance: shaftEnd))
        let shaftOutline = shaft.strokedPath(StrokeStyle(
            lineWidth: Proportion.shaftWidth * squareSide,
            lineCap: .butt,
            lineJoin: .round
        ))
        return shaftOutline.union(head)
    }

    /// The centerline points from the tail up to `distance`.
    func points(upToDistance distance: CGFloat) -> [CGPoint] {
        var result = [centerline[0]]
        var remaining = distance
        for (start, end) in zip(centerline, centerline.dropFirst()) {
            let segment = Self.distance(start, end)
            if remaining <= segment {
                let t = segment > 0 ? remaining / segment : 0
                result.append(CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                return result
            }
            result.append(end)
            remaining -= segment
        }
        return result
    }

    /// The point at `distance` along the centerline, and the direction of travel there.
    func point(atDistance distance: CGFloat) -> (CGPoint, CGVector) {
        var remaining = distance
        let segments = Array(zip(centerline, centerline.dropFirst()))
        for (index, (start, end)) in segments.enumerated() {
            let segment = Self.distance(start, end)
            if remaining <= segment || index == segments.count - 1 {
                let t = segment > 0 ? min(remaining / segment, 1) : 0
                return (CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                        Self.unit(from: start, to: end))
            }
            remaining -= segment
        }
        return (tip, Self.unit(from: centerline[centerline.count - 2], to: tip))
    }

    static func unit(from start: CGPoint, to end: CGPoint) -> CGVector {
        let length = distance(start, end)
        guard length > 0 else { return CGVector(dx: 0, dy: 0) }
        return CGVector(dx: (end.x - start.x) / length, dy: (end.y - start.y) / length)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}

// MARK: - Overlay

/// The arrow over the board. Group opacity 0.55 while the engine is thinking, 0.92 when the
/// result is final. The first arrow draws from tail to tip (220 ms); a changed move fades the
/// old arrow (120 ms) while the new one draws (180 ms). Reduce Motion: fades only.
struct AnalysisArrowOverlay: View {
    let move: Move?
    let whiteAtBottom: Bool
    let isFinal: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hasShownArrow = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                if let move, let geometry = AnalysisArrowGeometry(move: move, whiteAtBottom: whiteAtBottom, boardSide: side) {
                    AnalysisArrowDrawing(
                        geometry: geometry,
                        haloScale: Palette.arrowHaloScale(for: contrast),
                        drawDuration: reduceMotion ? nil : (hasShownArrow ? 0.18 : 0.22)
                    )
                    .id("\(move.uci)-\(whiteAtBottom)")
                    .transition(.opacity.animation(.easeOut(duration: Motion.valueChange)))
                    .onAppear { hasShownArrow = true }
                }
            }
            .frame(width: side, height: side)
        }
        .opacity(isFinal ? 0.92 : 0.55)
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.stateShort), value: isFinal)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One arrow instance: animates its own draw-in when it appears.
private struct AnalysisArrowDrawing: View {
    let geometry: AnalysisArrowGeometry
    let haloScale: CGFloat
    /// Seconds for the draw-in, or nil to appear complete (Reduce Motion).
    let drawDuration: Double?

    @State private var progress: CGFloat = 0

    var body: some View {
        AnalysisArrowCanvas(geometry: geometry, progress: drawDuration == nil ? 1 : progress, haloScale: haloScale)
            .onAppear {
                guard let drawDuration else { return }
                withAnimation(.easeOut(duration: drawDuration)) { progress = 1 }
            }
    }
}

/// Paints the arrow in one composited layer: outer edge, halo, fill, then the promotion badge.
private struct AnalysisArrowCanvas: View, Animatable {
    let geometry: AnalysisArrowGeometry
    var progress: CGFloat
    let haloScale: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let geometry = geometry
        let progress = progress
        let haloScale = haloScale
        let pixel = 1 / max(displayScale, 1)
        Canvas { context, _ in
            let side = geometry.squareSide
            let outline = geometry.outline(progress: progress)
            let halo = AnalysisArrowGeometry.Proportion.halo * side * haloScale

            // 1. Outer edge: the outline expanded by the halo plus 1 px.
            context.stroke(outline, with: .color(Palette.arrowEdge), style: StrokeStyle(lineWidth: 2 * (halo + pixel), lineJoin: .round))
            // 2. Halo and 3. fill replace what is under them, so overlaps never double up.
            context.blendMode = .copy
            context.stroke(outline, with: .color(Palette.arrowHalo), style: StrokeStyle(lineWidth: 2 * halo, lineJoin: .round))
            context.fill(outline, with: .color(Palette.arrowFill))

            if progress >= 1, let center = geometry.promotionBadgeCenter, let promotion = geometry.promotion {
                let ring = AnalysisArrowGeometry.Proportion.badgeRing * side
                let radius = AnalysisArrowGeometry.Proportion.badgeDiameter * side / 2
                let outer = Path(ellipseIn: CGRect(x: center.x - radius - ring, y: center.y - radius - ring,
                                                   width: 2 * (radius + ring), height: 2 * (radius + ring)))
                let inner = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
                context.fill(outer, with: .color(Palette.arrowHalo))
                context.fill(inner, with: .color(Palette.arrowFill))
                context.blendMode = .normal
                if let glyph = GlyphOutlines.shared.path(for: promotion, solid: true) {
                    let bounds = glyph.boundingRect
                    if bounds.width > 0, bounds.height > 0 {
                        let target = AnalysisArrowGeometry.Proportion.badgeGlyph * side
                        let factor = target / max(bounds.width, bounds.height)
                        let transform = CGAffineTransform(translationX: center.x, y: center.y)
                            .scaledBy(x: factor, y: -factor)
                            .translatedBy(x: -bounds.midX, y: -bounds.midY)
                        context.fill(glyph.applying(transform), with: .color(Palette.piecePaper))
                    }
                }
            }
        }
    }
}
