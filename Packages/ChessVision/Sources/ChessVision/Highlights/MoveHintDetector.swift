import ChessCore
import Foundation

/// Finds legal-move dots: the translucent dark disc drawn in the middle of each empty square
/// the selected piece can move to (measured on one large chess site's web board: black at 14%
/// opacity, a third of the square wide). They tell which tinted square is the selected piece.
@_spi(Testing)
public enum MoveHintDetector {
    /// Radius of the sampled center disc, as a fraction of the cell (the dot's is about 0.16).
    static let discRadius = 0.11
    /// Annulus between the dot and the border ring.
    static let annulusInner = 0.24
    static let annulusOuter = 0.32

    /// Display cells showing a dot. `emptyCells`: cells the classifier found empty (a dot on an
    /// occupied square would be hidden by the piece).
    public static func dots(_ image: RGBAImage, detection: BoardDetection, emptyCells: [Bool]) -> [Int] {
        var found: [Int] = []
        for cell in 0..<64 where emptyCells[cell] {
            let x = detection.originX + Double(cell % 8) * detection.cellSize
            let y = detection.originY + Double(cell / 8) * detection.cellSize
            guard let (disc, annulus) = discAndAnnulus(image, x: x, y: y, size: detection.cellSize) else { continue }
            let ring = detection.cellColors[cell]
            // The disc is a uniform darkening of the square's own color...
            let k = disc.dot(annulus) / max(annulus.dot(annulus), 1)
            let change = annulus.distance(to: disc)
            let residual = disc.distance(to: annulus * k)
            // ...and the rest of the square keeps its color.
            guard k >= 0.72, k <= 0.93, change >= 18, residual <= 0.25 * change,
                  annulus.distance(to: ring) <= 0.35 * change else { continue }
            found.append(cell)
        }
        return found
    }

    /// Interquartile-mean colors of the center disc and of an annulus around it.
    static func discAndAnnulus(_ image: RGBAImage, x: Double, y: Double, size: Double) -> (RGB, RGB)? {
        let n = 24
        var disc: [RGB] = [], annulus: [RGB] = []
        let w = image.width, h = image.height
        image.data.withUnsafeBufferPointer { d in
            for j in 0..<n {
                let v = (Double(j) + 0.5) / Double(n) - 0.5
                for i in 0..<n {
                    let u = (Double(i) + 0.5) / Double(n) - 0.5
                    let r = (u * u + v * v).squareRoot()
                    let isDisc = r <= discRadius
                    let isAnnulus = r >= annulusInner && r <= annulusOuter
                    guard isDisc || isAnnulus else { continue }
                    let px = Int(x + (u + 0.5) * size), py = Int(y + (v + 0.5) * size)
                    guard px >= 0, py >= 0, px < w, py < h else { continue }
                    let p = (py * w + px) * 4
                    let color = RGB(Double(d[p]), Double(d[p + 1]), Double(d[p + 2]))
                    if isDisc { disc.append(color) } else { annulus.append(color) }
                }
            }
        }
        guard disc.count >= 12, annulus.count >= 30,
              let discColor = RGB.median(disc), let annulusColor = RGB.median(annulus) else { return nil }
        return (discColor, annulusColor)
    }
}
