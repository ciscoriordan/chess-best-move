import ChessCore
import SwiftUI

/// The root navigation: Home, the pushed flow screens, the sheets and the editor cover.
/// Screen views come from the feature folders (see App/APP_CONTRACT.md).
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        #if DEBUG
        if DebugLaunchOptions.gallery {
            DesignGalleryView()
        } else {
            navigation
                .task { applyDebugLaunchOptions() }
                .task { await reimportSampleAfterFirstPaywallIfRequested() }
        }
        #else
        navigation
        #endif
    }

    private var navigation: some View {
        @Bindable var app = app
        return NavigationStack(path: $app.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .tint(Palette.ink)
        .sheet(item: $app.sheet, onDismiss: { app.sheetDidDismiss() }) { route in
            sheet(for: route)
                .environment(app)
        }
        .fullScreenCover(item: $app.editor) { context in
            PositionEditorView(context: context)
                .environment(app)
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .recognizing(let image):
            RecognizingView(image: image)
        case .boardNotFound(let image):
            BoardNotFoundView(image: image)
        case .checkPosition(let snapshot):
            CheckPositionView(snapshot: snapshot)
        case .analysis(let session):
            AnalysisView(session: session)
        }
    }

    @ViewBuilder
    private func sheet(for route: SheetRoute) -> some View {
        switch route {
        case .paywall(let context):
            PaywallView(context: context) { outcome in
                app.paywallFinished(context, outcome: outcome)
            }
        case .downsell(let context):
            // The downsell sizes its own sheet to its content (a half-height offer).
            DownsellView(context: context) { outcome in
                app.downsellFinished(context, outcome: outcome)
            }
        case .settings:
            SettingsView()
        case .shortcutSetup:
            ShortcutSetupView()
        }
    }

    #if DEBUG
    private func applyDebugLaunchOptions() {
        guard app.path.isEmpty, app.sheet == nil, app.editor == nil else { return }
        if DebugLaunchOptions.autorunSample, let sample = DebugSample.load() {
            app.importImage(sample)
        }
        if let fen = DebugLaunchOptions.analysisFEN, let position = try? Position(fen: fen) {
            let snapshot = BoardSnapshot(position: position, sideToMoveOrigin: .user, assumedCastlingRights: position.castlingRights)
            app.requestAnalysis(of: snapshot, origin: .handSetup)
        }
        switch DebugLaunchOptions.sheet {
        case "paywall":
            app.present(.paywall(PaywallContext(trigger: .creditsExhausted, board: BoardSnapshot(position: .start))))
        case "downsell":
            app.present(.downsell(DownsellContext(board: BoardSnapshot(position: .start))))
        case "settings":
            app.presentSettings()
        case "shortcutSetup":
            app.presentShortcutSetup()
        default:
            break
        }
        if DebugLaunchOptions.editor {
            app.presentEditor(EditorContext(snapshot: BoardSnapshot(position: .start), purpose: .handSetup))
        }
    }

    /// `-debugReimportSampleAfter <seconds>`: the Find Best Move shortcut run again while the
    /// paywall is open.
    private func reimportSampleAfterFirstPaywallIfRequested() async {
        guard let delay = DebugLaunchOptions.reimportSampleAfter, let sample = DebugSample.load() else { return }
        while true {
            if case .paywall? = app.sheet { break }
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
        }
        guard (try? await Task.sleep(for: delay)) != nil else { return }
        app.importImage(ImportedImage(image: sample.image, source: .shortcut))
    }
    #endif
}
