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
    /// Per entry of `tinted`: the tint color estimated as if blended at 50% over the base, which
    /// is what tells a premove's red from the last move's own color (see
    /// `HighlightDetector.isRedTint` and `LastMoveResolver.premoveGroup`).
    public var tintEstimates: [RGB] = []
    /// Per display cell: false when less than 40% of the cell's border ring lies inside the image
    /// (a board cut off by the image edge). Such cells have no color of their own; they are left
    /// out of the tint statistics and are never reported as tinted.
    public var measured: [Bool] = [Bool](repeating: true, count: 64)

    /// Display cells the last move may be read from: `tinted`, then the faint candidates, cells
    /// whose color changed too little to count as tinted but did so over the whole cell (see
    /// `HighlightDetector.uniformCells`). A faint candidate is never reported as tinted and never
    /// counts as a selected piece; `LastMoveResolver` reads a move from one only when the tint
    /// agreement and the position both support it.
    public var candidates: [Int] = []
    /// Relative tint distances between entries of `candidates` (as `tintDistances`).
    public var candidateDistances: [[Double]] = []
    /// Per entry of `candidates`: the tint estimate (as `tintEstimates`).
    public var candidateEstimates: [RGB] = []
    /// Per entry of `candidates`: the confident rule did not accept this cell on its own. True for
    /// the faint candidates and for a partner the search below the threshold added.
    public var candidateFaint: [Bool] = []

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
    /// Most cells the last move is read from: the tinted ones plus the faint candidates.
    public static let maximumCandidates = maximumTinted + maximumFaint

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
        var uniform = [Bool](repeating: true, count: 64)
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
            var sides: [RGB] = []
            if let image {
                sides = CellSampler.ringSides(
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
            uniform[i] = isUniform(sides, observed: observed, deviation: deviations[i])
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
        let confident = kept.count
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
        // Faint candidates. A tint that falls short of the threshold still covers the whole cell,
        // so the cells that changed uniformly are offered to the resolver, which reads a move from
        // one only when a second cell carries the same tint and the position supports the move.
        // The partner the search above added is one of them: it is below the threshold too.
        let faint = cells.filter { cell in
            measured[cell.cell] && uniform[cell.cell] && !cell.isShade
                && cell.strength >= faintMinimumStrength && cell.strength < 1
                && !kept.contains(where: { $0.cell == cell.cell })
        }.sorted { $0.strength > $1.strength }.prefix(maximumFaint)
        let candidates = kept + faint
        let candidateDistances = candidates.map { a in candidates.map { b in tintDistance(a, b) / scale } }
        return TintAnalysis(cells: cells, tinted: kept.map(\.cell), tintDistances: distances,
                            tintEstimates: kept.map(\.tintEstimate), measured: measured,
                            candidates: candidates.map(\.cell), candidateDistances: candidateDistances,
                            candidateEstimates: candidates.map(\.tintEstimate),
                            candidateFaint: candidates.indices.map { $0 >= confident })
    }

    /// Whether every side of the cell's border ring shows the color the cell was measured at: a
    /// tint covers the whole cell, while board texture (wood grain, marble, a graffiti stroke) and
    /// a piece or a glyph reaching into the ring change one part of it. A side counts as agreeing
    /// when it is within half the cell's deviation of the measured color, with a floor for boards
    /// whose deviation is a few levels; at most one side of four may disagree, because a tall
    /// piece, an arrow or a badge covers one.
    ///
    /// Measured over the 21 boards whose faint tint was missed: of the cells not already tinted
    /// and at least `faintMinimumStrength` strong, 26 of the 32 that carry a real tint pass, and
    /// 105 of 309 that do not, which is about five candidates per board for the pair rules to
    /// weigh instead of eighteen.
    static func isUniform(_ sides: [RGB], observed: RGB, deviation: Double) -> Bool {
        guard !sides.isEmpty else { return true }
        let tolerance = max(uniformSideTolerance * deviation, uniformSideFloor)
        let agreeing = sides.filter { $0.distance(to: observed) <= tolerance }.count
        return sides.count >= 3 ? agreeing >= sides.count - 1 : agreeing == sides.count
    }

    /// How far a ring side may be from the cell's measured color and still count as showing the
    /// same tint: half the deviation, never less than `uniformSideFloor` L1 units (JPEG noise and
    /// rounding on a faint tint).
    static let uniformSideTolerance = 0.5
    static let uniformSideFloor = 6.0

    /// Weakest strength a cell needs to be offered as a faint candidate, and how many are offered.
    static let faintMinimumStrength = 0.35
    static let maximumFaint = 6

    /// Whether a tint estimate (as if blended at 50%) belongs to the red family a premove is drawn
    /// in: red clearly above both green and blue.
    ///
    /// The bound is the whole family, not the pure red alone. Over the 192-image premove set the
    /// 335 squares a premove tints measure 172 and above in red minus the larger of green and
    /// blue, five in twenty of them below 223, while the 335 squares the last move tints stay at
    /// 167 and below, three quarters of them below 8. Game Review's reds (a blunder, a mistake's
    /// salmon; measured 112 to 186 on real_089, real_146 and the rendered classification colors)
    /// reach into the family and are not premoves: `LastMoveResolver.premoveGroup` separates them,
    /// because a premove is the most saturated red on a board that carries another tint too.
    static func isRedTint(_ estimate: RGB) -> Bool {
        estimate.r >= redTintMinimum && redness(estimate) >= redTintMargin
    }

    /// How far a tint estimate's red stands above both its green and its blue.
    static func redness(_ estimate: RGB) -> Double { estimate.r - max(estimate.g, estimate.b) }

    /// Red, and red minus the larger of green and blue, that a tint estimate needs to count as the
    /// red family. The premove squares of the stress set start at 172 and its last-move squares
    /// stop at 167; an orange last-move tint on a metal board measures 125 (synth_00248).
    static let redTintMinimum = 185.0
    static let redTintMargin = 150.0

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

    /// Interquartile-mean colors of the four sides of a cell's border ring (top, bottom, left,
    /// right), nil for a side that is mostly outside the image. Exposed for the tint measurements
    /// the tests and the diagnostics check.
    @_spi(Testing)
    public static func ringSides(_ detection: BoardDetection, image: RGBAImage, cell: Int) -> [RGB?] {
        CellSampler.ringSides(image, x: detection.originX + Double(cell % 8) * detection.cellSize,
                              y: detection.originY + Double(cell / 8) * detection.cellSize, size: detection.cellSize)
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
    ///
    /// The shade test above (`residual < 0.12 && abs(k - 1) < 0.25`) is measured against the
    /// cell's own deviation, which is tight for a textured board: the base color is a median of
    /// neighbors, so a cell's own grain leaves a chroma of its own and the ratio never falls to
    /// 0.12. On sealed_016, a marble board with a vignette, ten corner cells darken by up to 73 L1
    /// units at ratios of 0.14 to 0.30 and the strongest of them outranks both squares of the real
    /// tint. Two ways of widening it were measured over the 3,556 evaluated images of
    /// 2026-09-18 (221,952 cells), and both cost more than they gave, so the test stands as it is:
    ///
    /// * against the board's chroma noise, `chroma < 0.6 * chromaThreshold`: 191 cells no label
    ///   calls tinted become shades, against 24 that a label does, and 61 more labeled cells leave
    ///   the faint-candidate pool. Over all 16 sets, silently wrong 24 -> 35 and wrong last moves
    ///   301 -> 326, most of it in `tints` (4 -> 11 silently wrong);
    /// * the texture-aware form `chroma < 0.12 * deviation + chromaNoise`, which is the smallest
    ///   bound that reclassifies sealed_016's vignette: 143 unlabeled cells against 6 labeled, and
    ///   39 labeled cells out of the faint pool. Silently wrong 24 -> 27, wrong last moves
    ///   301 -> 307, `covered` 102 -> 106, and the gate fails on ten limits.
    ///
    /// Neither reads sealed_016's move, because the pair is not the shade test's to make: with the
    /// vignette out of the way the board offers exactly g4 (tinted) and f5 (faint), and their
    /// relative tint distance is 0.0387, past `LastMoveResolver.faintPairRadius` (0.025). That
    /// radius separates a real faint tint from texture on the 21 boards it was fitted to, whose
    /// texture cells start at 0.034, so widening it to reach 0.0387 would undo that. What closes
    /// sealed_016 instead is the doubt `BoardRecognizer` raises when tints in several colors read
    /// as no move.
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

    /// Largest relative tint distance between two squares of a pair that includes a faint
    /// candidate, and the radius within which no third square may carry the same tint.
    ///
    /// Measured on the 21 boards whose faint tint was missed: where the faint square carries the
    /// move's own tint it lies 0.000 to 0.020 from its partner, while the strongest texture cells
    /// of the same boards lie 0.034 and further from it. The same radius rejects a board whose
    /// faint cells all drift together, which is what texture and an uneven backlight do: on the
    /// five boards of the clock set that a faint pair was read from by mistake, every one of the
    /// six candidates had two to four others within this radius, while a real tint sits on exactly
    /// two squares.
    static let faintPairRadius = 0.025
    /// How much better the best faint pair's tint agreement must be than the next pair's that
    /// reads as another move, for the faint reading to be used at all.
    static let faintAmbiguityFactor = 0.5
    /// Score below which a reading of tinted squares is weak enough to lose to a faint pair: any
    /// reading that pays a penalty. A pair of one tint that the piece could have played scores at
    /// least 1.55, whatever its place in the strength order.
    static let faintOverrideScore = 1.4
    /// How many times more exactly a faint pair's two squares must carry one tint than a tinted
    /// pair's, for the faint reading to replace an unpenalized one, and how far apart that tinted
    /// pair's own tints must be for the comparison to mean anything. Two squares of one tint are
    /// measured 0.000 to 0.020 apart even on a textured board (synth_00248, a metal board: 0.006),
    /// so only a tinted pair beyond that is doubtful enough to lose this way.
    static let faintOverrideAgreement = 5.0
    static let faintOverrideMinimumDistance = 0.02

    /// Score penalty for reading a move from two squares of clearly different tint colors
    /// (relative tint distance 0.5 or more; none up to `HighlightDetector.sameTintRadius`).
    static let crossTintPenalty = 1.2
    /// Relative tint distance up to which a third tinted square counts as the selection.
    static let selectionTintRadius = 0.4
    /// Relative tint distance up to which that third square is reported as the selected piece
    /// (unless the legal-move dots point at it). A selected piece is drawn in the move's own
    /// color: over the evaluated sets the 298 selections read correctly lie a median of 0.004 from
    /// the move's squares, while the 15 squares reported as a selection by mistake lie 0.141 and
    /// further away.
    static let selectionReportRadius = 0.12
    /// Score penalty for reading the last move from one red-family square and one square of
    /// another tint while a complete pair of that other tint is on the board: the red belongs to
    /// the premove, so pairing it with a move square is a coincidence. Measured on premove_00116
    /// and premove_00126, where such a pair sat exactly on the cross-tint penalty's threshold and
    /// paid nothing.
    static let mixedRedPenalty = 0.6
    /// Score penalty for reading the last move from two red-family squares while squares of
    /// another tint are present: the premove pair holds the premoving piece on its start square,
    /// so read as a move it runs backward and names the wrong mover. It is subtracted after the
    /// `minimumScore` gate, so a red pair that is the only reading on the board still reads as the
    /// last move (Game Review draws a blunder in the same red family), and it is small on purpose:
    /// what settles a premove is the rule below, that a pair of one tint the piece could have
    /// played always wins. A penalty large enough to decide on its own also let a pair of two
    /// unrelated tints win over a red last move (measured on tints_00083, a red-pink board with a
    /// marked square: the marked square paired with a move square scored 0.70 against 0.35).
    static let premovePenalty = 0.3
    /// Readings by different movers whose scores differ by at most this are a tie that only the
    /// order of tint strengths would break (a selected piece that could have come from the
    /// vacated square scores exactly like the real move).
    static let tieMargin = 0.15

    /// `tinted` in strength order; `tintDistances` relative tint distances between entries (nil:
    /// all one tint); `board` indexed by `Square.index`; `dots` the squares showing a legal-move
    /// dot; `estimates` the tint color of each entry, which finds the premove; `faint` per entry,
    /// whether the threshold accepted the square on its own; `bottomColor` the color at the bottom
    /// of the screen, which breaks ties between readings by different movers when three or more
    /// squares are tinted: a piece is selected by the player at the bottom, who is to move, so the
    /// move was the top player's.
    public static func resolve(tinted: [Square], tintDistances: [[Double]]? = nil, board: [Piece?],
                               dots: [Square] = [], estimates: [RGB]? = nil, faint: [Bool]? = nil,
                               bottomColor: PieceColor? = nil) -> Resolution? {
        let candidates = Array(tinted.prefix(HighlightDetector.maximumCandidates))
        // No move has been played in the start position.
        guard candidates.count >= 2, board != Position.start.board else { return nil }
        let distance = { (i: Int, j: Int) -> Double in
            guard let tintDistances, tintDistances.indices.contains(i), tintDistances.indices.contains(j) else { return 0 }
            return tintDistances[i][j]
        }
        let isFaint = { (i: Int) -> Bool in faint.map { $0.indices.contains(i) && $0[i] } ?? false }
        let tintedIndices = candidates.indices.filter { !isFaint($0) }
        // The premove pair. Only the squares the threshold accepted count here, so a faint
        // candidate neither makes a premove nor hides one.
        let premove = premoveGroup(tintedIndices, estimates: estimates, distance: distance)
        let isPremoveSquare = { (i: Int) -> Bool in premove.contains(i) }
        let premoveShown = !premove.isEmpty
        let markers = resultMarkers(tintedIndices.map { candidates[$0] }, board: board, distance: distance)
        let same = { (i: Int, j: Int) -> Bool in distance(i, j) < selectionTintRadius }
        var readings: [Reading] = []
        var faintReadings: [Reading] = []
        for i in 0..<candidates.count {
            for j in (i + 1)..<candidates.count {
                let a = candidates[i], b = candidates[j]
                guard let (interpretation, raw) = interpret(a, b, board: board) else { continue }
                var resolution = interpretation
                var score = raw
                // Stronger tints first.
                score -= Double(i + j) * 0.05
                let d = distance(i, j)
                // A cell the threshold did not accept is read as part of a move only on evidence
                // that leaves little else: the two squares carry one tint, that tint is on no
                // other square of the board, the piece could have made the move with a clear path
                // and without leaving its own king in check (`raw >= 2`), and the position can
                // have been arrived at by it (below).
                let faintPair = isFaint(i) || isFaint(j)
                if faintPair {
                    // With no tinted square to anchor it, the pair must agree twice as closely:
                    // nothing on the board was measured as a tint, so the two faint squares carry
                    // the whole reading.
                    let radius = isFaint(i) && isFaint(j) ? faintPairRadius * 0.5 : faintPairRadius
                    guard d < radius, raw >= 2,
                          !candidates.indices.contains(where: {
                              $0 != i && $0 != j && (distance($0, i) < faintPairRadius || distance($0, j) < faintPairRadius)
                          })
                    else { continue }
                }
                // The premove is drawn over a board the last move already tinted, so it can cover
                // one of the move's two squares: its start square holds the premoving piece, which
                // may be the piece that just moved (real_090), and its destination can be the
                // square the move came from (premove_00028). Either way only one square of the
                // move's own color is left, which is what "every tinted square but one belongs to
                // the premove" says: the move then has to be read across the two colors, without
                // the cross-tint penalty. With two squares of another tint on the board the move pair is complete
                // and a mixed pair is a coincidence instead.
                let mixedRed = premoveShown && isPremoveSquare(i) != isPremoveSquare(j)
                let coveredMove = mixedRed && premove.count == tintedIndices.count - 1
                let isPremovePair = premoveShown && isPremoveSquare(i) && isPremoveSquare(j)
                // A game-over marker covers the square it is drawn on, so a move that ends under
                // one carries two unrelated colors for a reason: it pays the marker penalty
                // instead of the cross-tint one.
                let coveredByMarker = markers.contains(i) != markers.contains(j)
                if !isPremovePair && !coveredMove && !coveredByMarker {
                    score -= crossTintPenalty * max(0, min(1, (d - HighlightDetector.sameTintRadius) / 0.2))
                }
                if coveredByMarker { score -= resultMarkerPenalty }
                if mixedRed && !coveredMove { score -= mixedRedPenalty }

                // A third tinted square of the same color is normally the selected piece of the
                // side to move. A game-over marker and a faint candidate are never one.
                let others = tintedIndices.filter { $0 != i && $0 != j && !markers.contains($0) && same($0, i) && same($0, j) }
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
                            let tintMatches = max(distance(other, i), distance(other, j)) < selectionReportRadius
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
                // The gate is the reading's own score. The premove penalty is subtracted after it,
                // so a red pair with nothing to lose to still reads as the last move.
                guard score >= minimumScore else { continue }
                if isPremovePair { score -= premovePenalty }
                let reachable = predecessorIsPossible(resolution, board: board)
                if faintPair && !reachable { continue }
                let reading = Reading(resolution: resolution, score: score, selection: selection,
                                      reachable: reachable, isPremovePair: isPremovePair,
                                      beatsAPremove: (d < HighlightDetector.sameTintRadius || coveredMove)
                                          && resolution.isPlausible, tintDistance: d,
                                      faintSquares: (isFaint(i) ? 1 : 0) + (isFaint(j) ? 1 : 0))
                if faintPair { faintReadings.append(reading) } else { readings.append(reading) }
            }
        }
        // The faint candidates. A pair that carries the tint of a square the threshold did accept
        // is the stronger reading, because only one of its two squares rests on the faint
        // measurement; between pairs of one kind the closer tint agreement decides, and a rival of
        // the same kind that agrees nearly as well leaves the board without a last move rather
        // than with a guess.
        let ordered = faintReadings.sorted {
            ($0.faintSquares, $0.tintDistance) < ($1.faintSquares, $1.tintDistance)
        }
        if let faintBest = ordered.first {
            let rival = ordered.first {
                $0.faintSquares == faintBest.faintSquares
                    && ($0.resolution.from != faintBest.resolution.from || $0.resolution.to != faintBest.resolution.to)
            }
            // A faint pair is used when the tinted squares read as no move at all, when the move
            // they read pays a penalty (their two tints differ, the piece could not have made the
            // move, or its path is blocked), or when the faint pair's two squares carry one tint
            // several times more exactly than the tinted pair's do, which is what a false tint
            // beside a real one looks like (tints_00166: 0.003 against 0.045).
            let tinted = readings.max(by: { $0.score < $1.score })
            let weak = tinted == nil || tinted!.score < faintOverrideScore
                || (tinted!.tintDistance >= faintOverrideMinimumDistance
                    && faintBest.tintDistance * faintOverrideAgreement <= tinted!.tintDistance)
            if weak, rival == nil || faintBest.tintDistance <= faintAmbiguityFactor * rival!.tintDistance {
                readings = faintReadings.filter {
                    $0.resolution.from == faintBest.resolution.from && $0.resolution.to == faintBest.resolution.to
                }
            }
        }
        // A pair the position cannot have arrived at loses to any pair it can have: that is what
        // separates squares the user marked by hand from the move actually played, when both read
        // as legal-looking moves on the board shown. When no reading survives the test the board
        // itself is likely misread, so the readings are kept as they are rather than thrown away.
        let reachable = readings.filter(\.reachable)
        if !reachable.isEmpty { readings = reachable }
        guard var best = readings.max(by: { $0.score < $1.score }) else { return nil }
        // A premove pair never wins over a reading of the last move's own tint. The premove is
        // drawn in red over the board the last move already tinted, so whenever a pair of one tint
        // reads as a move the player could have played, that pair is the move and the red pair is
        // the queued one. Measured on the premove stress set: 16 of its 192 boards were read as
        // the premove, every one of them with such a pair on the board.
        if best.isPremovePair,
           let rival = readings.filter({ !$0.isPremovePair && $0.beatsAPremove }).max(by: { $0.score < $1.score }) {
            best = rival
        }
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
        /// Both squares carry the red family while squares of another tint are on the board.
        var isPremovePair = false
        /// The two squares carry one tint (or the red covers one of them) and the move is one the
        /// piece could have made: a reading a premove pair must not win over.
        var beatsAPremove = false
        /// Relative tint distance between the two squares.
        var tintDistance = 0.0
        /// How many of the two squares are faint candidates (0 for a reading of tinted squares).
        var faintSquares = 0
    }

    /// The candidates that carry a premove, or none.
    ///
    /// A premove is drawn in red over a board that already shows the last move, so the red squares
    /// are a premove only when something else on the board can be the move. Two cases:
    /// the red squares sit beside squares of another tint, which is the common one; or every
    /// tinted square is red because the last move is drawn in one of Game Review's reds as well,
    /// and then the premove is the more saturated group (measured on premove_00112: the premove's
    /// red stands 245 above green and blue, the mistake's salmon 167).
    ///
    /// `indices` are the tinted candidates; `estimates` and `distance` are indexed as they are in
    /// `resolve`.
    static func premoveGroup(_ indices: [Int], estimates: [RGB]?, distance: (Int, Int) -> Double) -> Set<Int> {
        guard let estimates else { return [] }
        let red = indices.filter { estimates.indices.contains($0) && HighlightDetector.isRedTint(estimates[$0]) }
        guard red.count >= 2 else { return [] }
        if red.count < indices.count { return Set(red) }
        // Everything tinted is red: look for a more saturated red inside it.
        var groups: [[Int]] = []
        for index in red {
            if let existing = groups.firstIndex(where: { $0.contains { distance($0, index) < premoveGroupRadius } }) {
                groups[existing].append(index)
            } else {
                groups.append([index])
            }
        }
        let redness = { (group: [Int]) -> Double in
            group.reduce(0.0) { $0 + HighlightDetector.redness(estimates[$1]) } / Double(group.count)
        }
        let ranked = groups.sorted { redness($0) > redness($1) }
        guard ranked.count >= 2, ranked[0].count >= 2, ranked[0].count < indices.count,
              redness(ranked[0]) - redness(ranked[1]) >= premoveRedSeparation else { return [] }
        return Set(ranked[0])
    }

    /// Relative tint distance within which two red squares are one group. Tighter than
    /// `sameTintRadius`, because the two reds this has to tell apart are both red: on
    /// premove_00112 the premove's two squares lie 0.003 apart and the last move's 0.000, while
    /// the two pairs lie 0.169 to 0.245 apart.
    static let premoveGroupRadius = 0.1

    /// How much more saturated the premove's red must be than the red the last move is drawn in,
    /// when both are on the board. Measured: 245 against 167 on premove_00112.
    static let premoveRedSeparation = 60.0

    /// Indices of `candidates` that mark how the game ended rather than a move.
    ///
    /// A finished game is shown with a tint on both kings' squares: a green "Winner" pill on one, a
    /// red "Abandon", "Resigned", "Timeout" or "Checkmate" pill on the other, gray on both for a
    /// draw. No move can tint both kings, because one of a move's two squares is always empty, and
    /// the result color is its own, drawn over whatever the square already carried. So a candidate
    /// counts as a marker when it holds a king, a king of the other color is tinted too, and its
    /// tint matches no square that holds no king: a king that just moved, a king in check drawn in
    /// red and a selected king all share the tint of the move or selection they belong to and are
    /// left alone. Measured: 7 of the 192 badge boards read a marker as part of the move or as the
    /// selected piece, and 11 of the 192 selection boards tint both kings in the move's own color.
    ///
    /// `distance(i, j)`: relative tint distance between two candidates.
    static func resultMarkers(_ candidates: [Square], board: [Piece?],
                              distance: (Int, Int) -> Double) -> Set<Int> {
        var kings: [PieceColor: [Int]] = [:]
        for (index, square) in candidates.enumerated() {
            guard let piece = board[square.index], piece.kind == .king else { continue }
            kings[piece.color, default: []].append(index)
        }
        guard kings[.white] != nil, kings[.black] != nil else { return [] }
        let others = candidates.indices.filter { index in
            board[candidates[index].index].map { $0.kind != .king } ?? true
        }
        return Set(kings.values.flatMap { $0 }.filter { king in
            others.allSatisfy { distance(king, $0) >= resultMarkerTintDistance }
        })
    }

    /// Relative tint distance from every tinted square that holds no king that a king's tint needs
    /// to count as a game-over marker. Measured: a marker's distance from the last move's own
    /// squares is 0.18 to 0.73 over the badge set (the result color is drawn over the square,
    /// whatever it held), while a king tinted as part of the move or because the player selected
    /// it carries the move's own tint, 0.00 to 0.05 away, on the 11 selection boards that tint
    /// both kings.
    static let resultMarkerTintDistance = 0.15

    /// Score penalty for reading the last move from a pair that includes a game-over marker. It is
    /// a penalty and not a refusal because the mating or winning move often ends on the king's own
    /// square, where the result tint covers the move's destination.
    static let resultMarkerPenalty = 0.5

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
