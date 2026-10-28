import Foundation
import Observation

/// Request state is shared with the phone test target so every failure and late callback
/// can be checked without a real Watch Connectivity session.
@MainActor
@Observable
final class WatchRequestState {
    struct Failure: Identifiable, Equatable {
        enum Origin: Equatable { case connection, phone }
        let id = UUID()
        let status: WatchAnalysisReply.Status
        let origin: Origin
    }
    private(set) var isAnalyzing = false
    private(set) var isActivated = false
    private(set) var reply: WatchAnalysisReply?
    private(set) var failure: Failure?
    var error: WatchAnalysisReply.Status? { failure?.status }
    private(set) var isWaitingForActivation = false
    private(set) var pendingRequest: WatchAnalysisRequest?
    var pendingID: UUID? { pendingRequest?.id }
    private(set) var attemptID: UUID?
    private(set) var transportRetries = 0
    private(set) var isWaitingToRetry = false
    var isReconnecting: Bool { isWaitingForActivation || isWaitingToRetry }

    @discardableResult
    func activate(_ activated: Bool) -> WatchAnalysisRequest? {
        isActivated = activated
        if !activated {
            isWaitingForActivation = false
            isAnalyzing = false
            clearDelivery()
            failure = Failure(status: .unavailable, origin: .connection)
        } else if isWaitingForActivation {
            isWaitingForActivation = false
            if let pendingRequest { return pendingRequest }
            isAnalyzing = false
            return begin()
        }
        return nil
    }

    func begin() -> WatchAnalysisRequest? {
        guard !isAnalyzing else { return nil }
        guard isActivated else { failure = Failure(status: .unavailable, origin: .connection); return nil }
        let request = WatchAnalysisRequest()
        clearDelivery()
        pendingRequest = request
        isAnalyzing = true
        failure = nil
        return request
    }

    /// A disconnected retry queues the analysis itself, rather than only reconnecting.
    func retry() -> WatchAnalysisRequest? {
        guard !isAnalyzing else { return nil }
        failure = nil
        if !isActivated {
            isWaitingForActivation = true
            isAnalyzing = true
            return nil
        }
        return begin()
    }

    func beginAttempt(for id: UUID) -> UUID? {
        guard pendingID == id, attemptID == nil, !isWaitingForActivation else { return nil }
        let attempt = UUID()
        attemptID = attempt
        isWaitingToRetry = false
        return attempt
    }

    func matchesAttempt(_ attempt: UUID, for id: UUID) -> Bool {
        pendingID == id && attemptID == attempt
    }

    /// Reuse the original identifier and timestamp for at most two automatic retries.
    func retryTransport(for id: UUID, attempt: UUID) -> Duration? {
        guard matchesAttempt(attempt, for: id), transportRetries < 2 else { return nil }
        attemptID = nil
        transportRetries += 1
        isWaitingToRetry = true
        return transportRetries == 1 ? .milliseconds(500) : .milliseconds(1_500)
    }

    func waitForReactivation(for id: UUID) -> Bool {
        guard pendingID == id, attemptID == nil else { return false }
        isActivated = false
        isWaitingForActivation = true
        return true
    }

    @discardableResult
    func finish(_ reply: WatchAnalysisReply, origin: Failure.Origin = .phone) -> Bool {
        guard pendingID == reply.requestID else { return false }
        clearDelivery()
        isAnalyzing = false
        isWaitingForActivation = false
        switch reply.status {
        case .result, .checkmate, .stalemate:
            self.reply = reply
            failure = nil
        default:
            failure = Failure(status: reply.status, origin: origin)
        }
        return true
    }

    @discardableResult
    func receive(_ data: Data, for id: UUID) -> Bool {
        guard pendingID == id else { return false }
        guard let reply = WatchWire.reply(from: data, for: id) else { return fail(.unavailable, id: id) }
        return finish(reply)
    }

    @discardableResult
    func fail(_ status: WatchAnalysisReply.Status, id: UUID) -> Bool {
        finish(WatchAnalysisReply(requestID: id, status: status), origin: .connection)
    }

    func dismissError(id: UUID? = nil) {
        guard id == nil || failure?.id == id else { return }
        failure = nil
    }

    private func clearDelivery() {
        pendingRequest = nil
        attemptID = nil
        transportRetries = 0
        isWaitingToRetry = false
    }

    #if DEBUG
    func preview(_ reply: WatchAnalysisReply) {
        isActivated = true
        pendingRequest = WatchAnalysisRequest(id: reply.requestID)
        finish(reply)
    }
    #endif
}
