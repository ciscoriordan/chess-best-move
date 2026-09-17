import ChessCore
import ChessEngine
import Foundation
import Observation

// MARK: - Factory

enum AnalysisFeature {
    @MainActor
    static func makeEngineController() -> any EngineController {
        AnalysisEngineController()
    }
}

// MARK: - Engine controller

/// Wraps `StockfishEngine.shared` for the app (App/APP_CONTRACT.md, "Engine").
///
/// - Validates and sanitizes the position before every search.
/// - Calls `prepare()` lazily, right before the first search of the session.
/// - Consumes the analysis stream on the main actor and publishes the readout at most
///   10 times per second, converted to White's point of view.
/// - A new `start` supersedes the running search; events of the old search are ignored.
/// - `stop()` ends the search early and the stream still delivers the best move so far.
///
/// Scene-phase handling (stopping when the app goes to the background) is done by the
/// Analysis screen, which knows whether the search belongs to the board on screen.
@MainActor
@Observable
final class AnalysisEngineController: EngineController {
    private(set) var phase: EnginePhase = .idle
    private(set) var readout: EngineReadout?
    private(set) var thinkTime: ThinkTime?

    nonisolated var engineVersion: String { StockfishEngine.shared.version }

    /// The sanitized position of the current or last search.
    private(set) var searchedPosition: Position?

    /// Readout publications of the current search, for tests and diagnostics.
    @ObservationIgnored private(set) var publicationTimes: [ContinuousClock.Instant] = []

    @ObservationIgnored private let updateInterval: Duration
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var throttle: AnalysisUpdateThrottle
    @ObservationIgnored private var pendingReadout: EngineReadout?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var isPrepared = false

    init(updateInterval: Duration = .milliseconds(100)) {
        self.updateInterval = updateInterval
        throttle = AnalysisUpdateThrottle(interval: updateInterval)
    }

    func start(_ position: Position, thinkTime: ThinkTime) async -> Bool {
        await start(position, movetime: thinkTime.duration, thinkTime: thinkTime)
    }

    /// Starts a search for `movetime`. `thinkTime` is what `thinkTime` reports (nil for a
    /// custom duration, used by tests).
    func start(_ position: Position, movetime: Duration, thinkTime: ThinkTime?) async -> Bool {
        generation += 1
        let generation = generation
        cancelConsumption()
        stopRequested = false
        publicationTimes = []

        let prepared = AnalysisPositionCheck.sanitized(position)
        let previous = searchedPosition
        searchedPosition = prepared
        self.thinkTime = thinkTime

        let issues = prepared.validate()
        let blocking = issues.filter { $0 != .noLegalMoves }
        guard blocking.isEmpty else {
            readout = nil
            phase = .failed(AnalysisEngineFailure.invalidPosition(blocking.map(\.description).joined(separator: "; ")))
            return false
        }
        if issues.contains(.noLegalMoves) {
            readout = nil
            phase = .noLegalMoves(checkmate: prepared.isCheckmate)
            return false
        }

        // A re-run of the same board keeps the previous result on screen as provisional
        // until the new search has searched at least as deep (see the accumulator).
        let seed = previous == prepared && (phase == .finished || phase == .searching) ? readout : nil
        if seed == nil { readout = nil }

        if !isPrepared {
            phase = .preparing
            do {
                // Lazy: the network loads right before the first analysis, never at launch.
                try await StockfishEngine.shared.prepare()
                isPrepared = true
            } catch {
                guard generation == self.generation else { return false }
                phase = .failed(AnalysisEngineFailure.message(for: error))
                return false
            }
            guard generation == self.generation else { return false }
        }
        phase = .searching

        let milliseconds = max(1, Int((movetime / .milliseconds(1)).rounded()))
        let stream = await StockfishEngine.shared.analyze(fen: prepared.fen, limit: .movetime(milliseconds: milliseconds))
        guard generation == self.generation else { return false }
        if stopRequested {
            await StockfishEngine.shared.stop()
        }

        let startedAt = ContinuousClock.now
        let sideToMove = prepared.sideToMove
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            consumer = Task { [weak self] in
                var didReportStart = false
                var accumulator = AnalysisReadoutAccumulator(sideToMove: sideToMove, seed: seed)
                do {
                    for try await event in stream {
                        guard let self, generation == self.generation else { break }
                        if !didReportStart {
                            didReportStart = true
                            continuation.resume(returning: true)
                        }
                        accumulator.apply(event, elapsed: ContinuousClock.now - startedAt)
                        if accumulator.isFinished {
                            self.publishFinal(accumulator.readout)
                        } else {
                            self.offer(accumulator.readout, generation: generation)
                        }
                    }
                } catch {
                    if let self, generation == self.generation {
                        self.flushTask?.cancel()
                        self.flushTask = nil
                        if case EngineError.noLegalMoves = error {
                            self.readout = nil
                            self.phase = .noLegalMoves(checkmate: prepared.isCheckmate)
                        } else {
                            self.phase = .failed(AnalysisEngineFailure.message(for: error))
                        }
                    }
                }
                if !didReportStart {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func stop() {
        switch phase {
        case .preparing:
            stopRequested = true
        case .searching:
            stopRequested = true
            Task { await StockfishEngine.shared.stop() }
        case .idle, .finished, .noLegalMoves, .failed:
            break
        }
    }

    // MARK: Publishing

    private func offer(_ update: EngineReadout, generation: Int) {
        pendingReadout = update
        let now = ContinuousClock.now
        switch throttle.decision(at: now) {
        case .publishNow:
            publishPending(at: now)
        case .wait(let deadline):
            guard flushTask == nil else { return }
            flushTask = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                self.flushTask = nil
                self.publishPending(at: .now)
            }
        }
    }

    private func publishPending(at now: ContinuousClock.Instant) {
        guard let pendingReadout else { return }
        self.pendingReadout = nil
        throttle.recordPublication(at: now)
        publicationTimes.append(now)
        readout = pendingReadout
    }

    private func publishFinal(_ final: EngineReadout) {
        flushTask?.cancel()
        flushTask = nil
        pendingReadout = nil
        publicationTimes.append(.now)
        readout = final
        phase = .finished
    }

    private func cancelConsumption() {
        consumer?.cancel()
        consumer = nil
        flushTask?.cancel()
        flushTask = nil
        pendingReadout = nil
        throttle = AnalysisUpdateThrottle(interval: updateInterval)
    }
}
