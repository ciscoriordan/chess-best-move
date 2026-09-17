import ChessCore
import Foundation

/// A cell whose classifier label was changed to make the position possible.
@_spi(Testing)
public struct PieceRepair: Sendable, Hashable {
    /// Display cell index (row * 8 + column).
    public var cell: Int
    /// The classifier's most probable label.
    public var from: Piece?
    /// The label chosen instead.
    public var to: Piece?
    /// Log-probability given up: ln(p(from) / p(to)).
    public var cost: Double
}

/// Turns classifier output into a possible chess position when the most probable labels are
/// not one.
///
/// Every legal position has, for each color: exactly one king, at most 8 pawns, no pawn on
/// either back rank, and no more promoted pieces than missing pawns (a second queen, a third
/// rook or knight, or a second bishop on squares of one color each need a promotion). All four
/// rules hold in display cells whatever the orientation (the back ranks are the top and bottom
/// rows, and square colors do not change when the board is flipped), so the repair runs before
/// orientation is known.
///
/// When the labels break a rule, cells are relabeled greedily: each step takes the change with
/// the smallest log-probability loss per rule violation removed, among labels whose probability
/// is at least `1 / exp(maximumCellCost)` of the cell's best. A confident misreading (a runner-up
/// near zero) is left alone and the position stays impossible, which the recognizer reports.
/// Typical fixes: a queen read as a second king, a king read in the wrong color, a phantom king
/// on an empty square.
@_spi(Testing)
public enum PieceConsistency {
    /// Largest log-probability loss accepted for one cell (runner-up at least 1/20 of the best).
    public static let maximumCellCost = 3.0
    /// Most cells changed on one board.
    public static let maximumRepairs = 8

    /// Number of rule violations of display-cell labels (0 for every legal position).
    public static func violations(_ cells: [Piece?]) -> Int {
        precondition(cells.count == 64)
        var total = 0
        for color in PieceColor.allCases {
            var kings = 0, pawns = 0, queens = 0, rooks = 0, knights = 0, lightBishops = 0, darkBishops = 0
            var backRankPawns = 0
            for (cell, piece) in cells.enumerated() {
                guard let piece, piece.color == color else { continue }
                let row = cell / 8, column = cell % 8
                switch piece.kind {
                case .king: kings += 1
                case .pawn:
                    pawns += 1
                    if row == 0 || row == 7 { backRankPawns += 1 }
                case .queen: queens += 1
                case .rook: rooks += 1
                case .knight: knights += 1
                case .bishop:
                    if (row + column) % 2 == 0 { lightBishops += 1 } else { darkBishops += 1 }
                }
            }
            total += abs(kings - 1) + backRankPawns + max(0, pawns - 8)
            let promoted = max(0, queens - 1) + max(0, rooks - 2) + max(0, knights - 2)
                + max(0, lightBishops - 1) + max(0, darkBishops - 1)
            total += max(0, promoted - max(0, 8 - pawns))
        }
        return total
    }

    /// The labels after repair, their probabilities, and the changes made (empty when the most
    /// probable labels already form a possible position or no affordable change helps).
    public static func repair(_ predictions: [CellPrediction]) -> (pieces: [Piece?], confidences: [Float], repairs: [PieceRepair]) {
        precondition(predictions.count == 64)
        var labels = predictions.map(\.bestClass)
        var pieces = labels.map { PieceClasses.all[$0] }
        var confidences = predictions.map(\.confidence)
        var remaining = violations(pieces)
        guard remaining > 0 else { return (pieces, confidences, []) }

        var repairs: [PieceRepair] = []
        var changed = Set<Int>()
        while remaining > 0 && repairs.count < maximumRepairs {
            var best: (cell: Int, label: Int, cost: Double, violations: Int, rate: Double)?
            for cell in 0..<64 where !changed.contains(cell) {
                let probabilities = predictions[cell].probabilities
                let top = probabilities[labels[cell]]
                guard top > 0 else { continue }
                for label in probabilities.indices where label != labels[cell] {
                    let p = probabilities[label]
                    guard p > 0 else { continue }
                    let cost = Double(log(top / p))
                    guard cost <= maximumCellCost else { continue }
                    let previous = pieces[cell]
                    pieces[cell] = PieceClasses.all[label]
                    let after = violations(pieces)
                    pieces[cell] = previous
                    guard after < remaining else { continue }
                    let rate = cost / Double(remaining - after)
                    if best == nil || rate < best!.rate {
                        best = (cell, label, cost, after, rate)
                    }
                }
            }
            guard let best else { break }
            repairs.append(PieceRepair(cell: best.cell, from: pieces[best.cell], to: PieceClasses.all[best.label], cost: best.cost))
            labels[best.cell] = best.label
            pieces[best.cell] = PieceClasses.all[best.label]
            confidences[best.cell] = predictions[best.cell].probabilities[best.label]
            changed.insert(best.cell)
            remaining = best.violations
        }
        return (pieces, confidences, repairs)
    }
}
