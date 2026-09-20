import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Takes the image out of the share sheet's item and puts it in the app group container.
///
/// The extension never decodes an image it does not have to: a file or the raw bytes are
/// copied through untouched, which keeps the memory an app extension is allowed a constant
/// regardless of how large the shared image is, and keeps the orientation metadata that the
/// app's decoder applies. Only an item that is handed over as a `UIImage` object, with no file
/// and no data behind it, is drawn and encoded here, and then at no more than
/// `ShareImageCap.maximumPixelSide` on its longer side, the same cap the app applies to every
/// import.
enum ShareImageIntake {
    /// The first attachment of the share sheet's items that offers an image.
    ///
    /// `NSItemProvider` is not `Sendable`, so the calls that take one stay on the main actor.
    /// That costs nothing: the loading itself happens in the provider's own callbacks, off the
    /// main actor, and so does the copy into the container.
    @MainActor
    static func imageProvider(in inputItems: [Any]) -> NSItemProvider? {
        for case let item as NSExtensionItem in inputItems {
            for provider in item.attachments ?? [] {
                if provider.registeredContentTypes.contains(where: { $0.conforms(to: .image) }) { return provider }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { return provider }
                if provider.canLoadObject(ofClass: UIImage.self) { return provider }
            }
        }
        return nil
    }

    /// Writes the provider's image into `inbox` and returns the item identifier the app is
    /// opened with.
    @MainActor
    static func store(_ provider: NSItemProvider, into inbox: ShareInbox) async throws -> String {
        let type = provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? .image
        if let id = try? await copyFile(from: provider, type: type, into: inbox) { return id }
        if let id = try? await copyData(from: provider, type: type, into: inbox) { return id }
        if provider.canLoadObject(ofClass: UIImage.self) {
            return try await drawImage(from: provider, into: inbox)
        }
        throw ShareIntakeError.unreadable
    }

    // MARK: The three ways an item arrives

    /// A file the sharing app already has on disk (the usual case for Photos and for the
    /// screenshot preview). It is copied byte for byte; nothing is decoded.
    @MainActor
    private static func copyFile(from provider: NSItemProvider, type: UTType, into inbox: ShareInbox) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                // The file is deleted as soon as this handler returns, so the copy happens here.
                guard let url else {
                    continuation.resume(throwing: error ?? ShareIntakeError.unreadable)
                    return
                }
                do {
                    let id = try inbox.write(copyingFileAt: url, fileExtension: type.preferredFilenameExtension)
                    continuation.resume(returning: id)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Raw bytes, for an item that has no file behind it.
    @MainActor
    private static func copyData(from provider: NSItemProvider, type: UTType, into inbox: ShareInbox) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, error in
                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: error ?? ShareIntakeError.unreadable)
                    return
                }
                do {
                    let id = try inbox.write(data: data, fileExtension: type.preferredFilenameExtension)
                    continuation.resume(returning: id)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// An item handed over as a `UIImage` object. This is the only path that costs memory, so
    /// the image is drawn down to `ShareImageCap.maximumPixelSide` before it is encoded.
    @MainActor
    private static func drawImage(from provider: NSItemProvider, into inbox: ShareInbox) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, error in
                guard let image = object as? UIImage, let cgImage = image.cgImage else {
                    continuation.resume(throwing: error ?? ShareIntakeError.unreadable)
                    return
                }
                do {
                    let data = try ShareImageCap.encodedPNG(of: cgImage)
                    let id = try inbox.write(data: data, fileExtension: UTType.png.preferredFilenameExtension)
                    continuation.resume(returning: id)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
