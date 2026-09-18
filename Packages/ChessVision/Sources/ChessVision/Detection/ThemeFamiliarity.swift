import Foundation

/// Whether a detected board's art looks like the art the classifier was trained on.
///
/// The classifier and the confidence temperature that turns its probabilities into the numbers
/// `BoardRecognizer.confidentSquareProbability` is compared against were both fitted on rendered
/// boards drawn from one library of board themes and piece sets (`training/README.md`). On art
/// outside that library the probabilities are not calibrated: the classifier can report a piece
/// it has never seen the like of at 1.00. So a board whose art falls outside the range the
/// training library covers is reported as unreadable rather than confident, and the user checks
/// it (owner decision of 2026-09-17).
///
/// WHAT THIS CAN AND CANNOT SEE, measured on 2026-09-17 (`build/round4-detector`). The reference
/// below is the range of seven statistics over the 1,020 rendered boards of the synthetic test
/// set and the `uniform` and `transformed` stress sets, widened by a tenth of each span. Inside
/// it lie 3,114 of the 3,115 images measured: all 152 images of the real screenshot set, all 82
/// of the sealed holdout set, and every stress set but one board of `tiny`, which is flagged
/// anyway.
/// The check costs nothing on any board seen so far.
///
/// That is also its limit, and the limit is worth knowing before anyone leans on it. The two
/// real screenshots whose piece colors were flipped on unusual art (a gray metal board with
/// metallic pieces, a salmon-and-lavender board with neon pieces) are not outliers by these
/// statistics at all: the metal board's two square colors sit 2.6 levels (sum of channel
/// differences) from a rendered theme's, well inside the rendered spread, and its piece ink is
/// as neutral as any other board's. Ranking every real and holdout screenshot by its distance to
/// the nearest rendered board puts it 77th of 82. Nor does a board-level ink statistic separate
/// those two, because it measures the position (how many pieces of each color stand on the
/// board) more than the art: the two farthest real boards by ink are ordinary green-board
/// endgames. Those failures are a training-data problem, not an out-of-range problem. This check
/// is the guard for art far outside anything rendered, and its reference wants refitting from
/// the art library itself (see `Reference.rendered`).
@_spi(Testing)
public enum ThemeFamiliarity {
    /// One statistic's familiar range.
    public struct Band: Sendable {
        public var lowest: Double
        public var highest: Double
        public init(_ lowest: Double, _ highest: Double) {
            self.lowest = lowest
            self.highest = highest
        }
        public func holds(_ value: Double) -> Bool { value >= lowest && value <= highest }
    }

    /// The familiar range of each board-color statistic.
    public struct Reference: Sendable {
        /// Sum of the channel differences between the two square colors, 0...765.
        public var contrast: Band
        /// Luminance of the brighter and of the darker square color, 0...255. The two colors are
        /// ordered by luminance, not by parity, so a theme with a dark top-left square
        /// (`BoardDetection.squareColorsInverted`) is measured the same way as any other.
        public var lightLuminance: Band
        public var darkLuminance: Band
        /// Largest minus smallest channel of each square color, 0...255.
        public var lightSaturation: Band
        public var darkSaturation: Band
        /// How colored the piece ink is: the median over the cells holding a piece of the
        /// largest-minus-smallest channel of the ink lighter than the square (`brightInk`) and
        /// of the ink darker than it (`darkInk`), 0...255. Neutral piece sets sit near 0; the
        /// renderer's cartoon and material recolors reach the top of the range.
        public var brightInkSaturation: Band
        public var darkInkSaturation: Band

        /// Fitted on the 1,020 rendered boards of the synthetic test set and the `uniform` and
        /// `transformed` stress sets on 2026-09-17: the observed range of each statistic
        /// widened by a tenth of its span on each side, which is what it takes for JPEG noise
        /// and rescaling not to push a real screenshot of a known theme out (without the margin
        /// 4 of 152 real and 3 of 82 holdout screenshots fall out by 1 to 8 levels).
        ///
        /// Refit this from the whole approved art library rather than from the rendered sets:
        /// the renderer's procedural boards stretch the range far past the real themes, which is
        /// why the range below accepts almost anything. The numbers to replace it with are the
        /// per-theme square colors of every approved board theme in the art library (a request
        /// to the training owner, 2026-09-17; the measurement is in the training program's
        /// distribution record).
        public static let rendered = Reference(
            contrast: Band(-16.4, 516.3),
            lightLuminance: Band(12.1, 277.1),
            darkLuminance: Band(-5.4, 248.5),
            lightSaturation: Band(-12.1, 133.1),
            darkSaturation: Band(-18.4, 202.4),
            brightInkSaturation: Band(-15.1, 166.1),
            darkInkSaturation: Band(-12.2, 134.2)
        )
    }

    /// Pixels of a cell's interior sampled per side for the ink statistics, and how far in from
    /// the cell edge the sampling starts (as a fraction of the cell).
    static let inkSamplesPerSide = 40
    static let inkMargin = 0.10
    /// Ink counts as ink when its luminance differs from the cell's own background by this much.
    static let inkLuminanceDistance = 35.0
    /// Cells holding ink of one direction needed before its saturation is measured at all.
    static let inkCellsNeeded = 4

    /// The statistics of one detected board. The ink statistics are nil on a board with too few
    /// pieces to measure them (`inkCellsNeeded`), and are then not checked.
    public struct Statistics: Sendable {
        public var contrast: Double
        public var lightLuminance: Double
        public var darkLuminance: Double
        public var lightSaturation: Double
        public var darkSaturation: Double
        public var brightInkSaturation: Double?
        public var darkInkSaturation: Double?

        public init(_ detection: BoardDetection, image: RGBAImage? = nil) {
            let brighter = detection.squareColorsInverted ? detection.darkColor : detection.lightColor
            let darker = detection.squareColorsInverted ? detection.lightColor : detection.darkColor
            contrast = detection.contrast
            lightLuminance = brighter.luminance
            darkLuminance = darker.luminance
            lightSaturation = Self.saturation(brighter)
            darkSaturation = Self.saturation(darker)
            guard let image else { return }
            let ink = ThemeFamiliarity.inkSaturations(detection, image: image)
            brightInkSaturation = ink.bright
            darkInkSaturation = ink.dark
        }

        static func saturation(_ color: RGB) -> Double {
            max(color.r, max(color.g, color.b)) - min(color.r, min(color.g, color.b))
        }
    }

    /// Median saturation of the piece ink lighter than its square and of the ink darker than it,
    /// over the cells that hold enough of each. Measured against each cell's own border-ring
    /// color (`BoardDetection.cellColors`), so a tint on the square is not read as ink.
    static func inkSaturations(_ detection: BoardDetection, image: RGBAImage) -> (bright: Double?, dark: Double?) {
        let n = inkSamplesPerSide
        let size = detection.cellSize
        let w = image.width, h = image.height
        let checksAlpha = image.hasTransparency, opaque = RGBAImage.opaqueAlpha
        var bright: [Double] = [], dark: [Double] = []
        // Histograms rather than sorted arrays: this runs over every cell of every board.
        var luminances = [Int](repeating: 0, count: 256)
        var high = [UInt16](repeating: 0, count: 256 * 3)
        var low = [UInt16](repeating: 0, count: 256 * 3)
        image.data.withUnsafeBufferPointer { d in
            for cell in 0..<64 {
                guard detection.isMeasured(cell) else { continue }
                let x = detection.originX + Double(cell % 8) * size
                let y = detection.originY + Double(cell / 8) * size
                let baseLuminance = detection.cellColors.count == 64
                    ? detection.cellColors[cell].luminance
                    : CoverRule.base(cell, light: detection.lightColor, dark: detection.darkColor).luminance
                for index in 0..<256 { luminances[index] = 0 }
                for index in 0..<(256 * 3) { high[index] = 0; low[index] = 0 }
                var count = 0
                /// Calls `body` with every sampled interior pixel of the cell.
                func sample(_ body: (Int) -> Void) {
                    for j in 0..<n {
                        let v = (Double(j) + 0.5) / Double(n)
                        guard min(v, 1 - v) >= inkMargin else { continue }
                        let py = Int(y + v * size)
                        guard py >= 0, py < h else { continue }
                        for i in 0..<n {
                            let u = (Double(i) + 0.5) / Double(n)
                            guard min(u, 1 - u) >= inkMargin else { continue }
                            let px = Int(x + u * size)
                            guard px >= 0, px < w else { continue }
                            let p = (py * w + px) * 4
                            guard !checksAlpha || d[p + 3] >= opaque else { continue }
                            body(p)
                        }
                    }
                }
                sample { p in
                    let value = RGB(Double(d[p]), Double(d[p + 1]), Double(d[p + 2])).luminance
                    luminances[min(255, max(0, Int(value.rounded())))] += 1
                    count += 1
                }
                guard count >= 16 else { continue }
                /// The smallest luminance with at least `share` of the samples at or below it.
                func quantile(_ share: Double) -> Int {
                    let wanted = Int((share * Double(count)).rounded(.up))
                    var seen = 0
                    for value in 0..<256 {
                        seen += luminances[value]
                        if seen >= max(1, wanted) { return value }
                    }
                    return 255
                }
                let highCut = quantile(0.92), lowCut = quantile(0.08)
                var highCount = 0, lowCount = 0
                sample { p in
                    let value = Int(RGB(Double(d[p]), Double(d[p + 1]), Double(d[p + 2])).luminance.rounded())
                    if value >= highCut {
                        highCount += 1
                        for channel in 0..<3 { high[256 * channel + Int(d[p + channel])] += 1 }
                    }
                    if value <= lowCut {
                        lowCount += 1
                        for channel in 0..<3 { low[256 * channel + Int(d[p + channel])] += 1 }
                    }
                }
                func medianColor(_ histograms: [UInt16], _ total: Int) -> RGB? {
                    guard total > 0 else { return nil }
                    let channel = { (c: Int) in
                        CellSampler.histogramMedian(Array(histograms[(256 * c)..<(256 * c + 256)]), count: total)
                    }
                    return RGB(channel(0), channel(1), channel(2))
                }
                if let top = medianColor(high, highCount), top.luminance - baseLuminance > inkLuminanceDistance {
                    bright.append(Statistics.saturation(top))
                }
                if let bottom = medianColor(low, lowCount), baseLuminance - bottom.luminance > inkLuminanceDistance {
                    dark.append(Statistics.saturation(bottom))
                }
            }
        }
        func median(_ values: [Double]) -> Double? {
            guard values.count >= inkCellsNeeded else { return nil }
            let sorted = values.sorted()
            let count = sorted.count
            return count % 2 == 1 ? sorted[count / 2] : (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
        return (median(bright), median(dark))
    }

    /// The statistics that fall outside `reference`, as one line each, or an empty array when the
    /// board's art is inside the range the classifier was trained on.
    public static func unfamiliar(_ detection: BoardDetection, image: RGBAImage? = nil,
                                  reference: Reference = .rendered) -> [String] {
        let statistics = Statistics(detection, image: image)
        var checks: [(String, Double, Band)] = [
            ("square contrast", statistics.contrast, reference.contrast),
            ("light square brightness", statistics.lightLuminance, reference.lightLuminance),
            ("dark square brightness", statistics.darkLuminance, reference.darkLuminance),
            ("light square color strength", statistics.lightSaturation, reference.lightSaturation),
            ("dark square color strength", statistics.darkSaturation, reference.darkSaturation),
        ]
        if let value = statistics.brightInkSaturation {
            checks.append(("light piece color strength", value, reference.brightInkSaturation))
        }
        if let value = statistics.darkInkSaturation {
            checks.append(("dark piece color strength", value, reference.darkInkSaturation))
        }
        return checks.filter { !$0.2.holds($0.1) }.map { name, value, band in
            String(format: "%@ %.0f outside the trained range %.0f to %.0f", name, value,
                   max(0, band.lowest), band.highest)
        }
    }
}
