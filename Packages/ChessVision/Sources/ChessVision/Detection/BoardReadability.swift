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

    /// Assesses a detected board. `labels`: the reported content of each display cell after the
    /// consistency repair, as `PieceClasses` indices.
    public static func assess(_ detection: BoardDetection, image: RGBAImage, predictions: [CellPrediction],
                              labels: [Int], temperature: Double) -> BoardReadability {
        let visible = visibleFractions(detection, image: image)
        let unseen = (0..<64).filter { visible[$0] < minimumVisibleFraction }
        let covered = BoardOcclusion.coveredCells(detection, image: image).filter { !unseen.contains($0) }
        var confidences = SquareCalibration.confidences(predictions, labels: labels, temperature: temperature)
        for cell in unseen + covered { confidences[cell] = hiddenSquareConfidence }
        return BoardReadability(visibleFractions: visible, unseenCells: unseen, coveredCells: covered,
                                confidences: confidences, cellSize: detection.cellSize,
                                squareColorsInverted: detection.squareColorsInverted, otherBoards: detection.otherBoards)
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
/// promotion picker, a floating window.
///
/// Such a cover is opaque, so on both square colors it shows the same color, while every tint the
/// board draws itself (last move, selection, premove, square marks) is translucent and keeps the
/// light and dark squares apart. Each side of each cell's border ring (`CellSampler.ringSides`)
/// is tested:
/// - A side is foreign when its color is clearly closer to the other square color than to its
///   own (margin below -`foreignMargin` of the light/dark contrast). A tint on a low-contrast
///   board can be foreign too, but only on isolated cells.
/// - Two cells of opposite colors that share an edge are linked there when the two sides along
///   that edge have nearly the same color (within `sameColorDistance` of the contrast), neither
///   shows its own square color (`minimumCoverDeviation` of the contrast, and at least
///   `minimumCoverDeviationLevels`), and at least one of them is foreign: one cover spans both.
/// - Links spread to the other sides of a linked cell that show nearly the same color as its
///   linked sides and are foreign themselves or match the neighbor's side across them.
/// A cell with at least `minimumCoveredSides` linked sides is covered.
///
/// Measured on the 2026-09-17 stress sets: 128 of the 161 detected screenshots of
/// build/stress/covered with a cover over at least half a square get a covered square (banners,
/// keyboards and promotion pickers nearly always; small toasts and video windows with content less
/// often), while 3 of 7,203 screenshots without covers do (two red premoves on low-contrast themes,
/// one real screenshot with a mark in a corner square).
@_spi(Testing)
public enum BoardOcclusion {
    /// Thresholds of the rule, as fractions of the board's light/dark contrast.
    public struct Parameters: Sendable {
        /// A side is foreign when its margin is below minus this.
        public var foreignMargin = 0.5
        /// Two sides have one color when they differ by less than this.
        public var sameColorDistance = 0.12
        /// A linked side must differ from its own square color by at least this, and by at least
        /// `minimumCoverDeviationLevels` (sum of the channel differences in 0...255 levels), so
        /// that JPEG noise and texture on a low-contrast board do not count.
        public var minimumCoverDeviation = 0.05
        public var minimumCoverDeviationLevels = 16.0
        /// A cell with at least this many linked sides is covered.
        public var minimumCoveredSides = 2
        public init() {}
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

    /// `sides`: per display cell, the ring side colors in `CellSampler.ringSides` order (top,
    /// bottom, left, right). `light` and `dark`: the colors of the cells whose row + column is
    /// even and odd.
    public static func coveredCells(sides: [[RGB?]], light: RGB, dark: RGB, parameters: Parameters = Parameters()) -> [Int] {
        let foreignMargin = parameters.foreignMargin, sameColorDistance = parameters.sameColorDistance
        let minimumCoveredSides = parameters.minimumCoveredSides
        precondition(sides.count == 64 && sides.allSatisfy { $0.count == 4 })
        let contrast = max(light.distance(to: dark), 1)
        let opposite = [1, 0, 3, 2]
        func neighbor(_ cell: Int, _ side: Int) -> Int? {
            var row = cell / 8, column = cell % 8
            switch side {
            case 0: row -= 1
            case 1: row += 1
            case 2: column -= 1
            default: column += 1
            }
            return (0..<8).contains(row) && (0..<8).contains(column) ? row * 8 + column : nil
        }
        var foreign = [[Bool]](repeating: [Bool](repeating: false, count: 4), count: 64)
        for cell in 0..<64 {
            let isEven = (cell / 8 + cell % 8) % 2 == 0
            let own = isEven ? light : dark, other = isEven ? dark : light
            for side in 0..<4 {
                guard let color = sides[cell][side] else { continue }
                foreign[cell][side] = (color.distance(to: other) - color.distance(to: own)) / contrast < -foreignMargin
            }
        }
        func base(_ cell: Int) -> RGB { (cell / 8 + cell % 8) % 2 == 0 ? light : dark }
        let minimumDeviation = max(parameters.minimumCoverDeviation * contrast, parameters.minimumCoverDeviationLevels)
        /// The neighbor across `side` when the two sides along that edge have nearly one color
        /// and neither shows its own square color (a square next to a tint that happens to look
        /// like it keeps its own color).
        func sameAcross(_ cell: Int, _ side: Int) -> Int? {
            guard let other = neighbor(cell, side), let a = sides[cell][side], let b = sides[other][opposite[side]],
                  a.distance(to: b) < sameColorDistance * contrast,
                  a.distance(to: base(cell)) >= minimumDeviation,
                  b.distance(to: base(other)) >= minimumDeviation else { return nil }
            return other
        }
        var linked = [[Bool]](repeating: [Bool](repeating: false, count: 4), count: 64)
        for cell in 0..<64 {
            for side in 0..<4 {
                guard let other = sameAcross(cell, side), foreign[cell][side] || foreign[other][opposite[side]] else { continue }
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
                          coverColors.contains(where: { color.distance(to: $0) < sameColorDistance * contrast }) else { continue }
                    let across = sameAcross(cell, side)
                    guard foreign[cell][side] || across != nil else { continue }
                    linked[cell][side] = true
                    changed = true
                    if let across { linked[across][opposite[side]] = true }
                }
            }
        }
        return (0..<64).filter { cell in linked[cell].filter { $0 }.count >= minimumCoveredSides }
    }
}
