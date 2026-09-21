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
        /// How far the notch of the other player's arrowhead is cut back toward the tip. The
        /// answer's head is the plain triangle, so this is 0 for it (design.md section 7).
        static let headNotch: CGFloat = 0.16
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

    /// The same arrow moved sideways by `offset` points: every vertex shifts together, so the
    /// shape, the head's direction and the notch are exactly what they were.
    ///
    /// Used only to move two collinear arrows apart (`AnalysisArrowSeparation`). A pure
    /// translation is what keeps the transverse cases provably untouched: an arrow that is not
    /// moved is drawn from the same path as before, byte for byte.
    func translated(by offset: CGVector) -> AnalysisArrowGeometry {
        var moved = self
        moved.centerline = centerline.map { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) }
        moved.corner = corner.map { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) }
        return moved
    }

    /// Length of the centerline from tail to tip.
    var length: CGFloat {
        zip(centerline, centerline.dropFirst()).reduce(0) { $0 + Self.distance($1.0, $1.1) }
    }

    /// The filled arrow shape (shaft plus head) drawn up to `progress` (0...1) of its length,
    /// for the "draws from tail to tip" animation. At 1 it is the complete arrow.
    ///
    /// `headNotch`, in units of the square side, cuts a V into the base of the head so that the
    /// two barbs sweep back from the tip. It is the difference that tells the two arrows apart
    /// without using color (design.md section 7): the answer passes 0 and keeps the plain
    /// triangle it has always had, and the move of the player at the top passes
    /// `Proportion.headNotch`. The notch shrinks with the head during the draw-in, so the shape
    /// is the same at every stage of the animation.
    func outline(progress: CGFloat = 1, headNotch: CGFloat = 0) -> Path {
        let total = length
        let drawn = total * min(max(progress, 0), 1)
        guard drawn > 0 else { return Path() }

        let (tipPoint, direction) = point(atDistance: drawn)
        let headLength = min(Proportion.headLength * squareSide, drawn)
        let headScale = headLength / (Proportion.headLength * squareSide)
        let half = Proportion.headWidth * squareSide / 2 * headScale
        let base = CGPoint(x: tipPoint.x - direction.dx * headLength, y: tipPoint.y - direction.dy * headLength)
        // Never deeper than the head is long, or the barbs would cross in front of the tip.
        let notch = min(max(headNotch, 0) * squareSide * headScale, headLength * 0.5)

        var head = Path()
        head.move(to: tipPoint)
        head.addLine(to: CGPoint(x: base.x - direction.dy * half, y: base.y + direction.dx * half))
        if notch > 0 {
            head.addLine(to: CGPoint(x: base.x + direction.dx * notch, y: base.y + direction.dy * notch))
        }
        head.addLine(to: CGPoint(x: base.x + direction.dy * half, y: base.y - direction.dx * half))
        head.closeSubpath()

        // The shaft runs slightly into the head so the union has no seam at the base. With a
        // notch it runs as far as the notch's apex instead, so the shaft meets the barbs where
        // they meet each other rather than leaving a stub inside the V.
        let shaftEnd = drawn - headLength + min(notch + 0.02 * squareSide, headLength)
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

// MARK: - Keeping two collinear arrows apart

/// Where the board draws two arrows, the reply is painted over the other player's move and its
/// opaque halo is the gap between them (design.md section 7). That works where the two shafts
/// **cross**: the gap is a ring, and what is left of the lower arrow is two long pieces that
/// read as one arrow passing under another.
///
/// It does not work where the two shafts run along the **same line**, because the upper arrow
/// then covers the lower one's shaft along its whole length instead of cutting across it.
/// Measured on the Petrov position the readout tests use, their knight and the reply both have
/// a leg on the f file, and the lower arrow came out as a stub at one end and a head at the
/// other with no shaft joining them: 49% of its fill hidden, in two disconnected pieces. Two
/// floating fragments read as a rendering fault rather than as a move, which is worse than the
/// single arrow the pair replaced (owner decision, `build/ui-requests.md` item 15).
///
/// So a collinear pair, and only a collinear pair, is moved apart: each arrow steps
/// `offset` square sides to its own side of the shared line, which is half of the separation
/// the two shafts need for neither to lose any of its fill. Everything is derived from the
/// widths the arrow is already drawn with rather than chosen by eye, and
/// `AnalysisArrowSeparationTests` rasterizes both arrows and counts the connected pieces of
/// each fill, so a severed arrow fails the build.
enum AnalysisArrowSeparation {
    /// The halo's width in square sides at its widest, which is Increase Contrast
    /// (`Palette.arrowHaloScale`). The separation has to hold in that setting too, so every
    /// figure below is computed from the widest one.
    static let widestHalo = AnalysisArrowGeometry.Proportion.halo * 1.5

    /// The painted width of a shaft, halo included, in square sides: 0.35 S.
    static let footprint = AnalysisArrowGeometry.Proportion.shaftWidth + 2 * widestHalo

    /// How far one arrow steps off the shared line, in square sides: 0.1375 S, so the two
    /// centerlines end up 0.275 S apart.
    ///
    /// That is exactly what it takes for the upper arrow's opaque halo to stop where the lower
    /// arrow's fill ends: half a shaft on each side (0.10 S + 0.10 S) plus the widest halo
    /// (0.075 S). Neither shaft is narrowed, and on a 335 pt board - a board on a 375 pt phone
    /// - the two 8.4 pt shafts end up 11.6 pt apart with white between them.
    static let offset = (AnalysisArrowGeometry.Proportion.shaftWidth + widestHalo) / 2

    /// The length of shaft an overlap has to cover before it stops being a crossing and starts
    /// being two arrows on top of each other, in square sides.
    static let coveredRunLimit: CGFloat = 1

    /// |sin| of the angle two shafts may make and still count as running along the same line.
    ///
    /// Measured rather than picked: two shafts crossing at an angle whose sine is `s` cover a
    /// run of `footprint / s` of each other, so the run reaches a whole square exactly at
    /// `footprint / coveredRunLimit` - 0.35, about 20 degrees.
    ///
    /// Board geometry gives it a wide margin on both sides. A shaft always runs along a file, a
    /// rank or a 45 degree diagonal (a knight's move is drawn as two legs, each along a file or
    /// a rank), so the angle between any two of them is 0, 45 or 90 degrees and nothing else.
    /// 45 degrees has a sine of 0.707, twice the threshold, and covers half a square.
    static let collinearSine = footprint / coveredRunLimit

    /// One arrow ready to draw: which move it is, and where on the board it goes.
    struct Placed: Identifiable {
        var arrow: AnalysisBoardArrow
        var geometry: AnalysisArrowGeometry

        var id: String { arrow.id }
    }

    /// The arrows of a board, in the order they are played, with a collinear pair moved apart.
    static func place(_ arrows: [AnalysisBoardArrow], whiteAtBottom: Bool, boardSide: CGFloat) -> [Placed] {
        let placed = arrows.compactMap { arrow -> Placed? in
            guard let geometry = AnalysisArrowGeometry(move: arrow.move, whiteAtBottom: whiteAtBottom, boardSide: boardSide)
            else { return nil }
            return Placed(arrow: arrow, geometry: geometry)
        }
        guard placed.count == 2,
              let axis = sharedAxis(placed[0].geometry, placed[1].geometry)
        else { return placed }
        let step = offset * placed[0].geometry.squareSide
        // The perpendicular of the shared line. Each arrow takes one side of it, so neither is
        // displaced more than the other and both stay well inside their own squares.
        let sideways = CGVector(dx: -axis.dy * step, dy: axis.dx * step)
        var separated = placed
        separated[0].geometry = placed[0].geometry.translated(by: CGVector(dx: -sideways.dx, dy: -sideways.dy))
        separated[1].geometry = placed[1].geometry.translated(by: sideways)
        return separated
    }

    /// The direction of the line two arrows share, or nil when they do not share one.
    ///
    /// Two segments share a line when they are within `collinearSine` of parallel, lie within
    /// one painted footprint of each other, and overlap along it. The longest such overlap
    /// wins, which matters for a knight's move: only one of its two legs is ever on the shared
    /// line. The direction is canonicalized (never pointing left, never straight up) so that
    /// which arrow goes to which side does not depend on the order the moves were read in.
    static func sharedAxis(_ first: AnalysisArrowGeometry, _ second: AnalysisArrowGeometry) -> CGVector? {
        let side = first.squareSide
        guard side > 0, second.squareSide == side else { return nil }
        let reach = footprint * side
        var best: (overlap: CGFloat, axis: CGVector)?

        for (start, end) in zip(first.centerline, first.centerline.dropFirst()) {
            let length = AnalysisArrowGeometry.distance(start, end)
            guard length > 0 else { continue }
            let axis = AnalysisArrowGeometry.unit(from: start, to: end)
            for (otherStart, otherEnd) in zip(second.centerline, second.centerline.dropFirst()) {
                guard AnalysisArrowGeometry.distance(otherStart, otherEnd) > 0 else { continue }
                let otherAxis = AnalysisArrowGeometry.unit(from: otherStart, to: otherEnd)
                // Near enough to parallel, in either direction of travel.
                guard abs(axis.dx * otherAxis.dy - axis.dy * otherAxis.dx) <= collinearSine else { continue }
                // And on the same line rather than a parallel one: two shafts a file apart are
                // a square apart, which is nearly three footprints.
                let middle = CGPoint(x: (otherStart.x + otherEnd.x) / 2, y: (otherStart.y + otherEnd.y) / 2)
                let across = abs((middle.x - start.x) * axis.dy - (middle.y - start.y) * axis.dx)
                guard across <= reach else { continue }
                // And overlapping along it. Each run is widened by half a footprint, because
                // the halo reaches that far past the ends of the centerline.
                let margin = reach / 2
                let firstProjection = (otherStart.x - start.x) * axis.dx + (otherStart.y - start.y) * axis.dy
                let secondProjection = (otherEnd.x - start.x) * axis.dx + (otherEnd.y - start.y) * axis.dy
                let overlap = min(length + margin, max(firstProjection, secondProjection) + margin)
                    - max(-margin, min(firstProjection, secondProjection) - margin)
                guard overlap > 0, overlap > (best?.overlap ?? 0) else { continue }
                best = (overlap, canonical(axis))
            }
        }
        return best?.axis
    }

    /// The same line pointing one agreed way: never to the left, and never straight up.
    private static func canonical(_ axis: CGVector) -> CGVector {
        let epsilon: CGFloat = 0.000_001
        if axis.dx < -epsilon || (abs(axis.dx) <= epsilon && axis.dy < 0) {
            return CGVector(dx: -axis.dx, dy: -axis.dy)
        }
        return axis
    }
}

// MARK: - What the board draws

/// One arrow on the board, and which player's move it is.
///
/// The board draws at most two: the move the app expects the player at the top to make, and
/// the user's reply to it. They come from `AnalysisReadoutContent.boardArrows`, which reads
/// them off the same engine line the readout's words are built from, so the board and the text
/// under it can never name different moves (design.md section 7 and 9.4,
/// `build/ui-requests.md` items 2 and 15).
struct AnalysisBoardArrow: Sendable, Hashable, Identifiable {
    /// Whose move the arrow draws, which picks both its color and the shape of its head.
    enum Role: Sendable, Hashable {
        /// The move the app is telling the user to play: cobalt, plain triangular head.
        case answer
        /// The move the app expects the player at the top to make first: near-black, with a
        /// notched head. Never cobalt, because cobalt means "the answer" (design.md rule 1).
        case theirMove

        /// The fill, which is fixed in both appearances because the board underneath is the
        /// user's screenshot and does not follow the app's theme (design.md section 3).
        var fill: Color {
            switch self {
            case .answer: Palette.arrowFill
            case .theirMove: Palette.arrowTheirMoveFill
            }
        }

        /// How deep the head is notched, in square sides. The second difference between the
        /// two arrows, so neither one depends on color alone (design.md 12).
        var headNotch: CGFloat {
            switch self {
            case .answer: 0
            case .theirMove: AnalysisArrowGeometry.Proportion.headNotch
            }
        }
    }

    /// The move drawn, in the board's own coordinates. The reply is legal only after the other
    /// move has been played, which is exactly what the pair of arrows says.
    var move: Move
    var role: Role

    var id: String { move.uci + (role == .answer ? "-answer" : "-theirs") }
}

// MARK: - Overlay

/// The arrows over the board. Each fill is drawn at 55% while the engine is thinking and fully
/// when the result is final; the halo and the outer edge are always drawn at full strength,
/// because they are what carries an arrow against the board (design.md section 7).
///
/// Fading the whole arrow, halo included, is what the app used to do, and it put the arrow
/// below 2.6:1 on every board theme tested for the entire length of a search - up to thirty
/// seconds on a Pro search, during which the arrow is the only thing on screen that says which
/// move to play. The provisional state still reads as provisional: a white-edged arrow with a
/// translucent interior, next to a move drawn in muted ink.
///
/// **Two arrows.** When the screenshot caught the turn of the player at the top, the board
/// carries that player's move and the user's reply to it. They are drawn in the order they are
/// played, the reply last, so the answer is never the one that is covered: each arrow is its
/// own composited layer, and the upper one's opaque halo and dark outer edge are the gap where
/// the two cross. The reply starts from the square the other move arrives on more often than
/// not, so they cross or share squares in the ordinary case rather than the rare one.
///
/// Where the two shafts run along the SAME LINE the halo is not a gap but a lid, so that pair
/// alone is moved apart before it is drawn (`AnalysisArrowSeparation`). A pair that crosses
/// transversely is drawn from exactly the path it was drawn from before.
///
/// The first arrow draws from tail to tip (220 ms); a changed move fades the old arrow (120 ms)
/// while the new one draws (180 ms). Reduce Motion: fades only.
struct AnalysisArrowOverlay: View {
    /// In the order the moves are played. Empty draws nothing.
    let arrows: [AnalysisBoardArrow]
    let whiteAtBottom: Bool
    let isFinal: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hasShownArrow = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                // ZStack order is paint order: the move that happens first is underneath.
                // A pair that runs along the same line is moved apart first, because there the
                // upper arrow would cover the lower one's shaft rather than cross it.
                ForEach(AnalysisArrowSeparation.place(arrows, whiteAtBottom: whiteAtBottom, boardSide: side)) { placed in
                    AnalysisArrowDrawing(
                        geometry: placed.geometry,
                        fill: placed.arrow.role.fill,
                        headNotch: placed.arrow.role.headNotch,
                        haloScale: Palette.arrowHaloScale(for: contrast),
                        fillOpacity: isFinal ? 1 : Self.provisionalFillOpacity,
                        drawDuration: reduceMotion ? nil : (hasShownArrow ? 0.18 : 0.22)
                    )
                    .id("\(placed.id)-\(whiteAtBottom)")
                    .transition(.opacity.animation(.easeOut(duration: Motion.valueChange)))
                    .onAppear { hasShownArrow = true }
                }
            }
            .frame(width: side, height: side)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.stateShort), value: isFinal)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// How strongly an arrow's fill is drawn while the engine is still searching. The halo and
    /// the outer edge are not faded with it (`AccessibilityContrastTests`).
    ///
    /// Faded, the two fills come within 1.9:1 of each other over every board tested, so while
    /// the engine is searching the pair is told apart by the notched head and by the ring the
    /// upper arrow cuts through the lower one - neither of which is ever faded - rather than
    /// by color. That is the same principle the single arrow already rests on.
    nonisolated static let provisionalFillOpacity: CGFloat = 0.55
}

/// One arrow instance: animates its own draw-in when it appears.
private struct AnalysisArrowDrawing: View {
    let geometry: AnalysisArrowGeometry
    /// Cobalt for the answer, near-black for the move of the player at the top.
    let fill: Color
    /// How deep the head is notched, in square sides: 0 for the answer's plain triangle.
    let headNotch: CGFloat
    let haloScale: CGFloat
    /// How strongly the fill is drawn: 1 for a final answer, less while searching.
    let fillOpacity: CGFloat
    /// Seconds for the draw-in, or nil to appear complete (Reduce Motion).
    let drawDuration: Double?

    @State private var progress: CGFloat = 0

    var body: some View {
        AnalysisArrowCanvas(
            geometry: geometry,
            fill: fill,
            headNotch: headNotch,
            progress: drawDuration == nil ? 1 : progress,
            fillOpacity: fillOpacity,
            haloScale: haloScale
        )
            .onAppear {
                guard let drawDuration else { return }
                withAnimation(.easeOut(duration: drawDuration)) { progress = 1 }
            }
    }
}

/// Paints the arrow in one composited layer: outer edge, halo, fill, then the promotion badge.
///
/// One layer per arrow, rather than both arrows in one canvas. The halo and the fill are drawn
/// with `.copy` so that a knight's L never doubles up on itself, and `.copy` would punch the
/// lower arrow out of a shared layer instead of compositing over it. Separate layers make the
/// crossing exactly what the contrast tests measure: the upper arrow's white halo and dark
/// outer edge over the lower arrow's fill.
private struct AnalysisArrowCanvas: View, Animatable {
    let geometry: AnalysisArrowGeometry
    let fill: Color
    let headNotch: CGFloat
    var progress: CGFloat
    /// Animated together with `progress`, so the fill can strengthen when the answer lands
    /// without the halo or the edge changing with it.
    var fillOpacity: CGFloat
    let haloScale: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, fillOpacity) }
        set {
            progress = newValue.first
            fillOpacity = newValue.second
        }
    }

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let geometry = geometry
        let progress = progress
        let haloScale = haloScale
        let fillOpacity = fillOpacity
        let fill = fill
        let headNotch = headNotch
        let pixel = 1 / max(displayScale, 1)
        Canvas { context, _ in
            let side = geometry.squareSide
            let outline = geometry.outline(progress: progress, headNotch: headNotch)
            let halo = AnalysisArrowGeometry.Proportion.halo * side * haloScale

            // 1. Outer edge: the outline expanded by the halo plus 1 px.
            context.stroke(outline, with: .color(Palette.arrowEdge), style: StrokeStyle(lineWidth: 2 * (halo + pixel), lineJoin: .round))
            // 2. Halo and 3. fill replace what is under them, so overlaps never double up.
            context.blendMode = .copy
            context.stroke(outline, with: .color(Palette.arrowHalo), style: StrokeStyle(lineWidth: 2 * halo, lineJoin: .round))
            context.fill(outline, with: .color(fill.opacity(fillOpacity)))

            if progress >= 1, let center = geometry.promotionBadgeCenter, let promotion = geometry.promotion {
                let ring = AnalysisArrowGeometry.Proportion.badgeRing * side
                let radius = AnalysisArrowGeometry.Proportion.badgeDiameter * side / 2
                let outer = Path(ellipseIn: CGRect(x: center.x - radius - ring, y: center.y - radius - ring,
                                                   width: 2 * (radius + ring), height: 2 * (radius + ring)))
                let inner = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
                context.fill(outer, with: .color(Palette.arrowHalo))
                context.fill(inner, with: .color(fill.opacity(fillOpacity)))
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
