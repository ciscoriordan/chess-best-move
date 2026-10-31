import Foundation

/// Selects only searched root alternatives from a completed MultiPV iteration. Scores,
/// arrows and continuations always belong to the chosen move. Never invents a move or
/// attaches the principal move's evaluation to a different move.
struct EngineAlternativeMoves {
    private var iterations: [Int: [Int: EngineInfo]] = [:]
    private var maximumLine = 1

    mutating func receive(_ info: EngineInfo, exact: Bool) {
        maximumLine = max(maximumLine, info.multiPV)
        guard exact, !info.pv.isEmpty else {
            iterations[info.depth]?[info.multiPV] = nil
            return
        }
        iterations[info.depth, default: [:]][info.multiPV] = info
        // The last three depths cover an unfinished final iteration and two completed ones.
        let retained = Set(iterations.keys.sorted().suffix(3))
        iterations = iterations.filter { retained.contains($0.key) }
    }

    func candidates() -> [EngineInfo] {
        for depth in iterations.keys.sorted(by: >) {
            guard let lines = iterations[depth],
                  (1...maximumLine).allSatisfy({ lines[$0] != nil }),
                  let best = lines[1], case .centipawns(let bestScore) = best.score else { continue }
            let alternatives = (2...max(2, maximumLine)).compactMap { index -> EngineInfo? in
                guard let info = lines[index], case .centipawns(let score) = info.score,
                      // Intentionally allows a noticeable concession, up to 1.5 pawns in
                      // this search. Preserve a positive evaluation rather than selecting
                      // a move already evaluated as losing. Forced-mate lines stay principal.
                      score <= bestScore, bestScore - score <= 150,
                      !(bestScore >= 0 && score < 0), info.pv.first != best.pv.first else { return nil }
                return info
            }
            return alternatives
        }
        return []
    }

    func select(fallback: EngineResult, choose: (Int) -> Int = { Int.random(in: 0..<$0) }) -> EngineResult {
        if case .mate = fallback.lastInfo?.score { return fallback }
        let options = candidates()
        guard !options.isEmpty else { return fallback }
        let index = choose(options.count)
        guard options.indices.contains(index) else { return fallback }
        let selected = options[index]
        return EngineResult(bestMove: selected.pv[0], ponder: selected.pv.dropFirst().first,
                            lastInfo: selected)
    }
}
