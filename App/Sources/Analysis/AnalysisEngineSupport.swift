// Pure engine-side helpers for the Analysis feature: position sanitizing, score conversion to
// White's point of view, readout accumulation and UI update throttling. No SwiftUI, no engine
// calls, so every piece is unit-testable.

import ChessCore
import ChessEngine
import Foundation

// MARK: - Position checks

/// Prepares a position for Stockfish (ARCHITECTURE.md, ChessEngine caveats: validate first).
enum AnalysisPositionCheck {
    /// The position with castling rights and en passant that the board cannot support removed.
    static func sanitized(_ position: Position) -> Position {
        var copy = position
        copy.removeInconsistentCastlingRights()
        copy.removeInvalidEnPassant()
        return copy
    }

    /// Issues that make the engine refuse the position. `noLegalMoves` is not blocking: the
    /// Result screen shows checkmate or stalemate directly.
    static func blockingIssues(in position: Position) -> [PositionIssue] {
        position.validate().filter { $0 != .noLegalMoves }
    }

    /// Squares worth flagging when a rejected board goes back to Check position.
    static func squares(for issues: [PositionIssue]) -> Set<Square> {
        var squares = Set<Square>()
        for issue in issues {
            if case .pawnOnBackRank(let square) = issue { squares.insert(square) }
        }
        return squares
    }
}

/// Failure messages the controller puts into `EnginePhase.failed`, so the screen can tell a
/// rejected position (back to Check position) from an engine that could not run.
enum AnalysisEngineFailure {
    static let invalidPositionPrefix = "Invalid position: "

    /// Shown when the engine refuses a board that `Position.validate()` accepts. ChessCore
    /// follows the engine's rules, so this should not happen; if it does, going back to Check
    /// position would list nothing to fix and bounce straight back here.
    static let unexplainedRejection = "The chess engine can't analyze this position. Use Edit to check the pieces."

    static func invalidPosition(_ detail: String) -> String {
        invalidPositionPrefix + detail
    }

    static func isInvalidPosition(_ phase: EnginePhase) -> Bool {
        if case .failed(let message) = phase { return message.hasPrefix(invalidPositionPrefix) }
        return false
    }

    /// A readable message for an engine error.
    static func message(for error: any Error) -> String {
        switch error {
        case EngineError.invalidPosition(let detail):
            return invalidPosition(detail)
        case EngineError.networkMissing:
            return "The chess engine's neural network is missing from the app."
        case EngineError.engineUnavailable:
            return "The chess engine could not start."
        case EngineError.invalidLimit:
            return "The think time is not valid."
        case EngineError.noLegalMoves:
            return "The side to move has no legal moves."
        default:
            return "The chess engine stopped unexpectedly."
        }
    }
}

// MARK: - Scores

/// Evaluation conversions and text (design.md sections 4, 8 and 12).
enum AnalysisScore {
    /// The winning-chances slope from design.md section 8.
    static let winningChancesSlope = 0.00368208
    /// Both colors stay visible unless a mate is announced.
    static let shareRange: ClosedRange<Double> = 0.04...0.96

    /// Converts an engine score (side to move's point of view) to White's point of view.
    static func whitePOV(_ score: EngineScore, sideToMove: PieceColor) -> WhiteScore {
        let sign = sideToMove == .white ? 1 : -1
        switch score {
        case .centipawns(let value): return .centipawns(value * sign)
        case .mate(let moves): return .mate(moves * sign)
        }
    }

    /// White's share of the evaluation bar: 0.5 before any score, the winning-chances curve
    /// clamped to 0.04...0.96 for centipawns, 1 when White mates and 0 when Black mates.
    static func whiteShare(_ score: WhiteScore?) -> Double {
        switch score {
        case nil:
            return 0.5
        case .centipawns(let cp)?:
            let chances = 2 / (1 + exp(-winningChancesSlope * Double(cp))) - 1
            let share = 0.5 + 0.5 * chances
            return min(max(share, shareRange.lowerBound), shareRange.upperBound)
        case .mate(let moves)?:
            if moves > 0 { return 1 }
            if moves < 0 { return 0 }
            return 0.5
        }
    }

    /// "+0.62", "−1.20" (U+2212), "0.00", "M3", "−M3".
    static func text(_ score: WhiteScore) -> String {
        switch score {
        case .centipawns(let cp):
            let magnitude = String(format: "%.2f", Double(abs(cp)) / 100)
            if cp > 0 { return "+" + magnitude }
            if cp < 0 { return "\u{2212}" + magnitude }
            return magnitude
        case .mate(let moves):
            return (moves < 0 ? "\u{2212}M" : "M") + "\(abs(moves))"
        }
    }

    /// One decimal, for the App Shortcut dialog: "+0.4", "−1.2", "M3".
    static func shortText(_ score: WhiteScore) -> String {
        switch score {
        case .centipawns(let cp):
            let magnitude = String(format: "%.1f", Double(abs(cp)) / 100)
            if magnitude == "0.0" { return magnitude }
            return (cp > 0 ? "+" : "\u{2212}") + magnitude
        case .mate:
            return text(score)
        }
    }

    /// VoiceOver form: "White is ahead by 2.35 pawns", "Equal", "Black mates in 3".
    static func spoken(_ score: WhiteScore) -> String {
        switch score {
        case .centipawns(let cp):
            if cp == 0 { return "Equal" }
            let side = cp > 0 ? "White" : "Black"
            let pawns = trimmedDecimal(Double(abs(cp)) / 100)
            return "\(side) is ahead by \(pawns) \(pawns == "1" ? "pawn" : "pawns")"
        case .mate(let moves):
            if moves == 0 { return "Checkmate" }
            return "\(moves > 0 ? "White" : "Black") mates in \(abs(moves))"
        }
    }

    /// "2.35", "0.8", "1": at most two decimals, no trailing zeros.
    static func trimmedDecimal(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

// MARK: - Readout accumulation

/// Folds engine events into the `EngineReadout` the screen shows.
///
/// The move, score and line only change at a completed depth (design.md 9.3: "The provisional
/// best move changes only when the engine's best move at a completed depth differs from the one
/// shown"). A depth counts as completed when a report for a deeper iteration arrives, so
/// aspiration-window re-searches inside one iteration never make the arrow jump. Depth and
/// nodes per second follow the latest report. The final `.bestMove` event is authoritative.
///
/// A re-run of the same board ("Think longer", a new think time) starts from the previous
/// result as `seed`: that move stays until the new search completes a depth at least as deep
/// as the one it came from, so the arrow does not fall back to a shallow move.
struct AnalysisReadoutAccumulator: Sendable {
    let sideToMove: PieceColor
    private(set) var readout: EngineReadout
    private(set) var isFinished = false
    /// Completed depths shallower than this do not replace the seed's move.
    private let seedDepth: Int
    /// The latest principal-line report of the iteration in progress.
    private var inProgress: EngineInfo?

    init(sideToMove: PieceColor, seed: EngineReadout? = nil) {
        self.sideToMove = sideToMove
        if let seed, seed.bestMove != nil {
            var start = seed
            start.elapsed = .zero
            readout = start
            seedDepth = seed.depth
        } else {
            readout = EngineReadout()
            seedDepth = 0
        }
    }

    mutating func apply(_ event: EngineEvent, elapsed: Duration) {
        guard !isFinished else { return }
        readout.elapsed = elapsed
        switch event {
        case .info(let info):
            apply(info)
        case .bestMove(let result):
            finish(result)
        }
    }

    private mutating func apply(_ info: EngineInfo) {
        guard info.multiPV == 1 else { return }
        if let nps = info.nps { readout.nodesPerSecond = nps }
        readout.depth = info.depth
        if let previous = inProgress, info.depth > previous.depth {
            if previous.depth >= seedDepth { adopt(previous) }
        } else if readout.bestMove == nil {
            // Nothing on screen yet: show the first report right away.
            adopt(info)
        }
        if !info.pv.isEmpty { inProgress = info }
    }

    private mutating func adopt(_ info: EngineInfo) {
        guard let first = info.pv.first else { return }
        readout.bestMove = first
        readout.principalVariation = info.pv
        if let score = info.score {
            readout.score = AnalysisScore.whitePOV(score, sideToMove: sideToMove)
        }
    }

    private mutating func finish(_ result: EngineResult) {
        isFinished = true
        readout.bestMove = result.bestMove
        if let info = result.lastInfo, info.pv.first == result.bestMove {
            readout.principalVariation = info.pv
            if let score = info.score {
                readout.score = AnalysisScore.whitePOV(score, sideToMove: sideToMove)
            }
            readout.depth = info.depth
            if let nps = info.nps { readout.nodesPerSecond = nps }
        } else if readout.principalVariation.first != result.bestMove {
            readout.principalVariation = [result.bestMove]
            readout.score = nil
        }
    }
}

// MARK: - Throttling

/// Coalesces UI updates to at most one per `interval` (10 per second by default, design.md
/// 9.3). The first update publishes at once; later ones wait until `interval` after the
/// previous publication, and the caller publishes only the newest pending value then.
struct AnalysisUpdateThrottle: Sendable {
    enum Decision: Sendable, Equatable {
        case publishNow
        case wait(until: ContinuousClock.Instant)
    }

    let interval: Duration
    private(set) var lastPublication: ContinuousClock.Instant?

    init(interval: Duration = .milliseconds(100)) {
        self.interval = interval
    }

    func decision(at now: ContinuousClock.Instant) -> Decision {
        guard let lastPublication else { return .publishNow }
        let next = lastPublication.advanced(by: interval)
        return now >= next ? .publishNow : .wait(until: next)
    }

    mutating func recordPublication(at now: ContinuousClock.Instant) {
        lastPublication = now
    }
}
