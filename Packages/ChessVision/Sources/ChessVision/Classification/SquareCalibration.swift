import Foundation

/// Calibrated square probabilities for confidence reporting.
///
/// The classifier is trained with label smoothing, so its softmax tops out near 0.95 on squares it
/// reads correctly and misreads mostly score 0.5 to 0.93: a plain 0.5 cutoff almost never fires.
/// Temperature scaling (softmax of logits / T, fitted on held-out squares) spreads the scale so
/// that a fixed cutoff separates reliable squares from doubtful ones. Only reported confidences
/// use it; the consistency repair keeps the model's own probabilities.
@_spi(Testing)
public enum SquareCalibration {
    /// Probabilities of `prediction` at temperature `temperature`. The model's softmax
    /// probabilities stand in for logits: log p differs from the logits by a constant per cell.
    public static func probabilities(_ prediction: CellPrediction, temperature: Double) -> [Double] {
        let t = max(temperature, 1e-3)
        let z = prediction.probabilities.map { log(max(Double($0), 1e-30)) / t }
        let top = z.max() ?? 0
        let e = z.map { exp($0 - top) }
        let total = e.reduce(0, +)
        return e.map { $0 / total }
    }

    /// Calibrated probability of `label` (a `PieceClasses` index) for each cell.
    public static func confidences(_ predictions: [CellPrediction], labels: [Int], temperature: Double) -> [Float] {
        precondition(predictions.count == labels.count)
        return zip(predictions, labels).map { prediction, label in
            Float(probabilities(prediction, temperature: temperature)[label])
        }
    }
}
