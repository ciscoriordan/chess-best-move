import SwiftUI

@main
struct ChessBestMoveWatchApp: App {
    @State private var model = WatchModel()
    var body: some Scene {
        WindowGroup {
            NavigationStack { WatchContentView(model: model) }
                #if DEBUG
                .transformEnvironment(\.dynamicTypeSize) { size in
                    if ProcessInfo.processInfo.arguments.contains("-watchLargeText") { size = .xxxLarge }
                }
                #endif
        }
    }
}
