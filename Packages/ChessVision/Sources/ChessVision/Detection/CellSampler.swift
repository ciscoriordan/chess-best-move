import Foundation

/// Robust color statistics of board cells.
enum CellSampler {
    /// Inner and outer distance of the sampled ring from the cell edge, as fractions of the cell.
    /// Pieces sit in the middle of the cell and rarely reach this band; coordinates, badges and
    /// arrows cover only a small part of it, which the median ignores.
    static let ringInner = 0.04
    static let ringOuter = 0.15
    static let samplesPerSide = 28

    /// Per-channel interquartile mean of the cell's border ring, or nil when less than 40% of the
    /// ring lies inside the image (transparent pixels count as outside). The interquartile mean ignores pieces, badges and coordinate
    /// glyphs covering up to a quarter of the ring, and unlike the median it gives hatched or
    /// grainy squares their average color instead of one of their two ink levels.
    static func ringMedian(_ image: RGBAImage, x: Double, y: Double, size: Double) -> RGB? {
        var histR = [UInt16](repeating: 0, count: 256)
        var histG = [UInt16](repeating: 0, count: 256)
        var histB = [UInt16](repeating: 0, count: 256)
        var inside = 0, total = 0
        let n = samplesPerSide
        let w = image.width, h = image.height
        let checksAlpha = image.hasTransparency, opaque = RGBAImage.opaqueAlpha
        image.data.withUnsafeBufferPointer { d in
            for j in 0..<n {
                let v = (Double(j) + 0.5) / Double(n)
                let dv = min(v, 1 - v)
                for i in 0..<n {
                    let u = (Double(i) + 0.5) / Double(n)
                    let edge = min(dv, min(u, 1 - u))
                    guard edge >= ringInner, edge <= ringOuter else { continue }
                    total += 1
                    let px = Int(x + u * size), py = Int(y + v * size)
                    guard px >= 0, py >= 0, px < w, py < h else { continue }
                    let p = (py * w + px) * 4
                    guard !checksAlpha || d[p + 3] >= opaque else { continue }
                    inside += 1
                    histR[Int(d[p])] += 1
                    histG[Int(d[p + 1])] += 1
                    histB[Int(d[p + 2])] += 1
                }
            }
        }
        guard total > 0, Double(inside) >= 0.4 * Double(total) else { return nil }
        return RGB(interquartileMean(histR, count: inside), interquartileMean(histG, count: inside),
                   interquartileMean(histB, count: inside))
    }

    /// Interquartile-mean colors of the four sides of the cell's border ring (top, bottom, left,
    /// right; each ring sample belongs to its nearest edge). Nil for a side with fewer than half
    /// of its samples inside the image (transparent pixels count as outside). A tint covers all four sides; a tall piece reaching over
    /// the cell edge, an arrow or a badge usually covers one or two.
    static func ringSides(_ image: RGBAImage, x: Double, y: Double, size: Double) -> [RGB?] {
        var hist = [[UInt16]](repeating: [UInt16](repeating: 0, count: 256 * 3), count: 4)
        var inside = [Int](repeating: 0, count: 4), total = [Int](repeating: 0, count: 4)
        let n = samplesPerSide
        let w = image.width, h = image.height
        let checksAlpha = image.hasTransparency, opaque = RGBAImage.opaqueAlpha
        image.data.withUnsafeBufferPointer { d in
            for j in 0..<n {
                let v = (Double(j) + 0.5) / Double(n)
                for i in 0..<n {
                    let u = (Double(i) + 0.5) / Double(n)
                    let distances = [v, 1 - v, u, 1 - u]
                    let edge = distances.min()!
                    guard edge >= ringInner, edge <= ringOuter else { continue }
                    let side = distances.firstIndex(of: edge)!
                    total[side] += 1
                    let px = Int(x + u * size), py = Int(y + v * size)
                    guard px >= 0, py >= 0, px < w, py < h else { continue }
                    let p = (py * w + px) * 4
                    guard !checksAlpha || d[p + 3] >= opaque else { continue }
                    inside[side] += 1
                    hist[side][Int(d[p])] += 1
                    hist[side][256 + Int(d[p + 1])] += 1
                    hist[side][512 + Int(d[p + 2])] += 1
                }
            }
        }
        return (0..<4).map { side in
            guard total[side] > 0, Double(inside[side]) >= 0.5 * Double(total[side]) else { return nil }
            let channel = { (c: Int) in interquartileMean(Array(hist[side][(256 * c)..<(256 * c + 256)]), count: inside[side]) }
            return RGB(channel(0), channel(1), channel(2))
        }
    }

    static func interquartileMean(_ hist: [UInt16], count: Int) -> Double {
        let lower = Double(count) * 0.25, upper = Double(count) * 0.75
        var cumulative = 0.0, sum = 0.0
        for (value, c) in hist.enumerated() where c > 0 {
            let start = cumulative, end = cumulative + Double(c)
            let overlap = min(end, upper) - max(start, lower)
            if overlap > 0 { sum += overlap * Double(value) }
            cumulative = end
            if cumulative >= upper { break }
        }
        return sum / max(1e-9, upper - lower)
    }

    static func histogramMedian(_ hist: [UInt16], count: Int) -> Double {
        let half = (count + 1) / 2
        var cumulative = 0
        for (value, c) in hist.enumerated() {
            cumulative += Int(c)
            if cumulative >= half { return Double(value) }
        }
        return 255
    }
}
