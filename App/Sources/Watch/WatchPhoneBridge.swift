import Foundation
import UIKit
import WatchConnectivity

/// The callback is immutable and invoked exactly once on the main actor.
private struct WatchReplyHandler: @unchecked Sendable {
    let send: (Data) -> Void
}

@MainActor
final class WatchPhoneBridge: NSObject, WCSessionDelegate {
    static let shared = WatchPhoneBridge()
    private var service: WatchAnalysisService?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var pendingID: UUID?
    private var pendingReply: WatchReplyHandler?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var foregroundObserver: NSObjectProtocol?

    func start(app: AppModel) {
        guard WCSession.isSupported(), service == nil else { return }
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
                             error: (any Error)?) {}
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
        guard pendingID == nil, let service else {
            send(WatchAnalysisReply(requestID: request.id, status: .busy), to: callback)
            return
        }
        pendingID = request.id
        pendingReply = callback
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Watch screenshot analysis") { [weak self] in
            Task { @MainActor in self?.cancel(id: request.id, status: .timedOut) }
        }
        guard backgroundTask != .invalid else {
            finish(WatchAnalysisReply(requestID: request.id, status: .unavailable))
            return
        }
        operation = Task { [weak self] in
            let reply = await service.analyze(request)
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
        guard pendingID == reply.requestID, let callback = pendingReply else { return }
        pendingID = nil
        pendingReply = nil
        operation = nil
        timeout?.cancel()
        timeout = nil
        send(reply, to: callback)
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func send(_ reply: WatchAnalysisReply, to callback: WatchReplyHandler) {
        if let data = try? JSONEncoder().encode(reply), data.count <= WatchWire.maximumReplyBytes {
            callback.send(data)
        } else {
            // This fallback has no thumbnail and always fits. It still carries the request ID.
            let fallback = WatchAnalysisReply(requestID: reply.requestID, status: .unavailable)
            callback.send((try? JSONEncoder().encode(fallback)) ?? Data())
        }
    }
}
