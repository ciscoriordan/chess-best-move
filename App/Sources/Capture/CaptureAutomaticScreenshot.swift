import Foundation
import SwiftUI

/// Checks silently before navigating. PhotoKit, decoding and recognition reuse the manual
/// import path, but no route or credit decision changes until a chessboard is found.
@MainActor
final class CaptureAutomaticScreenshotModel {
    static let checkedKey = "capture.automaticallyCheckedScreenshots"
    let observer = CapturePhotoLibraryObserver()
    private let library: CapturePhotoLibraryClient
    private let activity: CaptureAppActivity
    private let defaults: UserDefaults
    private let analyzed: CaptureAnalyzedScreenshots
    private let now: () -> Date
    private var monitoringID: UUID?

    init(library: CapturePhotoLibraryClient = .live,
         activity: CaptureAppActivity = .shared,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.library = library
        self.activity = activity
        self.defaults = defaults
        self.analyzed = CaptureAnalyzedScreenshots(defaults: defaults)
        self.now = now
    }

    deinit { observer.unregister() }

    static func make() -> CaptureAutomaticScreenshotModel {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "captureAutomaticScreenshot") != nil {
            return CaptureAutomaticScreenshotModel(library: CaptureNewScreenshotDebug.library)
        }
        #endif
        return CaptureAutomaticScreenshotModel()
    }

    static func canImport(into app: AppModel) -> Bool {
        guard app.settings.automaticallyAnalyzesScreenshots,
              app.store.hasLoadedEntitlements,
              app.sheet == nil, app.editor == nil, app.pendingAnalysis == nil,
              app.settings.pendingApprovalBoard == nil else { return false }
        switch app.engine.phase {
        case .preparing, .searching: return false
        default: break
        }
        switch app.path.last {
        case nil: return true
        case .analysis(let session): return session.isCreditCommitted
        default: return false
        }
    }

    /// The caller captures the revision on activation, before the short launch delay, so
    /// choosing an image, opening Settings or editing a position takes priority throughout.
    func check(app: AppModel, revision: Int, activatedAt: Date,
               isImporting: () -> Bool = { false }) async {
        func isCurrent() -> Bool {
            !Task.isCancelled && activity.log.awaySince == nil
                && app.screenshotInteractionRevision == revision
                && Self.canImport(into: app) && !isImporting()
                && library.currentAccess() == .authorized
        }
        guard isCurrent() else { return }
        // Only the newest screenshot: never fall back to an older chessboard when the
        // newest image is unrelated, already handled or deliberately selected by the user.
        let candidates = await library.newestScreenshots(1)
        guard isCurrent(), let asset = candidates.first,
              CaptureRecentScreenshotPolicy.shouldPromote(asset, access: .authorized, analyzed: analyzed, now: now()),
              let date = asset.creationDate,
              date <= activatedAt.addingTimeInterval(CaptureRecentScreenshotPolicy.futureTolerance),
              date > (app.settings.explicitScreenshotSelectionDate ?? .distantPast),
              !activity.log.isScreenshotOfThisApp(date, within: CaptureNewScreenshotPolicy.ownScreenshotWindow),
              !(defaults.stringArray(forKey: Self.checkedKey) ?? []).contains(asset.localIdentifier)
        else { return }
        guard let image = try? await CaptureScreenshotImport.importedImage(for: asset, library: library),
              isCurrent() else { return }
        let outcome = await app.recognition.recognize(image)
        guard isCurrent(), CaptureRecentScreenshotPolicy.isRecent(date, now: now()) else { return }
        // A newer screenshot may have arrived while recognition was running.
        let latest = await library.newestScreenshots(1).first
        guard isCurrent(), latest?.localIdentifier == asset.localIdentifier else { return }
        var checked = defaults.stringArray(forKey: Self.checkedKey) ?? []
        checked.append(asset.localIdentifier)
        defaults.set(Array(checked.suffix(CaptureAnalyzedScreenshots.limit)), forKey: Self.checkedKey)
        switch outcome {
        case .confident(let snapshot):
            analyzed.markAnalyzed(asset.localIdentifier)
            if app.store.isPro {
                app.requestAnalysis(of: snapshot, origin: .recognition)
            } else {
                app.automaticScreenshotConfirmationID = snapshot.id
                app.path = [.checkPosition(snapshot)]
            }
        case .needsCheck(let snapshot):
            analyzed.markAnalyzed(asset.localIdentifier)
            app.path = [.checkPosition(snapshot)]
        case .boardNotFound, .invalidImage:
            break
        }
    }

    /// A single task per foreground interval; canceling it prevents a late PhotoKit or
    /// recognition result from navigating after backgrounding. Subscribe before the first
    /// check to catch screenshots whose save finishes just after the app opens.
    func monitor(app: AppModel, isImporting: () -> Bool) async {
        guard library.currentAccess() == .authorized else { return }
        let id = UUID()
        monitoringID = id
        let revision = app.screenshotInteractionRevision
        let activatedAt = now()
        let changes = observer.changes()
        library.startObserving(observer)
        defer { if monitoringID == id { observer.unregister() } }
        // Give incoming Shortcut, widget and share requests the first opportunity to run.
        guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
        await check(app: app, revision: revision, activatedAt: activatedAt, isImporting: isImporting)
        for await _ in changes {
            guard !Task.isCancelled else { return }
            await check(app: app, revision: revision, activatedAt: activatedAt, isImporting: isImporting)
        }
    }
}

private struct CaptureAutomaticScreenshotModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CaptureAutomaticScreenshotModel.make()
    let capture: CaptureHomeModel

    private struct Trigger: Equatable {
        let phase: ScenePhase
        let enabled: Bool
        let entitlementsLoaded: Bool
    }

    func body(content: Content) -> some View {
        content.task(id: Trigger(phase: scenePhase,
                                 enabled: app.settings.automaticallyAnalyzesScreenshots,
                                 entitlementsLoaded: app.store.hasLoadedEntitlements)) {
            guard AppLaunch.current.startsStore, scenePhase == .active,
                  app.settings.automaticallyAnalyzesScreenshots,
                  app.store.hasLoadedEntitlements else { return }
            await model.monitor(app: app) { capture.isImporting || capture.showsScreenshotPicker || capture.showsPhotoPicker }
        }
    }
}

extension View {
    func automaticallyAnalyzesScreenshots(capture: CaptureHomeModel) -> some View {
        modifier(CaptureAutomaticScreenshotModifier(capture: capture))
    }
}
