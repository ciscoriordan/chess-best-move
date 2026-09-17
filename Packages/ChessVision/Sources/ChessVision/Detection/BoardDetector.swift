import CoreGraphics
import Foundation

/// A detected board: the 8x8 lattice in source pixels plus the base colors measured on it.
@_spi(Testing)
public struct BoardDetection: Sendable {
    /// Left edge of display column 0, in source pixels (may be slightly negative for a board
    /// cropped at the image edge).
    public var originX: Double
    /// Top edge of display row 0.
    public var originY: Double
    /// Cell edge length in source pixels.
    public var cellSize: Double
    /// Mean checkerboard margin over the 64 cells, -1...1. Real boards score about 0.6 to 0.95.
    public var score: Double
    /// Base color of the light squares: the cells whose row + column is even, which are the darker
    /// ones on a board with inverted square colors (`squareColorsInverted`).
    public var lightColor: RGB
    /// Base color of the dark squares: the other cells.
    public var darkColor: RGB
    /// Border-ring median color of each display cell, row-major from the top-left. Black for a
    /// cell with less than 40% of its ring inside the image (see `cellMeasured`).
    public var cellColors: [RGB]
    /// The score verification ranked lattices and candidates by (see `BoardDetector.checkerScore`):
    /// mismatched cells inside the image count double, cells outside it cost a quarter, and a dark
    /// top-left cluster costs a little.
    public var selectionScore: Double = 0
    /// Other boards in the image that verified well and do not overlap this one (a second game,
    /// a thumbnail, a checkered UI element), largest first.
    public var otherBoards: [CGRect] = []
    /// Per display cell: whether at least 40% of its border ring lies inside the image and is
    /// opaque, so that `cellColors` holds a measured color. Empty means every cell was measured.
    public var cellMeasured: [Bool] = []

    /// Whether display cell `index` has a measured border-ring color.
    public func isMeasured(_ index: Int) -> Bool { cellMeasured.isEmpty || cellMeasured[index] }

    public var rect: CGRect {
        CGRect(x: originX, y: originY, width: cellSize * 8, height: cellSize * 8)
    }

    public var contrast: Double { lightColor.distance(to: darkColor) }

    /// The squares whose row + column is even (the top-left square) are the darker ones. Every
    /// chess board has a light square at the top-left in both orientations, so this board is
    /// drawn with inverted square colors, or the image is mirrored.
    public var squareColorsInverted: Bool { lightColor.luminance < darkColor.luminance }
}

/// Finds the axis-aligned 8x8 board in a screenshot.
///
/// 1. Coarse search on a downscaled copy (short side about 300 px): for each candidate cell
///    size `s`, a checkerboard response `d(p, p+s·x) + d(p, p+s·y) - d(p, p+s·(x+y)) -
///    (d(p, p+2s·x) + d(p, p+2s·y)) / 2` is positive only inside a checkerboard of cell size s
///    (independent of the grid phase, roughly zero on pieces and text), and its box mean over
///    a 6s x 6s window locates the board.
/// 2. Lattice fit at full resolution: edge-energy profiles along x and y, and the cell size and
///    offsets that put the 7 interior grid lines on edge peaks (sub-pixel, square cells).
/// 3. Verification: the border-ring median color of every cell must form two alternating
///    clusters. The lattice shifted by whole cells in each direction is scored too, which fixes
///    whole-cell offsets of the coarse stage. Which cluster is at the top-left is not assumed:
///    some themes and mirrored images have a dark top-left square
///    (`BoardDetection.squareColorsInverted`).
/// 4. Choice: every candidate is verified. Larger boards are preferred over better-scoring small
///    ones (a main board over a cleaner thumbnail), and the other boards that verified are listed
///    in `BoardDetection.otherBoards`.
@_spi(Testing)
public enum BoardDetector {
    /// Smallest board edge considered, as a fraction of the image's short side.
    public static let minimumBoardFraction = 0.25
    /// Verification thresholds for accepting a board.
    public static let minimumScore = 0.30
    public static let minimumContrast = 12.0
    /// Coarse candidates verified per image.
    static let maximumCandidates = 6
    /// Candidates whose coarse response is below this fraction of the strongest are skipped.
    static let minimumRelativeResponse = 0.1
    /// A board can be chosen over the best-scoring one when its selection score is at most this
    /// much lower, or when it verifies as another board (`otherBoardScore`).
    static let largerBoardTolerance = 0.12
    /// Selection-score bonus per doubling of the cell size, relative to the largest eligible
    /// board: a main board with pieces, highlights or a textured theme scores 0.8 to 0.87 where
    /// a clean thumbnail next to it scores 1.0.
    static let sizePreference = 0.2
    /// The best lattice with the other top-left brightness is refined too when its selection score
    /// is at most this much lower (`verifyAlternatives`).
    static let alternativeTolerance = 0.15
    /// A non-overlapping board with at least this verification score counts as another board.
    public static let otherBoardScore = 0.7

    public static func detect(_ image: RGBAImage) -> BoardDetection? {
        let shortSide = min(image.width, image.height)
        guard shortSide >= 64 else { return nil }
        let factor = max(1, shortSide / 300)
        let coarse = image.downscaledRGB(factor: factor)
        let candidates = coarseCandidates(coarse, maxCount: maximumCandidates)
        let strongest = candidates.map(\.score).max() ?? 0
        var verifiedBoards: [BoardDetection] = []
        // A board's checkerboard response depends on its contrast, not its size, so a second
        // board or thumbnail responds about as strongly as the main board; much weaker windows
        // are text and UI and are not worth a lattice fit.
        for candidate in candidates where candidate.score >= minimumRelativeResponse * strongest {
            let x = Double(candidate.x * factor)
            let y = Double(candidate.y * factor)
            let s = Double(candidate.s * factor)
            // A candidate mostly inside a board already verified is that board again (another
            // scale or window position); verification already tried its whole-cell shifts.
            let window = CGRect(x: x, y: y, width: 8 * s, height: 8 * s)
            if verifiedBoards.contains(where: { board in
                let inside = window.intersection(board.rect)
                return !inside.isNull && Double(inside.width * inside.height) > 0.5 * Double(window.width * window.height)
            }) { continue }
            guard let lattice = fitLattice(image, x: x, y: y, s: s) else { continue }
            let alternatives = verifyAlternatives(image, lattice: lattice)
            guard let first = alternatives.first else { continue }
            var refined: [BoardDetection] = []
            for (index, alternative) in alternatives.enumerated() {
                // The other brightness is refined only when it scored close to the best.
                guard index == 0 || alternative.selectionScore >= first.selectionScore - alternativeTolerance else { continue }
                var verified = alternative
                if verified.score >= minimumScore, verified.contrast >= minimumContrast,
                   let signed = refineSigned(image, detection: verified),
                   let reverified = verify(image, lattice: signed, shifts: false),
                   reverified.score >= verified.score - 0.05, reverified.contrast >= verified.contrast * 0.98 {
                    // A better-aligned ring samples less of the neighboring cells, so its measured
                    // light/dark contrast does not drop.
                    verified = reverified
                }
                refined.append(verified)
            }
            guard let verified = refined.max(by: { $0.selectionScore < $1.selectionScore }),
                  verified.score >= minimumScore, verified.contrast >= minimumContrast else { continue }
            verifiedBoards.append(verified)
        }
        return choose(verifiedBoards)
    }

    /// Picks the board to return from verified candidates and lists the other boards.
    static func choose(_ boards: [BoardDetection]) -> BoardDetection? {
        // Lattices that overlap describe one board: keep the best-scoring of them.
        var distinct: [BoardDetection] = []
        for board in boards.sorted(by: { $0.selectionScore > $1.selectionScore })
        where !distinct.contains(where: { overlapFraction($0.rect, board.rect) > 0.1 }) {
            distinct.append(board)
        }
        guard let bestSelection = distinct.first?.selectionScore else { return nil }
        // Among boards scoring close to the best, or verifying as boards in their own right, the
        // one with the best selection score after a bonus for size: the main board rather than a
        // cleaner thumbnail or checkered UI element.
        let eligible = distinct.filter { $0.selectionScore >= bestSelection - largerBoardTolerance || $0.score >= otherBoardScore }
        let largestCell = eligible.map(\.cellSize).max() ?? 1
        func utility(_ board: BoardDetection) -> Double {
            board.selectionScore + sizePreference * log2(board.cellSize / largestCell)
        }
        guard var chosen = eligible.max(by: { utility($0) < utility($1) }) else { return nil }
        chosen.otherBoards = distinct
            .filter { $0.score >= otherBoardScore && overlapFraction($0.rect, chosen.rect) <= 0.1 }
            .sorted { $0.cellSize > $1.cellSize }
            .map(\.rect)
        return chosen
    }

    /// Intersection area over the smaller rectangle's area.
    static func overlapFraction(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        return Double(inter.width * inter.height) / Double(min(a.width * a.height, b.width * b.height))
    }

    // MARK: - Coarse search

    struct CoarseCandidate: Sendable {
        var x: Int
        var y: Int
        var s: Int
        var score: Double
    }

    static func coarseCandidates(_ plane: RGBPlane, maxCount: Int) -> [CoarseCandidate] {
        let w = plane.width, h = plane.height
        let shortSide = min(w, h)
        let sMin = max(5, Int(Double(shortSide) * minimumBoardFraction / 8))
        let sMax = max(sMin, Int((Double(shortSide) * 1.03 / 8).rounded(.up)))
        let scales = Array(sMin...sMax)
        let perScale: [[CoarseCandidate]] = plane.data.withUnsafeBufferPointer { px in
            let pxBox = UncheckedSendableBox(px)
            return parallelMap(scales.count) { index in
                bestBoxes(pxBox.value, width: w, height: h, s: scales[index])
            }
        }
        var all = perScale.flatMap { $0 }.sorted { $0.score > $1.score }
        var kept: [CoarseCandidate] = []
        while let top = all.first, kept.count < maxCount {
            all.removeFirst()
            guard top.score > 0 else { break }
            let rect = CGRect(x: top.x, y: top.y, width: top.s * 8, height: top.s * 8)
            let overlapping = kept.contains { k in
                let other = CGRect(x: k.x, y: k.y, width: k.s * 8, height: k.s * 8)
                return iou(rect, other) > 0.5
            }
            if !overlapping { kept.append(top) }
        }
        return kept
    }

    /// Best box position for cell size `s` on the coarse plane, and the best position whose box
    /// does not overlap it (a second board of the same size).
    static func bestBoxes(_ px: UnsafeBufferPointer<UInt8>, width w: Int, height h: Int, s: Int) -> [CoarseCandidate] {
        // Sample grid with stride 2; sample (gx, gy) is pixel (2gx, 2gy) and needs p + 2s inside.
        guard w - 1 - 2 * s >= 0, h - 1 - 2 * s >= 0 else { return [] }
        let gw = (w - 1 - 2 * s) / 2 + 1
        let gh = (h - 1 - 2 * s) / 2 + 1
        let box = 3 * s
        guard gw >= box - 1, gh >= box - 1 else { return [] }
        let bw = min(box, gw), bh = min(box, gh)
        var integral = [Int64](repeating: 0, count: (gw + 1) * (gh + 1))
        integral.withUnsafeMutableBufferPointer { ii in
            for gy in 0..<gh {
                let y = 2 * gy
                let row0 = y * w, rowS = (y + s) * w, row2S = (y + 2 * s) * w
                var rowSum: Int64 = 0
                let base = (gy + 1) * (gw + 1)
                let above = gy * (gw + 1)
                for gx in 0..<gw {
                    let x = 2 * gx
                    let p = (row0 + x) * 3
                    let pX = (row0 + x + s) * 3
                    let pY = (rowS + x) * 3
                    let pXY = (rowS + x + s) * 3
                    let pXX = (row0 + x + 2 * s) * 3
                    let pYY = (row2S + x) * 3
                    let r0 = Int(px[p]), g0 = Int(px[p + 1]), b0 = Int(px[p + 2])
                    @inline(__always) func d(_ q: Int) -> Int {
                        abs(r0 - Int(px[q])) + abs(g0 - Int(px[q + 1])) + abs(b0 - Int(px[q + 2]))
                    }
                    let response = 2 * (d(pX) + d(pY) - d(pXY)) - d(pXX) - d(pYY)
                    rowSum += Int64(response)
                    ii[base + gx + 1] = ii[above + gx + 1] + rowSum
                }
            }
        }
        var best = CoarseCandidate(x: 0, y: 0, s: s, score: -.infinity)
        var second = best
        let area = Double(bw * bh) * 2   // response was doubled to stay integral
        integral.withUnsafeBufferPointer { ii in
            let stride = gw + 1
            func score(_ gx: Int, _ gy: Int) -> Double {
                let sum = ii[(gy + bh) * stride + gx + bw] - ii[gy * stride + gx + bw]
                    - ii[(gy + bh) * stride + gx] + ii[gy * stride + gx]
                return Double(sum) / area
            }
            for gy in 0...(gh - bh) {
                for gx in 0...(gw - bw) {
                    let value = score(gx, gy)
                    if value > best.score {
                        best = CoarseCandidate(x: 2 * gx, y: 2 * gy, s: s, score: value)
                    }
                }
            }
            guard best.score.isFinite else { return }
            // The response window covers 6 of a board's 8 cells, so windows of two separate boards
            // are at least 6 cells apart along one axis.
            let separation = 6 * s
            for gy in 0...(gh - bh) {
                for gx in 0...(gw - bw) where abs(2 * gx - best.x) >= separation || abs(2 * gy - best.y) >= separation {
                    let value = score(gx, gy)
                    if value > second.score {
                        second = CoarseCandidate(x: 2 * gx, y: 2 * gy, s: s, score: value)
                    }
                }
            }
        }
        guard best.score.isFinite else { return [] }
        return second.score.isFinite && second.score > 0 ? [best, second] : [best]
    }

    // MARK: - Lattice fit

    struct Lattice: Sendable {
        var x: Double
        var y: Double
        var s: Double
    }

    /// Edge-energy profiles and the grid that puts the interior lines on edge peaks.
    static func fitLattice(_ image: RGBAImage, x: Double, y: Double, s: Double) -> Lattice? {
        let w = image.width, h = image.height
        let cap = 140
        // Profile along x: vertical edges summed over the board's inner rows.
        let px0 = max(1, Int(x - 1.2 * s)), px1 = min(w - 1, Int(x + 9.2 * s))
        let rowStart = max(0, Int(y + 0.4 * s)), rowEnd = min(h - 1, Int(y + 7.6 * s))
        let py0 = max(1, Int(y - 1.2 * s)), py1 = min(h - 1, Int(y + 9.2 * s))
        let colStart = max(0, Int(x + 0.4 * s)), colEnd = min(w - 1, Int(x + 7.6 * s))
        guard px1 - px0 > Int(4 * s), py1 - py0 > Int(4 * s), rowEnd > rowStart, colEnd > colStart else { return nil }

        // Edge strength of column x is measured in short windows of rows (about a sixth of a
        // cell): inside a window the pixel differences across a grid line all have one sign and
        // add up, while the grain of textured boards (sand, marble) cancels. The profile value
        // is a low quantile of the windows' edge magnitudes, not their sum: a grid line crosses
        // every window, while the outlines of pieces standing in the same column position (a
        // full back rank) reach only some of them.
        let window = max(2, Int(s / 6))
        let rowWindows = Array(stride(from: rowStart, through: max(rowStart, rowEnd - window + 1), by: window))
        let columnWindows = Array(stride(from: colStart, through: max(colStart, colEnd - window + 1), by: window))
        let profileX: [Double] = image.data.withUnsafeBufferPointer { d in
            let db = UncheckedSendableBox(d)
            return parallelMap(px1 - px0 + 1) { i -> Double in
                let xx = px0 + i
                var values = [Double]()
                values.reserveCapacity(rowWindows.count)
                for start in rowWindows {
                    var dr = 0, dg = 0, dbl = 0, n = 0
                    var yy = start
                    while yy < min(h, start + window) {
                        let p = (yy * w + xx) * 4
                        dr += Int(db.value[p]) - Int(db.value[p - 4])
                        dg += Int(db.value[p + 1]) - Int(db.value[p - 3])
                        dbl += Int(db.value[p + 2]) - Int(db.value[p - 2])
                        n += 1
                        yy += 2
                    }
                    values.append(min(Double(cap), Double(abs(dr) + abs(dg) + abs(dbl)) / Double(max(n, 1))))
                }
                return Self.quantile(values, fraction: edgeQuantile)
            }
        }
        let profileY: [Double] = image.data.withUnsafeBufferPointer { d in
            let db = UncheckedSendableBox(d)
            return parallelMap(py1 - py0 + 1) { i -> Double in
                let yy = py0 + i
                var values = [Double]()
                values.reserveCapacity(columnWindows.count)
                let rowP = yy * w, rowQ = (yy - 1) * w
                for start in columnWindows {
                    var dr = 0, dg = 0, dbl = 0, n = 0
                    var xx = start
                    while xx < min(w, start + window) {
                        let p = (rowP + xx) * 4, q = (rowQ + xx) * 4
                        dr += Int(db.value[p]) - Int(db.value[q])
                        dg += Int(db.value[p + 1]) - Int(db.value[q + 1])
                        dbl += Int(db.value[p + 2]) - Int(db.value[q + 2])
                        n += 1
                        xx += 2
                    }
                    values.append(min(Double(cap), Double(abs(dr) + abs(dg) + abs(dbl)) / Double(max(n, 1))))
                }
                return Self.quantile(values, fraction: edgeQuantile)
            }
        }
        let sx = smooth(profileX), sy = smooth(profileY)

        // Energy of the 7 interior lines for origin o and cell size c.
        func lineEnergy(_ profile: [Double], start: Int, origin o: Double, cell c: Double) -> Double {
            var total = 0.0
            for k in 1...7 {
                total += sample(profile, at: o + Double(k) * c - Double(start))
            }
            return total
        }
        func bestOrigin(_ profile: [Double], start: Int, center: Double, cell c: Double, range: Double, step: Double) -> (Double, Double) {
            var bestO = center, bestE = -1.0
            var o = center - range
            while o <= center + range {
                let e = lineEnergy(profile, start: start, origin: o, cell: c)
                if e > bestE { bestE = e; bestO = o }
                o += step
            }
            return (bestO, bestE)
        }

        var best = (x: x, y: y, s: s, e: -1.0)
        var c = s * 0.88
        let coarseStep = max(0.25, s * 0.004)
        // Smoothed edge peaks are about 3 px wide whatever the cell size, so the origin step
        // stays below that on large boards.
        let originStep = min(1.5, max(0.5, s * 0.01))
        while c <= s * 1.12 {
            let (ox, ex) = bestOrigin(sx, start: px0, center: x, cell: c, range: 0.65 * s, step: originStep)
            let (oy, ey) = bestOrigin(sy, start: py0, center: y, cell: c, range: 0.65 * s, step: originStep)
            if ex + ey > best.e { best = (ox, oy, c, ex + ey) }
            c += coarseStep
        }
        // Fine pass around the best coarse fit.
        var fine = best
        c = best.s - coarseStep
        while c <= best.s + coarseStep {
            let (ox, ex) = bestOrigin(sx, start: px0, center: best.x, cell: c, range: max(1.0, s * 0.012), step: 0.1)
            let (oy, ey) = bestOrigin(sy, start: py0, center: best.y, cell: c, range: max(1.0, s * 0.012), step: 0.1)
            if ex + ey > fine.e { fine = (ox, oy, c, ex + ey) }
            c += 0.05
        }
        guard fine.e > 0 else { return nil }
        return Lattice(x: fine.x, y: fine.y, s: fine.s)
    }

    /// Quantile of the edge magnitudes used for the lattice-fit profiles.
    static let edgeQuantile = 0.35

    /// Linear-interpolated quantile of `values` (0 when empty).
    static func quantile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = fraction * Double(sorted.count - 1)
        let i = Int(position)
        guard i + 1 < sorted.count else { return sorted[sorted.count - 1] }
        let t = position - Double(i)
        return sorted[i] * (1 - t) + sorted[i + 1] * t
    }

    static func smooth(_ v: [Double]) -> [Double] {
        guard v.count > 2 else { return v }
        var out = v
        for i in 1..<(v.count - 1) {
            out[i] = 0.25 * v[i - 1] + 0.5 * v[i] + 0.25 * v[i + 1]
        }
        return out
    }

    static func sample(_ v: [Double], at position: Double) -> Double {
        guard position >= 0 else { return 0 }
        let i = Int(position)
        guard i + 1 < v.count else { return 0 }
        let t = position - Double(i)
        return v[i] * (1 - t) + v[i + 1] * t
    }

    // MARK: - Signed refinement

    /// Refits the lattice with parity-signed edge profiles. Once the light and dark colors and
    /// the cell parity are known, a true grid line changes the color from dark to light or back
    /// with a sign that alternates cell by cell along the line. Edges that do not alternate, such
    /// as the aligned bases of a row of pieces or a bevel drawn inside every cell, cancel out.
    static func refineSigned(_ image: RGBAImage, detection: BoardDetection) -> Lattice? {
        let w = image.width, h = image.height
        let s = detection.cellSize, x0 = detection.originX, y0 = detection.originY
        let axis = detection.lightColor - detection.darkColor
        let norm = abs(axis.r) + abs(axis.g) + abs(axis.b)
        guard norm > 1 else { return nil }
        // Integer weights for the projection onto the light-minus-dark direction.
        let wr = Int(axis.r / norm * 256), wg = Int(axis.g / norm * 256), wb = Int(axis.b / norm * 256)
        let cap = Int(detection.contrast * 1.5 * 256)
        let margin = 0.45 * s

        // Profile along x: differences between x-1 and x, signed by the row's parity.
        let px0 = max(1, Int(x0 - margin)), px1 = min(w - 1, Int(x0 + 8 * s + margin))
        let py0 = max(1, Int(y0 - margin)), py1 = min(h - 1, Int(y0 + 8 * s + margin))
        guard px1 > px0 + Int(2 * s), py1 > py0 + Int(2 * s) else { return nil }

        // Sample rows (for the x profile) in the middle 60% of each board row, with the sign
        // (-1)^row, and likewise sample columns for the y profile.
        func samples(origin: Double, limit: Int) -> [(Int, Int)] {
            var out: [(Int, Int)] = []
            for k in 0..<8 {
                let a = Int(origin + (Double(k) + 0.2) * s), b = Int(origin + (Double(k) + 0.8) * s)
                var v = max(0, a)
                while v <= min(limit - 1, b) {
                    out.append((v, k % 2 == 0 ? 1 : -1))
                    v += 2
                }
            }
            return out
        }
        let rowSamples = samples(origin: y0, limit: h)
        let colSamples = samples(origin: x0, limit: w)

        let profileX: [Double] = image.data.withUnsafeBufferPointer { d in
            let db = UncheckedSendableBox(d)
            return parallelMap(px1 - px0 + 1) { i -> Double in
                let xx = px0 + i
                var sum = 0
                for (yy, sign) in rowSamples {
                    let p = (yy * w + xx) * 4, q = p - 4
                    let diff = wr * (Int(db.value[p]) - Int(db.value[q])) + wg * (Int(db.value[p + 1]) - Int(db.value[q + 1]))
                        + wb * (Int(db.value[p + 2]) - Int(db.value[q + 2]))
                    sum += sign * max(-cap, min(cap, diff))
                }
                return Double(sum)
            }
        }
        let profileY: [Double] = image.data.withUnsafeBufferPointer { d in
            let db = UncheckedSendableBox(d)
            return parallelMap(py1 - py0 + 1) { i -> Double in
                let yy = py0 + i
                var sum = 0
                for (xx, sign) in colSamples {
                    let p = (yy * w + xx) * 4, q = ((yy - 1) * w + xx) * 4
                    let diff = wr * (Int(db.value[p]) - Int(db.value[q])) + wg * (Int(db.value[p + 1]) - Int(db.value[q + 1]))
                        + wb * (Int(db.value[p + 2]) - Int(db.value[q + 2]))
                    sum += sign * max(-cap, min(cap, diff))
                }
                return Double(sum)
            }
        }
        let sx = smooth(profileX), sy = smooth(profileY)

        // Line k (1...7) runs between cells k-1 and k. Along x, in board row 0 the cell k is
        // light when k is even, so the difference is positive there: weight (-1)^k.
        func energy(_ profile: [Double], start: Int, origin o: Double, cell c: Double) -> Double {
            var total = 0.0
            for k in 1...7 {
                let value = sample(profile, at: o + Double(k) * c - Double(start))
                total += k % 2 == 0 ? value : -value
            }
            return total
        }
        func bestOrigin(_ profile: [Double], start: Int, center: Double, cell c: Double, range: Double, step: Double) -> (Double, Double) {
            var bestO = center, bestE = -Double.infinity
            var o = center - range
            while o <= center + range {
                let e = energy(profile, start: start, origin: o, cell: c)
                if e > bestE { bestE = e; bestO = o }
                o += step
            }
            return (bestO, bestE)
        }
        var best = (x: x0, y: y0, s: s, e: -Double.infinity)
        var c = s * 0.97
        while c <= s * 1.03 {
            let (ox, ex) = bestOrigin(sx, start: px0, center: x0, cell: c, range: 0.3 * s, step: 0.25)
            let (oy, ey) = bestOrigin(sy, start: py0, center: y0, cell: c, range: 0.3 * s, step: 0.25)
            if ex + ey > best.e { best = (ox, oy, c, ex + ey) }
            c += 0.1
        }
        guard best.e > 0 else { return nil }
        return Lattice(x: best.x, y: best.y, s: best.s)
    }

    // MARK: - Verification

    /// Largest whole-cell shift of the fitted lattice that verification tries. The coarse window
    /// covers six of the eight rows and columns, so it can sit up to two cells off when pieces
    /// crowd one side of the board.
    static let maximumShift = 2

    /// Scores the lattice and its whole-cell shifts; returns the best as a detection.
    static func verify(_ image: RGBAImage, lattice: Lattice, shifts: Bool = true) -> BoardDetection? {
        verifyAlternatives(image, lattice: lattice, shifts: shifts).first
    }

    /// Scores the lattice and its whole-cell shifts. Returns the best as a detection, followed by
    /// the best shift whose top-left cluster has the other brightness (a shift by an odd number
    /// of cells) when there is one. On a low-contrast board a lattice a tenth of a cell off can
    /// score the true board and the board shifted by one row alike; the signed refinement then
    /// tells them apart.
    static func verifyAlternatives(_ image: RGBAImage, lattice: Lattice, shifts: Bool = true) -> [BoardDetection] {
        let m = shifts ? maximumShift : 0
        let span = 8 + 2 * m
        // Ring colors for cells -m...7+m in both directions, sampled in parallel by row.
        let rows: [[RGB?]] = parallelMap(span) { jj in
            (0..<span).map { ii in
                CellSampler.ringMedian(image, x: lattice.x + Double(ii - m) * lattice.s,
                                       y: lattice.y + Double(jj - m) * lattice.s, size: lattice.s)
            }
        }
        var best: BoardDetection?
        var bestOfEachBrightness: [Bool: BoardDetection] = [:]
        for dy in -m...m {
            for dx in -m...m {
                var cells: [RGB?] = []
                cells.reserveCapacity(64)
                for r in 0..<8 {
                    for c in 0..<8 {
                        cells.append(rows[r + dy + m][c + dx + m])
                    }
                }
                guard let scored = checkerScore(cells) else { continue }
                // Prefer the unshifted lattice on near ties.
                let selection = scored.selection - (dx == 0 && dy == 0 ? 0 : 0.01)
                let detection = BoardDetection(
                    originX: lattice.x + Double(dx) * lattice.s,
                    originY: lattice.y + Double(dy) * lattice.s,
                    cellSize: lattice.s,
                    score: scored.score,
                    lightColor: scored.light,
                    darkColor: scored.dark,
                    cellColors: cells.map { $0 ?? RGB(0, 0, 0) },
                    selectionScore: selection,
                    cellMeasured: cells.map { $0 != nil }
                )
                if best == nil || selection > best!.selectionScore { best = detection }
                let inverted = detection.squareColorsInverted
                if selection > bestOfEachBrightness[inverted]?.selectionScore ?? -.infinity {
                    bestOfEachBrightness[inverted] = detection
                }
            }
        }
        guard let best else { return [] }
        let other = bestOfEachBrightness[!best.squareColorsInverted]
        return [best] + (other.map { [$0] } ?? [])
    }

    /// Selection-score cost of a lattice cell outside the image (see `checkerScore`).
    static let outsidePenalty = 0.25
    /// Selection-score cost of a lattice whose top-left cluster is the darker one.
    static let invertedPenalty = 0.06

    /// Two-cluster alternating-pattern scores of 64 cell colors (row-major, nil = outside image).
    /// `light` is the median color of the cells whose row + column is even and `dark` that of the
    /// others, even when the even cells are the darker ones.
    ///
    /// Each cell inside the image has a margin in -1...1: how much closer its color is to its own
    /// cluster than to the other, relative to the contrast.
    /// - `score`: the mean margin, with -0.5 for each cell outside the image.
    /// - `selection`: the mean margin with negative margins doubled and -0.25 for each cell outside
    ///   the image, minus 0.06 when the top-left cluster is the darker one; it ranks whole-cell
    ///   shifts and candidates. Cells of screen UI next to a board match one cluster on one parity
    ///   and miss it on the other, averaging about 0, so without the doubled penalty a lattice
    ///   moved onto the UI would beat the true lattice of a board running past the image edge (16
    ///   cells outside cost 0.0625; 16 UI cells, half matching and half not, cost 0.125). The small
    ///   outside and brightness penalties keep a board flush with the image edge whose edge row is
    ///   covered (a keyboard, a promotion picker) from moving one row out of the image, while a
    ///   board drawn with inverted colors still beats a lattice moved one row onto the screen
    ///   (about 0.12).
    static func checkerScore(_ cells: [RGB?]) -> (score: Double, selection: Double, light: RGB, dark: RGB)? {
        var even: [RGB] = [], odd: [RGB] = []
        for r in 0..<8 {
            for c in 0..<8 {
                guard let color = cells[r * 8 + c] else { continue }
                if (r + c) % 2 == 0 { even.append(color) } else { odd.append(color) }
            }
        }
        guard even.count >= 20, odd.count >= 20,
              let light = RGB.median(even), let dark = RGB.median(odd) else { return nil }
        let contrast = light.distance(to: dark)
        guard contrast > 1 else { return (-1, -2, light, dark) }
        var total = 0.0, selection = 0.0
        for r in 0..<8 {
            for c in 0..<8 {
                guard let color = cells[r * 8 + c] else { total -= 0.5; selection -= outsidePenalty; continue }
                let isEven = (r + c) % 2 == 0
                let own = isEven ? light : dark, other = isEven ? dark : light
                let margin = max(-1, min(1, (color.distance(to: other) - color.distance(to: own)) / contrast))
                total += margin
                selection += margin < 0 ? 2 * margin : margin
            }
        }
        let inverted = light.luminance < dark.luminance
        return (total / 64, selection / 64 - (inverted ? invertedPenalty : 0), light, dark)
    }
}

func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let inter = a.intersection(b)
    guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
    let i = Double(inter.width * inter.height)
    return i / (Double(a.width * a.height) + Double(b.width * b.height) - i)
}
