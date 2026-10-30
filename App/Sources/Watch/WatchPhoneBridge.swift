import Foundation
import Observation
import UIKit
import WatchConnectivity

/// The callback is immutable and invoked exactly once on the main actor.
private struct WatchReplyHandler: @unchecked Sendable {
    let send: (Data) -> Void
}

/// Repeated delivery of one request shares its running analysis and eventual reply.
@MainActor
final class WatchReplyGroup<Handler> {
    enum Admission: Equatable { case start, joined, busy }
    private(set) var requestID: UUID?
    private var handlers: [Handler] = []

    func accept(_ id: UUID, handler: Handler) -> Admission {
        if requestID == id {
            handlers.append(handler)
            return .joined
        }
        guard requestID == nil else { return .busy }
        requestID = id
        handlers = [handler]
        return .start
    }

    func finish(_ id: UUID) -> [Handler]? {
        guard requestID == id else { return nil }
        let completed = handlers
        requestID = nil
        handlers = []
        return completed
    }
}

@MainActor
final class WatchPhoneBridge: NSObject, WCSessionDelegate {
    static let shared = WatchPhoneBridge()
    private var service: WatchAnalysisService?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private let replies = WatchReplyGroup<WatchReplyHandler>()
    private var pendingID: UUID? { replies.requestID }
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var foregroundObserver: NSObjectProtocol?
    private var settings: AppSettings?

    func start(app: AppModel) {
        guard WCSession.isSupported(), service == nil else { return }
        settings = app.settings
        observePreferences()
        service = .live(app: app, phoneIsActive: { UIApplication.shared.applicationState == .active })
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.pendingID else { return }
                self.cancel(id: id, status: .busy)
            }
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        Task { @MainActor [weak self] in self?.sendPreferences() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessageData data: Data,
                             replyHandler: @escaping (Data) -> Void) {
        let callback = WatchReplyHandler(send: replyHandler)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.receive(data, callback: callback)
        }
    }

    private func receive(_ data: Data, callback: WatchReplyHandler) {
        guard let request = WatchWire.request(from: data) else {
            send(WatchAnalysisReply(requestID: UUID(), status: .invalidRequest), to: callback)
            return
        }
        guard let service else {
            send(WatchAnalysisReply(requestID: request.id, status: .busy), to: callback)
            return
        }
        switch replies.accept(request.id, handler: callback) {
        case .joined: return
        case .busy:
            send(WatchAnalysisReply(requestID: request.id, status: .busy), to: callback)
            return
        case .start: break
        }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Watch screenshot analysis") { [weak self] in
            Task { @MainActor in self?.cancel(id: request.id, status: .timedOut) }
        }
        guard backgroundTask != .invalid else {
            finish(WatchAnalysisReply(requestID: request.id, status: .unavailable))
            return
        }
        operation = Task { [weak self] in
            let reply = await service.analyze(request, onPreview: { [weak self] preview in
                self?.send(preview)
            })
            self?.finish(reply)
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(18)) } catch { return }
            self?.cancel(id: request.id, status: .timedOut)
        }
    }

    private func cancel(id: UUID, status: WatchAnalysisReply.Status) {
        guard pendingID == id else { return }
        service?.cancel()
        operation?.cancel()
        finish(WatchAnalysisReply(requestID: id, status: status))
    }

    private func finish(_ reply: WatchAnalysisReply) {
        guard let callbacks = replies.finish(reply.requestID) else { return }
        operation = nil
        timeout?.cancel()
        timeout = nil
        for callback in callbacks { send(reply, to: callback) }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func send(_ reply: WatchAnalysisReply, to callback: WatchReplyHandler) {
        var reply = reply
        reply.moveDisplayFormat = settings?.moveDisplayFormat
        if let data = try? JSONEncoder().encode(reply), data.count <= WatchWire.maximumReplyBytes {
            callback.send(data)
        } else {
            // This fallback has no thumbnail and always fits. It still carries the request ID.
            let fallback = WatchAnalysisReply(requestID: reply.requestID, status: .unavailable)
            callback.send((try? JSONEncoder().encode(fallback)) ?? Data())
        }
    }

    private func send(_ preview: WatchBoardPreview) {
        guard pendingID == preview.requestID, WCSession.default.activationState == .activated,
              WCSession.default.isReachable,
              let data = try? JSONEncoder().encode(preview), data.count <= WatchWire.maximumReplyBytes else { return }
        // Preview delivery is best effort. A failure must not end or repeat the search.
        // The Sendable adapter also prevents a Swift 6 actor trap on the framework queue.
        let callbacks = WatchMessageCallbacks(onReply: { _ in }, onError: { _ in })
        WCSession.default.sendMessageData(data, replyHandler: nil, errorHandler: callbacks.error)
    }

    private func observePreferences() {
        guard let settings else { return }
        withObservationTracking { _ = settings.watchPreferences } onChange: {
            Task { @MainActor [weak self] in
                self?.observePreferences()
                self?.sendPreferences()
            }
        }
    }

    private func sendPreferences() {
        guard let settings, WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(settings.watchPreferences.applicationContext)
    }
}
