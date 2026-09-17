import CStockfish
import Foundation
import os

/// Stockfish running in-process through its C++ `Engine` API (no UCI text, no pipes,
/// no stdout redirection).
///
/// - One engine instance lives for the whole app session; searches reuse its threads
///   and transposition table.
/// - Starting a new analysis stops the running one first. The stopped analysis still
///   ends with its `.bestMove` (the best move found so far).
/// - Cancelling the task that consumes a stream stops that search.
public actor StockfishEngine {
    public static let shared = StockfishEngine()

    /// Settings applied when the engine is created.
    struct Configuration: Sendable {
        var threads: Int
        var hashMegabytes: Int

        static var deviceDefault: Configuration {
            Configuration(threads: defaultThreadCount(), hashMegabytes: defaultHashMegabytes())
        }
    }

    private let configuration: Configuration
    /// Every blocking call into Stockfish (create, resize, start search) runs here, in order.
    private let queue = DispatchQueue(label: "ChessEngine.StockfishEngine", qos: .userInitiated)

    private var handle: EngineHandle?
    private var prepareTask: Task<EngineHandle, Error>?
    private var activeSearch: SearchRequest?
    /// The most recently queued search start; each start waits for the previous one.
    private var startChain: Task<Void, Never>?

    init(configuration: Configuration = .deviceDefault) {
        self.configuration = configuration
    }

    /// "Stockfish 19".
    public nonisolated var version: String {
        String(cString: sf_engine_version())
    }

    /// The thread count and hash size (MB) this engine uses or will use.
    nonisolated var settings: (threads: Int, hashMegabytes: Int) {
        (configuration.threads, configuration.hashMegabytes)
    }

    /// Creates the engine and loads the NNUE network from the package bundle.
    /// Idempotent: later calls return immediately; concurrent calls share one load.
    public func prepare() async throws {
        _ = try await preparedHandle()
    }

    /// Starts analyzing `fen` and returns a stream of `.info` events that ends with one
    /// `.bestMove` event. The engine is prepared first if needed.
    public func analyze(
        fen: String,
        limit: SearchLimit,
        multiPV: Int = 1
    ) -> AsyncThrowingStream<EngineEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<EngineEvent, Error>.makeStream(
            bufferingPolicy: .unbounded
        )

        let limitValue: Int
        switch limit {
        case .movetime(let milliseconds): limitValue = milliseconds
        case .depth(let plies): limitValue = plies
        }
        if limitValue < 1 {
            continuation.finish(throwing: EngineError.invalidLimit)
            return stream
        }

        activeSearch?.requestStop()

        let request = SearchRequest(continuation: continuation)
        activeSearch = request
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                request.markCancelled()
            }
        }

        let previous = startChain
        let clampedMultiPV = max(1, min(multiPV, 256))
        startChain = Task {
            await previous?.value
            await self.start(request, fen: fen, limit: limit, multiPV: clampedMultiPV)
        }
        return stream
    }

    /// Makes the running search stop and emit its `.bestMove` promptly. Does not wait
    /// for the stream to end. The search always completes its first depth (milliseconds)
    /// before stopping, so the best move is a searched one even when the stop arrives
    /// before or while the search starts.
    public func stop() async {
        activeSearch?.requestStop()
    }

    // MARK: - Private

    private func preparedHandle() async throws -> EngineHandle {
        if let handle {
            return handle
        }
        if let prepareTask {
            return try await prepareTask.value
        }

        let queue = self.queue
        let configuration = self.configuration
        let task = Task<EngineHandle, Error> {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try EngineHandle.create(configuration) })
                }
            }
        }
        prepareTask = task
        do {
            let created = try await task.value
            handle = created
            prepareTask = nil
            return created
        } catch {
            prepareTask = nil
            throw error
        }
    }

    private func start(_ request: SearchRequest, fen: String, limit: SearchLimit, multiPV: Int) async {
        if request.isCancelled {
            return
        }

        let engine: EngineHandle
        do {
            engine = try await preparedHandle()
        } catch {
            request.continuation.finish(throwing: error)
            return
        }

        if request.isCancelled {
            return
        }

        // A stop that arrived before the search could start still gets a (quick) searched
        // best move: depth 1 takes milliseconds, and SearchRequest does not stop a search
        // before it has completed its first depth.
        let effectiveLimit = request.isStopRequested ? .depth(1) : limit
        let callbacks = SearchCallbacks(request: request)
        let queue = self.queue

        let outcome: Result<UInt64, EngineError> = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: engine.startSearch(
                        fen: fen, limit: effectiveLimit, multiPV: multiPV, callbacks: callbacks
                    )
                )
            }
        }

        switch outcome {
        case .success(let searchID):
            request.didStart(searchID: searchID, engine: engine)
        case .failure(let error):
            request.continuation.finish(throwing: error)
        }
    }

    // MARK: - Device defaults

    /// Performance-core count (`hw.perflevel0.physicalcpu`), falling back to the active
    /// processor count minus one.
    static func defaultThreadCount() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    }

    /// 128 MB, or 64 MB on devices with less than 4 GB of RAM. iOS reports somewhat less
    /// than the installed RAM as physical memory, so the cut-off is 3.5 GiB: 3 GB devices
    /// get 64 MB and 4 GB devices get 128 MB.
    static func defaultHashMegabytes() -> Int {
        let lowMemoryThreshold: UInt64 = 3_584 * 1_024 * 1_024
        return ProcessInfo.processInfo.physicalMemory < lowMemoryThreshold ? 64 : 128
    }
}

// MARK: - Engine handle

/// Owns the C engine. The pointer is used according to CStockfish.h's threading rules:
/// blocking calls only on `StockfishEngine.queue`, stop from anywhere.
final class EngineHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    private init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sf_engine_destroy(pointer)
    }

    static func create(_ configuration: StockfishEngine.Configuration) throws -> EngineHandle {
        let fileName = String(cString: sf_engine_network_file_name())
        guard let url = Bundle.module.url(forResource: fileName, withExtension: nil, subdirectory: "NNUE")
        else {
            throw EngineError.networkMissing(fileName: fileName)
        }
        let directory = url.deletingLastPathComponent().path

        var error = [CChar](repeating: 0, count: 2048)
        guard let pointer = sf_engine_create(directory, &error, error.count) else {
            throw EngineError.engineUnavailable(string(fromNullTerminated: error))
        }
        // Threads first: resizing the pool reallocates the hash table, so the 128 MB
        // table is then allocated (and cleared) only once, by all threads.
        sf_engine_set_threads(pointer, Int32(clamping: configuration.threads))
        sf_engine_set_hash(pointer, Int32(clamping: configuration.hashMegabytes))
        return EngineHandle(pointer: pointer)
    }

    /// Blocking: waits for any previous search to end, then starts a new one.
    func startSearch(
        fen: String,
        limit: SearchLimit,
        multiPV: Int,
        callbacks: SearchCallbacks
    ) -> Result<UInt64, EngineError> {
        let movetime: Int32
        let depth: Int32
        switch limit {
        case .movetime(let milliseconds):
            movetime = Int32(clamping: milliseconds)
            depth = 0
        case .depth(let plies):
            movetime = 0
            depth = Int32(clamping: plies)
        }

        // Retained for Stockfish; released by the best-move callback (or below on failure).
        let context = Unmanaged.passRetained(callbacks).toOpaque()
        var error = [CChar](repeating: 0, count: 1024)
        let searchID = sf_engine_start_search(
            pointer, fen, movetime, depth, Int32(clamping: multiPV),
            searchInfoCallback, searchBestMoveCallback, context,
            &error, error.count
        )
        if searchID == 0 {
            Unmanaged<SearchCallbacks>.fromOpaque(context).release()
            return .failure(.invalidPosition(string(fromNullTerminated: error)))
        }
        return .success(searchID)
    }

    func stop(searchID: UInt64) {
        sf_engine_stop_search(pointer, searchID)
    }
}

// MARK: - Search bookkeeping

/// Tracks one `analyze` call from queueing to start, so stop and cancellation work in
/// every phase.
///
/// A stop (`requestStop`, from `stop()` or from a newer analysis) is held back until the
/// search has completed its first depth. Stockfish stopped before that has scored no
/// root move, and it then reports the first legal move in move-generation order (for
/// example a2a3) with score 0 and an empty principal variation, which is not a best move
/// at all. Depth 1 takes milliseconds, so the stop still ends the search promptly.
/// Consumer cancellation stops the search at once: nobody reads its result.
final class SearchRequest: Sendable {
    let continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation

    private struct State {
        var searchID: UInt64 = 0
        var engine: EngineHandle?
        var stopRequested = false
        var cancelled = false
        /// The search has reported a principal variation for a completed depth.
        var completedFirstDepth = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }
    var isStopRequested: Bool { state.withLock { $0.stopRequested } }

    func requestStop() {
        let running = state.withLock { state -> (EngineHandle, UInt64)? in
            state.stopRequested = true
            guard state.completedFirstDepth else { return nil }  // forwarded by didCompleteFirstDepth
            return state.engine.map { ($0, state.searchID) }
        }
        if let (engine, searchID) = running {
            engine.stop(searchID: searchID)
        }
    }

    func markCancelled() {
        let running = state.withLock { state -> (EngineHandle, UInt64)? in
            state.cancelled = true
            return state.engine.map { ($0, state.searchID) }
        }
        if let (engine, searchID) = running {
            engine.stop(searchID: searchID)
        }
    }

    func didStart(searchID: UInt64, engine: EngineHandle) {
        let shouldStop = state.withLock { state -> Bool in
            state.searchID = searchID
            state.engine = engine
            return state.cancelled || (state.stopRequested && state.completedFirstDepth)
        }
        if shouldStop {
            engine.stop(searchID: searchID)
        }
    }

    /// Called on the search thread with the first principal-variation report of a
    /// completed depth. Forwards a stop that was held back. If the search has not been
    /// registered by `didStart` yet, `didStart` forwards it instead.
    func didCompleteFirstDepth() {
        let running = state.withLock { state -> (EngineHandle, UInt64)? in
            state.completedFirstDepth = true
            guard state.stopRequested else { return nil }
            return state.engine.map { ($0, state.searchID) }
        }
        if let (engine, searchID) = running {
            engine.stop(searchID: searchID)
        }
    }
}

/// Receives Stockfish's callbacks for one search. Only touched on Stockfish's main
/// search thread, which delivers callbacks one at a time.
final class SearchCallbacks: @unchecked Sendable {
    let request: SearchRequest
    var continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation { request.continuation }
    private var lastPrimaryInfo: EngineInfo?
    private var reportedFirstDepth = false

    init(request: SearchRequest) {
        self.request = request
    }

    func receive(_ raw: sf_info) {
        // Reports whose score is only a lower or upper bound (aspiration-window fail-high
        // or fail-low, marked in raw.bound) are passed on as well: Stockfish reports every
        // multiPV line in each batch, and its final report can itself be a bound. Dropping
        // them would leave `lastInfo` or a multiPV line pointing at an older, different PV.
        let score: EngineScore =
            raw.score_kind == SF_SCORE_MATE
            ? .mate(Int(raw.score_value)) : .centipawns(Int(raw.score_value))
        let pv = raw.pv.map { String(cString: $0).split(separator: " ").map(String.init) } ?? []
        let info = EngineInfo(
            depth: Int(raw.depth),
            selDepth: raw.sel_depth >= 0 ? Int(raw.sel_depth) : nil,
            score: score,
            pv: pv,
            nodes: raw.nodes >= 0 ? Int(raw.nodes) : nil,
            nps: raw.nps >= 0 ? Int(raw.nps) : nil,
            multiPV: Int(raw.multipv)
        )
        if info.multiPV == 1 {
            lastPrimaryInfo = info
        }
        continuation.yield(.info(info))

        // Stockfish's first report of line 1 with a non-empty PV comes at the end of the
        // first completed iteration (after all multiPV lines), or in its final report if
        // the search ended earlier after scoring some root move. A search that ended
        // before scoring any root move reports depth 1, score 0 and an empty PV.
        if !reportedFirstDepth, info.multiPV == 1, info.depth >= 1, !info.pv.isEmpty {
            reportedFirstDepth = true
            request.didCompleteFirstDepth()
        }
    }

    func finish(bestMove: String, ponder: String) {
        if bestMove == "(none)" {
            continuation.finish(throwing: EngineError.noLegalMoves)
            return
        }
        let result = EngineResult(
            bestMove: bestMove,
            ponder: ponder.isEmpty ? nil : ponder,
            lastInfo: lastPrimaryInfo
        )
        continuation.yield(.bestMove(result))
        continuation.finish()
    }
}

private func string(fromNullTerminated buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private let searchInfoCallback: sf_info_callback = { context, info in
    guard let context, let info else { return }
    Unmanaged<SearchCallbacks>.fromOpaque(context).takeUnretainedValue().receive(info.pointee)
}

private let searchBestMoveCallback: sf_bestmove_callback = { context, bestMove, ponder in
    guard let context else { return }
    let callbacks = Unmanaged<SearchCallbacks>.fromOpaque(context).takeRetainedValue()
    callbacks.finish(
        bestMove: bestMove.map { String(cString: $0) } ?? "(none)",
        ponder: ponder.map { String(cString: $0) } ?? ""
    )
}
