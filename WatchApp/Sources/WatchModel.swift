import Foundation
import Observation
import WatchConnectivity
import WatchKit

@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    let state = WatchRequestState()
    var isAnalyzing: Bool { state.isAnalyzing }
    var isActivated: Bool { state.isActivated }
    var reply: WatchAnalysisReply? { state.reply }
    var error: WatchAnalysisReply.Status? { state.error }
    #if DEBUG
    private(set) var isPreview = false
    #endif
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var activationTimeout: Task<Void, Never>?

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
            state.preview(preview)
            isPreview = true
            return
        }
        #endif
        guard WCSession.isSupported() else { state.activate(false); return }
        WCSession.default.delegate = self
        activate()
    }

    func activate() {
        state.dismissError()
        guard WCSession.isSupported() else { state.activate(false); return }
        if WCSession.default.activationState == .activated { state.activate(true) }
        WCSession.default.activate()
        activationTimeout?.cancel()
        activationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, !self.isActivated else { return }
            self.state.activate(false)
            WKInterfaceDevice.current().play(.failure)
        }
    }

    func analyze() {
        #if DEBUG
        if isPreview {
            isPreview = false
            WCSession.default.delegate = self
            activate()
        }
        #endif
        guard let request = state.begin() else { return }
        guard let data = try? JSONEncoder().encode(request) else {
            fail(.unavailable, id: request.id)
            return
        }
        // Do not gate this on isReachable: a foreground Watch message can wake the iPhone app.
        WKInterfaceDevice.current().play(.click)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            self?.fail(.timedOut, id: request.id)
        }
        let callbacks = WatchMessageCallbacks(onReply: { [weak self] data in
            guard let self, self.state.receive(data, for: request.id) else { return }
            self.didFinish()
        }, onError: { [weak self] in
            self?.fail(.unavailable, id: request.id)
        })
        WCSession.default.sendMessageData(data, replyHandler: callbacks.reply, errorHandler: callbacks.error)
    }

    private func didFinish() {
        timeout?.cancel()
        timeout = nil
        WKInterfaceDevice.current().play(state.error == nil ? .success : .failure)
    }

    private func fail(_ status: WatchAnalysisReply.Status, id: UUID) {
        if state.fail(status, id: id) { didFinish() }
    }

    func dismissError() { state.dismissError() }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: (any Error)?) {
        let activated = state == .activated
        Task { @MainActor [weak self] in
            self?.activationTimeout?.cancel()
            self?.state.activate(activated)
        }
    }
}
