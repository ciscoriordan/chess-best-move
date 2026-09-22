import CoreGraphics
import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftUI

/// Home's import state: photo access, the newest screenshot and its thumbnail, and the work
/// of turning any import (latest screenshot, Photos picker, paste, drag and drop) into an
/// `ImportedImage` for `AppModel.importImage(_:)`.
///
/// Photo access is only requested when the user taps "Use latest screenshot"; refreshing
/// never prompts.
@MainActor
@Observable
final class CaptureHomeModel {
    private(set) var access: CapturePhotoAccess
    private(set) var latest: CaptureScreenshotAsset?
    private(set) var thumbnail: CGImage?
    private(set) var isImporting = false
    /// A one-line error under the actions, cleared by the next import.
    var importError: String?
    /// Presents the Photos picker filtered to screenshots (limited access).
    var showsScreenshotPicker = false

    let analyzed: CaptureAnalyzedScreenshots
    @ObservationIgnored let observer = CapturePhotoLibraryObserver()
    @ObservationIgnored private var thumbnailIdentifier: String?

    /// Target thumbnail size in pixels (48 pt at 3x).
    static let thumbnailPixelSide: CGFloat = 144

    init(analyzed: CaptureAnalyzedScreenshots = CaptureAnalyzedScreenshots()) {
        self.analyzed = analyzed
        access = CapturePhotoLibrary.currentAccess()
    }

    deinit {
        observer.unregister()
    }

    /// Re-reads access and, with full access, the newest screenshot and its thumbnail.
    func refresh() async {
        access = CapturePhotoLibrary.currentAccess()
        guard access == .authorized else {
            latest = nil
            thumbnail = nil
            thumbnailIdentifier = nil
            return
        }
        startObservingIfNeeded()
        let newest = await Self.fetchNewestScreenshot()
        latest = newest
        guard let newest else {
            thumbnail = nil
            thumbnailIdentifier = nil
            return
        }
        if newest.localIdentifier != thumbnailIdentifier {
            let image = await CapturePhotoLibrary.thumbnail(for: newest.localIdentifier, pixelSide: Self.thumbnailPixelSide)
            // Another refresh may have moved on to a newer screenshot meanwhile.
            if latest?.localIdentifier == newest.localIdentifier {
                thumbnail = image
                thumbnailIdentifier = newest.localIdentifier
            }
        }
    }

    // MARK: Import paths

    /// "Use latest screenshot". Asks for access the first time; with limited access opens the
    /// screenshot picker; with denied access calls `openSettings`.
    func useLatestScreenshot(app: AppModel, openSettings: () -> Void) async {
        importError = nil
        access = CapturePhotoLibrary.currentAccess()
        switch access {
        case .notDetermined:
            access = await CapturePhotoLibrary.requestAccess()
            switch access {
            case .authorized:
                await refresh()
                if let latest {
                    await importScreenshot(latest, app: app)
                }
            case .limited:
                showsScreenshotPicker = true
            case .notDetermined, .denied, .restricted:
                break
            }
        case .authorized:
            guard let newest = await Self.fetchNewestScreenshot() else {
                latest = nil
                thumbnail = nil
                return
            }
            await importScreenshot(newest, app: app)
        case .limited:
            showsScreenshotPicker = true
        case .denied:
            openSettings()
        case .restricted:
            break
        }
    }

    /// Imports a photo library screenshot and remembers it as analyzed.
    func importScreenshot(_ asset: CaptureScreenshotAsset, app: AppModel) async {
        beginImport()
        defer { isImporting = false }
        do {
            let image = try await CaptureScreenshotImport.importedImage(for: asset, library: .live)
            analyzed.markAnalyzed(asset.localIdentifier)
            app.importImage(image)
        } catch {
            importError = "Couldn't open your latest screenshot. Try Photos instead."
        }
    }

    /// Imports an item chosen in the Photos picker (no photo access needed).
    func importPickerItem(_ item: PhotosPickerItem, app: AppModel) async {
        beginImport()
        defer { isImporting = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CaptureImageDecodingError.empty
            }
            let image = try await Self.decode(data, orientation: nil)
            if let identifier = item.itemIdentifier {
                analyzed.markAnalyzed(identifier)
            }
            app.importImage(ImportedImage(image: image, source: .photosPicker, photoAssetIdentifier: item.itemIdentifier))
        } catch {
            importError = "Couldn't open that image."
        }
    }

    /// Paste and drag and drop. Returns false when no provider offers an image.
    @discardableResult
    func importItemProviders(_ providers: [NSItemProvider], source: ImportSource, app: AppModel) -> Bool {
        guard CaptureItemProviderLoader.hasImage(providers) else {
            importError = "That isn't an image."
            return false
        }
        beginImport()
        CaptureItemProviderLoader.loadFirstImage(from: providers) { [weak self] data in
            Task { @MainActor in
                await self?.finishProviderImport(data, source: source, app: app)
            }
        }
        return true
    }

    /// Imports raw image data (paste, drop, tests).
    func importData(_ data: Data, source: ImportSource, app: AppModel) async {
        beginImport()
        defer { isImporting = false }
        do {
            let image = try await Self.decode(data, orientation: nil)
            app.importImage(ImportedImage(image: image, source: source))
        } catch {
            importError = "Couldn't open that image."
        }
    }

    // MARK: Helpers

    private func finishProviderImport(_ data: Data?, source: ImportSource, app: AppModel) async {
        guard let data else {
            isImporting = false
            importError = "Couldn't open that image."
            return
        }
        await importData(data, source: source, app: app)
    }

    private func beginImport() {
        importError = nil
        isImporting = true
    }

    private func startObservingIfNeeded() {
        observer.register()
    }

    /// Decodes off the main actor.
    nonisolated static func decode(_ data: Data, orientation: CGImagePropertyOrientation?) async throws -> CGImage {
        try CaptureImageDecoder.decode(data: data, orientation: orientation)
    }

    /// Fetches off the main actor.
    nonisolated static func fetchNewestScreenshot() async -> CaptureScreenshotAsset? {
        CapturePhotoLibrary.newestScreenshot()
    }
}
