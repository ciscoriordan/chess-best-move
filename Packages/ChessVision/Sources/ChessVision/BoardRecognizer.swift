import ChessCore
import CoreGraphics
import Foundation

/// Recognizes a chess position from a screenshot: board detection, piece classification,
/// orientation, last-move highlight and side to move.
public final class BoardRecognizer: Sendable {
    /// A board whose verification score is below this is reported as low confidence.
    public static let confidentBoardScore: Float = 0.5
    /// A square whose calibrated probability (`RecognitionResult.squareConfidences`, see
    /// `SquareCalibration`) is below this is reported as low confidence.
    public static let confidentSquareProbability: Float = BoardReadability.confidentSquareProbability

    /// Glyph-shape log-odds above which coordinate text recognition is skipped.
    static let decisiveGlyphEvidence = 3.0

    private let classifier: any SquareClassifier
    private let readsCoordinateText: Bool

    /// Loads the compiled Core ML model from the package bundle. Throws
    /// `ModelLoadError.modelNotFound` when `Model/PieceClassifier.mlmodelc` has not been added.
    public convenience init() throws {
        try self.init(classifier: CoreMLSquareClassifier())
    }

    /// Uses a custom classifier (tests, evaluation with ground-truth pieces).
    /// `readsCoordinateText`: run Vision text recognition on coordinate labels.
    @_spi(Testing)
    public init(classifier: any SquareClassifier, readsCoordinateText: Bool = true) {
        self.classifier = classifier
        self.readsCoordinateText = readsCoordinateText
    }

    /// Runs one classification of a blank board, so the first real recognition does not pay the
    /// classifier's one-time costs (compute-unit setup, buffers). `BoardRecognizer.init()` itself
    /// loads the model, so a caller that wants the whole load paid ahead of time creates the
    /// recognizer and calls this. The predictions are discarded; it never looks at an image.
    public func warmUp() throws {
        let side = classifier.inputSize
        _ = try classifier.classify(crops: [Float](repeating: 0, count: 64 * 3 * side * side))
    }

    /// Recognizes the position. Throws `RecognitionError.boardNotFound` when there is no board,
    /// `.invalidImage` when the image cannot be read, and `.lowConfidence(result)` when the
    /// result is complete but doubtful (see `RecognitionError`).
    public func recognize(_ image: CGImage) throws -> RecognitionResult {
        let analysis = try analyze(image)
        if !analysis.result.doubts.isEmpty {
            throw RecognitionError.lowConfidence(analysis.result)
        }
        return analysis.result
    }

    /// Full recognition details, including intermediate stages.
    @_spi(Testing)
    public struct Analysis: Sendable {
        public var result: RecognitionResult
        public var detection: BoardDetection
        /// Classifier output per display cell.
        public var predictions: [CellPrediction]
        /// Pieces per display cell after `PieceConsistency` repair, and their calibrated
        /// probabilities (`BoardReadability.confidences`: 0 for unseen and covered cells).
        public var displayPieces: [Piece?]
        public var displayConfidences: [Float]
        /// Cells relabeled to make the position possible.
        public var repairs: [PieceRepair]
        public var tints: [CellTint]
        /// Tinted display cells, strongest first, and the tint group of each.
        public var tintedCells: [Int]
        public var tintGroups: [Int]
        /// Relative tint distances between the tinted cells.
        public var tintDistances: [[Double]]
        /// Display cells showing a legal-move dot (searched only when three or more cells are tinted).
        public var dotCells: [Int]
        public var coordinateTranscript: String
        /// Where the coordinate labels were found (nil: no labels).
        public var coordinateLayout: CoordinateReader.LabelLayout?
        /// The running-clock icon, read only when no plausible highlight decides the side to move.
        public var runningClock: RunningClock?

        /// Reasons the result is low confidence, as one line each (empty when confident).
        public var doubts: [String] { result.doubts.map(\.description) }
    }

    @_spi(Testing)
    public func analyze(_ image: CGImage) throws -> Analysis {
        let start = Date()
        // Images with a side over 4096 px are analyzed scaled down (bounded memory and lattice search).
        guard let (rgba, scale) = RGBAImage.bounded(cgImage: image) else { throw RecognitionError.invalidImage }
        return try analyze(rgba, source: image, imageScale: scale, start: start)
    }

    /// `imageScale`: pixels of `rgba` per pixel of `source` (1 unless the image was scaled down).
    @_spi(Testing)
    public func analyze(_ rgba: RGBAImage, source: CGImage, imageScale: Double = 1, start: Date = Date()) throws -> Analysis {
        var timings: [String: Double] = [:]
        var mark = start
        func lap(_ name: String) {
            let now = Date()
            timings[name] = now.timeIntervalSince(mark)
            mark = now
        }
        lap("decode")

        guard let detection = BoardDetector.detect(rgba) else { throw RecognitionError.boardNotFound }
        lap("detect")

        let crops = BoardResampler.cellBatch(rgba, x: detection.originX, y: detection.originY,
                                             size: detection.cellSize * 8, cell: classifier.inputSize,
                                             fill: BoardResampler.fillColors(detection, imageWidth: rgba.width, imageHeight: rgba.height))
        lap("crops")
        let predictions = try classifier.classify(crops: crops)
        precondition(predictions.count == 64, "classifier must return 64 predictions")
        lap("classify")
        let (displayPieces, _, repairs) = PieceConsistency.repair(predictions)
        // Calibrated confidences, unseen and covered squares, square size, other boards.
        let readability = BoardReadability.assess(detection, image: rgba, predictions: predictions,
                                                  labels: displayPieces.map { PieceClasses.index(of: $0) },
                                                  temperature: classifier.confidenceTemperature)
        let displayConfidences = readability.confidences
        let modelHighlight: [Float]? = predictions.allSatisfy { $0.highlightProbability != nil }
            ? predictions.map { $0.highlightProbability! } : nil

        let tintAnalysis = HighlightDetector.analyze(detection, image: rgba, modelHighlight: modelHighlight)
        let tintedCells = tintAnalysis.tinted
        let dotCells = tintedCells.count >= 3
            ? MoveHintDetector.dots(rgba, detection: detection, emptyCells: displayPieces.map { $0 == nil }) : []
        lap("highlights")

        // Orientation.
        var evidence = OrientationEvidence()
        let glyphs = CoordinateReader.glyphs(rgba, detection: detection)
        evidence.glyphShapes = CoordinateReader.shapeLogOdds(letters: glyphs.letters, digits: glyphs.digits)
        var transcript = ""
        // Vision text recognition costs about 100 ms, so it runs only when the glyph shapes
        // are inconclusive but glyphs were found.
        if readsCoordinateText && abs(evidence.glyphShapes) < Self.decisiveGlyphEvidence {
            let (text, words) = CoordinateReader.textLogOdds(letters: glyphs.letters, digits: glyphs.digits)
            evidence.textRecognition = text
            transcript = words
        }
        lap("coordinates")
        evidence.piecePlacement = OrientationEstimator.pieceLogOdds(displayPieces: displayPieces)
        evidence.startPosition = OrientationEstimator.startPositionLogOdds(displayPieces: displayPieces)
        evidence.lastMove = OrientationEstimator.lastMoveLogOdds(tintedCells: tintedCells, tintDistances: tintAnalysis.tintDistances,
                                                                 displayPieces: displayPieces, estimates: tintAnalysis.tintEstimates)
            + OrientationEstimator.pawnHintLogOdds(tintedCells: tintedCells, dotCells: dotCells, displayPieces: displayPieces)
        let (whiteAtBottom, orientationConfidence) = OrientationEstimator.decide(evidence)

        let pieces = DisplayGrid.toSquares(displayPieces, whiteAtBottom: whiteAtBottom)
        let confidences = DisplayGrid.toSquares(displayConfidences, whiteAtBottom: whiteAtBottom)
        let dotSquares = dotCells.map { DisplayGrid.square(row: $0 / 8, column: $0 % 8, whiteAtBottom: whiteAtBottom) }
        // The last move is read from the tinted cells and the faint candidates behind them; the
        // orientation evidence above uses the tinted cells alone.
        let candidateSquares = tintAnalysis.candidates.map { DisplayGrid.square(row: $0 / 8, column: $0 % 8, whiteAtBottom: whiteAtBottom) }
        let resolution = LastMoveResolver.resolve(tinted: candidateSquares, tintDistances: tintAnalysis.candidateDistances,
                                                  board: pieces, dots: dotSquares, estimates: tintAnalysis.candidateEstimates,
                                                  faint: tintAnalysis.candidateFaint,
                                                  bottomColor: whiteAtBottom ? .white : .black)
        // The running clock is read only when the highlight does not settle the side to move.
        let runningClock = resolution?.isPlausible == true ? nil : RunningClockReader.read(rgba, detection: detection)
        let sideDecision = SideToMoveRule.decide(board: pieces, lastMove: resolution.map(SideToMoveRule.LastMove.init),
                                                 runningClockAtTop: runningClock?.isTop, whiteAtBottom: whiteAtBottom)
        let (side, sideSource) = (sideDecision.side, sideDecision.source)
        // Report the squares the move was read from, plus a selected piece of the side to move.
        // Tints that do not form a move (a premove, a square mark, a lone selection) are left
        // out: they say nothing about the last move.
        var highlighted: [Square] = []
        if let resolution {
            highlighted = resolution.highlighted + (resolution.selected.map { [$0] } ?? [])
        }
        lap("infer")

        let rect = detection.rect.applying(CGAffineTransform(scaleX: 1 / imageScale, y: 1 / imageScale))
        let crop = rect.integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let boardImage = source.cropping(to: crop) else { throw RecognitionError.invalidImage }

        timings["total"] = Date().timeIntervalSince(start)
        var result = RecognitionResult(
            boardRect: rect,
            boardImage: boardImage,
            whiteAtBottom: whiteAtBottom,
            orientationConfidence: orientationConfidence,
            pieces: pieces,
            squareConfidences: confidences,
            highlightedSquares: highlighted,
            lastMove: resolution.map { ($0.from, $0.to) },
            suggestedSideToMove: side,
            sideToMoveSource: sideSource,
            boardScore: Float(detection.score),
            orientationEvidence: evidence,
            timings: timings
        )

        var doubts: [RecognitionDoubt] = []
        if Float(detection.score) < Self.confidentBoardScore {
            doubts.append(.weakBoard(score: Float(detection.score)))
        }
        doubts += readability.doubts(whiteAtBottom: whiteAtBottom, sourceScale: 1 / imageScale)
        let hiddenSquares = Set(readability.hiddenCells.map { DisplayGrid.square(row: $0 / 8, column: $0 % 8, whiteAtBottom: whiteAtBottom).index })
        let unsure = (0..<64).filter { confidences[$0] < Self.confidentSquareProbability && !hiddenSquares.contains($0) }
        if !unsure.isEmpty {
            doubts.append(.uncertainSquares(unsure.map { Square(index: $0)! }))
        }
        let issues = result.position().validate().filter {
            switch $0 {
            case .missingKing, .extraKings, .pawnOnBackRank, .tooManyPieces: return true
            case .sideNotToMoveInCheck, .noLegalMoves: return false
            }
        }
        if !issues.isEmpty {
            doubts.append(.impossiblePosition(reason: issues.map(\.description).joined(separator: "; ")))
        } else if PieceConsistency.violations(displayPieces) > 0 {
            doubts.append(.impossiblePosition(reason: "more promoted pieces than missing pawns"))
        }
        if let orientationDoubt = OrientationEstimator.doubt(evidence, displayPieces: displayPieces) {
            doubts.append(.orientation(reason: orientationDoubt))
        }
        doubts += sideDecision.doubts.map { .sideToMove(reason: $0) }
        // Tinted squares in more than one color that read as no move at all. Something is drawn
        // on the board, the recognizer cannot say what, and it reports no last move: if one of
        // those tints is the move, the position goes to the engine with the wrong side to move
        // and without the en passant square. One tint color is a different matter and is left
        // alone: a lone selection, a pair of marks or two squares the user colored by hand are
        // drawn in one color, they are what most boards with unread tints carry, and they say
        // nothing about a move. Measured over the 3,776 evaluated images (2026-09-18), 18 boards
        // carry two or more tinted squares and report no move without a doubt; the 6 whose
        // reading is wrong are the ones this is for, and taking only the boards whose tints fall
        // in several colors catches 4 of those 6 while flagging 1 correct board (real_047).
        //
        // That one board would be free to keep quiet about: its second tint is a plain darkening,
        // and counting only cells the shade test calls colored would flag the same 4 and cost
        // nothing. It is not worth it, because the shade test is the measurement this doubt
        // cannot rely on: what hid sealed_016's move is a vignette darkening that the test does
        // not recognize on a textured board (see HighlightDetector.shadeMinimumStrength), so a
        // rule resting on it would let the next board of that kind through in silence.
        if resolution == nil, Set(tintAnalysis.groups).count >= 2, pieces != Position.start.board {
            doubts.append(.unreadableHighlight(tintedCells.map {
                DisplayGrid.square(row: $0 / 8, column: $0 % 8, whiteAtBottom: whiteAtBottom)
            }))
        }
        if !repairs.isEmpty {
            let squares = repairs.map { DisplayGrid.square(row: $0.cell / 8, column: $0.cell % 8, whiteAtBottom: whiteAtBottom) }
            doubts.append(.relabeledSquares(squares, detail: zip(squares, repairs).map { square, repair in
                "\(square.algebraic) \(repair.from.map { String($0.fenCharacter) } ?? "-")->\(repair.to.map { String($0.fenCharacter) } ?? "-")"
            }.joined(separator: " ")))
        }
        result.doubts = doubts
        return Analysis(result: result, detection: detection, predictions: predictions, displayPieces: displayPieces,
                        displayConfidences: displayConfidences, repairs: repairs, tints: tintAnalysis.cells,
                        tintedCells: tintedCells, tintGroups: tintAnalysis.groups, tintDistances: tintAnalysis.tintDistances, dotCells: dotCells, coordinateTranscript: transcript,
                        coordinateLayout: glyphs.layout, runningClock: runningClock)
    }
}
