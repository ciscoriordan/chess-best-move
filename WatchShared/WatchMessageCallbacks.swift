import Foundation
import WatchConnectivity

/// Retain framework error codes without recording screenshots, positions, or error descriptions.
struct WatchTransportFailure: Sendable, Equatable {
    let domain: String
    let code: Int

    init(_ error: any Error) {
        let error = error as NSError
        domain = error.domain
        code = error.code
    }

    var canRetry: Bool {
        guard domain == WCErrorDomain else { return false }
        switch WCError.Code(rawValue: code) {
        case .notReachable, .sessionNotActivated, .sessionInactive, .deliveryFailed: return true
        default: return false
        }
    }
}

/// Watch Connectivity invokes its Objective-C blocks on a background serial queue.
/// Explicitly Sendable entry points prevent Swift 6 from inheriting main-actor isolation
/// before the body runs. A Task inside an actor-isolated block alone cannot prevent that trap.
struct WatchMessageCallbacks: Sendable {
    let reply: @Sendable (Data) -> Void
    let error: @Sendable (any Error) -> Void

    init(onReply: @escaping @MainActor @Sendable (Data) -> Void,
         onError: @escaping @MainActor @Sendable (WatchTransportFailure) -> Void) {
        reply = { data in Task { @MainActor in onReply(data) } }
        error = { error in
            let failure = WatchTransportFailure(error)
            Task { @MainActor in onError(failure) }
        }
    }
}
