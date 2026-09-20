import CoreGraphics
import Foundation
import SwiftUI
import os

/// How one hand-over from the share extension ended.
enum ShareImportOutcome: Sendable, Hashable {
    /// The URL is not a hand-over URL (`chessbestmove://shared-image?id=<uuid>`).
    case notAShareURL
    /// The app group container is not available to this build.
    case noContainer
    /// This item was already imported. A URL can arrive twice (the extension opens the app,
    /// and the app also looks in the container when it comes to the front); the image is
    /// imported once, so a screenshot shared twice is never charged for twice.
    case alreadyImported
    /// Nothing in the container carries that identifier. It has expired and been cleaned up,
    /// or it was imported by an earlier launch.
    case noSuchItem
    /// The file is there but is not an image the app can read.
    case unreadable
    /// The image went into the normal import flow.
    case imported
}

/// Receives images the share extension put in the app group container.
///
/// The extension writes the image and opens the app at a URL naming it; this reads that file,
/// deletes it and hands the image to `AppModel.importImage`, which is the same entry point
/// every other import uses. From there nothing is special about a shared image: recognition
/// runs, Check position appears when the reading is doubtful, the credit rules decide (a
/// screenshot of a position already analyzed stays free), and the paywall opens when there is
/// no credit left.
///
/// A hand-over is imported at most once. The app claims an item before it reads it, so the URL
/// arriving twice, or the URL and the container sweep both naming the same item, still costs
/// one analysis at most.
@MainActor
final class ShareImportReceiver {
    static let shared = ShareImportReceiver()

    private let inbox: ShareInbox?
    private let log = Logger(subsystem: "com.motomatic.chessbestmove", category: "share")
    /// Items this launch has taken responsibility for.
    private var claimedItemIDs: Set<String> = []

    init(inbox: ShareInbox? = ShareInbox()) {
        self.inbox = inbox
    }

    /// Whether this URL is a hand-over from the share extension. Any other URL is left alone.
    nonisolated static func isShareURL(_ url: URL) -> Bool {
        ShareInboxURL.itemID(from: url) != nil
    }

    // MARK: Entry points

    /// `onOpenURL`: import the image the extension put in the container. Returns whether the
    /// URL was a hand-over URL at all; the import itself finishes later, because decoding runs
    /// off the main actor.
    @discardableResult
    func handle(_ url: URL, app: AppModel) -> Bool {
        guard Self.isShareURL(url) else { return false }
        Task { await receive(url, app: app) }
        return true
    }

    /// The app came to the front. Imports an image the extension handed over but never got the
    /// app opened for (`NSExtensionContext.open` can fail), as long as it is recent enough that
    /// the person is still expecting it, and deletes anything old enough to be forgotten.
    func importPendingItem(app: AppModel, window: TimeInterval = ShareInboxNames.handoverWindow) {
        Task { await receivePendingItem(app: app, window: window) }
    }

    // MARK: The work

    /// The body of `handle(_:app:)`, awaitable for tests.
    @discardableResult
    func receive(_ url: URL, app: AppModel) async -> ShareImportOutcome {
        guard let id = ShareInboxURL.itemID(from: url) else { return .notAShareURL }
        return await importItem(id: id, app: app)
    }

    /// The body of `importPendingItem(app:window:)`, awaitable for tests. It also deletes items
    /// too old to import, so an image the app never opened for cannot stay in the container.
    @discardableResult
    func receivePendingItem(app: AppModel, window: TimeInterval = ShareInboxNames.handoverWindow) async -> ShareImportOutcome {
        guard let inbox else { return .noContainer }
        await Self.removeStaleItems(in: inbox)
        let pending = inbox.items(writtenWithin: window).first { !claimedItemIDs.contains($0.id) }
        guard let pending else { return .noSuchItem }
        log.notice("share: importing an image the extension left in the container")
        return await importItem(id: pending.id, app: app)
    }

    private func importItem(id: String, app: AppModel) async -> ShareImportOutcome {
        guard let inbox else {
            log.error("share: no app group container for \(ShareInboxNames.appGroupIdentifier, privacy: .public)")
            return .noContainer
        }
        guard claimedItemIDs.insert(id).inserted else { return .alreadyImported }
        guard let fileURL = inbox.fileURL(forItemID: id) else { return .noSuchItem }

        let image = await Self.decode(fileURL)
        // The container is not storage: the image is deleted whether or not it could be read.
        inbox.remove(itemID: id)
        guard let image else {
            log.error("share: the shared file is not an image the app can read")
            return .unreadable
        }
        app.importImage(ImportedImage(image: image, source: .shareExtension))
        return .imported
    }

    /// Decodes off the main actor, with the same orientation handling and 4096 px cap as every
    /// other import (`CaptureImageDecoder`).
    ///
    /// The bytes are read into memory first, and the image is decoded from those bytes rather
    /// than from the file. Decoding straight from the file gives back an image that is still
    /// tied to it, and this file is deleted as soon as it has been read: measured on an
    /// iPhone 17 Pro simulator (iOS 26.5), `CaptureImageDecoder.decode(fileURL:)` followed by
    /// deleting the file produced a mostly black image, and recognition then reported no board.
    /// Reading the file first is also exactly what every other import path does.
    nonisolated private static func decode(_ url: URL) async -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CaptureImageDecoder.decode(data: data)
    }

    nonisolated private static func removeStaleItems(in inbox: ShareInbox) async {
        inbox.removeItems(olderThan: ShareInboxNames.staleAge)
    }
}

// MARK: - Wiring

/// Delivers hand-over URLs and, when the app comes to the front, anything the extension left
/// behind. Applied once, by `ChessBestMoveApp`.
private struct ShareImportModifier: ViewModifier {
    let app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                ShareImportReceiver.shared.handle(url, app: app)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                ShareImportReceiver.shared.importPendingItem(app: app)
            }
            .task {
                // A cold launch reports no change of scene phase (the scene is already active
                // when this view appears), so the container is looked at once here as well.
                ShareImportReceiver.shared.importPendingItem(app: app)
                #if DEBUG
                await ShareImportDebug.deliverSampleIfRequested(app: app)
                #endif
            }
    }
}

extension View {
    /// Receives images shared to the app through its share extension.
    func receivesSharedImages(app: AppModel) -> some View {
        modifier(ShareImportModifier(app: app))
    }
}

#if DEBUG
/// `-debugShareImport YES`: hands the DEBUG sample screenshot over exactly as the share
/// extension does (written into the app group container, then delivered as a
/// `chessbestmove://shared-image?id=<uuid>` URL), so the whole receiving path can be exercised
/// by a UI test on a simulator, where the share sheet cannot be driven from the app's own
/// process.
@MainActor
enum ShareImportDebug {
    static let argument = "debugShareImport"

    private static var hasRun = false

    static func deliverSampleIfRequested(app: AppModel) async {
        guard !hasRun, UserDefaults.standard.bool(forKey: argument) else { return }
        hasRun = true
        guard let inbox = ShareInbox(),
              let url = Bundle.main.url(forResource: "DebugSampleScreenshot", withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let id = try? inbox.write(data: data, fileExtension: "png")
        else { return }
        ShareImportReceiver.shared.handle(ShareInboxURL.url(forItemID: id), app: app)
    }
}
#endif
