import ChessCore
import CoreML
import Foundation

/// Classifier output for one display cell.
@_spi(Testing)
public struct CellPrediction: Sendable, Hashable {
    /// Softmax probabilities in the model's class order (`PieceClasses.all`).
    public var probabilities: [Float]
    /// Sigmoid of the model's `highlight` logit, when the model has that output.
    public var highlightProbability: Float?

    public init(probabilities: [Float], highlightProbability: Float? = nil) {
        self.probabilities = probabilities
        self.highlightProbability = highlightProbability
    }

    public var bestClass: Int {
        var best = 0
        for i in 1..<probabilities.count where probabilities[i] > probabilities[best] { best = i }
        return best
    }

    public var piece: Piece? { PieceClasses.all[bestClass] }
    public var confidence: Float { probabilities[bestClass] }

    /// Probability that the cell holds a piece of `color`.
    public func probability(of color: PieceColor) -> Float {
        color == .white ? probabilities[1...6].reduce(0, +) : probabilities[7...12].reduce(0, +)
    }

    /// A one-hot prediction (used by tests and the ground-truth evaluation mode).
    public static func certain(_ piece: Piece?) -> CellPrediction {
        var p = [Float](repeating: 0, count: 13)
        p[PieceClasses.index(of: piece)] = 1
        return CellPrediction(probabilities: p)
    }
}

/// The model's class order: empty, wP, wN, wB, wR, wQ, wK, bP, bN, bB, bR, bQ, bK.
@_spi(Testing)
public enum PieceClasses {
    public static let all: [Piece?] = [nil]
        + [PieceKind.pawn, .knight, .bishop, .rook, .queen, .king].map { Piece(color: .white, kind: $0) }
        + [PieceKind.pawn, .knight, .bishop, .rook, .queen, .king].map { Piece(color: .black, kind: $0) }

    public static func index(of piece: Piece?) -> Int {
        all.firstIndex(of: piece)!
    }
}

/// Classifies the 64 cells of a detected board.
@_spi(Testing)
public protocol SquareClassifier: Sendable {
    /// Edge length of each crop fed to `classify`.
    var inputSize: Int { get }
    /// Temperature that turns the returned probabilities into calibrated ones for confidence
    /// reporting (`SquareCalibration`); 1 leaves them as returned.
    var confidenceTemperature: Double { get }
    /// `crops`: planar Float32 RGB in 0...1, shape [N, 3, inputSize, inputSize], display cells
    /// row-major from the top-left (N is 64 for a board). Returns N predictions in the same order.
    func classify(crops: [Float]) throws -> [CellPrediction]
}

extension SquareClassifier {
    public var confidenceTemperature: Double { 1 }
}

/// The Core ML piece classifier described in docs/ARCHITECTURE.md.
///
/// The model's `squares` input may take a flexible batch (N in 1...64, the 1.0.0 model) or a
/// fixed one (exactly [64, 3, 64, 64], which loads fastest on the Neural Engine). Crops are sent
/// in batches the model accepts, padded with zeros when a batch has fewer crops. `logits` may be
/// shaped [B, 13] or [1, 1, B, 13], and `highlight` [B, 1] or [1, 1, B, 1].
@_spi(Testing)
public final class CoreMLSquareClassifier: SquareClassifier, @unchecked Sendable {
    // MLModel predictions are thread-safe; the class is immutable after init.
    private let model: MLModel
    private let hasHighlight: Bool
    public let inputSize: Int
    /// Batch sizes the model accepts, ascending.
    public let batchSizes: [Int]
    public let confidenceTemperature: Double

    static let inputName = "squares"
    static let logitsName = "logits"
    static let highlightName = "highlight"
    static let classCount = 13
    /// Model metadata key (user-defined) holding the calibration temperature, fitted by
    /// minimizing the negative log-likelihood of held-out square labels.
    public static let temperatureMetadataKey = "calibration_temperature"
    /// Temperature used when the model's metadata has none: fitted for model 1.0.0 (trained with
    /// label smoothing 0.05) on the rendered and stress screenshots
    /// (`Scripts/fit_square_calibration.py`).
    ///
    /// The shipped model 1.1.0 was exported before `training/export_coreml.py` wrote the
    /// metadata key, so it uses this value. Fitting its own temperature on 40,000 held-out crops
    /// gives 0.559 (`val_id`) and 0.537 (`val_holdout`), and running the whole evaluation at 0.56
    /// flags 8 more correctly read boards of 3,364 while catching no misread the pair (0.39,
    /// `confidentSquareProbability` 0.97) misses, so the pair stays as it was tuned
    /// (`build/round3/calibration-1.1.0.json`, `build/round3/after.json`). A model exported from
    /// now on carries its own temperature, and the threshold should be re-checked against it.
    public static let defaultTemperature = 0.39

    /// The compiled model in the package bundle, or nil when it has not been added yet.
    public static var bundledModelURL: URL? {
        Bundle.module.url(forResource: "PieceClassifier", withExtension: "mlmodelc", subdirectory: "Model")
            ?? Bundle.module.url(forResource: "PieceClassifier", withExtension: "mlmodelc")
    }

    public convenience init() throws {
        guard let url = Self.bundledModelURL else { throw ModelLoadError.modelNotFound }
        try self.init(modelURL: url)
    }

    public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw ModelLoadError.modelNotFound }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let description = model.modelDescription
        guard let input = description.inputDescriptionsByName[Self.inputName],
              input.type == .multiArray, let constraint = input.multiArrayConstraint else {
            throw ModelLoadError.incompatibleModel("no multi-array input named \"\(Self.inputName)\"")
        }
        guard description.outputDescriptionsByName[Self.logitsName]?.type == .multiArray else {
            throw ModelLoadError.incompatibleModel("no multi-array output named \"\(Self.logitsName)\"")
        }
        let layout = try Self.inputLayout(constraint)
        self.model = model
        self.hasHighlight = description.outputDescriptionsByName[Self.highlightName]?.type == .multiArray
        self.inputSize = layout.size
        self.batchSizes = layout.batchSizes
        let metadata = description.metadata[.creatorDefinedKey] as? [String: String]
        if let text = metadata?[Self.temperatureMetadataKey], let value = Double(text), value > 0 {
            self.confidenceTemperature = value
        } else {
            self.confidenceTemperature = Self.defaultTemperature
        }
    }

    /// Crop size and accepted batch sizes from the input's shape constraint.
    static func inputLayout(_ constraint: MLMultiArrayConstraint) throws -> (size: Int, batchSizes: [Int]) {
        let shapes: [[Int]]
        var ranged: [Int] = []
        switch constraint.shapeConstraint.type {
        case .enumerated:
            shapes = constraint.shapeConstraint.enumeratedShapes.map { $0.map(\.intValue) }
        case .range:
            let ranges = constraint.shapeConstraint.sizeRangeForDimension.map(\.rangeValue)
            guard ranges.count == 4 else { throw ModelLoadError.incompatibleModel("input must have 4 dimensions") }
            let low = max(1, ranges[0].location)
            let high = ranges[0].length < 0 || ranges[0].length >= 64 ? 64 : min(64, ranges[0].location + ranges[0].length)
            ranged = low <= high ? Array(low...high) : [low]
            shapes = [constraint.shape.map(\.intValue)]
        default:
            shapes = [constraint.shape.map(\.intValue)]
        }
        guard let first = shapes.first, first.count == 4, first[1] == 3, first[2] == first[3], first[2] > 0,
              shapes.allSatisfy({ $0.count == 4 && $0[1...3] == first[1...3] }) else {
            throw ModelLoadError.incompatibleModel("input must be [N, 3, S, S], got \(shapes)")
        }
        let batches = Set(ranged.isEmpty ? shapes.map { $0[0] } : ranged).filter { $0 > 0 }.sorted()
        guard !batches.isEmpty else { throw ModelLoadError.incompatibleModel("input has no usable batch size") }
        return (first[2], batches)
    }

    /// Batch sizes to send `count` crops in: the smallest accepted batch that holds the rest,
    /// otherwise the largest accepted batch, repeatedly.
    static func batchPlan(count: Int, accepted: [Int]) -> [(crops: Int, batch: Int)] {
        var plan: [(Int, Int)] = []
        var remaining = count
        while remaining > 0 {
            if let fitting = accepted.first(where: { $0 >= remaining }) {
                plan.append((remaining, fitting))
                remaining = 0
            } else {
                let largest = accepted.last!
                plan.append((largest, largest))
                remaining -= largest
            }
        }
        return plan
    }

    public func classify(crops: [Float]) throws -> [CellPrediction] {
        let size = inputSize
        let perCrop = 3 * size * size
        precondition(crops.count % perCrop == 0 && !crops.isEmpty, "crops must be [N, 3, \(size), \(size)]")
        var predictions: [CellPrediction] = []
        var offset = 0
        for (count, batch) in Self.batchPlan(count: crops.count / perCrop, accepted: batchSizes) {
            let input = try MLMultiArray(shape: [NSNumber(value: batch), 3, NSNumber(value: size), NSNumber(value: size)],
                                         dataType: .float32)
            let pointer = input.dataPointer.bindMemory(to: Float32.self, capacity: batch * perCrop)
            // A freshly allocated array is contiguous with standard strides; unused slots are zeros.
            pointer.initialize(repeating: 0, count: batch * perCrop)
            crops.withUnsafeBufferPointer { source in
                pointer.update(from: source.baseAddress! + offset, count: count * perCrop)
            }
            offset += count * perCrop
            let provider = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(multiArray: input)])
            let output = try model.prediction(from: provider)
            guard let logits = output.featureValue(for: Self.logitsName)?.multiArrayValue else {
                throw ModelLoadError.incompatibleModel("missing logits output")
            }
            let logitRows = try Self.rows(Self.floats(logits), shape: logits.shape.map(\.intValue), batch: batch,
                                          width: Self.classCount, name: Self.logitsName)
            var highlightRows: [[Float]]?
            if hasHighlight, let highlight = output.featureValue(for: Self.highlightName)?.multiArrayValue {
                highlightRows = try? Self.rows(Self.floats(highlight), shape: highlight.shape.map(\.intValue), batch: batch,
                                               width: 1, name: Self.highlightName)
            }
            for i in 0..<count {
                predictions.append(Self.prediction(logits: logitRows[i], highlightLogit: highlightRows?[i][0]))
            }
        }
        return predictions
    }

    /// Softmax probabilities and the highlight sigmoid of one crop.
    static func prediction(logits row: [Float], highlightLogit: Float?) -> CellPrediction {
        let maxLogit = row.max() ?? 0
        let exps = row.map { exp($0 - maxLogit) }
        let total = exps.reduce(0, +)
        return CellPrediction(probabilities: exps.map { $0 / total }, highlightProbability: highlightLogit.map { 1 / (1 + exp(-$0)) })
    }

    /// Splits an output of `batch` rows of `width` values. Any shape that equals [batch, width]
    /// once dimensions of size 1 are dropped is accepted: [batch, width], [1, 1, batch, width],
    /// [batch, width, 1, 1], and for the highlight [batch] or [1, 1, batch, 1].
    static func rows(_ values: [Float], shape: [Int], batch: Int, width: Int, name: String) throws -> [[Float]] {
        guard shape.filter({ $0 != 1 }) == [batch, width].filter({ $0 != 1 }), values.count == batch * width else {
            throw ModelLoadError.incompatibleModel("\(name) has shape \(shape), expected [\(batch), \(width)] or [1, 1, \(batch), \(width)]")
        }
        return (0..<batch).map { Array(values[($0 * width)..<(($0 + 1) * width)]) }
    }

    /// All values of a multi-array in row-major order, whatever its data type and strides.
    static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        var result = [Float](repeating: 0, count: count)
        var index = [Int](repeating: 0, count: shape.count)
        func offset() -> Int { zip(index, strides).reduce(0) { $0 + $1.0 * $1.1 } }
        for n in 0..<count {
            let o = offset()
            switch array.dataType {
            case .float32:
                result[n] = array.dataPointer.assumingMemoryBound(to: Float32.self)[o]
            case .double:
                result[n] = Float(array.dataPointer.assumingMemoryBound(to: Double.self)[o])
            case .float16:
                result[n] = Self.halfToFloat(array.dataPointer.assumingMemoryBound(to: UInt16.self)[o])
            default:
                result[n] = array[n].floatValue
            }
            var axis = shape.count - 1
            while axis >= 0 {
                index[axis] += 1
                if index[axis] < shape[axis] { break }
                index[axis] = 0
                axis -= 1
            }
        }
        return result
    }

    static func halfToFloat(_ h: UInt16) -> Float {
        let sign: Float = (h & 0x8000) != 0 ? -1 : 1
        let exponent = Int((h >> 10) & 0x1F)
        let mantissa = Float(h & 0x3FF)
        if exponent == 0 { return sign * mantissa * pow(2, -24) }
        if exponent == 31 { return mantissa == 0 ? sign * .infinity : .nan }
        return sign * (1 + mantissa / 1024) * pow(2, Float(exponent - 15))
    }
}
