import ChessCore
import ChessVision
import CoreGraphics
import Foundation

struct WatchScreenshot: Sendable {
    let date: Date?
    let image: ImportedImage
}

enum WatchScreenshotError: Error { case permission, missing }

/// Owns one bounded request. It never routes the phone UI or prompts for permission/purchases.
@MainActor
final class WatchAnalysisService {
    typealias ScreenshotLoader = @Sendable () async throws -> WatchScreenshot
    typealias PreviewHandler = @MainActor @Sendable (WatchBoardPreview) -> Void
    private let loadScreenshot: ScreenshotLoader
    private let recognition: any RecognitionService
    private let store: any StoreService
    private let credits: any CreditsService
    private let engine: any EngineController
    private let foregroundEngine: (any EngineController)?
    private let phoneIsActive: @MainActor () -> Bool
    private let now: @Sendable () -> Date
    private let timeBudget: Duration
    private let history: AnalysisHistoryStore
    private let automaticAnalysisEnabled: @MainActor () -> Bool
    private var activeID: UUID?
    private var ownsEngine = false
    private var completed: [WatchAnalysisReply] = []

    init(store: any StoreService, credits: any CreditsService, engine: any EngineController,
         recognition: any RecognitionService, loadScreenshot: @escaping ScreenshotLoader,
         phoneIsActive: @escaping @MainActor () -> Bool,
         now: @escaping @Sendable () -> Date = { .now }, timeBudget: Duration = .seconds(16),
         foregroundEngine: (any EngineController)? = nil,
         history: AnalysisHistoryStore = AnalysisHistoryStore(),
         automaticAnalysisEnabled: @escaping @MainActor () -> Bool = { true }) {
        self.store = store
        self.credits = credits
        self.engine = engine
        self.recognition = recognition
        self.loadScreenshot = loadScreenshot
        self.phoneIsActive = phoneIsActive
        self.now = now
        self.timeBudget = timeBudget
        self.foregroundEngine = foregroundEngine
        self.history = history
        self.automaticAnalysisEnabled = automaticAnalysisEnabled
    }

    static func live(app: AppModel, phoneIsActive: @escaping @MainActor () -> Bool) -> WatchAnalysisService {
        let settings = app.settings
        return WatchAnalysisService(
            store: app.store, credits: app.credits, engine: AnalysisFeature.makeEngineController(),
            recognition: CaptureRecognitionService(makeRecognizer: { try BoardRecognizer(computeUnits: .cpuOnly) }),
            loadScreenshot: {
                guard CapturePhotoLibrary.currentAccess() == .authorized else { throw WatchScreenshotError.permission }
                guard let asset = CapturePhotoLibrary.newestScreenshot() else {
                    throw WatchScreenshotError.missing
                }
                let loaded = try await CapturePhotoLibrary.imageData(for: asset.localIdentifier, allowNetwork: false)
                let image = try CaptureImageDecoder.decode(data: loaded.data, orientation: loaded.orientation)
                return WatchScreenshot(date: asset.creationDate, image: ImportedImage(image: image, source: .latestScreenshot))
            }, phoneIsActive: phoneIsActive, foregroundEngine: app.engine, history: app.history,
            automaticAnalysisEnabled: { settings.automaticallyAnalyzesOnWatchOpen })
    }

    /// Called synchronously on activation/expiry before the foreground can take the engine.
    func cancel() {
        activeID = nil
        if ownsEngine { engine.stop() }
        ownsEngine = false
    }

    func analyze(_ request: WatchAnalysisRequest, onPreview: PreviewHandler? = nil) async -> WatchAnalysisReply {
        func failure(_ status: WatchAnalysisReply.Status) -> WatchAnalysisReply {
            WatchAnalysisReply(requestID: request.id, status: status)
        }
        guard request.version == WatchWire.version,
              (-5...30).contains(now().timeIntervalSince(request.createdAt)) else { return failure(.invalidRequest) }
        if let cached = completed.first(where: { $0.requestID == request.id }) {
            return cached
        }
        // The phone is authoritative even if a Watch still has an older cached preference.
        if request.automaticallyTriggered == true, !automaticAnalysisEnabled() {
            return failure(.automaticAnalysisSkipped)
        }
        guard activeID == nil, !phoneIsActive(), !foregroundIsSearching else { return failure(.busy) }
        switch engine.phase {
        case .preparing, .searching: return failure(.busy)
        default: break
        }
        activeID = request.id
        defer {
            if activeID == request.id {
                if ownsEngine { engine.stop() }
                ownsEngine = false
                activeID = nil
            }
        }
        func isCurrent() -> Bool {
            activeID == request.id && !Task.isCancelled && !phoneIsActive() && !foregroundIsSearching
        }
        let deadline = ContinuousClock.now + timeBudget
        let screenshot: WatchScreenshot
        do { screenshot = try await loadScreenshot() }
        catch WatchScreenshotError.permission { return failure(.setupRequired) }
        catch WatchScreenshotError.missing { return failure(.noScreenshot) }
        catch { return failure(.unavailable) }
        guard isCurrent() else { return failure(.timedOut) }
        if let cached = history.entry(for: screenshot.image, engineVersion: engine.engineVersion),
           let snapshot = cached.snapshot(importing: screenshot.image) {
            return await savedReply(cached, snapshot: snapshot, screenshot: screenshot, request: request)
        }
        let outcome = await recognition.recognize(screenshot.image)
        guard isCurrent(), ContinuousClock.now < deadline else { return failure(.timedOut) }
        let snapshot: BoardSnapshot
        switch outcome {
        case .confident(let value): snapshot = value
        case .needsCheck: return failure(.needsCorrection)
        case .boardNotFound, .invalidImage: return failure(.noBoard)
        }
        let position = AnalysisPositionCheck.sanitized(snapshot.position)
        let issues = position.validate()
        guard issues.allSatisfy({ $0 == .noLegalMoves }) else { return failure(.needsCorrection) }
        if let cached = history.entry(for: position, engineVersion: engine.engineVersion) {
            return await savedReply(cached, snapshot: snapshot, screenshot: screenshot, request: request)
        }
        if issues.contains(.noLegalMoves) {
            history.record(snapshot: snapshot, origin: .recognition, readout: nil,
                checkmate: position.isCheckmate, thinkTime: .threeSeconds, engineVersion: engine.engineVersion)
            return WatchAnalysisReply(requestID: request.id,
                status: position.isCheckmate ? .checkmate : .stalemate,
                screenshotDate: screenshot.date, whiteToMove: position.sideToMove == .white)
        }
        // Send only the selected board crop, without an old arrow, before waiting for
        // entitlements or starting Stockfish. The final reply remains the reliable result.
        if request.supportsBoardPreview == true, let onPreview {
            let image = snapshot.boardImage
            let thumbnail = await Task.detached(priority: .utility) {
                WatchBoardThumbnail.make(board: image)
            }.value
            guard isCurrent(), ContinuousClock.now < deadline else { return failure(.timedOut) }
            if let thumbnail {
                onPreview(WatchBoardPreview(requestID: request.id, screenshotDate: screenshot.date,
                                            thumbnail: thumbnail))
            }
        }
        guard isCurrent(), ContinuousClock.now < deadline else { return failure(.timedOut) }
        // A background launch must not spend a subscriber's free credits before StoreKit loads.
        let entitlementDeadline = min(deadline, ContinuousClock.now + .seconds(5))
        while !store.hasLoadedEntitlements, isCurrent(), ContinuousClock.now < entitlementDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard isCurrent(), store.hasLoadedEntitlements else { return failure(.unavailable) }
        let authorization = credits.authorize(board: position.board, origin: .recognition,
                                              recognition: MonetizationRecognitionEvidence(snapshot))
        guard authorization.decision.allowsAnalysis else { return failure(.noCredits) }
        // Recognition and entitlement loading yield the actor; check ownership again before starting.
        switch engine.phase {
        case .preparing, .searching: return failure(.busy)
        default: break
        }
        // The phone keeps its own published result. Both controllers use scoped search IDs
        // on the one Stockfish instance, so a late quiet-search stop cannot stop this request.
        (foregroundEngine as? any AnalysisLongerSearchRunner)?.stopLongerSearch()
        ownsEngine = true
        let started = await engine.start(position, thinkTime: .threeSeconds)
        // A started search consumes its existing authorization even if the Watch disconnected.
        if started { credits.commit(authorization) }
        guard isCurrent() else { return failure(.timedOut) }
        guard started else { return failure(.unavailable) }
        while engine.phase == .searching || engine.phase == .preparing {
            guard isCurrent(), ContinuousClock.now < deadline else { return failure(.timedOut) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard engine.phase == .finished, let uci = engine.readout?.bestMove,
              let move = Move(uci: uci), let san = position.san(for: move) else { return failure(.unavailable) }
        ownsEngine = false
        history.record(snapshot: snapshot, origin: .recognition, readout: engine.readout,
            thinkTime: .threeSeconds, engineVersion: engine.engineVersion)
        let thumbnail = await Task.detached {
            WatchBoardThumbnail.make(board: snapshot.boardImage, move: move, whiteAtBottom: snapshot.whiteAtBottom)
        }.value
        guard isCurrent() else { return failure(.timedOut) }
        let reply = WatchAnalysisReply(requestID: request.id, status: .result,
            screenshotDate: screenshot.date, whiteToMove: position.sideToMove == .white,
            san: san, moveDescription: AnalysisSpeech.moveDescription(san: san, move: move,
                capture: AnalysisCapture.find(for: move, in: position)), thumbnail: thumbnail,
            playback: .make(position: position, moves: [move], whiteAtBottom: snapshot.whiteAtBottom))
        completed.append(reply)
        completed = Array(completed.suffix(8))
        return reply
    }

    private func savedReply(_ cached: AnalysisHistoryEntry, snapshot: BoardSnapshot,
                            screenshot: WatchScreenshot, request: WatchAnalysisRequest) async -> WatchAnalysisReply {
        history.rememberScreenshot(snapshot, for: cached.id)
        history.touch(cached.id)
        if let checkmate = cached.checkmate {
            return WatchAnalysisReply(requestID: request.id, status: checkmate ? .checkmate : .stalemate,
                screenshotDate: screenshot.date, whiteToMove: snapshot.position.sideToMove == .white)
        }
        guard let uci = cached.result?.bestMove, let move = Move(uci: uci),
              let san = snapshot.position.san(for: move) else {
            return WatchAnalysisReply(requestID: request.id, status: .unavailable)
        }
        let thumbnail = await Task.detached {
            WatchBoardThumbnail.make(board: snapshot.boardImage, move: move, whiteAtBottom: snapshot.whiteAtBottom)
        }.value
        guard activeID == request.id, !Task.isCancelled, !phoneIsActive() else {
            return WatchAnalysisReply(requestID: request.id, status: .timedOut)
        }
        return WatchAnalysisReply(requestID: request.id, status: .result, screenshotDate: screenshot.date,
            whiteToMove: snapshot.position.sideToMove == .white, san: san,
            moveDescription: AnalysisSpeech.moveDescription(san: san, move: move,
                capture: AnalysisCapture.find(for: move, in: snapshot.position)), thumbnail: thumbnail,
            playback: .make(position: snapshot.position, moves: [move], whiteAtBottom: snapshot.whiteAtBottom))
    }

    private var foregroundIsSearching: Bool {
        guard let foregroundEngine else { return false }
        switch foregroundEngine.phase {
        case .preparing, .searching: return true
        default: return false
        }
    }
}
