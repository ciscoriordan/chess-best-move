import Foundation
import Observation
import WatchConnectivity
import WatchKit

@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    private(set) var isAnalyzing = false
    private(set) var isActivated = false
    private(set) var reply: WatchAnalysisReply?
    private(set) var error: WatchAnalysisReply.Status?
    #if DEBUG
    private(set) var isPreview = false
    #endif
    @ObservationIgnored private var pending: UUID?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        #if DEBUG
        // Read a real pipeline test attachment for repeatable layout review. This path is
        // absent from Release and does not establish Watch Connectivity verification.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-watchPreviewFile"), arguments.indices.contains(index + 1),
           let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])),
           data.count <= WatchWire.maximumReplyBytes,
           let preview = try? JSONDecoder().decode(WatchAnalysisReply.self, from: data),
           preview.version == WatchWire.version {
            reply = preview
            isActivated = true
            isPreview = true
            return
        }
        #endif
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        activate()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.activate()
    }

    func analyze() {
        #if DEBUG
        if isPreview {
            isPreview = false
            reply = nil
            isActivated = false
            WCSession.default.delegate = self
            activate()
            return
        }
        #endif
        guard !isAnalyzing, isActivated else { return }
        let request = WatchAnalysisRequest()
        guard let data = try? JSONEncoder().encode(request) else { return }
        // Do not gate this on isReachable: a foreground Watch message can wake the iPhone app.
        pending = request.id
        isAnalyzing = true
        reply = nil
        error = nil
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            self?.fail(.timedOut, id: request.id)
        }
        let callbacks = WatchMessageCallbacks(onReply: { [weak self] data in
            guard let self, self.pending == request.id else { return }
            guard let reply = WatchWire.reply(from: data, for: request.id) else {
                self.fail(.unavailable, id: request.id)
                return
            }
            self.finish(reply)
        }, onError: { [weak self] in
            self?.fail(.unavailable, id: request.id)
        })
        WCSession.default.sendMessageData(data, replyHandler: callbacks.reply, errorHandler: callbacks.error)
    }

    private func finish(_ reply: WatchAnalysisReply) {
        guard pending == reply.requestID else { return }
        pending = nil
        timeout?.cancel()
        timeout = nil
        isAnalyzing = false
        switch reply.status {
        case .result, .checkmate, .stalemate:
            self.reply = reply
            error = nil
            WKInterfaceDevice.current().play(.success)
        default:
            self.reply = nil
            error = reply.status
        }
    }

    private func fail(_ status: WatchAnalysisReply.Status, id: UUID) {
        finish(WatchAnalysisReply(requestID: id, status: status))
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: (any Error)?) {
        let activated = state == .activated
        Task { @MainActor [weak self] in self?.isActivated = activated }
    }
}
