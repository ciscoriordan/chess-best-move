import Foundation

/// A running-clock marker found next to the board.
@_spi(Testing)
public struct RunningClock: Sendable, Hashable {
    /// True when the marked clock is the top player's (above the board), false for the bottom
    /// player's.
    public var isTop: Bool
    /// Center of the clock icon in image pixels.
    public var centerX: Double
    public var centerY: Double
    /// Radius of the icon's ring in image pixels.
    public var radius: Double
}

/// Finds the clock icon drawn in the running clock's box: a ring with clock hands to the left of
/// the time. The box color says nothing about whose turn it is (in the phone apps it follows the
/// player's piece color, light for White and black for Black; on the same sites' web boards the
/// running box is white), so only the icon is used, in either polarity.
///
/// Ink is luminance that differs by more than 40 from the mean over a window about a third of a
/// square wide, dark on light boxes and light on dark ones. An ink component counts as the icon
/// only when it looks like a clock in a clock box:
/// - a round ring (width and height within 20% of each other, 14% to 60% of a square across)
///   closed in at least 21 of 24 directions, with ink at its center (the hands) and little ink
///   between hands and ring, which rules out the digit 0, the letter O and the pause icon of a
///   daily game on vacation;
/// - a uniform box color around the ring, contrasting with the ring by at least 70, whose edge
///   is within 3.5 ring radii to the left, above and below with nothing drawn in between, which
///   rules out the puzzle timer drawn straight on the background and letters in running text;
/// - at least two glyphs of about the ring's height to its right (the time).
/// Searched: the right part of the bars 1.8 squares above and below the board (phones, portrait
/// tablets, the website), then a column right of the board (landscape tablets). An icon at both
/// the top and the bottom is contradictory and reports nothing.
///
/// Measured on 2026-09-17: all 223 icons in the synthetic test set found with none invented; in
/// the real screenshot set, 41 icons found, none invented; the 2 that disagree with the labeled side to move
/// are stepped-back game viewers whose highlight decides instead (real_057, real_064). Missed:
/// a centered clock in a wide landscape-tablet box (real_040) and a clock cut off by the image
/// edge (real_152).
@_spi(Testing)
public enum RunningClockReader {
    /// Samples per square edge.
    static let samplesPerCell = 90.0
    /// Height of each searched bar, in squares.
    static let barDepth = 1.8
    /// Width of the searched column right of the board, in squares.
    static let columnWidth = 5.0

    public static func read(_ image: RGBAImage, detection: BoardDetection) -> RunningClock? {
        let cell = detection.cellSize
        let left = detection.originX, right = detection.originX + 8 * cell
        let upper = detection.originY, lower = detection.originY + 8 * cell
        // Phones and portrait tablets: bars above and below the board, clock boxes at their right
        // end. Landscape tablets and wide windows: a column right of the board, the top player's
        // clock level with the board's top edge and the bottom player's with its bottom edge.
        let top = search(image, detection: detection, x0: left + 3.6 * cell, y0: upper - barDepth * cell,
                         x1: right, y1: upper - 0.03 * cell, top: true)
            ?? search(image, detection: detection, x0: right + 0.1 * cell, y0: upper - 0.8 * cell,
                      x1: right + columnWidth * cell, y1: upper + 2 * cell, top: true)
        let bottom = search(image, detection: detection, x0: left + 3.6 * cell, y0: lower + 0.03 * cell,
                            x1: right, y1: lower + barDepth * cell, top: false)
            ?? search(image, detection: detection, x0: right + 0.1 * cell, y0: lower - 2 * cell,
                      x1: right + columnWidth * cell, y1: lower + 0.8 * cell, top: false)
        switch (top, bottom) {
        case (let clock?, nil): return clock
        case (nil, let clock?): return clock
        default: return nil
        }
    }

    /// Luminance samples of one bar.
    struct Plane {
        var width: Int
        var height: Int
        var originX: Double
        var originY: Double
        var step: Double
        var luminance: [Float]
        /// False where the sample lies outside the image.
        var inside: [Bool]

        /// The image, for luminance just outside the searched bar.
        var image: RGBAImage

        /// Luminance of the image at sample coordinates that may lie outside the bar.
        func sample(_ x: Int, _ y: Int) -> Float? {
            let px = Int(originX + (Double(x) + 0.5) * step), py = Int(originY + (Double(y) + 0.5) * step)
            guard px >= 0, py >= 0, px < image.width, py < image.height else { return nil }
            let p = (py * image.width + px) * 4
            return image.data.withUnsafeBufferPointer { d in
                0.299 * Float(d[p]) + 0.587 * Float(d[p + 1]) + 0.114 * Float(d[p + 2])
            }
        }

        func at(_ x: Int, _ y: Int) -> Float? {
            guard x >= 0, y >= 0, x < width, y < height, inside[y * width + x] else { return nil }
            return luminance[y * width + x]
        }
    }

    /// Searches one image region (clipped to the image) for the icon.
    static func search(_ image: RGBAImage, detection: BoardDetection, x0: Double, y0: Double, x1: Double, y1: Double,
                       top: Bool) -> RunningClock? {
        let cell = detection.cellSize
        let step = max(1, cell / samplesPerCell)
        let x0 = max(0, x0), x1 = min(Double(image.width), x1)
        let y0 = max(0, y0), y1 = min(Double(image.height), y1)
        let width = Int((x1 - x0) / step), height = Int((y1 - y0) / step)
        guard width >= 40, height >= 20 else { return nil }
        var plane = Plane(width: width, height: height, originX: x0, originY: y0, step: step,
                          luminance: [Float](repeating: 0, count: width * height),
                          inside: [Bool](repeating: false, count: width * height), image: image)
        image.data.withUnsafeBufferPointer { d in
            for gy in 0..<height {
                let py = Int(y0 + (Double(gy) + 0.5) * step)
                guard py >= 0, py < image.height else { continue }
                for gx in 0..<width {
                    let px = Int(x0 + (Double(gx) + 0.5) * step)
                    guard px >= 0, px < image.width else { continue }
                    let p = (py * image.width + px) * 4
                    plane.luminance[gy * width + gx] = 0.299 * Float(d[p]) + 0.587 * Float(d[p + 1]) + 0.114 * Float(d[p + 2])
                    plane.inside[gy * width + gx] = true
                }
            }
        }
        let local = localMean(plane, radius: Int(0.18 * samplesPerCell))
        var best: (clock: RunningClock, score: Double)?
        for bright in [true, false] {
            var mask = [Bool](repeating: false, count: width * height)
            for i in 0..<mask.count where plane.inside[i] {
                let difference = plane.luminance[i] - local[i]
                mask[i] = bright ? difference > inkContrast : difference < -inkContrast
            }
            let components = self.components(mask, width: width, height: height)
            for component in components {
                guard let (score, cx, cy, r) = ringScore(component, components: components, mask: mask, plane: plane) else { continue }
                let clock = RunningClock(isTop: top, centerX: x0 + (cx + 0.5) * step, centerY: y0 + (cy + 0.5) * step,
                                         radius: r * step)
                if best == nil || score > best!.score { best = (clock, score) }
            }
        }
        return best?.clock
    }

    /// Farthest a box edge may be from the icon's center, in ring radii (measured: about 1.9 to 2.6).
    static let boxPadding = 3.5
    /// Luminance step between the box and the bar behind it (an Android running box: 10).
    static let boxEdgeContrast: Float = 6

    /// Luminance difference from the local mean that counts as ink.
    static let inkContrast: Float = 40

    struct Component {
        var minX: Int, maxX: Int, minY: Int, maxY: Int
        var count: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    static func components(_ mask: [Bool], width: Int, height: Int) -> [Component] {
        var label = [Bool](repeating: false, count: mask.count)
        var result: [Component] = []
        var stack: [Int] = []
        for start in 0..<mask.count where mask[start] && !label[start] {
            label[start] = true
            stack.append(start)
            var c = Component(minX: width, maxX: -1, minY: height, maxY: -1, count: 0)
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                c.count += 1
                c.minX = min(c.minX, x); c.maxX = max(c.maxX, x); c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let n = ny * width + nx
                        if mask[n] && !label[n] {
                            label[n] = true
                            stack.append(n)
                        }
                    }
                }
            }
            result.append(c)
        }
        return result
    }

    /// Whether a component is a clock icon in a box; returns a score and the ring's center and
    /// radius in samples.
    static func ringScore(_ c: Component, components: [Component], mask: [Bool], plane: Plane) -> (Double, Double, Double, Double)? {
        let diameter = Double(max(c.width, c.height))
        guard diameter >= 0.14 * samplesPerCell, diameter <= 0.60 * samplesPerCell,
              Double(min(c.width, c.height)) >= 0.8 * diameter else { return nil }
        let cx = Double(c.minX + c.maxX) / 2, cy = Double(c.minY + c.maxY) / 2
        let r = diameter / 2
        func ink(_ x: Double, _ y: Double) -> Bool {
            let ix = Int(x.rounded()), iy = Int(y.rounded())
            guard ix >= 0, iy >= 0, ix < plane.width, iy < plane.height else { return false }
            return mask[iy * plane.width + ix]
        }
        // A glyph inside the box: ink with the box color again within half a radius beyond it.
        var boxColorGuess: Float = 0
        func inkInside(_ x: Int, _ y: Int) -> Bool {
            let reach = max(2, Int(0.8 * r))
            return (1...reach).contains { k in
                guard let v = plane.at(x - k, y) else { return false }
                return abs(v - boxColorGuess) <= boxEdgeContrast && !mask[y * plane.width + x - k]
            }
        }
        let directions = 24
        var closed = 0, between = 0
        var boxSamples: [Float] = []
        for k in 0..<directions {
            let angle = Double(k) / Double(directions) * 2 * .pi
            let (dx, dy) = (cos(angle), sin(angle))
            if [0.72, 0.82, 0.92, 1.0].contains(where: { ink(cx + dx * r * $0, cy + dy * r * $0) }) { closed += 1 }
            if ink(cx + dx * r * 0.52, cy + dy * r * 0.52) { between += 1 }
            for factor in [1.3, 1.5] {
                if let value = plane.at(Int((cx + dx * r * factor).rounded()), Int((cy + dy * r * factor).rounded())) {
                    boxSamples.append(value)
                }
            }
        }
        guard closed >= 21, between <= 7 else { return nil }
        // The hands: ink near the center.
        var hands = 0
        for (fx, fy) in [(0.0, 0.0), (0.15, 0), (-0.15, 0), (0, 0.15), (0, -0.15), (0, -0.3), (0.3, 0), (0, 0.3), (-0.3, 0)] {
            if ink(cx + fx * r, cy + fy * r) { hands += 1 }
        }
        guard hands >= 2 else { return nil }
        // A uniform box around the ring, standing out from the bar.
        guard boxSamples.count >= 40 else { return nil }
        let box = median(boxSamples)
        boxColorGuess = box
        let uniform = boxSamples.filter { abs($0 - box) <= 20 }.count
        guard Double(uniform) >= 0.85 * Double(boxSamples.count) else { return nil }
        // The box ends close to the icon on the left, above and below (its padding), where the
        // bar behind it starts; nothing is drawn between the icon and the box's left edge.
        for (dx, dy, limit) in [(-1.0, 0.0, boxPadding), (0.0, -1.0, boxPadding), (0.0, 1.0, boxPadding)] {
            var edge: Double?
            var distance = 1.3 * r
            while distance <= limit * r + 1, edge == nil {
                let x = Int((cx + dx * distance).rounded()), y = Int((cy + dy * distance).rounded())
                guard let value = plane.at(x, y) ?? plane.sample(x, y) else { break }
                if abs(value - box) > boxEdgeContrast {
                    if dx < 0 && plane.at(x, y) != nil && mask[y * plane.width + x] && abs(value - box) > 40 && inkInside(x, y) {
                        return nil
                    }
                    // A sustained change: the next samples also differ from the box.
                    let ahead = (1...3).compactMap { k -> Float? in
                        let ax = Int((cx + dx * (distance + Double(k))).rounded()), ay = Int((cy + dy * (distance + Double(k))).rounded())
                        return plane.at(ax, ay) ?? plane.sample(ax, ay)
                    }
                    if ahead.count == 3 && ahead.allSatisfy({ abs($0 - box) > boxEdgeContrast }) {
                        edge = distance
                    }
                }
                distance += 1
            }
            guard edge != nil else { return nil }
        }
        var ringValues: [Float] = []
        for k in 0..<directions {
            let angle = Double(k) / Double(directions) * 2 * .pi
            for factor in [0.82, 0.92] {
                let x = Int((cx + cos(angle) * r * factor).rounded()), y = Int((cy + sin(angle) * r * factor).rounded())
                if let value = plane.at(x, y), mask[y * plane.width + x] { ringValues.append(value) }
            }
        }
        guard !ringValues.isEmpty, abs(median(ringValues) - box) >= 70 else { return nil }
        // The time to the right: glyphs of about the ring's height, on its line.
        let glyphs = components.filter { g in
            Double(g.minX) >= cx + 1.2 * r && Double(g.minX) <= cx + 14 * r
                && abs(Double(g.minY + g.maxY) / 2 - cy) <= 0.6 * r
                && Double(g.height) >= 0.6 * diameter && Double(g.height) <= 1.7 * diameter
                && Double(g.width) <= 1.5 * diameter
        }
        guard glyphs.count >= 2 else { return nil }
        let score = Double(closed) / Double(directions) + Double(uniform) / Double(boxSamples.count) - Double(between) * 0.05
        return (score, cx, cy, r)
    }

    /// Mean luminance over a square window, from an integral image.
    static func localMean(_ plane: Plane, radius: Int) -> [Float] {
        let w = plane.width, h = plane.height
        var integral = [Double](repeating: 0, count: (w + 1) * (h + 1))
        var counts = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum = 0.0, rowCount = 0.0
            for x in 0..<w {
                if plane.inside[y * w + x] {
                    rowSum += Double(plane.luminance[y * w + x])
                    rowCount += 1
                }
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + rowSum
                counts[(y + 1) * (w + 1) + x + 1] = counts[y * (w + 1) + x + 1] + rowCount
            }
        }
        var result = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let ya = max(0, y - radius), yb = min(h, y + radius + 1)
            for x in 0..<w {
                let xa = max(0, x - radius), xb = min(w, x + radius + 1)
                let sum = integral[yb * (w + 1) + xb] - integral[ya * (w + 1) + xb] - integral[yb * (w + 1) + xa] + integral[ya * (w + 1) + xa]
                let n = counts[yb * (w + 1) + xb] - counts[ya * (w + 1) + xb] - counts[yb * (w + 1) + xa] + counts[ya * (w + 1) + xa]
                result[y * w + x] = Float(sum / max(n, 1))
            }
        }
        return result
    }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
