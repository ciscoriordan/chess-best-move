import ChessCore
import Foundation

/// Display cells and board squares.
@_spi(Testing)
public enum DisplayGrid {
    /// The square shown in display row `row` (0 = top) and column `column` (0 = left).
    public static func square(row: Int, column: Int, whiteAtBottom: Bool) -> Square {
        whiteAtBottom
            ? Square(file: column, rank: 7 - row)!
            : Square(file: 7 - column, rank: row)!
    }

    /// Display cell index (row * 8 + column) of `square`.
    public static func cell(of square: Square, whiteAtBottom: Bool) -> Int {
        whiteAtBottom
            ? (7 - square.rank) * 8 + square.file
            : square.rank * 8 + (7 - square.file)
    }

    /// Reorders 64 display-cell values into `Square.index` order.
    public static func toSquares<T>(_ cells: [T], whiteAtBottom: Bool) -> [T] {
        precondition(cells.count == 64)
        return (0..<64).map { index in cells[cell(of: Square(index: index)!, whiteAtBottom: whiteAtBottom)] }
    }

    /// Reorders 64 `Square.index` values into display-cell order.
    public static func toCells<T>(_ squares: [T], whiteAtBottom: Bool) -> [T] {
        precondition(squares.count == 64)
        return (0..<64).map { cell in squares[square(row: cell / 8, column: cell % 8, whiteAtBottom: whiteAtBottom).index] }
    }
}

/// Resamples the board region the way the training crops were made: PIL-style bilinear with
/// the filter widened by the downscale factor (antialiased), from the source pixels.
enum BoardResampler {
    /// Planar Float32 RGB in 0...1, shape [64, 3, cell, cell], display cells in row-major order.
    /// `fill`: 64 colors (0...255, display cells row-major) that stand in for the parts of each
    /// cell outside the image, so a board cut off by the screenshot edge gives crops that show
    /// the square's own color there. Without it, edge pixels are repeated.
    /// Transparent pixels (`RGBAImage.hasTransparency`) count as outside the image too.
    static func cellBatch(_ image: RGBAImage, x: Double, y: Double, size: Double, cell: Int, fill: [RGB]? = nil) -> [Float] {
        let out = cell * 8
        var source = image
        if image.hasTransparency, let fill {
            source = filledTransparency(image, x: x, y: y, size: size, fill: fill)
        }
        let rgb = resample(source, x: x, y: y, size: size, outSize: out, fill: fill)
        var batch = [Float](repeating: 0, count: 64 * 3 * cell * cell)
        let plane = cell * cell
        batch.withUnsafeMutableBufferPointer { dst in
            rgb.withUnsafeBufferPointer { src in
                for row in 0..<8 {
                    for column in 0..<8 {
                        let n = row * 8 + column
                        let base = n * 3 * plane
                        for yy in 0..<cell {
                            let srcRow = ((row * cell + yy) * out + column * cell) * 3
                            let dstRow = yy * cell
                            for xx in 0..<cell {
                                let s = srcRow + xx * 3
                                dst[base + dstRow + xx] = src[s]
                                dst[base + plane + dstRow + xx] = src[s + 1]
                                dst[base + 2 * plane + dstRow + xx] = src[s + 2]
                            }
                        }
                    }
                }
            }
        }
        return batch
    }

    /// A copy of `image` whose transparent pixels on the board take their cell's `fill` color.
    static func filledTransparency(_ image: RGBAImage, x: Double, y: Double, size: Double, fill: [RGB]) -> RGBAImage {
        precondition(fill.count == 64)
        var data = image.data
        let w = image.width, h = image.height
        let cellPixels = size / 8
        let x0 = max(0, Int(x.rounded(.down))), x1 = min(w, Int((x + size).rounded(.up)))
        let y0 = max(0, Int(y.rounded(.down))), y1 = min(h, Int((y + size).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return image }
        data.withUnsafeMutableBufferPointer { d in
            for py in y0..<y1 {
                let row = max(0, min(7, Int((Double(py) + 0.5 - y) / cellPixels)))
                for px in x0..<x1 {
                    let p = (py * w + px) * 4
                    guard d[p + 3] < RGBAImage.opaqueAlpha else { continue }
                    let column = max(0, min(7, Int((Double(px) + 0.5 - x) / cellPixels)))
                    let color = fill[row * 8 + column]
                    d[p] = UInt8(max(0, min(255, color.r.rounded())))
                    d[p + 1] = UInt8(max(0, min(255, color.g.rounded())))
                    d[p + 2] = UInt8(max(0, min(255, color.b.rounded())))
                }
            }
        }
        return RGBAImage(width: w, height: h, data: data, hasTransparency: true)
    }

    /// Colors for the parts of the board's cells outside the image: the cell's own border-ring
    /// color when at least half of the cell is visible and its ring was measured (it then carries
    /// a highlight tint, too), otherwise the base color of its parity.
    static func fillColors(_ detection: BoardDetection, imageWidth: Int, imageHeight: Int) -> [RGB] {
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let s = detection.cellSize
        return (0..<64).map { index in
            let row = index / 8, column = index % 8
            let rect = CGRect(x: detection.originX + Double(column) * s, y: detection.originY + Double(row) * s, width: s, height: s)
            let visible = rect.intersection(bounds)
            let fraction = visible.isNull ? 0 : Double(visible.width * visible.height) / (s * s)
            if fraction >= 0.5 && detection.isMeasured(index) { return detection.cellColors[index] }
            return (row + column) % 2 == 0 ? detection.lightColor : detection.darkColor
        }
    }

    struct Filter {
        var start: [Int]
        var count: [Int]
        var weights: [Float]   // count.max per output sample, zero-padded
        var stride: Int
    }

    /// PIL `precompute_coeffs` for the bilinear (triangle) filter.
    static func filter(inStart: Double, inSize: Double, outSize: Int) -> Filter {
        let scale = inSize / Double(outSize)
        let filterScale = max(scale, 1)
        let support = filterScale
        let stride = Int(ceil(support)) * 2 + 1
        var start = [Int](repeating: 0, count: outSize)
        var count = [Int](repeating: 0, count: outSize)
        var weights = [Float](repeating: 0, count: outSize * stride)
        for i in 0..<outSize {
            let center = inStart + (Double(i) + 0.5) * scale
            let lo = Int(floor(center - support + 0.5))
            let hi = Int(floor(center + support + 0.5))
            var total = 0.0
            var local = [Double](repeating: 0, count: stride)
            var n = 0
            for x in lo..<hi where n < stride {
                let t = abs((Double(x) - center + 0.5) / filterScale)
                let wgt = max(0, 1 - t)
                local[n] = wgt
                total += wgt
                n += 1
            }
            start[i] = lo
            count[i] = n
            for k in 0..<n {
                weights[i * stride + k] = Float(total > 0 ? local[k] / total : 0)
            }
        }
        return Filter(start: start, count: count, weights: weights, stride: stride)
    }

    /// Interleaved Float32 RGB (0...1) of size outSize x outSize. Samples outside the image take
    /// the `fill` color of their board cell (display cells row-major, 0...255) or, without
    /// `fill`, the nearest edge pixel.
    static func resample(_ image: RGBAImage, x: Double, y: Double, size: Double, outSize: Int, fill: [RGB]? = nil) -> [Float] {
        let w = image.width, h = image.height
        let fx = filter(inStart: x, inSize: size, outSize: outSize)
        let fy = filter(inStart: y, inSize: size, outSize: outSize)
        let fillColors: [Float]? = fill.map { colors in
            precondition(colors.count == 64)
            return colors.flatMap { [Float($0.r), Float($0.g), Float($0.b)] }
        }
        let cellPixels = size / 8
        /// Board cell column of a source column (clamped to the board).
        func cellColumn(_ sx: Int) -> Int { max(0, min(7, Int(floor((Double(sx) + 0.5 - x) / cellPixels)))) }
        // Vertical pass first, over the source columns the horizontal filter touches.
        let colLo = max(0, min(w - 1, fx.start.first ?? 0))
        let colHi = max(0, min(w - 1, (fx.start.last ?? 0) + (fx.count.last ?? 0)))
        let span = colHi - colLo + 1
        let columnCells = (0..<span).map { cellColumn(colLo + $0) }
        var temp = [Float](repeating: 0, count: span * outSize * 3)
        image.data.withUnsafeBufferPointer { src in
            temp.withUnsafeMutableBufferPointer { dst in
                let s = UncheckedSendableBox(src), d = UncheckedSendableBox(dst)
                parallelRows(outSize, minimumRowsPerChunk: 8) { oy in
                    let start = fy.start[oy], n = fy.count[oy]
                    let inside = start >= 0 && start + n <= h
                    let cellRow = oy * 8 / outSize
                    for column in 0..<span {
                        let sx = colLo + column
                        var r: Float = 0, g: Float = 0, b: Float = 0
                        for k in 0..<n {
                            let wgt = fy.weights[oy * fy.stride + k]
                            let sy = start + k
                            if !inside, sy < 0 || sy >= h, let fillColors {
                                let f = (cellRow * 8 + columnCells[column]) * 3
                                r += wgt * fillColors[f]; g += wgt * fillColors[f + 1]; b += wgt * fillColors[f + 2]
                                continue
                            }
                            let p = (max(0, min(h - 1, sy)) * w + sx) * 4
                            r += wgt * Float(s.value[p]); g += wgt * Float(s.value[p + 1]); b += wgt * Float(s.value[p + 2])
                        }
                        let o = (oy * span + column) * 3
                        d.value[o] = r; d.value[o + 1] = g; d.value[o + 2] = b
                    }
                }
            }
        }
        var result = [Float](repeating: 0, count: outSize * outSize * 3)
        temp.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { dst in
                let s = UncheckedSendableBox(src), d = UncheckedSendableBox(dst)
                parallelRows(outSize, minimumRowsPerChunk: 8) { oy in
                    let cellRow = oy * 8 / outSize
                    for ox in 0..<outSize {
                        let start = fx.start[ox], n = fx.count[ox]
                        let inside = start >= 0 && start + n <= w
                        var r: Float = 0, g: Float = 0, b: Float = 0
                        for k in 0..<n {
                            let wgt = fx.weights[ox * fx.stride + k]
                            let sx = start + k
                            if !inside, sx < 0 || sx >= w, let fillColors {
                                let f = (cellRow * 8 + ox * 8 / outSize) * 3
                                r += wgt * fillColors[f]; g += wgt * fillColors[f + 1]; b += wgt * fillColors[f + 2]
                                continue
                            }
                            let column = max(0, min(span - 1, max(0, min(w - 1, sx)) - colLo))
                            let p = (oy * span + column) * 3
                            r += wgt * s.value[p]; g += wgt * s.value[p + 1]; b += wgt * s.value[p + 2]
                        }
                        let o = (oy * outSize + ox) * 3
                        let inv: Float = 1.0 / 255.0
                        d.value[o] = r * inv; d.value[o + 1] = g * inv; d.value[o + 2] = b * inv
                    }
                }
            }
        }
        return result
    }
}
