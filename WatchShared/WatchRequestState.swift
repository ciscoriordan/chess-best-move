import Foundation
import Observation

/// Request state is shared with the phone test target so every failure and late callback
/// can be checked without a real Watch Connectivity session.
@MainActor
@Observable
final class WatchRequestState {
    private(set) var isAnalyzing = false
    private(set) var isActivated = false
    private(set) var reply: WatchAnalysisReply?
    private(set) var error: WatchAnalysisReply.Status?
    private(set) var pendingID: UUID?

    func activate(_ activated: Bool) {
        isActivated = activated
        if !activated { error = .unavailable }
    }

    func begin() -> WatchAnalysisRequest? {
        guard !isAnalyzing else { return nil }
        guard isActivated else { error = .unavailable; return nil }
        let request = WatchAnalysisRequest()
        pendingID = request.id
        isAnalyzing = true
        reply = nil
        error = nil
        return request
    }

    @discardableResult
    func finish(_ reply: WatchAnalysisReply) -> Bool {
        guard pendingID == reply.requestID else { return false }
        pendingID = nil
        isAnalyzing = false
        switch reply.status {
        case .result, .checkmate, .stalemate:
            self.reply = reply
            error = nil
        default:
            self.reply = nil
            error = reply.status
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

    func dismissError() { error = nil }

    #if DEBUG
    func preview(_ reply: WatchAnalysisReply) {
        isActivated = true
        pendingID = reply.requestID
        finish(reply)
    }
    #endif
}
