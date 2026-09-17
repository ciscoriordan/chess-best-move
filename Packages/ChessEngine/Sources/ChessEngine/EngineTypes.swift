/// How long a search runs.
public enum SearchLimit: Sendable, Hashable {
    /// Search for this many milliseconds (must be at least 1).
    case movetime(milliseconds: Int)
    /// Search to this depth in plies (must be at least 1).
    case depth(Int)
}

/// An evaluation from the point of view of the side to move.
public enum EngineScore: Sendable, Hashable {
    /// Centipawns; positive means the side to move is better.
    case centipawns(Int)
    /// Moves (not plies) until mate. Positive: the side to move mates. Negative: the
    /// side to move gets mated. `mate(0)`: the side to move is already checkmated.
    case mate(Int)
}

/// One principal-variation report from the engine (a UCI "info ... pv" line).
public struct EngineInfo: Sendable, Hashable {
    public var depth: Int
    public var selDepth: Int?
    public var score: EngineScore?
    /// Principal variation as UCI moves ("e2e4", "e7e8q", castling as "e1g1").
    public var pv: [String]
    public var nodes: Int?
    public var nps: Int?
    /// 1-based index of the line when searching with `multiPV > 1`; 1 otherwise.
    public var multiPV: Int

    public init(
        depth: Int,
        selDepth: Int? = nil,
        score: EngineScore? = nil,
        pv: [String] = [],
        nodes: Int? = nil,
        nps: Int? = nil,
        multiPV: Int = 1
    ) {
        self.depth = depth
        self.selDepth = selDepth
        self.score = score
        self.pv = pv
        self.nodes = nodes
        self.nps = nps
        self.multiPV = multiPV
    }
}

/// The final result of a search.
public struct EngineResult: Sendable, Hashable {
    /// Best move in UCI notation.
    public var bestMove: String
    /// The expected reply, when the engine has one.
    public var ponder: String?
    /// The last complete report for the principal line (`multiPV == 1`).
    public var lastInfo: EngineInfo?

    public init(bestMove: String, ponder: String? = nil, lastInfo: EngineInfo? = nil) {
        self.bestMove = bestMove
        self.ponder = ponder
        self.lastInfo = lastInfo
    }
}

public enum EngineEvent: Sendable {
    case info(EngineInfo)
    case bestMove(EngineResult)
}

/// Errors thrown by `StockfishEngine.prepare()` and by analysis streams.
public enum EngineError: Error, Sendable, Hashable {
    /// The NNUE network file is not in the package bundle (run scripts/fetch-nets.sh).
    case networkMissing(fileName: String)
    /// Stockfish could not be created, typically because the network failed to load.
    case engineUnavailable(String)
    /// The FEN was rejected: malformed, or a position Stockfish cannot search safely
    /// (wrong number of kings, pawns on the first or eighth rank, too many pieces, the
    /// side not to move in check, more than two checkers).
    case invalidPosition(String)
    /// The limit's value was not positive.
    case invalidLimit
    /// The position is checkmate or stalemate, so there is no best move. The stream
    /// yields a depth-0 `.info` with the score (`mate(0)` or `centipawns(0)`) first.
    case noLegalMoves
}
