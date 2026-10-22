import ChessCore
import ChessVision
import CoreGraphics
import Foundation

struct WatchScreenshot: Sendable {
    let date: Date
    let image: ImportedImage
}

enum WatchScreenshotError: Error { case permission, missing }

/// Owns one bounded request. It never routes the phone UI or prompts for permission/purchases.
@MainActor
final class WatchAnalysisService {
    typealias ScreenshotLoader = @Sendable () async throws -> WatchScreenshot
    private let loadScreenshot: ScreenshotLoader
    private let recognition: any RecognitionService
    private let store: any StoreService
    private let credits: any CreditsService
    private let engine: any EngineController
    private let foregroundEngine: (any EngineController)?
    private let phoneIsActive: @MainActor () -> Bool
    private let now: @Sendable () -> Date
    private let timeBudget: Duration
    private var activeID: UUID?
    private var ownsEngine = false
    private var completed: [WatchAnalysisReply] = []

    init(store: any StoreService, credits: any CreditsService, engine: any EngineController,
         recognition: any RecognitionService, loadScreenshot: @escaping ScreenshotLoader,
         phoneIsActive: @escaping @MainActor () -> Bool,
         now: @escaping @Sendable () -> Date = { .now }, timeBudget: Duration = .seconds(16),
         foregroundEngine: (any EngineController)? = nil) {
        self.store = store
        self.credits = credits
        self.engine = engine
        self.recognition = recognition
        self.loadScreenshot = loadScreenshot
        self.phoneIsActive = phoneIsActive
        self.now = now
        self.timeBudget = timeBudget
        self.foregroundEngine = foregroundEngine
    }

    static func live(app: AppModel, phoneIsActive: @escaping @MainActor () -> Bool) -> WatchAnalysisService {
        WatchAnalysisService(
            store: app.store, credits: app.credits, engine: AnalysisFeature.makeEngineController(),
            recognition: CaptureRecognitionService(makeRecognizer: { try BoardRecognizer(computeUnits: .cpuOnly) }),
            loadScreenshot: {
                guard CapturePhotoLibrary.currentAccess() == .authorized else { throw WatchScreenshotError.permission }
                guard let asset = CapturePhotoLibrary.newestScreenshot(), let date = asset.creationDate,
                      (-5...WatchWire.screenshotMaximumAge).contains(Date.now.timeIntervalSince(date)) else {
                    throw WatchScreenshotError.missing
                }
                let loaded = try await CapturePhotoLibrary.imageData(for: asset.localIdentifier, allowNetwork: false)
                let image = try CaptureImageDecoder.decode(data: loaded.data, orientation: loaded.orientation)
                return WatchScreenshot(date: date, image: ImportedImage(image: image, source: .latestScreenshot))
            }, phoneIsActive: phoneIsActive, foregroundEngine: app.engine)
    }

    /// Called synchronously on activation/expiry before the foreground can take the engine.
    func cancel() {
        activeID = nil
        if ownsEngine { engine.stop() }
        ownsEngine = false
    }

    func analyze(_ request: WatchAnalysisRequest) async -> WatchAnalysisReply {
        func failure(_ status: WatchAnalysisReply.Status) -> WatchAnalysisReply {
            WatchAnalysisReply(requestID: request.id, status: status)
        }
        guard request.version == WatchWire.version,
              (-5...30).contains(now().timeIntervalSince(request.createdAt)) else { return failure(.invalidRequest) }
        if let cached = completed.first(where: { $0.requestID == request.id }) {
            guard let date = cached.screenshotDate,
                  now().timeIntervalSince(date) <= WatchWire.screenshotMaximumAge else { return failure(.noFreshScreenshot) }
            return cached
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
        catch WatchScreenshotError.missing { return failure(.noFreshScreenshot) }
        catch { return failure(.unavailable) }
        guard isCurrent() else { return failure(.timedOut) }
        guard (-5...WatchWire.screenshotMaximumAge).contains(now().timeIntervalSince(screenshot.date)) else {
            return failure(.noFreshScreenshot)
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
        if issues.contains(.noLegalMoves) {
            return WatchAnalysisReply(requestID: request.id,
                status: position.isCheckmate ? .checkmate : .stalemate,
                screenshotDate: screenshot.date, whiteToMove: position.sideToMove == .white)
        }
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
        let thumbnail = await Task.detached {
            WatchBoardThumbnail.make(board: snapshot.boardImage, move: move, whiteAtBottom: snapshot.whiteAtBottom)
        }.value
        guard isCurrent() else { return failure(.timedOut) }
        let reply = WatchAnalysisReply(requestID: request.id, status: .result,
            screenshotDate: screenshot.date, whiteToMove: position.sideToMove == .white,
            san: san, moveDescription: AnalysisSpeech.moveDescription(san: san, move: move,
                capture: AnalysisCapture.find(for: move, in: position)), thumbnail: thumbnail)
        completed.append(reply)
        completed = Array(completed.suffix(8))
        return reply
    }

    private var foregroundIsSearching: Bool {
        guard let foregroundEngine else { return false }
        switch foregroundEngine.phase {
        case .preparing, .searching: return true
        default: return false
        }
    }
}
