#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import os
import UIKit

/// `-captureFakeNewScreenshot YES`: the new-screenshot row (design.md 9.4) reads a stand-in
/// photo library instead of PhotoKit, so it can be exercised without Photos, a permission
/// prompt or `simctl addmedia` (`CaptureNewScreenshotUITests`).
///
/// The stand-in has full access and holds one screenshot, the DEBUG sample, which appears the
/// first time the app goes to the background and is dated at that moment: a screenshot taken
/// while the user was away. It never registers with PhotoKit and never reports a change. It is
/// DEBUG only because `DebugSampleScreenshot.png` is excluded from Release builds.
enum CaptureNewScreenshotDebug {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "captureFakeNewScreenshot")
    }

    /// Built the first time a flow screen creates its model, which is before the app can first
    /// go to the background from that screen.
    static let library: CapturePhotoLibraryClient = {
        let screenshot = OSAllocatedUnfairLock<CaptureScreenshotAsset?>(initialState: nil)
        // The notification center keeps the registration for the life of the process.
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            screenshot.withLock { current in
                if current == nil {
                    current = CaptureScreenshotAsset(
                        localIdentifier: "debug-new-screenshot-" + UUID().uuidString,
                        creationDate: Date()
                    )
                }
            }
        }
        return CapturePhotoLibraryClient(
            currentAccess: { .authorized },
            newestScreenshots: { _ in screenshot.withLock { $0.map { [$0] } ?? [] } },
            assetExists: { identifier in screenshot.withLock { $0?.localIdentifier == identifier } },
            thumbnail: { _, pixelSide in thumbnail(pixelSide: pixelSide) },
            imageData: { _ in
                guard let data = sampleData() else { throw CapturePhotoLibrary.LoadError.noData }
                return (data, .up)
            },
            startObserving: { _ in }
        )
    }()

    private static func sampleData() -> Data? {
        Bundle.main.url(forResource: "DebugSampleScreenshot", withExtension: "png").flatMap { try? Data(contentsOf: $0) }
    }

    /// The sample, scaled so its shorter side is `pixelSide`, as PhotoKit's aspect-fill
    /// thumbnail is.
    private static func thumbnail(pixelSide: CGFloat) -> CGImage? {
        guard let data = sampleData(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        let longest = pixelSide * max(width, height) / min(width, height)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longest.rounded(.up)),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
#endif
