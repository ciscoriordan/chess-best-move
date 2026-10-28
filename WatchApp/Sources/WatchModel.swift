import Foundation
import Observation
import WatchConnectivity
import WatchKit
import os

@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    let state = WatchRequestState()
    var isAnalyzing: Bool { state.isAnalyzing }
    var isActivated: Bool { state.isActivated }
    var reply: WatchAnalysisReply? { state.reply }
    var error: WatchAnalysisReply.Status? { state.error }
    var failure: WatchRequestState.Failure? { state.failure }
    var isWaitingForActivation: Bool { state.isWaitingForActivation }
    var isReconnecting: Bool { state.isReconnecting }
    private(set) var moveDisplayFormat = MoveDisplayFormat.words
    #if DEBUG
    private(set) var isPreview = false
    #endif
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var activationTimeout: Task<Void, Never>?
    @ObservationIgnored private var activationID: UUID?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.motomatic.chessbestmove", category: "watch-connectivity")

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
            moveDisplayFormat = preview.moveDisplayFormat ?? .words
            if let formatIndex = arguments.firstIndex(of: "-watchPreviewMoveFormat"),
               arguments.indices.contains(formatIndex + 1),
               let format = MoveDisplayFormat(rawValue: arguments[formatIndex + 1]) {
                moveDisplayFormat = format
            }
            isPreview = true
            if arguments.contains("-watchPreviewAnalyzing") { _ = state.begin() }
            return
        }
        #endif
        guard WCSession.isSupported() else { state.activate(false); return }
        WCSession.default.delegate = self
        activate()
    }

    func activate() {
        state.dismissError()
        guard WCSession.isSupported() else { completeActivation(false); return }
        if WCSession.default.activationState == .activated {
            applyPreferences(WCSession.default.receivedApplicationContext["moveDisplayFormat"] as? String)
            completeActivation(true)
            return
        }
        let activation = UUID()
        activationID = activation
        WCSession.default.activate()
        activationTimeout?.cancel()
        activationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.activationID == activation, !self.isActivated else { return }
            self.completeActivation(false)
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
        send(request)
    }

    func setAppActive(_ active: Bool) {
        #if DEBUG
        if isPreview { return }
        #endif
        if let request = state.setAppActive(active) { sendAttempt(request) }
    }

    func retry(dismissing id: UUID) {
        guard state.failure?.id == id else { return }
        state.dismissError(id: id)
        if let request = state.retry() { send(request) }
    }

    private func send(_ request: WatchAnalysisRequest) {
        guard state.pendingID == request.id else { return }
        // Start the deadline and feedback on the first tap, including time spent waiting
        // for app/session activation. Retries never restart this deadline.
        if timeout == nil {
            WKInterfaceDevice.current().play(.click)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.fail(.timedOut, id: request.id)
            }
        }
        if WCSession.default.activationState != .activated {
            guard state.waitForReactivation(for: request.id) else { return }
            activate()
        } else {
            completeActivation(true)
        }
    }

    private func sendAttempt(_ request: WatchAnalysisRequest) {
        guard state.pendingID == request.id else { return }
        // Always On controls run their action before transitioning the app to active.
        // Only an active Watch app can wake a suspended iPhone with an interactive message.
        guard WKApplication.shared().applicationState == .active else {
            state.setAppActive(false)
            return
        }
        guard WCSession.default.activationState == .activated else {
            guard state.waitForReactivation(for: request.id) else { return }
            activate()
            return
        }
        guard let attempt = state.beginAttempt(for: request.id) else { return }
        guard let data = try? JSONEncoder().encode(request) else {
            fail(.unavailable, id: request.id)
            return
        }
        // Do not gate this on isReachable: a foreground Watch message can wake the iPhone app.
        let callbacks = WatchMessageCallbacks(onReply: { [weak self] data in
            guard let self, self.state.receive(data, for: request.id) else { return }
            if let format = self.reply?.moveDisplayFormat { self.moveDisplayFormat = format }
            self.didFinish()
        }, onError: { [weak self] failure in
            self?.deliveryFailed(failure, request: request, attempt: attempt)
        })
        WCSession.default.sendMessageData(data, replyHandler: callbacks.reply, errorHandler: callbacks.error)
    }

    private func deliveryFailed(_ failure: WatchTransportFailure,
                                request: WatchAnalysisRequest, attempt: UUID) {
        guard state.matchesAttempt(attempt, for: request.id) else { return }
        logger.error("Message failed: domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
        guard failure.canRetry, let delay = state.retryTransport(for: request.id, attempt: attempt) else {
            fail(.unavailable, id: request.id)
            return
        }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.state.pendingID == request.id else { return }
            self.retryTask = nil
            let resumed = self.state.completeTransportRetry(for: request.id)
            if WCSession.default.activationState != .activated {
                guard self.state.waitForReactivation(for: request.id) else { return }
                self.activate()
            } else if let resumed {
                self.sendAttempt(resumed)
            }
        }
    }

    private func didFinish() {
        timeout?.cancel()
        timeout = nil
        retryTask?.cancel()
        retryTask = nil
        activationTimeout?.cancel()
        activationTimeout = nil
        activationID = nil
        WKInterfaceDevice.current().play(state.error == nil ? .success : .failure)
    }

    private func fail(_ status: WatchAnalysisReply.Status, id: UUID) {
        if state.fail(status, id: id) { didFinish() }
    }

    func dismissError(id: UUID? = nil) { state.dismissError(id: id) }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyPreferences(WCSession.default.receivedApplicationContext["moveDisplayFormat"] as? String)
            self.completeActivation(WCSession.default.activationState == .activated)
        }
    }

    private func completeActivation(_ activated: Bool) {
        activationTimeout?.cancel()
        activationTimeout = nil
        activationID = nil
        if let request = state.activate(activated) { sendAttempt(request) }
        else if !activated { didFinish() }
    }

    private func applyPreferences(_ rawValue: String?) {
        if let rawValue, let format = MoveDisplayFormat(rawValue: rawValue) { moveDisplayFormat = format }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let rawValue = applicationContext["moveDisplayFormat"] as? String
        Task { @MainActor [weak self] in self?.applyPreferences(rawValue) }
    }
}
