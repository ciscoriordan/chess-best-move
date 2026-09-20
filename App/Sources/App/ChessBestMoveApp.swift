import SwiftUI
#if DEBUG
import os
#endif

@main
struct ChessBestMoveApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        DebugLaunchOptions.resetStateIfRequested()
        #endif
        let model = AppModel.live()
        model.makeCurrent()
        // The Transaction.updates listener must run from launch so purchases made outside
        // the app (Ask to Buy approvals, renewals, refunds) are never missed. Not in the unit
        // test host: the tests build their own store stacks, and a live listener there would
        // consume their test transactions.
        if AppLaunch.current.startsStore {
            model.store.start()
        }
        #if DEBUG
        Logger(subsystem: "com.motomatic.chessbestmove", category: "launch")
            .notice("launch: startsStore=\(AppLaunch.current.startsStore, privacy: .public) warmsUpRecognition=\(AppLaunch.current.warmsUpRecognition, privacy: .public)")
        #endif
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // The window's width, published once here so the side gutter never measures a
                // view its own padding took part in sizing (DesignSystem/Metrics.swift).
                .measuresWindowWidth()
                .background(Palette.canvas.ignoresSafeArea())
                // An image shared to the app from the screenshot preview or from Photos
                // (App/Sources/App/ShareImport.swift). It enters the flow where a Photos
                // import does.
                .receivesSharedImages(app: model)
                .task {
                    // Loads the recognition model in the background shortly after the first
                    // frame, so the first import does not wait for it (AppModel).
                    guard AppLaunch.current.warmsUpRecognition else { return }
                    await model.warmUpRecognition(after: AppModel.recognitionWarmUpDelay)
                }
                #if DEBUG
                .preferredColorScheme(DebugLaunchOptions.colorScheme)
                #endif
        }
    }
}

/// What the app starts at launch, which depends on whether this process hosts the unit tests.
struct AppLaunch: Equatable, Sendable {
    /// Start the live store's `Transaction.updates` listener.
    var startsStore: Bool
    /// Load the recognition model in the background after launch.
    var warmsUpRecognition: Bool

    /// The scheme's Test action sets `CHESS_BEST_MOVE_TESTS=1` (project.yml). Only the process
    /// that hosts the unit tests also has XCTest's configuration in its environment; an app
    /// launched by UI tests does not, and starts like a normal launch.
    static func make(environment: [String: String]) -> AppLaunch {
        let hostsUnitTests = environment["CHESS_BEST_MOVE_TESTS"] == "1"
            && (environment["XCTestConfigurationFilePath"] != nil
                || environment["XCTestSessionIdentifier"] != nil
                || environment["XCTestBundlePath"] != nil)
        return AppLaunch(startsStore: !hostsUnitTests, warmsUpRecognition: !hostsUnitTests)
    }

    static let current = make(environment: ProcessInfo.processInfo.environment)
}
