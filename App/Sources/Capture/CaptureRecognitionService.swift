import ChessCore
import ChessVision
import CoreGraphics
import Foundation
import UIKit
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
///   the recognizer instead of loading it twice. An import that beat the warm-up to it and read a
///   board has already paid both costs, so the warm-up then does nothing: it classifies a blank
///   board only when no recognition has run the classifier yet (an import that found no board
///   loaded the model without ever classifying, and the warm-up still has work to do).
/// - A memory warning releases the recognizer (`releaseRecognizerUnderMemoryPressure()`), which
///   releases the Core ML model with it. The next import loads it again on the queue, and a later
///   warm-up may run again.
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
        var memoryWarningReleases = 0
    }

    private let makeRecognizer: RecognizerFactory
    private let queue = DispatchQueue(label: "com.motomatic.chessbestmove.capture.recognition", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = Logger(subsystem: "com.motomatic.chessbestmove", category: "recognition")
    /// The memory-warning observer: written once in `init`, read once in `deinit`.
    private nonisolated(unsafe) var memoryWarningObserver: (any NSObjectProtocol)?

    init(
        makeRecognizer: @escaping RecognizerFactory = { try BoardRecognizer() },
        observesMemoryWarnings: Bool = true
    ) {
        self.makeRecognizer = makeRecognizer
        guard observesMemoryWarnings else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.releaseRecognizerUnderMemoryPressure()
        }
        memoryWarningObserver = observer
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// Drops the recognizer and the Core ML model it holds, on a memory warning. Safe at any
    /// time: a recognition already running holds its own reference and finishes, and the next
    /// one loads the model again (`loadRecognizer`). The service is cold afterwards, so a later
    /// warm-up pays the first classification again.
    func releaseRecognizerUnderMemoryPressure() {
        let released: Bool = state.withLock { state in
            let had = state.recognizer != nil
            state.recognizer = nil
            state.isWarm = false
            if had { state.memoryWarningReleases += 1 }
            return had
        }
        if released { log.notice("memory warning: released the recognition model") }
    }

    /// How many times a memory warning released a loaded recognizer.
    var memoryWarningReleases: Int {
        state.withLock { $0.memoryWarningReleases }
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
        switch outcome {
        case .confident, .needsCheck:
            // This image went through the classifier, which is what the warm-up pays for: a
            // warm-up that has not run yet has nothing left to do.
            state.withLock { $0.isWarm = true }
        case .boardNotFound, .invalidImage:
            // No board, so nothing was classified (`BoardRecognizer.analyze` gives up first):
            // the warm-up still has its first prediction to make.
            break
        }
        return outcome
    }

    private func warmUpOnQueue() {
        guard !state.withLock({ $0.isWarm }) else { return }
        let loadStart = ContinuousClock.now
        guard case .success(let recognizer) = loadRecognizer() else { return }
        let loaded = ContinuousClock.now
        // Loading the model is most of the cost, but the first prediction also pays for the
        // compute-unit setup and the buffers, so the warm-up runs one classification.
        do {
            try recognizer.warmUp()
        } catch {
            // A classification that threw warmed nothing up: stay cold so a later warm-up, or
            // the first import, tries again.
            log.error("warm-up classification failed: \(String(describing: error), privacy: .public)")
            return
        }
        let classified = ContinuousClock.now
        state.withLock { $0.isWarm = true }
        // What the launch warm-up costs, on every build, so the figure in App/APP_CONTRACT.md can
        // be measured again on any device: the model load and the first classification.
        func milliseconds(_ duration: Duration) -> Int { Int((duration / .milliseconds(1)).rounded()) }
        log.notice("""
            warm-up: model load \(milliseconds(loaded - loadStart), privacy: .public) ms, \
            first classification \(milliseconds(classified - loaded), privacy: .public) ms
            """)
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
            // A recognizer that reported a doubt without throwing is still doubtful: the user
            // checks the board, and nothing is spent until they do (owner decision of
            // 2026-09-17 on the side to move and on unfamiliar board styles).
            if CapturePositionIssues.blocking(in: snapshot.position).isEmpty, cutOff.isEmpty,
               snapshot.doubts.isEmpty {
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
    /// are the whole list the recognizer gave. A doubt this version of the app does not know
    /// becomes `.other`: the board still goes to Check position, without a sentence of its own.
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
        case .unfamiliarBoardArt: .unfamiliarTheme
        @unknown default: .other
        }
    }

    /// A doubt read together with where the side to move came from. ChessVision has one case for
    /// every doubt about the side to move, but the two the user is told apart differ in what is
    /// missing rather than in the doubt itself: with the side taken from the player at the bottom
    /// (`bottomPlayerDefault`) there was neither a last-move highlight nor a clock to read, while
    /// the other origins doubt evidence that exists. Check position says which
    /// (`CaptureCheckPositionSummary.chipNote`, owner decision of 2026-09-17).
    static func doubt(_ doubt: BoardDoubt, sideToMoveOrigin: SideToMoveOrigin) -> BoardDoubt {
        guard doubt == .sideToMoveUncertain, sideToMoveOrigin == .assumedBottomPlayer else { return doubt }
        return .sideToMoveNotEstablished
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
        case .startPosition: .startPosition
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
            doubts: result.doubts.map { doubt(boardDoubt($0), sideToMoveOrigin: origin) },
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
    /// is inside the image. It rests on the same measurement as `forcedCheckVisibleFraction`,
    /// one step more cautious: boards cut by up to 0.4 of a square (0.6 visible) were still read
    /// correctly, so a cut smaller than that does not explain a doubtful square and the marks
    /// have another cause. At 0.9 the screen blamed the edge for squares that are 88% visible,
    /// which happens on real screenshots (one of the 152 in the real test set cuts its h-file by
    /// 0.12 of a square), and the sentence that named the real cause was dropped.
    static let partlyOutsideVisibleFraction = 0.6

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
