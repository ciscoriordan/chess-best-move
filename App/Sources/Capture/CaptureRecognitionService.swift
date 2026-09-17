import ChessCore
import ChessVision
import CoreGraphics
import Foundation
import os

/// The part of ChessVision's `BoardRecognizer` that Capture uses. Tests substitute a fake.
protocol CaptureBoardRecognizing: Sendable {
    func recognize(_ image: CGImage) throws -> RecognitionResult
    /// Pays the classifier's one-time costs ahead of the first import
    /// (`BoardRecognizer.warmUp()`). Test doubles need not do anything.
    func warmUp() throws
}

extension CaptureBoardRecognizing {
    func warmUp() throws {}
}

extension BoardRecognizer: CaptureBoardRecognizing {}

/// Why an image did not produce a board. `BoardNotFoundView` reads it to explain the failure.
enum CaptureRecognitionFailure: Sendable, Hashable {
    /// No chessboard in the image.
    case boardNotFound
    /// The image could not be read or is too small.
    case invalidImage
    /// The recognizer could not be created (for example the Core ML model is missing from
    /// the build). The associated text is the technical reason, for logs.
    case recognizerUnavailable(String)
}

/// Capture's `RecognitionService`: runs ChessVision's `BoardRecognizer` on a serial
/// background queue, never on the main actor.
///
/// - The recognizer is created lazily on first use, on the same queue, and reused. Creating
///   it loads the Core ML model, which is slow (seconds on a device the first time).
/// - `warmUp()` (called shortly after launch) creates it ahead of time on that queue at utility
///   priority and runs one classification of a blank board (`BoardRecognizer.warmUp()`), so the
///   first real import finds the model loaded and its compute units set up. A recognition started
///   meanwhile is queued behind the warm-up (its higher priority raises the queue's) and reuses
///   the recognizer instead of loading it twice.
/// - If creating it throws (the model is missing), recognition reports `.invalidImage` and
///   remembers `CaptureRecognitionFailure.recognizerUnavailable`, which the Board not found
///   screen explains. The next recognition tries to create the recognizer again.
/// - Mapping (`outcome(for:recognizer:)`): a result whose position passes
///   `Position.validate()` (ignoring `noLegalMoves`, which Analysis shows as checkmate or
///   stalemate) is `.confident`; a result with blocking issues, or a low-confidence result,
///   is `.needsCheck` with the uncertain squares marked; no board is `.boardNotFound`;
///   anything else is `.invalidImage`.
/// - A board that runs past the screenshot's edge far enough that a square is less than 55%
///   visible (`CaptureBoardCoverage`) is never `.confident`: those squares are marked, because
///   the recognizer cannot know what stood on them. ChessVision applies the same rule (and also
///   to transparent and covered squares); the app repeats the geometric part so the rule holds
///   whatever the recognizer reports.
final class CaptureRecognitionService: RecognitionService {
    typealias RecognizerFactory = @Sendable () throws -> any CaptureBoardRecognizing

    /// Images smaller than this on either side cannot hold a readable board.
    static let minimumImageSide = 64
    /// How many failures are remembered for the Board not found screen.
    static let rememberedFailures = 8

    private struct State: Sendable {
        var recognizer: (any CaptureBoardRecognizing)?
        var loadAttempts = 0
        var isWarm = false
        var failures: [UUID: CaptureRecognitionFailure] = [:]
        var failureOrder: [UUID] = []
    }

    private let makeRecognizer: RecognizerFactory
    private let queue = DispatchQueue(label: "com.motomatic.chessbestmove.capture.recognition", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(makeRecognizer: @escaping RecognizerFactory = { try BoardRecognizer() }) {
        self.makeRecognizer = makeRecognizer
    }

    func recognize(_ image: ImportedImage) async -> RecognitionOutcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.recognizeOnQueue(image))
            }
        }
    }

    /// Loads the recognizer and runs one classification, off the main actor at utility priority
    /// (`RecognitionService.warmUp()`). Does nothing when its task is cancelled before the queue
    /// reaches it, or when a warm-up already succeeded.
    func warmUp() async {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async(qos: .utility, flags: .enforceQoS) {
                    if !cancelled.withLock({ $0 }) {
                        self.warmUpOnQueue()
                    }
                    continuation.resume()
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Whether a warm-up loaded the recognizer and ran it.
    var isWarm: Bool {
        state.withLock { $0.isWarm }
    }

    /// The reason recognition of `imageID` failed, if it did.
    func failure(for imageID: UUID) -> CaptureRecognitionFailure? {
        state.withLock { $0.failures[imageID] }
    }

    /// How many times the recognizer was created (or creation was attempted).
    var recognizerLoadAttempts: Int {
        state.withLock { $0.loadAttempts }
    }

    // MARK: - Work on the recognition queue

    private func recognizeOnQueue(_ image: ImportedImage) -> RecognitionOutcome {
        let recognizer: any CaptureBoardRecognizing
        switch loadRecognizer() {
        case .success(let loaded):
            recognizer = loaded
        case .failure(let reason):
            record(.recognizerUnavailable(reason), for: image.id)
            return .invalidImage
        }
        let (outcome, failure) = Self.outcome(for: image, recognizer: recognizer)
        if let failure { record(failure, for: image.id) }
        return outcome
    }

    private func warmUpOnQueue() {
        guard !state.withLock({ $0.isWarm }) else { return }
        guard case .success(let recognizer) = loadRecognizer() else { return }
        // Loading the model is most of the cost, but the first prediction also pays for the
        // compute-unit setup and the buffers, so the warm-up runs one classification.
        try? recognizer.warmUp()
        state.withLock { $0.isWarm = true }
    }

    private enum LoadResult {
        case success(any CaptureBoardRecognizing)
        case failure(String)
    }

    private func loadRecognizer() -> LoadResult {
        if let cached = state.withLock({ $0.recognizer }) {
            return .success(cached)
        }
        state.withLock { $0.loadAttempts += 1 }
        do {
            let recognizer = try makeRecognizer()
            state.withLock { $0.recognizer = recognizer }
            return .success(recognizer)
        } catch {
            return .failure(String(describing: error))
        }
    }

    private func record(_ failure: CaptureRecognitionFailure, for id: UUID) {
        state.withLock { state in
            if state.failures.updateValue(failure, forKey: id) == nil {
                state.failureOrder.append(id)
            }
            while state.failureOrder.count > Self.rememberedFailures {
                state.failures[state.failureOrder.removeFirst()] = nil
            }
        }
    }

    // MARK: - Mapping (pure)

    /// Runs `recognizer` on `image` and maps the result to the outcome the app routes on.
    static func outcome(
        for image: ImportedImage,
        recognizer: any CaptureBoardRecognizing
    ) -> (RecognitionOutcome, CaptureRecognitionFailure?) {
        guard image.image.width >= minimumImageSide, image.image.height >= minimumImageSide else {
            return (.invalidImage, .invalidImage)
        }
        do {
            let result = try recognizer.recognize(image.image)
            let snapshot = snapshot(from: result, image: image)
            // Squares cut off by the screenshot's edge were never seen, whatever the recognizer's
            // confidence: the user checks them.
            let cutOff = CaptureBoardCoverage.cutOffSquares(
                boardRect: result.boardRect,
                imageWidth: image.image.width,
                imageHeight: image.image.height,
                whiteAtBottom: result.whiteAtBottom,
                below: CaptureBoardCoverage.forcedCheckVisibleFraction
            )
            if CapturePositionIssues.blocking(in: snapshot.position).isEmpty, cutOff.isEmpty {
                return (.confident(snapshot), nil)
            }
            return (.needsCheck(snapshot), nil)
        } catch RecognitionError.lowConfidence(let result) {
            return (.needsCheck(snapshot(from: result, image: image)), nil)
        } catch RecognitionError.boardNotFound {
            return (.boardNotFound, .boardNotFound)
        } catch {
            return (.invalidImage, .invalidImage)
        }
    }

    /// ChessVision's reason for doubting a result, in the app's own terms (the contract keeps
    /// ChessVision types out of `BoardSnapshot`). Every case is mapped, so a snapshot's `doubts`
    /// are the whole list the recognizer gave.
    static func boardDoubt(_ doubt: RecognitionDoubt) -> BoardDoubt {
        switch doubt {
        case .squaresOutsideImage(let squares): .squaresOutsideImage(Set(squares))
        case .squaresCovered(let squares): .squaresCovered(Set(squares))
        case .uncertainSquares(let squares): .uncertainSquares(Set(squares))
        case .squaresTooSmall(let cellPixels): .squaresTooSmall(pixelsPerSquare: cellPixels)
        case .severalBoards(let count): .severalBoards(count: count)
        case .invertedSquareColors: .invertedSquareColors
        case .weakBoard: .weakBoardMatch
        case .impossiblePosition, .relabeledSquares: .impossiblePosition
        case .orientation: .orientationUnconfirmed
        case .sideToMove: .sideToMoveUncertain
        }
    }

    /// The snapshot for a recognition result: the position with consistent castling rights
    /// (all of them assumed until the user confirms them), the user's board crop and
    /// orientation (Analysis draws the arrow over the crop), the pieces as recognized, and the
    /// squares to check: those whose classifier probability is below
    /// `BoardRecognizer.confidentSquareProbability`, and those less than 55% inside the
    /// screenshot (`CaptureBoardCoverage.cutOffSquares`). The recognizer's doubts come along as
    /// `BoardDoubt`s, so Check position can say what was wrong (`CaptureCheckPositionSummary`).
    static func snapshot(from result: RecognitionResult, image: ImportedImage) -> BoardSnapshot {
        var position = result.position()
        position.removeInconsistentCastlingRights()
        let origin: SideToMoveOrigin = switch result.sideToMoveSource {
        case .lastMoveHighlight: .lastMoveHighlight
        case .runningClock: .runningClock
        case .checkRule: .checkRule
        case .bottomPlayerDefault: .assumedBottomPlayer
        }
        let confidences = result.squareConfidences
        var uncertain: Set<Square> = confidences.count == 64
            ? Set(Square.all.filter { confidences[$0.index] < BoardRecognizer.confidentSquareProbability })
            : []
        uncertain.formUnion(CaptureBoardCoverage.cutOffSquares(
            boardRect: result.boardRect,
            imageWidth: image.image.width,
            imageHeight: image.image.height,
            whiteAtBottom: result.whiteAtBottom,
            below: CaptureBoardCoverage.forcedCheckVisibleFraction
        ))
        return BoardSnapshot(
            position: position,
            whiteAtBottom: result.whiteAtBottom,
            sideToMoveOrigin: origin,
            sourceImage: image.image,
            boardImage: result.boardImage,
            boardRect: result.boardRect,
            recognizedBoard: position.board,
            squareConfidences: confidences.count == 64 ? confidences : nil,
            lowConfidenceSquares: uncertain,
            lastMove: result.lastMove.map { Move(from: $0.from, to: $0.to) },
            importSource: image.source,
            doubts: result.doubts.map(boardDoubt),
            assumedCastlingRights: position.castlingRights
        )
    }
}

/// How much of each square of a detected board lies inside the screenshot. A board that runs
/// past the image's edge has squares the recognizer never saw: whatever stood there is
/// missing from the recognized position.
enum CaptureBoardCoverage {
    /// A square less than this fraction inside the image makes recognition ask the user to
    /// check it (the recognition service marks it). It matches ChessVision's
    /// `BoardReadability.minimumVisibleFraction`. Measured on the test sets: correctly read
    /// boards run at most 0.12 of a square past the edge, and cut-off boards were still read
    /// correctly up to about 0.4 of a square, while cuts of 0.55 of a square and more dropped
    /// pieces with full confidence (build/round3/vision_findings.json,
    /// cells-outside-image-or-covered-read-as-confident).
    static let forcedCheckVisibleFraction = 0.55

    /// Check position explains a marked square as cut off when less than this fraction of it
    /// is inside the image.
    static let partlyOutsideVisibleFraction = 0.9

    /// The fraction (0...1) of each square inside the image, by `Square.index`.
    static func visibleFractions(boardRect: CGRect, imageWidth: Int, imageHeight: Int, whiteAtBottom: Bool) -> [Double] {
        var fractions = [Double](repeating: 1, count: 64)
        guard boardRect.width > 0, boardRect.height > 0 else { return fractions }
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let cellWidth = boardRect.width / 8
        let cellHeight = boardRect.height / 8
        for row in 0..<8 {
            for column in 0..<8 {
                let cell = CGRect(
                    x: boardRect.minX + CGFloat(column) * cellWidth,
                    y: boardRect.minY + CGFloat(row) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                let inside = cell.intersection(bounds)
                let fraction = inside.isNull ? 0 : Double((inside.width * inside.height) / (cellWidth * cellHeight))
                if let square = BoardGeometry.square(row: row, column: column, whiteAtBottom: whiteAtBottom) {
                    fractions[square.index] = min(max(fraction, 0), 1)
                }
            }
        }
        return fractions
    }

    /// The squares less than `fraction` inside the image.
    static func cutOffSquares(boardRect: CGRect, imageWidth: Int, imageHeight: Int, whiteAtBottom: Bool, below fraction: Double) -> Set<Square> {
        let fractions = visibleFractions(boardRect: boardRect, imageWidth: imageWidth, imageHeight: imageHeight, whiteAtBottom: whiteAtBottom)
        return Set(Square.all.filter { fractions[$0.index] < fraction })
    }

    /// The squares of `snapshot` (in its current orientation) less than `fraction` inside its
    /// screenshot; empty for a board without a screenshot.
    static func cutOffSquares(in snapshot: BoardSnapshot, below fraction: Double) -> Set<Square> {
        guard let rect = snapshot.boardRect, let image = snapshot.sourceImage else { return [] }
        return cutOffSquares(
            boardRect: rect,
            imageWidth: image.width,
            imageHeight: image.height,
            whiteAtBottom: snapshot.whiteAtBottom,
            below: fraction
        )
    }
}
