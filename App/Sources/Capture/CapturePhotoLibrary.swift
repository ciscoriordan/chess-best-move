import CoreGraphics
import Foundation
import ImageIO
import os
import Photos
import UIKit

/// PhotoKit access for Home's "Use latest screenshot" and for the new-screenshot row that the
/// Analysis result and Check position show (design.md 9.4).
///
/// Every function is nonisolated, and the PhotoKit completion handlers are created here
/// rather than in main-actor code, because PhotoKit may call them on a background queue.
/// Only Sendable values (identifiers, dates, `Data`, `CGImage`) leave this type.
enum CapturePhotoLibrary {
    /// The current access level. Never prompts.
    static func currentAccess() -> CapturePhotoAccess {
        access(from: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Shows the system prompt if access was never asked for.
    static func requestAccess() async -> CapturePhotoAccess {
        access(from: await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func access(from status: PHAuthorizationStatus) -> CapturePhotoAccess {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// The newest image whose media subtypes include `.photoScreenshot`, or nil. Returns nil
    /// without touching the library unless access was granted.
    static func newestScreenshot() -> CaptureScreenshotAsset? {
        newestScreenshots(limit: 1).first
    }

    /// Up to `limit` screenshots, newest first. Empty without touching the library unless
    /// access was granted.
    static func newestScreenshots(limit: Int) -> [CaptureScreenshotAsset] {
        let access = currentAccess()
        guard access == .authorized || access == .limited else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0",
            Int(PHAssetMediaSubtype.photoScreenshot.rawValue)
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        options.includeHiddenAssets = false
        var screenshots: [CaptureScreenshotAsset] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
            screenshots.append(CaptureScreenshotAsset(localIdentifier: asset.localIdentifier, creationDate: asset.creationDate))
        }
        return screenshots
    }

    /// Whether the library still holds the asset (it was not deleted, and access still covers it).
    /// False without touching the library unless access was granted: a fetch before that can
    /// show the permission prompt.
    static func assetExists(_ localIdentifier: String) -> Bool {
        let access = currentAccess()
        guard access == .authorized || access == .limited else { return false }
        return PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).count > 0
    }

    /// A square thumbnail of at least `pixelSide` pixels, cropped to fill.
    static func thumbnail(for localIdentifier: String, pixelSide: CGFloat) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: pixelSide, height: pixelSide),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                guard !degraded else { return }
                continuation.resume(returning: image?.cgImage)
            }
        }
    }

    enum LoadError: Error, Sendable {
        case assetMissing
        case noData
    }

    /// The asset's current image data (HEIC, PNG or JPEG) and its display orientation,
    /// downloading it from iCloud if needed.
    static func imageData(for localIdentifier: String) async throws -> (data: Data, orientation: CGImagePropertyOrientation) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw LoadError.assetMissing
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let result: (Data, CGImagePropertyOrientation)? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, orientation, _ in
                continuation.resume(returning: data.map { ($0, orientation) })
            }
        }
        guard let result else { throw LoadError.noData }
        return result
    }
}

/// Forwards photo library changes into `AsyncStream`s, so Home can refresh the newest
/// screenshot while it is on screen.
///
/// Every call to `changes()` returns a new stream with its own continuation. Home iterates
/// the changes in a view `.task`, which SwiftUI cancels whenever a flow screen is pushed over
/// Home; cancelling the iteration finishes that stream for good. A single shared stream would
/// then end at once for the `.task` that starts when Home appears again, and later changes
/// would be dropped.
///
/// Home is not the only owner. Each flow screen that shows the new-screenshot row (the
/// Analysis result and Check position, design.md 9.4) has an observer of its own, owned by
/// that screen's `CaptureNewScreenshotOfferModel` and unregistered when the model goes away,
/// so leaving one screen never ends another's changes.
final class CapturePhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
        var isRegistered = false
        var isFinished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A new stream that yields once per photo library change (coalesced to the newest while
    /// the consumer is busy). It finishes when the consuming task is cancelled or when
    /// `unregister()` is called.
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let added = state.withLock { state -> Bool in
            guard !state.isFinished else { return false }
            state.continuations[id] = continuation
            return true
        }
        guard added else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { state in
                _ = state.continuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    /// How many streams from `changes()` are still being consumed.
    var subscriberCount: Int {
        state.withLock { $0.continuations.count }
    }

    /// Registers with the photo library once. Call only after access was granted:
    /// registering earlier can show the permission prompt.
    func register() {
        let shouldRegister = state.withLock { state -> Bool in
            defer { state.isRegistered = true }
            return !state.isRegistered
        }
        if shouldRegister { PHPhotoLibrary.shared().register(self) }
    }

    /// Unregisters if `register()` was called (otherwise does not touch the photo library) and
    /// finishes every stream, including ones requested later.
    func unregister() {
        let (wasRegistered, continuations) = state.withLock { state in
            defer {
                state.isRegistered = false
                state.isFinished = true
                state.continuations = [:]
            }
            return (state.isRegistered, Array(state.continuations.values))
        }
        if wasRegistered { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
        for continuation in continuations { continuation.finish() }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        notifySubscribers()
    }

    /// Yields one change to every current stream.
    func notifySubscribers() {
        let continuations = state.withLock { Array($0.continuations.values) }
        for continuation in continuations { continuation.yield() }
    }
}

/// The photo library as the new-screenshot row uses it (design.md 9.4). `live` is PhotoKit;
/// the unit tests and `-captureFakeNewScreenshot` pass their own, so neither touches the real
/// library.
///
/// The async closures are nonisolated, so a fetch and a PhotoKit callback run off the main actor,
/// as `CaptureHomeModel.fetchNewestScreenshot` does.
struct CapturePhotoLibraryClient: Sendable {
    var currentAccess: @Sendable () -> CapturePhotoAccess
    /// Up to `limit` screenshots, newest first.
    var newestScreenshots: @Sendable (_ limit: Int) async -> [CaptureScreenshotAsset]
    var assetExists: @Sendable (_ localIdentifier: String) async -> Bool
    var thumbnail: @Sendable (_ localIdentifier: String, _ pixelSide: CGFloat) async -> CGImage?
    var imageData: @Sendable (_ localIdentifier: String) async throws -> (data: Data, orientation: CGImagePropertyOrientation)
    /// Registers `observer` with PhotoKit. Call only with full access: registering earlier can
    /// show the permission prompt.
    var startObserving: @Sendable (CapturePhotoLibraryObserver) -> Void

    static let live = CapturePhotoLibraryClient(
        currentAccess: { CapturePhotoLibrary.currentAccess() },
        newestScreenshots: { CapturePhotoLibrary.newestScreenshots(limit: $0) },
        assetExists: { CapturePhotoLibrary.assetExists($0) },
        thumbnail: { await CapturePhotoLibrary.thumbnail(for: $0, pixelSide: $1) },
        imageData: { try await CapturePhotoLibrary.imageData(for: $0) },
        startObserving: { $0.register() }
    )
}

/// Loads image data from item providers (paste, drag and drop). The completion handler is
/// created here, outside main-actor code, because item providers call it on a background
/// queue.
enum CaptureItemProviderLoader {
    /// Whether any provider offers an image.
    static func hasImage(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier("public.image") }
    }

    /// Starts loading the first image among `providers`; `completion` receives its data, or
    /// nil if there is none or loading failed.
    static func loadFirstImage(from providers: [NSItemProvider], completion: @escaping @Sendable (Data?) -> Void) {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.image") }) else {
            completion(nil)
            return
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
            completion(data)
        }
    }
}
