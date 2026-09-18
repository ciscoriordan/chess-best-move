import ChessCore
import CoreGraphics
import Foundation

/// What the detector and classifier can vouch for on a detected board: squares outside the image
/// or covered by something drawn over the board, squares too small to read, other boards in the
/// image, inverted square colors, and calibrated square confidences. Each problem becomes a doubt,
/// so the recognizer reports low confidence instead of a confident result built from squares it
/// never saw.
@_spi(Testing)
public struct BoardReadability: Sendable {
    /// A display cell with less than this fraction inside the image (transparent pixels count as
    /// outside) is unseen: its content is not reported with any confidence. Cells cut by up to
    /// 45% are read reliably, because pieces stand in the middle of their square.
    public static let minimumVisibleFraction = 0.55
    /// Squares smaller than this (in analyzed pixels: source pixels unless the image was scaled
    /// down to `RGBAImage.maximumAnalyzedSide`) are too small to read reliably: the
    /// classifier is trained on squares of 40 to 180 px, and below about 20 px it confuses colors
    /// and kinds with high probabilities (measured on boards scaled down to 10 to 32 px squares).
    public static let minimumCellSize = 22.0
    /// Calibrated probability below which a square is uncertain
    /// (`BoardRecognizer.confidentSquareProbability`). Chosen on 11,895 rendered and stress
    /// screenshots at temperature 0.39 (`Scripts/fit_square_calibration.py`): it flags 0.23% of
    /// the boards read correctly and catches 11 of the 16 misread boards no other doubt caught
    /// (the old 0.5 cutoff caught none). On the 151 real screenshots it flags 3 correct boards.
    public static let confidentSquareProbability: Float = 0.97
    /// Reported confidence of an unseen or covered square.
    public static let hiddenSquareConfidence: Float = 0
    /// Highest confidence reported for any square of a board whose art falls outside the range
    /// the classifier was trained on (`ThemeFamiliarity`). It is below
    /// `confidentSquareProbability`, so every square of such a board is uncertain and the whole
    /// board goes to the user to check: the calibration the 0.97 cutoff rests on was fitted on
    /// the training art, and outside it the reported probability means nothing.
    public static let unfamiliarThemeConfidence: Float = 0.9

    /// Fraction of each display cell inside the image and opaque, row-major from the top-left.
    public var visibleFractions: [Double]
    /// Display cells mostly outside the image.
    public var unseenCells: [Int]
    /// Display cells covered by something drawn over the board (a card, banner, picker or window).
    public var coveredCells: [Int]
    /// Calibrated probability of each display cell's reported content; 0 for unseen and covered
    /// cells.
    public var confidences: [Float]
    public var cellSize: Double
    public var squareColorsInverted: Bool
    public var otherBoards: [CGRect]
    /// Board-color statistics outside the range the classifier was trained on, one line each
    /// (empty for familiar art). Every square's confidence is capped at
    /// `unfamiliarThemeConfidence` when this is not empty.
    public var unfamiliarTheme: [String]

    /// Assesses a detected board. `labels`: the reported content of each display cell after the
    /// consistency repair, as `PieceClasses` indices.
    public static func assess(_ detection: BoardDetection, image: RGBAImage, predictions: [CellPrediction],
                              labels: [Int], temperature: Double) -> BoardReadability {
        let visible = visibleFractions(detection, image: image)
        let unseen = (0..<64).filter { visible[$0] < minimumVisibleFraction }
        let covered = BoardOcclusion.coveredCells(detection, image: image).filter { !unseen.contains($0) }
        var confidences = SquareCalibration.confidences(predictions, labels: labels, temperature: temperature)
        let unfamiliar = ThemeFamiliarity.unfamiliar(detection, image: image)
        if !unfamiliar.isEmpty {
            for cell in 0..<64 { confidences[cell] = min(confidences[cell], unfamiliarThemeConfidence) }
        }
        for cell in unseen + covered { confidences[cell] = hiddenSquareConfidence }
        return BoardReadability(visibleFractions: visible, unseenCells: unseen, coveredCells: covered,
                                confidences: confidences, cellSize: detection.cellSize,
                                squareColorsInverted: detection.squareColorsInverted,
                                otherBoards: detection.otherBoards, unfamiliarTheme: unfamiliar)
    }

    /// Display cells that already have a doubt of their own (unseen or covered).
    public var hiddenCells: Set<Int> { Set(unseenCells + coveredCells) }

    /// The doubts, with squares named for the decided orientation. `sourceScale`: source pixels
    /// per analyzed pixel, for reporting the square size in the source image.
    public func doubts(whiteAtBottom: Bool, sourceScale: Double = 1) -> [RecognitionDoubt] {
        func squares(_ cells: [Int]) -> [Square] {
            cells.map { DisplayGrid.square(row: $0 / 8, column: $0 % 8, whiteAtBottom: whiteAtBottom) }
        }
        var doubts: [RecognitionDoubt] = []
        if !unseenCells.isEmpty {
            doubts.append(.squaresOutsideImage(squares(unseenCells)))
        }
        if !coveredCells.isEmpty {
            doubts.append(.squaresCovered(squares(coveredCells)))
        }
        if cellSize < Self.minimumCellSize {
            doubts.append(.squaresTooSmall(cellPixels: cellSize * sourceScale))
        }
        if !otherBoards.isEmpty {
            doubts.append(.severalBoards(count: otherBoards.count + 1))
        }
        if squareColorsInverted {
            doubts.append(.invertedSquareColors)
        }
        if !unfamiliarTheme.isEmpty {
            doubts.append(.unfamiliarBoardArt(reason: unfamiliarTheme.joined(separator: "; ")))
        }
        return doubts
    }

    /// Fraction of each display cell that lies inside the image and is opaque, from a 12 x 12
    /// sample grid per cell.
    static func visibleFractions(_ detection: BoardDetection, image: RGBAImage) -> [Double] {
        let n = 12
        let s = detection.cellSize
        let w = image.width, h = image.height
        return (0..<64).map { cell in
            let x0 = detection.originX + Double(cell % 8) * s
            let y0 = detection.originY + Double(cell / 8) * s
            var inside = 0
            for j in 0..<n {
                let py = Int((y0 + (Double(j) + 0.5) / Double(n) * s).rounded(.down))
                guard py >= 0, py < h else { continue }
                for i in 0..<n {
                    let px = Int((x0 + (Double(i) + 0.5) / Double(n) * s).rounded(.down))
                    guard px >= 0, px < w else { continue }
                    if image.isOpaque(offset: (py * w + px) * 4) { inside += 1 }
                }
            }
            return Double(inside) / Double(n * n)
        }
    }
}

/// Finds board cells hidden under something drawn over the board: a result card, a banner, a
/// promotion picker, a floating window, a toast.
///
/// Each side of each cell's border ring (`CellSampler.ringSides`) is measured against the board's
/// own two square colors:
/// - A side is *foreign* when its color is clearly closer to the other square color than to its
///   own (margin below -`foreignMargin` of the light/dark contrast).
/// - A side is *alien* when it is at least `alienDistance` of the contrast away from both square
///   colors, so neither square color explains it. A mid-tone cover (a gray or brand-colored card
///   whose color sits between the two square colors) is alien on both parities although it is
///   foreign on neither.
/// - Two cells of opposite colors that share an edge are *linked* there when the two sides along
///   that edge show one cover: either the same color (an opaque cover), or two colors that differ
///   only by at most `maximumTintFraction` of the light/dark difference (a translucent cover, which
///   leaves that much of the square colors showing through). Both sides must differ from their own
///   square color by `minimumCoverDeviation` of the contrast and at least
///   `minimumCoverDeviationLevels`, and at least one of them must be foreign or alien.
/// - A cover whose color happens to equal one square color leaves that parity showing its own
///   color exactly. Such an edge is linked when the other side is foreign or alien, deviates, and
///   its cell's whole ring shows that one cover color (`seedSides` sides of it).
/// - Links spread to the other sides of a linked cell that show nearly the same color as its
///   linked sides and are foreign or alien themselves or match the neighbor's side across them.
/// A cell with at least `minimumCoveredSides` linked sides is covered.
///
/// The board draws its own tints (last move, selection, premove, square marks) square by square,
/// so a tint fills whole cells and stops at their edges. Anything drawn over the board is placed
/// in screen pixels, so its edge cuts across cells. Only the plain foreign rule (the rule as it
/// stood before 2026-09-17) is trusted on its own; cells found only through the alien, translucent
/// or equal-color tests are reported only when the cover they belong to shows such an edge:
/// `minimumFringeSides` sides of neighboring cells outside the cover showing the cover color, or
/// `minimumSplitCells` of its own cells showing their square color on one ring side and the cover
/// color on another. A premove or a lone strong tint has neither, because it stops exactly at the
/// cell edges.
///
/// Measured on 2026-09-17 (`build/round4-detector`, the same tree with and without these tests):
/// of the 192 screenshots of build/stress/covered, 150 raise a covered doubt where 128 did, the
/// images with hidden squares and no doubt at all fall from 10 to 3, and the set's silently wrong
/// results fall from 6 to 1 (the one left is a last move hidden under a toast, not a square).
/// Over the 3,254 screenshots of every other set (the real screenshot set, the synthetic test
/// set, the sealed holdout set and every stress set without covers) the extended tests add a
/// covered doubt to 2
/// images, both of which were already flagged and one of which is misread.
@_spi(Testing)
public enum BoardOcclusion {
    /// Thresholds of the rule, as fractions of the board's light/dark contrast.
    public struct Parameters: Sendable {
        /// A side is foreign when its margin is below minus this.
        public var foreignMargin = 0.5
        /// A side is alien when it is at least this far from both square colors.
        public var alienDistance = 0.3
        /// Two sides have one color when they differ by less than this.
        public var sameColorDistance = 0.12
        /// Largest share of the light/dark difference that may remain between the two sides along
        /// a shared edge for them to count as one translucent cover (a cover at an opacity of
        /// 1 - this or more). The board's own tints reach this far too, which is why a cover found
        /// this way must also show a cut edge (`minimumFringeSides`, `minimumSplitCells`).
        public var maximumTintFraction = 0.45
        /// A linked side must differ from its own square color by at least this, and by at least
        /// `minimumCoverDeviationLevels` (sum of the channel differences in 0...255 levels), so
        /// that JPEG noise and texture on a low-contrast board do not count.
        public var minimumCoverDeviation = 0.05
        public var minimumCoverDeviationLevels = 16.0
        /// A side within this of its own square color (and at least this many levels) shows that
        /// square color: the cover does not reach it.
        public var quietDeviation = 0.02
        public var quietDeviationLevels = 8.0
        /// Sides of one cover color a cell needs for it to stand in for a neighbor that shows its
        /// own square color exactly.
        public var seedSides = 3
        /// A cell with at least this many linked sides is covered.
        public var minimumCoveredSides = 2
        /// A cover found only by the extended tests needs one of these: this many sides of cells
        /// outside it showing its color, or this many of its own cells showing both their square
        /// color and its color.
        public var minimumFringeSides = 2
        public var minimumSplitCells = 2
        public init() {}

        /// The rule as it stood before the extended tests were added (2026-09-17): foreign sides
        /// only, both sides of a linked edge differing from their own square color, and one
        /// color across the edge. `coveredCells` reports what this finds without asking for a
        /// cut edge, so it is also what the cut-edge tests are measured against.
        public static var plain: Parameters {
            var parameters = Parameters()
            parameters.alienDistance = .infinity
            parameters.maximumTintFraction = 0
            parameters.seedSides = 5
            return parameters
        }
    }

    public static func coveredCells(_ detection: BoardDetection, image: RGBAImage, parameters: Parameters = Parameters()) -> [Int] {
        coveredCells(sides: ringSides(detection, image: image), light: detection.lightColor, dark: detection.darkColor,
                     parameters: parameters)
    }

    /// Ring side colors of every display cell (`CellSampler.ringSides`).
    public static func ringSides(_ detection: BoardDetection, image: RGBAImage) -> [[RGB?]] {
        let s = detection.cellSize
        return parallelMap(64) { cell in
            CellSampler.ringSides(image, x: detection.originX + Double(cell % 8) * s,
                                  y: detection.originY + Double(cell / 8) * s, size: s)
        }
    }

    static let opposite = [1, 0, 3, 2]

    static func neighbor(_ cell: Int, _ side: Int) -> Int? {
        var row = cell / 8, column = cell % 8
        switch side {
        case 0: row -= 1
        case 1: row += 1
        case 2: column -= 1
        default: column += 1
        }
        return (0..<8).contains(row) && (0..<8).contains(column) ? row * 8 + column : nil
    }

    /// `sides`: per display cell, the ring side colors in `CellSampler.ringSides` order (top,
    /// bottom, left, right). `light` and `dark`: the colors of the cells whose row + column is
    /// even and odd.
    public static func coveredCells(sides: [[RGB?]], light: RGB, dark: RGB, parameters: Parameters = Parameters()) -> [Int] {
        precondition(sides.count == 64 && sides.allSatisfy { $0.count == 4 })
        let rule = CoverRule(sides: sides, light: light, dark: dark, parameters: parameters)
        // The plain rule is trusted on its own; the extended tests need a cut edge.
        var covered = Set(rule.coveredCells(extended: false))
        for cover in rule.covers(rule.coveredCells(extended: true)) where rule.showsCutEdge(cover) {
            covered.formUnion(cover)
        }
        return covered.sorted()
    }
}

/// The cover rule over one board's ring colors (`BoardOcclusion`).
struct CoverRule {
    let sides: [[RGB?]]
    let light: RGB
    let dark: RGB
    let parameters: BoardOcclusion.Parameters
    let contrast: Double
    /// light - dark, the direction a translucent cover leaves the two square colors apart in.
    let separation: RGB
    let minimumDeviation: Double
    let quiet: Double
    /// Per cell and side: the side's color is clearly closer to the other square color than to
    /// its own.
    var foreign: [[Bool]]
    /// Per cell and side: no square color explains the side's color (it is far from both).
    var alien: [[Bool]]
    /// Per cell and side: the side differs from its own square color enough to be a cover.
    var deviates: [[Bool]]

    init(sides: [[RGB?]], light: RGB, dark: RGB, parameters: BoardOcclusion.Parameters) {
        self.sides = sides
        self.light = light
        self.dark = dark
        self.parameters = parameters
        contrast = max(light.distance(to: dark), 1)
        separation = light - dark
        minimumDeviation = max(parameters.minimumCoverDeviation * contrast, parameters.minimumCoverDeviationLevels)
        quiet = max(parameters.quietDeviation * contrast, parameters.quietDeviationLevels)
        foreign = [[Bool]](repeating: [Bool](repeating: false, count: 4), count: 64)
        alien = foreign
        deviates = foreign
        for cell in 0..<64 {
            let own = Self.base(cell, light: light, dark: dark)
            let other = Self.base(cell, light: dark, dark: light)
            for side in 0..<4 {
                guard let color = sides[cell][side] else { continue }
                let distance = color.distance(to: own)
                deviates[cell][side] = distance >= minimumDeviation
                foreign[cell][side] = (color.distance(to: other) - distance) / contrast < -parameters.foreignMargin
                alien[cell][side] = min(color.distance(to: light), color.distance(to: dark)) >= parameters.alienDistance * contrast
            }
        }
    }

    /// The side carries cover evidence: it is not its own square color, and either the other
    /// square color fits it better or neither fits (`extended`).
    func isCover(_ cell: Int, _ side: Int, extended: Bool) -> Bool {
        deviates[cell][side] && (foreign[cell][side] || (extended && alien[cell][side]))
    }

    static func base(_ cell: Int, light: RGB, dark: RGB) -> RGB {
        (cell / 8 + cell % 8) % 2 == 0 ? light : dark
    }

    func base(_ cell: Int) -> RGB { Self.base(cell, light: light, dark: dark) }

    /// Whether two ring sides show one cover. `extended`: also accept a translucent cover, which
    /// leaves up to `maximumTintFraction` of the light/dark difference between the two sides.
    func showOneCover(_ a: RGB, _ b: RGB, lightFirst: Bool, extended: Bool) -> Bool {
        let budget = parameters.sameColorDistance * contrast
        if a.distance(to: b) < budget { return true }
        guard extended else { return false }
        let direction = lightFirst ? separation : separation * -1
        let length = direction.dot(direction)
        guard length > 0 else { return false }
        let difference = a - b
        let share = difference.dot(direction) / length
        guard share > -0.02, share <= parameters.maximumTintFraction else { return false }
        return difference.distance(to: direction * share) < budget
    }

    /// The whole ring of the cell shows one cover color, on `seedSides` sides or more: the cell
    /// stands in for a neighbor whose own square color the cover happens to match exactly.
    func isSeed(_ cell: Int) -> Bool {
        for side in 0..<4 where isCover(cell, side, extended: true) {
            guard let color = sides[cell][side] else { continue }
            let count = (0..<4).filter { other in
                isCover(cell, other, extended: true)
                    && sides[cell][other].map { $0.distance(to: color) < parameters.sameColorDistance * contrast } == true
            }.count
            if count >= parameters.seedSides { return true }
        }
        return false
    }

    /// The neighbor across `side` when the two sides along that edge show one cover. Normally
    /// neither side may show its own square color (a square next to a tint that happens to look
    /// like it keeps its own color); `extended` also accepts an edge where one side does, as long
    /// as the other is a strong cover side of a cell whose whole ring is that cover.
    func sameAcross(_ cell: Int, _ side: Int, extended: Bool) -> Int? {
        let opposite = BoardOcclusion.opposite
        guard let other = BoardOcclusion.neighbor(cell, side), let a = sides[cell][side], let b = sides[other][opposite[side]],
              showOneCover(a, b, lightFirst: (cell / 8 + cell % 8) % 2 == 0, extended: extended) else { return nil }
        if deviates[cell][side] && deviates[other][opposite[side]] { return other }
        guard extended else { return nil }
        if isCover(cell, side, extended: true) && isSeed(cell) { return other }
        if isCover(other, opposite[side], extended: true) && isSeed(other) { return other }
        return nil
    }

    /// Display cells with at least `minimumCoveredSides` linked sides. `extended`: use the alien,
    /// translucent and equal-color tests as well as the plain foreign one.
    func coveredCells(extended: Bool) -> [Int] {
        let opposite = BoardOcclusion.opposite
        func evidence(_ cell: Int, _ side: Int) -> Bool { isCover(cell, side, extended: extended) }
        // Spreading along one cover only asks that the side not fit its own square color; the
        // color match to the cell's linked sides already ties it to the cover.
        func spreads(_ cell: Int, _ side: Int) -> Bool {
            foreign[cell][side] || (extended && alien[cell][side])
        }
        var linked = [[Bool]](repeating: [Bool](repeating: false, count: 4), count: 64)
        for cell in 0..<64 {
            for side in 0..<4 {
                guard let other = sameAcross(cell, side, extended: extended),
                      evidence(cell, side) || evidence(other, opposite[side]) else { continue }
                linked[cell][side] = true
                linked[other][opposite[side]] = true
            }
        }
        var changed = true
        while changed {
            changed = false
            for cell in 0..<64 where linked[cell].contains(true) {
                let coverColors = (0..<4).filter { linked[cell][$0] }.compactMap { sides[cell][$0] }
                for side in 0..<4 where !linked[cell][side] {
                    guard let color = sides[cell][side],
                          coverColors.contains(where: { color.distance(to: $0) < parameters.sameColorDistance * contrast }) else { continue }
                    let across = sameAcross(cell, side, extended: extended)
                    guard spreads(cell, side) || across != nil else { continue }
                    linked[cell][side] = true
                    changed = true
                    if let across { linked[across][opposite[side]] = true }
                }
            }
        }
        return (0..<64).filter { cell in linked[cell].filter { $0 }.count >= parameters.minimumCoveredSides }
    }

    /// The covered cells split into covers: connected groups, joined again when they show the
    /// same cover color (one banner broken by a piece, or by a cell the rule missed).
    func covers(_ cells: [Int]) -> [[Int]] {
        var remaining = Set(cells)
        var groups: [[Int]] = []
        while let start = remaining.min() {
            var group: [Int] = []
            var stack = [start]
            remaining.remove(start)
            while let cell = stack.popLast() {
                group.append(cell)
                for side in 0..<4 {
                    guard let next = BoardOcclusion.neighbor(cell, side), remaining.contains(next) else { continue }
                    remaining.remove(next)
                    stack.append(next)
                }
            }
            groups.append(group)
        }
        var merged: [[Int]] = []
        var colors: [RGB?] = []
        for group in groups {
            let color = coverColor(group)
            let index = color.flatMap { color in
                colors.firstIndex { $0.map { $0.distance(to: color) < parameters.sameColorDistance * contrast } == true }
            }
            if let index {
                merged[index] += group
            } else {
                merged.append(group)
                colors.append(color)
            }
        }
        return merged
    }

    /// The median of the ring colors of `cells` that differ from their own square color: the
    /// color of the thing drawn over them.
    func coverColor(_ cells: [Int]) -> RGB? {
        var colors: [RGB] = []
        for cell in cells {
            for side in 0..<4 where deviates[cell][side] {
                if let color = sides[cell][side] { colors.append(color) }
            }
        }
        return RGB.median(colors)
    }

    /// Whether the cover's edge cuts across cells instead of following the board's grid: sides of
    /// cells outside it that show its color, or its own cells that show both their square color
    /// and its color. The board's own tints fill whole cells, so they show neither.
    func showsCutEdge(_ cover: [Int]) -> Bool {
        let coverColors = cover.flatMap { cell in
            (0..<4).filter { deviates[cell][$0] }.compactMap { sides[cell][$0] }
        }
        guard !coverColors.isEmpty else { return false }
        let inside = Set(cover)
        let budget = 1.5 * parameters.sameColorDistance * contrast
        var fringe = 0
        for cell in cover {
            for side in 0..<4 {
                guard let other = BoardOcclusion.neighbor(cell, side), !inside.contains(other),
                      deviates[other][BoardOcclusion.opposite[side]],
                      let seen = sides[other][BoardOcclusion.opposite[side]],
                      coverColors.contains(where: { seen.distance(to: $0) < budget }) else { continue }
                fringe += 1
            }
        }
        if fringe >= parameters.minimumFringeSides { return true }
        var split = 0
        for cell in cover {
            var showsSquare = false, showsCover = false
            for side in 0..<4 {
                guard let seen = sides[cell][side] else { continue }
                if seen.distance(to: base(cell)) <= quiet { showsSquare = true }
                else if isCover(cell, side, extended: true) { showsCover = true }
            }
            if showsSquare && showsCover { split += 1 }
        }
        return split >= parameters.minimumSplitCells
    }
}
