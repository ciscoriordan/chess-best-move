import Foundation

/// Watch Connectivity invokes its Objective-C blocks on a background serial queue.
/// Explicitly Sendable entry points prevent Swift 6 from inheriting main-actor isolation
/// before the body runs. A Task inside an actor-isolated block alone cannot prevent that trap.
struct WatchMessageCallbacks: Sendable {
    let reply: @Sendable (Data) -> Void
    let error: @Sendable (any Error) -> Void

    init(onReply: @escaping @MainActor @Sendable (Data) -> Void,
         onError: @escaping @MainActor @Sendable () -> Void) {
        reply = { data in Task { @MainActor in onReply(data) } }
        error = { _ in Task { @MainActor in onError() } }
    }
}
