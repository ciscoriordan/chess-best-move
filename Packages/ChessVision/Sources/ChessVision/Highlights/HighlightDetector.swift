import ChessCore
import Foundation

/// Per-cell tint measurement.
@_spi(Testing)
public struct CellTint: Sendable, Hashable {
    /// Display cell index (row * 8 + column).
    public var cell: Int
    /// L1 distance of the cell's border-ring color from its parity's base color.
    public var deviation: Double
    /// `deviation` relative to the detection threshold for this board (>= 1 means tinted).
    public var strength: Double
    /// Tint color estimated as if blended at 50% over the base: 2 * observed - base.
    public var tintEstimate: RGB
    /// True when the change is a plain darkening or brightening of the base color (a capture
    /// ring or a dimmed square) rather than a colored tint.
    public var isShade: Bool
    /// Least-squares factor k in observed ≈ k * base.
    public var scale: Double
    /// L1 distance between observed and k * base, relative to `deviation`.
    public var residual: Double
    /// Border-ring color of the cell.
    public var observed: RGB
    /// Local base color the cell is compared with.
    public var base: RGB
}

/// Tinted cells found on a board.
@_spi(Testing)
public struct TintAnalysis: Sendable {
    /// Every display cell's measurement.
    public var cells: [CellTint]
    /// Display cells judged tinted, strongest first (at most `HighlightDetector.maximumTinted`).
    public var tinted: [Int]
    /// `tintDistances[i][j]`: how far entries i and j of `tinted` are from carrying one tint
    /// color, relative to the board's light/dark contrast (see `HighlightDetector.tintDistance`).
    /// Last move and selection share one color; a premove or a square mark usually has another.
    public var tintDistances: [[Double]]
    /// Per entry of `tinted`: the cell carries the saturated red of a premove (see
    /// `HighlightDetector.isPremoveRed`).
    public var premove: [Bool] = []
    /// Per display cell: false when less than 40% of the cell's border ring lies inside the image
    /// (a board cut off by the image edge). Such cells have no color of their own; they are left
    /// out of the tint statistics and are never reported as tinted.
    public var measured: [Bool] = [Bool](repeating: true, count: 64)

    /// Group label per entry of `tinted`, linking entries closer than
    /// `HighlightDetector.sameTintRadius`, for diagnostics.
    public var groups: [Int] {
        var labels = [Int](repeating: -1, count: tinted.count)
        var next = 0
        for start in tinted.indices where labels[start] < 0 {
            var stack = [start]
            labels[start] = next
            while let i = stack.popLast() {
                for j in tinted.indices where labels[j] < 0 && tintDistances[i][j] < HighlightDetector.sameTintRadius {
                    labels[j] = next
                    stack.append(j)
                }
            }
            next += 1
        }
        return labels
    }
}

/// Finds last-move and selection tints from cell border colors, relative to the board's own
/// light and dark base colors (the tint hue differs by theme, so no color is assumed).
@_spi(Testing)
public enum HighlightDetector {
    /// Most tinted cells reported (last move, selection, premove pair, a square mark).
    public static let maximumTinted = 6

    /// Measures every cell and returns the cells judged tinted, strongest first, with their
    /// tint groups.
    ///
    /// Each cell's color is the mean of the two sides of its border ring that agree best (with
    /// `image`; otherwise the whole-ring color of the detection), so a tall piece, an arrow or a
    /// badge covering one or two sides does not look like a tint.
    ///
    /// Two measures are compared with the rest of the board. `deviation` is the L1 distance of
    /// the cell color from the local base color; `chroma` is the part of that change that is not
    /// a plain darkening or brightening of the base (L1 distance from the best scaled base
    /// color). A board has at most six tinted cells (last move, selection, a premove pair, a
    /// square mark), so the seventh-largest value of each measure is a robust estimate of how
    /// much untinted cells vary (texture, JPEG noise, pieces touching the ring). A cell is
    /// tinted when either measure clearly exceeds that level. The chroma measure finds colored
    /// tints on heavily textured boards (parchment, wood, marble), whose texture varies mostly in
    /// brightness; the deviation measure finds brightening tints on translucent themes. Cells
    /// whose change is a pure darkening or brightening (capture rings, dimmed squares) are
    /// dropped when colored tints are present.
    public static func analyze(_ detection: BoardDetection, image: RGBAImage? = nil,
                               modelHighlight: [Float]? = nil) -> TintAnalysis {
        let light = detection.lightColor, dark = detection.darkColor
        let contrast = max(detection.contrast, 1)
        let measured = image.map { measuredCells(detection, imageWidth: $0.width, imageHeight: $0.height) }
            ?? [Bool](repeating: true, count: 64)
        // Local base color: median of same-parity cells within two rows and columns, which
        // follows lighting gradients and texture drift across textured boards (wood, metal,
        // parchment) while an isolated tinted cell stands out.
        var bases = [RGB](repeating: light, count: 64)
        var observations = detection.cellColors
        var deviations = [Double](repeating: 0, count: 64)
        var chromas = [Double](repeating: 0, count: 64)
        var scales = [Double](repeating: 1, count: 64)
        for i in 0..<64 {
            let row = i / 8, column = i % 8
            let global = (row + column) % 2 == 0 ? light : dark
            var neighbors: [RGB] = []
            for dr in -2...2 {
                for dc in -2...2 where (dr != 0 || dc != 0) && (dr + dc) % 2 == 0 {
                    let r = row + dr, c = column + dc
                    guard (0..<8).contains(r), (0..<8).contains(c), measured[r * 8 + c] else { continue }
                    neighbors.append(detection.cellColors[r * 8 + c])
                }
            }
            while neighbors.count < 7 { neighbors.append(global) }
            let base = RGB.median(neighbors) ?? global
            guard measured[i] else {
                // No color was measured (the detector stores black): the cell counts as its base
                // color, adds nothing to the noise level and cannot be tinted.
                observations[i] = base
                bases[i] = base
                continue
            }
            if let image {
                let sides = CellSampler.ringSides(
                    image, x: detection.originX + Double(column) * detection.cellSize,
                    y: detection.originY + Double(row) * detection.cellSize, size: detection.cellSize
                ).compactMap { $0 }
                if let pair = consistentPair(sides, base: base) {
                    observations[i] = pair
                }
            }
            let observed = observations[i]
            bases[i] = base
            deviations[i] = observed.distance(to: base)
            scales[i] = observed.dot(base) / max(base.dot(base), 1)
            chromas[i] = observed.distance(to: base * scales[i])
        }
        let rank = backgroundRank
        let threshold = max(minimumDeviation, 1.4 * deviations.sorted(by: >)[rank] + 4, 0.06 * contrast)
        let chromaThreshold = max(minimumDeviation, 2.5 * chromas.sorted(by: >)[rank] + 4, 0.06 * contrast)

        var cells: [CellTint] = []
        for i in 0..<64 {
            let base = bases[i]
            let observed = observations[i]
            let deviation = deviations[i]
            let k = scales[i]
            let residual = chromas[i] / max(deviation, 1)
            let isShade = residual < 0.12 && abs(k - 1) < 0.25
            var strength = measured[i] ? max(deviation / threshold, chromas[i] / chromaThreshold) : 0
            if let modelHighlight {
                // The model's highlight head can only raise borderline cells (by up to 30%). It
                // never lowers a cell: the interim model missed most real highlights (54 of 74
                // tinted cells in the real screenshot set scored below 0.5), which the color
                // measures find.
                let p = Double(modelHighlight[i])
                strength *= 1 + modelBoost * max(0, 2 * p - 1)
            }
            cells.append(CellTint(cell: i, deviation: deviation, strength: strength,
                                  tintEstimate: observed * 2 - base, isShade: isShade,
                                  scale: k, residual: residual, observed: observed, base: base))
        }
        // A plain brightening or darkening is weaker evidence (textured squares, legal-move dots
        // and capture rings also shade a square), so it must be clearly stronger.
        var tinted = cells.filter { $0.strength >= ($0.isShade ? shadeMinimumStrength : 1) }
            .sorted { $0.strength > $1.strength }
        let colored = tinted.filter { !$0.isShade }
        if colored.count >= 2 || (colored.count == 1 && tinted.count == 1) {
            tinted = colored
        } else if colored.isEmpty && tinted.count == 1 {
            tinted = []
        }
        var kept = Array(tinted.prefix(maximumTinted))
        // Relative to the contrast (a dimmed screen scales every color difference), with a floor
        // for JPEG noise on low-contrast boards.
        let scale = max(40, contrast)
        // A move tints two squares in one color. When a clearly tinted square has no partner, the
        // other square's tint can be too faint to pass the threshold on its own (a blue tint on
        // the icy sea board, a tan tint on wood): take the strongest weaker square of the same
        // tint color.
        for anchor in kept where anchor.strength >= partnerAnchorStrength && !anchor.isShade {
            guard kept.count < maximumTinted,
                  !kept.contains(where: { $0.cell != anchor.cell && tintDistance(anchor, $0) / scale < sameTintRadius })
            else { continue }
            let partner = cells.filter { cell in
                measured[cell.cell] && !cell.isShade && cell.strength >= partnerMinimumStrength
                    && !kept.contains(where: { $0.cell == cell.cell })
                    && tintDistance(anchor, cell) / scale < partnerTintRadius
            }.max { $0.strength < $1.strength }
            if let partner { kept.append(partner) }
        }
        let distances = kept.map { a in kept.map { b in tintDistance(a, b) / scale } }
        return TintAnalysis(cells: cells, tinted: kept.map(\.cell), tintDistances: distances,
                            premove: kept.map { isPremoveRed($0.tintEstimate) }, measured: measured)
    }

    /// Whether a tint estimate (as if blended at 50%) is the saturated pure red drawn under a
    /// premove: measured (255, 0, 0) within about 30 on real screenshots (real_090, real_092,
    /// real_113). The red that marks a blunder in a reviewed game is less saturated, about
    /// (225, 75, 53) to (282, 96, 56), and is not matched.
    static func isPremoveRed(_ estimate: RGB) -> Bool {
        estimate.r >= 200 && estimate.r - max(estimate.g, estimate.b) >= premoveRedMargin
    }

    /// Red minus the larger of green and blue that a premove tint estimate reaches (premoves:
    /// 231 to 267; Game Review red: 150 to 186).
    static let premoveRedMargin = 210.0

    /// Per display cell, whether at least 40% of its border ring lies inside the image, the
    /// condition under which `CellSampler.ringMedian` measures a color.
    static func measuredCells(_ detection: BoardDetection, imageWidth: Int, imageHeight: Int) -> [Bool] {
        let n = CellSampler.samplesPerSide
        return (0..<64).map { cell in
            let x = detection.originX + Double(cell % 8) * detection.cellSize
            let y = detection.originY + Double(cell / 8) * detection.cellSize
            let size = detection.cellSize
            guard x < 0 || y < 0 || x + size > Double(imageWidth) || y + size > Double(imageHeight) else { return true }
            var inside = 0, total = 0
            for j in 0..<n {
                let v = (Double(j) + 0.5) / Double(n)
                let dv = min(v, 1 - v)
                for i in 0..<n {
                    let u = (Double(i) + 0.5) / Double(n)
                    let edge = min(dv, min(u, 1 - u))
                    guard edge >= CellSampler.ringInner, edge <= CellSampler.ringOuter else { continue }
                    total += 1
                    let px = Int(x + u * size), py = Int(y + v * size)
                    if px >= 0, py >= 0, px < imageWidth, py < imageHeight { inside += 1 }
                }
            }
            return total > 0 && Double(inside) >= 0.4 * Double(total)
        }
    }

    /// Mean color of the two ring sides that agree best with each other, preferring sides near
    /// the base color on near ties. Two sides not covered by a piece, an arrow or a badge show
    /// the square's own color, tinted or not.
    static func consistentPair(_ sides: [RGB], base: RGB) -> RGB? {
        guard sides.count >= 2 else { return nil }
        var best: (cost: Double, color: RGB)?
        for i in 0..<sides.count {
            for j in (i + 1)..<sides.count {
                let mean = (sides[i] + sides[j]) * 0.5
                let cost = sides[i].distance(to: sides[j]) + 0.25 * mean.distance(to: base)
                if best == nil || cost < best!.cost { best = (cost, mean) }
            }
        }
        return best?.color
    }

    /// Strength a cell whose change is a plain brightening or darkening needs to count as tinted
    /// (translucent themes highlight by brightening; real example: strength 3.3, while shaded
    /// untinted cells reach about 2.1).
    static let shadeMinimumStrength = 2.5

    /// A tinted square at least this strong without a same-tint partner gets its partner searched
    /// among weaker squares.
    static let partnerAnchorStrength = 2.0
    /// Weakest strength, and largest relative tint distance to the anchor, of such a partner.
    static let partnerMinimumStrength = 0.55
    static let partnerTintRadius = 0.2

    /// Index (0-based, descending) of the deviation taken as the untinted background level.
    static let backgroundRank = 6

    /// Largest factor by which a confident model highlight raises a cell's strength.
    static let modelBoost = 0.3

    /// Absolute floor for a tint, in L1 units.
    static let minimumDeviation = 18.0

    /// Relative tint distance up to which two cells count as one tint. Measured: cells of one
    /// tint reach 0.39 on textured boards; a square mark or a 3D piece next to a tint starts at
    /// about 0.25, so the resolver penalizes pairs gradually between 0.3 and 0.5.
    static let sameTintRadius = 0.3

    /// How far two cells are from carrying one tint color T at one opacity a, where each cell
    /// shows (1 - a) * base + a * T. Then observed1 - observed2 = (1 - a) * (base1 - base2), so
    /// the distance is the L1 residual of that relation with the best a in 0...1. The opacity of
    /// a theme's tint is not known (review colors, marks and premoves differ), so it is fitted.
    static func tintDistance(_ a: CellTint, _ b: CellTint) -> Double {
        // One brightens and the other darkens: not one tint.
        if a.isShade && b.isShade && (a.scale - 1) * (b.scale - 1) < 0 { return .infinity }
        let observedDifference = a.observed - b.observed
        let baseDifference = a.base - b.base
        let norm = baseDifference.dot(baseDifference)
        guard norm >= 400 else {
            // Same base color: the observed colors must match.
            return abs(observedDifference.r) + abs(observedDifference.g) + abs(observedDifference.b)
        }
        let factor = max(0, min(1, observedDifference.dot(baseDifference) / norm))
        let residual = observedDifference - baseDifference * factor
        return abs(residual.r) + abs(residual.g) + abs(residual.b)
    }
}

/// Derives the last move from tinted squares and the recognized pieces.
@_spi(Testing)
public enum LastMoveResolver {
    public struct Resolution: Sendable, Hashable {
        public var from: Square
        public var to: Square
        public var mover: PieceColor
        /// The two highlighted squares the move was read from (for castling shown as king start
        /// plus rook start, these differ from `from`/`to`).
        public var highlighted: [Square]
        /// A third square in the same tint holding a piece of the side to move: the piece the
        /// player has selected.
        public var selected: Square?
        /// Whether the piece could have made the move (castling included). A reading that is not
        /// comes from spurious or faint tints (texture, a hatched or grayscale board) and is
        /// wrong far more often than a plausible one.
        public var isPlausible: Bool = true
    }

    /// Score penalty for reading a move from two squares of clearly different tint colors
    /// (relative tint distance 0.5 or more; none up to `HighlightDetector.sameTintRadius`).
    static let crossTintPenalty = 1.2
    /// Relative tint distance up to which a third tinted square counts as the selection.
    static let selectionTintRadius = 0.4
    /// Score penalty for reading the last move from two premove-red squares while squares of
    /// another tint are present: the premove pair holds the premoving piece on its start square,
    /// so read as a move it runs backward and names the wrong mover.
    static let premovePenalty = 1.5
    /// Readings by different movers whose scores differ by at most this are a tie that only the
    /// order of tint strengths would break (a selected piece that could have come from the
    /// vacated square scores exactly like the real move).
    static let tieMargin = 0.15

    /// `tinted` in strength order; `tintDistances` relative tint distances between entries (nil:
    /// all one tint); `board` indexed by `Square.index`; `dots` the squares showing a legal-move
    /// dot; `premove` per entry of `tinted`, whether it carries the premove red; `bottomColor`
    /// the color at the bottom of the screen, which breaks ties between readings by different
    /// movers when three or more squares are tinted: a piece is selected by the player at the
    /// bottom, who is to move, so the move was the top player's.
    public static func resolve(tinted: [Square], tintDistances: [[Double]]? = nil, board: [Piece?],
                               dots: [Square] = [], premove: [Bool]? = nil, bottomColor: PieceColor? = nil) -> Resolution? {
        let candidates = Array(tinted.prefix(HighlightDetector.maximumTinted))
        // No move has been played in the start position.
        guard candidates.count >= 2, board != Position.start.board else { return nil }
        let distance = { (i: Int, j: Int) -> Double in
            guard let tintDistances, tintDistances.indices.contains(i), tintDistances.indices.contains(j) else { return 0 }
            return tintDistances[i][j]
        }
        let isRed = { (i: Int) -> Bool in premove.map { $0.indices.contains(i) && $0[i] } ?? false }
        // Premove squares next to squares of another tint: the red pair is the premove.
        let redCount = candidates.indices.filter(isRed).count
        let premoveShown = redCount >= 2 && redCount < candidates.count
        let same = { (i: Int, j: Int) -> Bool in distance(i, j) < selectionTintRadius }
        var readings: [Reading] = []
        for i in 0..<candidates.count {
            for j in (i + 1)..<candidates.count {
                let a = candidates[i], b = candidates[j]
                guard var (resolution, score) = interpret(a, b, board: board) else { continue }
                // Stronger tints first.
                score -= Double(i + j) * 0.05
                let d = distance(i, j)
                // The premove's start square holds the premoving piece, which may be the piece
                // that just moved: its red then covers the last move's tint, and only one square
                // of the last move's color is left.
                let redStartSquare = (isRed(i) && board[a.index] != nil) || (isRed(j) && board[b.index] != nil)
                let coveredMove = premoveShown && redCount == candidates.count - 1 && isRed(i) != isRed(j) && redStartSquare
                if premoveShown && isRed(i) && isRed(j) {
                    score -= premovePenalty
                } else if !coveredMove {
                    score -= crossTintPenalty * max(0, min(1, (d - HighlightDetector.sameTintRadius) / 0.2))
                }
                // A third tinted square of the same color is normally the selected piece of the
                // side to move.
                let others = candidates.indices.filter { $0 != i && $0 != j && same($0, i) && same($0, j) }
                var selection = false
                if let other = others.first {
                    let square = candidates[other]
                    if let piece = board[square.index] {
                        if piece.color != resolution.mover {
                            score += 0.5
                            selection = true
                            // The dots show where the selected piece can go.
                            var reach: Double?
                            if !dots.isEmpty {
                                let reachable = dots.filter { canReach(piece, from: square, to: $0, board: board) }.count
                                reach = Double(reachable) / Double(dots.count)
                                score += dotWeight * (reach! - 0.5)
                            }
                            // Report the selection when its tint clearly matches the move's, or
                            // when the dots belong to its piece.
                            let tintMatches = max(distance(other, i), distance(other, j)) < HighlightDetector.sameTintRadius
                            if tintMatches || (reach ?? 0) >= 0.5 {
                                resolution.selected = square
                            }
                        } else {
                            score -= 0.3
                        }
                    } else {
                        score -= 0.5
                    }
                }
                resolution.highlighted = [a, b]
                guard score >= minimumScore else { continue }
                let reachable = predecessorIsPossible(resolution, board: board)
                readings.append(Reading(resolution: resolution, score: score, selection: selection,
                                        reachable: reachable))
            }
        }
        // A pair the position cannot have arrived at loses to any pair it can have: that is what
        // separates squares the user marked by hand from the move actually played, when both read
        // as legal-looking moves on the board shown. When no reading survives the test the board
        // itself is likely misread, so the readings are kept as they are rather than thrown away.
        let reachable = readings.filter(\.reachable)
        if !reachable.isEmpty { readings = reachable }
        guard var best = readings.max(by: { $0.score < $1.score }) else { return nil }
        // Two readings of three same-tint squares, each with the third square as a selected
        // piece of the other side, that differ only in tint order.
        let rivals: [Reading] = readings.filter { reading in
            reading.selection && reading.resolution.mover != best.resolution.mover
                && reading.resolution.isPlausible == best.resolution.isPlausible
        }
        if let bottomColor, best.selection, best.resolution.mover == bottomColor,
           let rival = rivals.max(by: { $0.score < $1.score }),
           best.score - rival.score <= tieMargin {
            best = rival
        }
        return best.resolution
    }

    /// One way to read two of the tinted squares as the last move.
    struct Reading {
        var resolution: Resolution
        var score: Double
        /// A third tinted square holds a piece of the side to move (a selected piece).
        var selection: Bool
        /// The position before this move could have been legal (see `predecessorIsPossible`).
        var reachable: Bool
    }

    /// Score added for a selected piece that can reach all legal-move dots (subtracted when it
    /// reaches none).
    static let dotWeight = 1.2

    /// Whether `piece` on `from` could move to the empty square `to` on `board`.
    static func canReach(_ piece: Piece, from: Square, to: Square, board: [Piece?]) -> Bool {
        let df = to.file - from.file, dr = to.rank - from.rank
        let adf = abs(df), adr = abs(dr)
        switch piece.kind {
        case .pawn:
            let forward = piece.color == .white ? 1 : -1
            let startRank = piece.color == .white ? 1 : 6
            if df == 0 && dr == forward { return true }
            if df == 0 && dr == 2 * forward && from.rank == startRank {
                return board[Square(file: from.file, rank: from.rank + forward)!.index] == nil
            }
            return adf == 1 && dr == forward   // en passant
        case .knight:
            return (adf == 1 && adr == 2) || (adf == 2 && adr == 1)
        case .king:
            return max(adf, adr) == 1 || (adr == 0 && adf == 2)
        case .bishop:
            return adf == adr && adf > 0 && pathIsClear(piece, from: from, to: to, board: board)
        case .rook:
            return (df == 0) != (dr == 0) && pathIsClear(piece, from: from, to: to, board: board)
        case .queen:
            return ((adf == adr && adf > 0) || ((df == 0) != (dr == 0))) && pathIsClear(piece, from: from, to: to, board: board)
        }
    }

    /// Pairs scoring below this are not read as a move (for example an implausible move from two
    /// squares of different tints).
    static let minimumScore = 0.5

    /// Reads a move from two highlighted squares, with a plausibility score: 2 for a move the
    /// piece can make, 1 otherwise, lowered when the path is blocked or the mover's king is left
    /// in check.
    static func interpret(_ a: Square, _ b: Square, board: [Piece?]) -> (Resolution, Double)? {
        let pa = board[a.index], pb = board[b.index]
        var resolution: Resolution
        var score: Double
        switch (pa, pb) {
        case (nil, .some(let piece)):
            resolution = Resolution(from: a, to: b, mover: piece.color, highlighted: [a, b],
                                    isPlausible: isPlausible(piece, from: a, to: b))
            score = moveScore(piece, from: a, to: b, board: board)
        case (.some(let piece), nil):
            resolution = Resolution(from: b, to: a, mover: piece.color, highlighted: [a, b],
                                    isPlausible: isPlausible(piece, from: b, to: a))
            score = moveScore(piece, from: b, to: a, board: board)
        case (nil, nil):
            // Castling shown as king start + rook start, both empty after the move.
            guard let castling = castling(a, b, board: board) else { return nil }
            resolution = castling
            score = 2.2
        default:
            return nil
        }
        // The side that just moved cannot be in check.
        if Position(board: board, sideToMove: resolution.mover.opposite).isInCheck(resolution.mover) {
            score -= 1.5
        }
        return (resolution, score)
    }

    /// Whether the position before this reading could have been legal.
    ///
    /// Undoing the move puts the moved piece back on its start square and empties its destination.
    /// It was then the mover's turn, so the mover's opponent cannot already have been in check: a
    /// reading whose undone position checks the opponent did not happen, and the tinted squares
    /// are squares the user marked, a premove or a review color instead. Measured on a screenshot
    /// with a yellow-green pair on b2/b4 and a red-orange marked pair on c4/d5: reading d5-c4
    /// leaves the black king on a5 in check from the pawn already standing on b4, while b2-b4
    /// undoes cleanly, and only this test tells the two pairs apart.
    ///
    /// The piece the move captured is unknown, so a check along a line that runs through the
    /// emptied destination is ignored: whatever stood there would have blocked it. A promotion is
    /// ambiguous from the board alone (a queen on the last rank may have been a pawn or a queen),
    /// so both readings are tried and either one being possible is enough.
    static func predecessorIsPossible(_ resolution: Resolution, board: [Piece?]) -> Bool {
        let boards = predecessors(resolution, board: board)
        guard !boards.isEmpty else { return true }
        return boards.contains { previous, captured in
            guard let kingIndex = previous.firstIndex(of: Piece(color: resolution.mover.opposite, kind: .king)),
                  let king = Square(index: kingIndex) else { return true }
            let checkers = attackers(of: king, by: resolution.mover, board: previous)
            guard !checkers.isEmpty else { return true }
            guard let captured else { return false }
            return checkers.allSatisfy { isBetween(captured, $0, king) }
        }
    }

    /// The board before the move, with the square a capture could have emptied. Empty when the
    /// reading cannot be undone (nothing on the destination, or a castling whose rook is not where
    /// it would be).
    static func predecessors(_ resolution: Resolution, board: [Piece?]) -> [(board: [Piece?], captured: Square?)] {
        guard let moved = board[resolution.to.index] else { return [] }
        var previous = board
        previous[resolution.to.index] = nil
        let from = resolution.from, to = resolution.to
        // Castling, reported as the king's two-square move: the rook goes back too, and castling
        // never captures.
        if moved.kind == .king, from.file == 4, abs(to.file - from.file) == 2, from.rank == to.rank {
            let kingside = to.file > from.file
            guard let rookStart = Square(file: kingside ? 7 : 0, rank: from.rank),
                  let rookDestination = Square(file: kingside ? 5 : 3, rank: from.rank),
                  previous[rookDestination.index] == Piece(color: moved.color, kind: .rook) else { return [] }
            previous[rookDestination.index] = nil
            previous[rookStart.index] = Piece(color: moved.color, kind: .rook)
            previous[from.index] = moved
            return [(previous, nil)]
        }
        var result: [(board: [Piece?], captured: Square?)] = []
        previous[from.index] = moved
        result.append((previous, to))
        let lastRank = moved.color == .white ? 7 : 0
        let pawnRank = moved.color == .white ? 6 : 1
        if moved.kind != .pawn, moved.kind != .king, to.rank == lastRank, from.rank == pawnRank {
            var promoted = previous
            promoted[from.index] = Piece(color: moved.color, kind: .pawn)
            result.append((promoted, to))
        }
        return result
    }

    /// Squares from which `color` attacks `square`. A pawn attacks diagonally only, and the
    /// contents of `square` itself do not matter.
    static func attackers(of square: Square, by color: PieceColor, board: [Piece?]) -> [Square] {
        (0..<64).compactMap { index in
            guard let piece = board[index], piece.color == color, let from = Square(index: index),
                  from != square, attacks(piece, from: from, to: square, board: board) else { return nil }
            return from
        }
    }

    static func attacks(_ piece: Piece, from: Square, to: Square, board: [Piece?]) -> Bool {
        let df = to.file - from.file, dr = to.rank - from.rank
        let adf = abs(df), adr = abs(dr)
        switch piece.kind {
        case .pawn:
            return adf == 1 && dr == (piece.color == .white ? 1 : -1)
        case .knight:
            return (adf == 1 && adr == 2) || (adf == 2 && adr == 1)
        case .king:
            return max(adf, adr) == 1
        case .bishop:
            return adf == adr && adf > 0 && pathIsClear(piece, from: from, to: to, board: board)
        case .rook:
            return (df == 0) != (dr == 0) && pathIsClear(piece, from: from, to: to, board: board)
        case .queen:
            return ((adf == adr && adf > 0) || ((df == 0) != (dr == 0)))
                && pathIsClear(piece, from: from, to: to, board: board)
        }
    }

    /// Whether `square` lies strictly between `a` and `b` along a rank, file or diagonal.
    static func isBetween(_ square: Square, _ a: Square, _ b: Square) -> Bool {
        let df = b.file - a.file, dr = b.rank - a.rank
        guard df == 0 || dr == 0 || abs(df) == abs(dr) else { return false }
        let steps = max(abs(df), abs(dr))
        guard steps > 1 else { return false }
        let sf = df.signum(), sr = dr.signum()
        return (1..<steps).contains { Square(file: a.file + $0 * sf, rank: a.rank + $0 * sr) == square }
    }

    static func moveScore(_ piece: Piece, from: Square, to: Square, board: [Piece?]) -> Double {
        guard isPlausible(piece, from: from, to: to) else { return 1 }
        return pathIsClear(piece, from: from, to: to, board: board) ? 2 : 1.1
    }

    /// Whether the squares strictly between `from` and `to` are empty, for moves that slide
    /// (bishop, rook and queen lines, a pawn's double step). Only the moving piece changed
    /// squares, so the path is still empty after the move.
    static func pathIsClear(_ piece: Piece, from: Square, to: Square, board: [Piece?]) -> Bool {
        let df = to.file - from.file, dr = to.rank - from.rank
        switch piece.kind {
        case .knight, .king:
            return true
        case .pawn, .bishop, .rook, .queen:
            guard df == 0 || dr == 0 || abs(df) == abs(dr) else { return true }
            let steps = max(abs(df), abs(dr))
            guard steps > 1 else { return true }
            let sf = df.signum(), sr = dr.signum()
            for k in 1..<steps {
                if board[Square(file: from.file + k * sf, rank: from.rank + k * sr)!.index] != nil { return false }
            }
            return true
        }
    }

    static func castling(_ a: Square, _ b: Square, board: [Piece?]) -> Resolution? {
        for color in PieceColor.allCases {
            let rank = color == .white ? 0 : 7
            let king = Piece(color: color, kind: .king), rook = Piece(color: color, kind: .rook)
            let kingStart = Square(file: 4, rank: rank)!
            for (rookFile, kingTo, rookTo) in [(7, 6, 5), (0, 2, 3)] {
                let rookStart = Square(file: rookFile, rank: rank)!
                guard Set([a, b]) == Set([kingStart, rookStart]) else { continue }
                let kingDestination = Square(file: kingTo, rank: rank)!
                let rookDestination = Square(file: rookTo, rank: rank)!
                if board[kingDestination.index] == king && board[rookDestination.index] == rook {
                    return Resolution(from: kingStart, to: kingDestination, mover: color, highlighted: [a, b])
                }
            }
        }
        return nil
    }

    /// Whether `piece`, now on `to`, could have come from `from` in one move (promotion included).
    public static func isPlausible(_ piece: Piece, from: Square, to: Square) -> Bool {
        let df = to.file - from.file, dr = to.rank - from.rank
        let adf = abs(df), adr = abs(dr)
        let forward = piece.color == .white ? 1 : -1
        switch piece.kind {
        case .pawn:
            // A pawn never stands on its own back rank.
            guard from.rank != (piece.color == .white ? 0 : 7) else { return false }
            if df == 0 && dr == forward { return true }
            if df == 0 && dr == 2 * forward && from.rank == (piece.color == .white ? 1 : 6) { return true }
            return adf == 1 && dr == forward
        case .knight:
            return (adf == 1 && adr == 2) || (adf == 2 && adr == 1) || promotion(piece, from: from, to: to)
        case .bishop:
            return (adf == adr && adf > 0) || promotion(piece, from: from, to: to)
        case .rook:
            return (df == 0) != (dr == 0) || promotion(piece, from: from, to: to)
        case .queen:
            return (adf == adr && adf > 0) || ((df == 0) != (dr == 0))
        case .king:
            return (max(adf, adr) == 1) || (adr == 0 && adf == 2 && from.file == 4 && from.rank == (piece.color == .white ? 0 : 7))
        }
    }

    static func promotion(_ piece: Piece, from: Square, to: Square) -> Bool {
        let lastRank = piece.color == .white ? 7 : 0
        return to.rank == lastRank && from.rank == lastRank - (piece.color == .white ? 1 : -1) && abs(to.file - from.file) <= 1
    }
}
