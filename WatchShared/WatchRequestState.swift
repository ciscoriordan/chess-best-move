import Foundation
import Observation

/// Request state is shared with the phone test target so every failure and late callback
/// can be checked without a real Watch Connectivity session.
@MainActor
@Observable
final class WatchRequestState {
    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let status: WatchAnalysisReply.Status
    }
    private(set) var isAnalyzing = false
    private(set) var isActivated = false
    private(set) var reply: WatchAnalysisReply?
    private(set) var failure: Failure?
    var error: WatchAnalysisReply.Status? { failure?.status }
    private(set) var isWaitingForActivation = false
    private(set) var pendingID: UUID?

    @discardableResult
    func activate(_ activated: Bool) -> WatchAnalysisRequest? {
        isActivated = activated
        if !activated {
            isWaitingForActivation = false
            isAnalyzing = false
            pendingID = nil
            failure = Failure(status: .unavailable)
        } else if isWaitingForActivation {
            isWaitingForActivation = false
            isAnalyzing = false
            return begin()
        }
        return nil
    }

    func begin() -> WatchAnalysisRequest? {
        guard !isAnalyzing else { return nil }
        guard isActivated else { failure = Failure(status: .unavailable); return nil }
        let request = WatchAnalysisRequest()
        pendingID = request.id
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

    @discardableResult
    func finish(_ reply: WatchAnalysisReply) -> Bool {
        guard pendingID == reply.requestID else { return false }
        pendingID = nil
        isAnalyzing = false
        switch reply.status {
        case .result, .checkmate, .stalemate:
            self.reply = reply
            failure = nil
        default:
            failure = Failure(status: reply.status)
        }
        return true
    }

    @discardableResult
    func receive(_ data: Data, for id: UUID) -> Bool {
        guard pendingID == id else { return false }
        return finish(WatchWire.reply(from: data, for: id)
            ?? WatchAnalysisReply(requestID: id, status: .unavailable))
    }

    @discardableResult
    func fail(_ status: WatchAnalysisReply.Status, id: UUID) -> Bool {
        finish(WatchAnalysisReply(requestID: id, status: status))
    }

    func dismissError(id: UUID? = nil) {
        guard id == nil || failure?.id == id else { return }
        failure = nil
    }

    #if DEBUG
    func preview(_ reply: WatchAnalysisReply) {
        isActivated = true
        pendingID = reply.requestID
        finish(reply)
    }
    #endif
}
