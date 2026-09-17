import CoreGraphics
import Foundation
import Vision

/// Reads the coordinate labels around the board's edge. Three placements are searched:
/// - inside the board, digits in the left column (the style of one large chess app and its
///   website): rank digits in the top-left corner of the left column's cells, file letters in
///   the bottom-right corner of the bottom row's cells, each in the other square color;
/// - inside the board, digits in the right column (the style of another large chess site): rank
///   digits in the top-right corner of the right column's cells, file letters in the bottom-left
///   corner of the bottom row's cells, also in the other square color;
/// - outside the board (many sites, printed diagrams, and the first site's "outside" setting):
///   digits left of the left column, letters below the bottom row, in any color that stands out
///   from the page behind them.
///
/// The cases are named after the geometry, and the styles above are described rather than named,
/// because the case names and raw values of a public enum end up in the shipped binary and the
/// app's source is published: nothing either one carries names the sites the board art came from.
@_spi(Testing)
public enum CoordinateReader {
    /// One corner glyph as a binary ink mask.
    struct Glyph {
        var width: Int
        var height: Int
        var mask: [Bool]
        var inkCount: Int
        /// Ink bounding box in cell-size units relative to the region's top-left.
        var top: Double
        var bottom: Double
        var left: Double
        var right: Double
    }

    /// Where a layout draws its labels.
    public enum LabelLayout: String, Sendable, CaseIterable {
        /// Inside the board: digits in the left column, letters in the bottom row.
        case insideDigitsLeft
        /// Inside the board: digits in the right column, letters in the bottom row.
        case insideDigitsRight
        /// Outside the board: digits left of it, letters below it.
        case outside
    }

    /// Region of the file letter within a bottom-row cell, as cell fractions (x0, y0, x1, y1).
    static let letterRegion = (0.58, 0.62, 0.99, 0.995)
    /// Region of the rank digit within a left-column cell.
    static let digitRegion = (0.01, 0.01, 0.40, 0.38)
    /// Digits in the right column: letters bottom-left in the bottom row, digits top-right in
    /// the right column.
    static let rightColumnLetterRegion = (0.01, 0.62, 0.42, 0.995)
    static let rightColumnDigitRegion = (0.60, 0.01, 0.99, 0.38)
    /// Outside the board, relative to the bottom-row cell (letters) and the left-column cell
    /// (digits): a strip about half a square deep.
    static let outsideLetterRegion = (0.12, 1.02, 0.88, 1.55)
    static let outsideDigitRegion = (-0.55, 0.12, -0.02, 0.88)

    /// How a glyph sits in its region.
    enum Anchor {
        /// Against the right edge of the cell (file letters end about 6% from it).
        case right
        /// Against the left edge of the cell (rank digits start about 5% from it).
        case left
        /// Anywhere away from the region's edges (labels outside the board).
        case free
    }

    /// Extracts glyph masks for the 8 file letters (bottom row, left to right) and the 8 rank
    /// digits (top to bottom) in the layout with the most glyphs (`insideDigitsLeft` on ties). Nil
    /// entries: no plausible glyph found.
    static func glyphs(_ image: RGBAImage, detection: BoardDetection) -> (letters: [Glyph?], digits: [Glyph?], layout: LabelLayout?) {
        var best: (letters: [Glyph?], digits: [Glyph?], layout: LabelLayout?) = ([Glyph?](repeating: nil, count: 8), [Glyph?](repeating: nil, count: 8), nil)
        var bestCount = 0
        for layout in LabelLayout.allCases {
            // Clear `insideDigitsLeft` labels: the other placements are not searched.
            if layout != .insideDigitsLeft && bestCount >= 10 { break }
            var (letters, digits) = glyphs(image, detection: detection, layout: layout)
            if layout == .outside {
                // Text below and beside a board is common (names, move lists), so outside labels
                // count only as a consistent row of letters or column of digits.
                if !aligned(letters, vertical: false) { letters = [Glyph?](repeating: nil, count: 8) }
                if !aligned(digits, vertical: true) { digits = [Glyph?](repeating: nil, count: 8) }
            }
            let count = letters.compactMap { $0 }.count + digits.compactMap { $0 }.count
            if count > bestCount + (layout == .insideDigitsLeft ? 0 : 1) || (bestCount == 0 && count > 0) {
                best = (letters, digits, layout)
                bestCount = count
            }
        }
        return best
    }

    static func glyphs(_ image: RGBAImage, detection: BoardDetection, layout: LabelLayout) -> (letters: [Glyph?], digits: [Glyph?]) {
        var letters: [Glyph?] = []
        var digits: [Glyph?] = []
        for column in 0..<8 {
            switch layout {
            case .insideDigitsLeft:
                letters.append(glyph(image, detection: detection, row: 7, column: column, region: letterRegion, anchor: .right))
            case .insideDigitsRight:
                letters.append(glyph(image, detection: detection, row: 7, column: column, region: rightColumnLetterRegion, anchor: .left))
            case .outside:
                letters.append(glyph(image, detection: detection, row: 7, column: column, region: outsideLetterRegion, anchor: .free))
            }
        }
        for row in 0..<8 {
            switch layout {
            case .insideDigitsLeft:
                digits.append(glyph(image, detection: detection, row: row, column: 0, region: digitRegion, anchor: .left))
            case .insideDigitsRight:
                digits.append(glyph(image, detection: detection, row: row, column: 7, region: rightColumnDigitRegion, anchor: .right))
            case .outside:
                digits.append(glyph(image, detection: detection, row: row, column: 0, region: outsideDigitRegion, anchor: .free))
            }
        }
        return (letters, digits)
    }

    /// Whether at least 5 glyphs were found and they line up like printed labels: letters on one
    /// baseline, digits of one height in one column.
    static func aligned(_ glyphs: [Glyph?], vertical: Bool) -> Bool {
        let found = glyphs.compactMap { $0 }
        guard found.count >= 5 else { return false }
        if vertical {
            let heights = found.map { $0.bottom - $0.top }
            let centers = found.map { ($0.left + $0.right) / 2 }
            return heights.max()! <= 1.4 * heights.min()! && centers.max()! - centers.min()! <= 0.12
        }
        let bottoms = found.map(\.bottom)
        return bottoms.max()! - bottoms.min()! <= 0.06
    }

    /// Ink mask of a region of one cell (fractions of the cell, which may reach outside it), on a
    /// sampling grid of about 1.5 px or finer.
    struct InkMask {
        var width: Int
        var height: Int
        var step: Double
        var mask: [Bool]
    }

    static func inkMask(_ image: RGBAImage, detection: BoardDetection, row: Int, column: Int,
                        region: (Double, Double, Double, Double), onBackground: Bool = false) -> InkMask? {
        let s = detection.cellSize
        let x0 = detection.originX + (Double(column) + region.0) * s
        let y0 = detection.originY + (Double(row) + region.1) * s
        let x1 = detection.originX + (Double(column) + region.2) * s
        let y1 = detection.originY + (Double(row) + region.3) * s
        let step = max(1.0, s / 110)
        let gw = Int((x1 - x0) / step), gh = Int((y1 - y0) / step)
        guard gw >= 8, gh >= 8 else { return nil }
        let w = image.width, h = image.height
        var colors = [RGB?](repeating: nil, count: gw * gh)
        image.data.withUnsafeBufferPointer { d in
            for gy in 0..<gh {
                let py = Int(y0 + (Double(gy) + 0.5) * step)
                guard py >= 0, py < h else { continue }
                for gx in 0..<gw {
                    let px = Int(x0 + (Double(gx) + 0.5) * step)
                    guard px >= 0, px < w else { continue }
                    let p = (py * w + px) * 4
                    colors[gy * gw + gx] = RGB(Double(d[p]), Double(d[p + 1]), Double(d[p + 2]))
                }
            }
        }
        var mask = [Bool](repeating: false, count: gw * gh)
        // A region mostly outside the image (a board cut off by the image edge) has no label to
        // read, and its cell has no measured color.
        guard colors.lazy.filter({ $0 != nil }).count * 2 >= gw * gh else { return nil }
        if onBackground {
            // Labels outside the board: ink is whatever stands out from the page, the median
            // color of the region, by at least half the strongest difference found.
            let inside = colors.compactMap { $0 }
            guard let background = RGB.median(stride(from: 0, to: inside.count, by: 7).map { inside[$0] }) else { return nil }
            let distances = colors.map { $0.map { $0.distance(to: background) } ?? 0 }
            let strongest = stride(from: 0, to: distances.count, by: 3).map { distances[$0] }.sorted(by: >)[max(0, distances.count / 300)]
            guard strongest >= 60 else { return nil }
            let threshold = max(40, 0.5 * strongest)
            for i in 0..<mask.count where distances[i] >= threshold { mask[i] = true }
            return InkMask(width: gw, height: gh, step: step, mask: mask)
        }
        let cellIndex = row * 8 + column
        let isLight = (row + column) % 2 == 0
        let own = detection.cellColors[cellIndex]
        let ink = isLight ? detection.darkColor : detection.lightColor
        let contrast = max(own.distance(to: ink), 1)
        guard contrast >= 20 else { return nil }
        let axis = ink - own
        let axisLengthSquared = max(axis.dot(axis), 1)
        for i in 0..<mask.count {
            guard let color = colors[i] else { continue }
            // Ink lies along the line from the square's own color toward the other square
            // color, at least half way; some themes draw labels a little darker or lighter than
            // the other square color, so overshoot is allowed.
            let offset = color - own
            let t = offset.dot(axis) / axisLengthSquared
            let perpendicular = offset - axis * t
            let off = abs(perpendicular.r) + abs(perpendicular.g) + abs(perpendicular.b)
            if t >= 0.5 && t <= 2.5 && off < 0.35 * contrast {
                mask[i] = true
            }
        }
        return InkMask(width: gw, height: gh, step: step, mask: mask)
    }

    static func glyph(_ image: RGBAImage, detection: BoardDetection, row: Int, column: Int,
                      region: (Double, Double, Double, Double), anchor: Anchor) -> Glyph? {
        let s = detection.cellSize
        let onBackground = anchor == .free
        guard let ink = inkMask(image, detection: detection, row: row, column: column, region: region,
                                onBackground: onBackground) else { return nil }
        let gw = ink.width, gh = ink.height, step = ink.step
        var mask = ink.mask
        // Remove decorations drawn identically in every cell (the corner rivets of the metal
        // board, bevels): ink that is also present, within one sample, at the same place in two
        // cells of the same color that carry no label. Requiring both keeps a label whose
        // reference cell happens to hold a piece reaching into the corner.
        let references: [(Int, Int)]
        if onBackground {
            references = []
        } else if row == 7 {
            references = [(5, column), (3, column)]
        } else {
            references = column < 4 ? [(row, column + 2), (row, column + 4)] : [(row, column - 2), (row, column - 4)]
        }
        let referenceMasks = references.compactMap { inkMask(image, detection: detection, row: $0.0, column: $0.1, region: region) }
            .filter { $0.width == gw && $0.height == gh }
        if referenceMasks.count == 2 {
            func dilated(_ m: [Bool], _ x: Int, _ y: Int) -> Bool {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, ny >= 0, nx < gw, ny < gh, m[ny * gw + nx] { return true }
                    }
                }
                return false
            }
            for y in 0..<gh {
                for x in 0..<gw where mask[y * gw + x] {
                    if dilated(referenceMasks[0].mask, x, y) && dilated(referenceMasks[1].mask, x, y) {
                        mask[y * gw + x] = false
                    }
                }
            }
        }
        var count = 0
        var minX = gw, maxX = -1, minY = gh, maxY = -1
        // Connected ink components that do not touch the region's edges. Pieces reach into the
        // corner from the cell's middle, and neighboring squares or the board edge touch the
        // outer sides; the label glyph floats inside.
        struct Component { var members: [Int]; var minX: Int; var maxX: Int; var minY: Int; var maxY: Int }
        var label = [Int32](repeating: 0, count: gw * gh)
        var components: [Component] = []
        var stack: [Int] = []
        var next: Int32 = 0
        for startIndex in 0..<(gw * gh) where mask[startIndex] && label[startIndex] == 0 {
            next += 1
            label[startIndex] = next
            stack.append(startIndex)
            var component = Component(members: [], minX: gw, maxX: -1, minY: gh, maxY: -1)
            var touchesEdge = false
            while let index = stack.popLast() {
                component.members.append(index)
                let x = index % gw, y = index / gw
                component.minX = min(component.minX, x); component.maxX = max(component.maxX, x)
                component.minY = min(component.minY, y); component.maxY = max(component.maxY, y)
                if x == 0 || y == 0 || x == gw - 1 || y == gh - 1 { touchesEdge = true }
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                        let n = ny * gw + nx
                        if mask[n] && label[n] == 0 {
                            label[n] = next
                            stack.append(n)
                        }
                    }
                }
            }
            if !touchesEdge && component.members.count >= 3 { components.append(component) }
        }
        // The glyph is anchored to the cell corner: file letters end about 6% from the right
        // edge, rank digits start about 5% from the left edge. Take the largest component near
        // that anchor, plus components overlapping it (the dot of a glyph, a broken stroke).
        func cellX(_ gx: Int) -> Double { region.0 + Double(gx) * step / s }
        let anchored = components.filter { c in
            switch anchor {
            case .right: return cellX(c.maxX + 1) >= 0.84
            case .left: return cellX(c.minX) <= 0.14 + max(0, region.0 - 0.01)
            case .free:
                let cx = Double(c.minX + c.maxX + 1) / 2 / Double(gw), cy = Double(c.minY + c.maxY + 1) / 2 / Double(gh)
                return cx >= 0.15 && cx <= 0.85 && cy >= 0.15 && cy <= 0.85
            }
        }
        guard let main = anchored.max(by: { $0.members.count < $1.members.count }) else { return nil }
        let margin = 2
        var kept = [Bool](repeating: false, count: gw * gh)
        count = 0
        for c in components {
            let overlaps = c.maxX >= main.minX - margin && c.minX <= main.maxX + margin
                && c.maxY >= main.minY - margin && c.minY <= main.maxY + margin
            guard overlaps else { continue }
            for index in c.members {
                kept[index] = true
                count += 1
            }
            minX = min(minX, c.minX); maxX = max(maxX, c.maxX); minY = min(minY, c.minY); maxY = max(maxY, c.maxY)
        }
        let area = gw * gh
        guard count >= max(6, area / 250), count <= area / 5, maxY >= minY, maxX >= minX else { return nil }
        let heightFraction = Double(maxY - minY + 1) * step / s
        let widthFraction = Double(maxX - minX + 1) * step / s
        // A coordinate glyph is roughly 8% to 22% of a cell tall and narrower than 20%.
        guard heightFraction >= 0.05, heightFraction <= 0.3, widthFraction <= 0.24 else { return nil }
        return Glyph(width: gw, height: gh, mask: kept, inkCount: count,
                     top: Double(minY) * step / s, bottom: Double(maxY + 1) * step / s,
                     left: Double(minX) * step / s, right: Double(maxX + 1) * step / s)
    }

    // MARK: - Glyph shapes

    /// Log-odds for white at the bottom from glyph geometry: file letters b, d, f and h have
    /// ascenders (in columns 1, 3, 5, 7 when white is at the bottom), and "1" is the narrowest,
    /// lightest digit (bottom row when white is at the bottom).
    static func shapeLogOdds(letters: [Glyph?], digits: [Glyph?]) -> Double {
        var total = 0.0
        // Letters: how far each glyph reaches above the common baseline, compared with the
        // digit height (digits are as tall as ascenders) or, without digits, the tallest letter.
        let found = letters.compactMap { $0 }
        let digitHeights = digits.compactMap { $0 }.map { $0.bottom - $0.top }.sorted()
        if found.count >= 3 {
            let bottoms = found.map(\.bottom).sorted()
            let baseline = bottoms[bottoms.count / 2]
            let heights = letters.map { $0.map { baseline - $0.top } }
            let known = heights.compactMap { $0 }
            let reference: Double?
            if digitHeights.count >= 3 {
                reference = digitHeights[digitHeights.count / 2]
            } else if let high = known.max(), let low = known.min(), high > 1.15 * low {
                reference = high
            } else {
                reference = nil
            }
            if let reference, reference > 0 {
                var agree = 0, disagree = 0
                for (column, height) in heights.enumerated() {
                    guard let height else { continue }
                    let tall: Bool
                    if height >= 0.87 * reference { tall = true } else if height <= 0.8 * reference { tall = false } else { continue }
                    // White at bottom: columns 1, 3, 5, 7 show b, d, f, h (ascenders).
                    if tall == (column % 2 == 1) { agree += 1 } else { disagree += 1 }
                }
                if agree + disagree >= 3 {
                    total += max(-6, min(6, Double(agree - disagree) * 0.9))
                }
            }
        }
        // Digits: the "1" is the narrowest glyph.
        let digitGlyphs = digits.compactMap { $0 }
        if digitGlyphs.count >= 6, let top = digits[0], let bottom = digits[7] {
            let topWidth = top.right - top.left, bottomWidth = bottom.right - bottom.left
            let narrowest = digitGlyphs.map { $0.right - $0.left }.min() ?? 0
            let ratio = topWidth / max(bottomWidth, 1e-6)
            if ratio > 1.3 && bottomWidth <= narrowest + 1e-9 {
                total += min(3, log(ratio) * 4)
            } else if ratio < 1 / 1.3 && topWidth <= narrowest + 1e-9 {
                total -= min(3, -log(ratio) * 4)
            }
        }
        return total
    }

    // MARK: - Vision

    /// Log-odds from Vision text recognition of the glyphs, laid out as two clean text lines.
    static func textLogOdds(letters: [Glyph?], digits: [Glyph?]) -> (Double, String) {
        let letterCount = letters.compactMap { $0 }.count
        let digitCount = digits.compactMap { $0 }.count
        guard letterCount >= 4 || digitCount >= 4 else { return (0, "") }
        var total = 0.0
        var transcript = ""
        if letterCount >= 4, let strip = stripImage(letters) {
            let text = recognize(strip, customWords: ["abcdefgh", "hgfedcba"])
            transcript += "letters=\(text) "
            let chars = Array(text.lowercased().filter { "abcdefgh".contains($0) })
            total += sequenceLogOdds(chars, forward: Array("abcdefgh"))
        }
        if digitCount >= 4, let strip = stripImage(digits) {
            let text = recognize(strip, customWords: ["87654321", "12345678"])
            transcript += "digits=\(text)"
            let chars = Array(text.filter { "12345678".contains($0) })
            // Digits run top to bottom: 8...1 when white is at the bottom.
            total += sequenceLogOdds(chars, forward: Array("87654321"))
        }
        return (total, transcript)
    }

    /// Positive when `chars` read in the `forward` order, negative when reversed.
    static func sequenceLogOdds(_ chars: [Character], forward: [Character]) -> Double {
        guard chars.count >= 2 else { return 0 }
        let backward = Array(forward.reversed())
        let f = lcs(chars, forward), b = lcs(chars, backward)
        guard f != b else { return 0 }
        let margin = Double(f - b)
        return max(-6, min(6, margin * 1.5))
    }

    static func lcs(_ a: [Character], _ b: [Character]) -> Int {
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1] ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table[a.count][b.count]
    }

    /// Black-on-white image of the glyphs side by side, each cropped to its ink and scaled to
    /// a common height.
    static func stripImage(_ glyphs: [Glyph?]) -> CGImage? {
        let targetHeight = 40
        let gap = 28, margin = 24
        var pieces: [(w: Int, pixels: [UInt8])] = []
        for glyph in glyphs {
            guard let g = glyph else { continue }
            // Crop the mask to its ink bounding box.
            var minX = g.width, maxX = -1, minY = g.height, maxY = -1
            for y in 0..<g.height {
                for x in 0..<g.width where g.mask[y * g.width + x] {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { continue }
            let cw = maxX - minX + 1, ch = maxY - minY + 1
            let scale = Double(targetHeight) / Double(ch)
            let ow = max(4, Int(Double(cw) * scale))
            var pixels = [UInt8](repeating: 255, count: ow * targetHeight)
            for y in 0..<targetHeight {
                let sy = minY + min(ch - 1, Int(Double(y) / scale))
                for x in 0..<ow {
                    let sx = minX + min(cw - 1, Int(Double(x) / scale))
                    if g.mask[sy * g.width + sx] { pixels[y * ow + x] = 0 }
                }
            }
            pieces.append((ow, pixels))
        }
        guard !pieces.isEmpty else { return nil }
        let width = margin * 2 + pieces.map(\.w).reduce(0, +) + gap * (pieces.count - 1)
        let height = targetHeight + margin * 2
        var canvas = [UInt8](repeating: 255, count: width * height)
        var x0 = margin
        for piece in pieces {
            for y in 0..<targetHeight {
                for x in 0..<piece.w {
                    canvas[(y + margin) * width + x0 + x] = piece.pixels[y * piece.w + x]
                }
            }
            x0 += piece.w + gap
        }
        guard let provider = CGDataProvider(data: Data(canvas) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func recognize(_ image: CGImage, customWords: [String]) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.customWords = customWords
        request.minimumTextHeight = 0.2
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let observations = request.results ?? []
        return observations
            .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined()
            .replacingOccurrences(of: " ", with: "")
    }
}
