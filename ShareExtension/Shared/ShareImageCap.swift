import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The size cap an image is held to when the share extension has to draw one itself.
///
/// The extension copies a file or raw bytes through untouched, so nothing is decoded and its
/// memory does not grow with the size of the shared image. Only an item handed over as a
/// `UIImage` object has to be drawn and encoded, and then this caps it, at the same size the
/// app's own decoder caps every import (`CaptureImageDecoder.maximumPixelSide`). An app
/// extension is given a fraction of the memory an app gets, so this is the one place where a
/// very large image could cost it anything.
///
/// This file is compiled into both targets, so the cap the extension applies and the cap the
/// app applies cannot drift apart.
enum ShareImageCap {
    /// The longest side, in pixels, an image keeps.
    static let maximumPixelSide = 4096

    /// `image` as PNG bytes, with its longer side capped at `maximumPixelSide`.
    static func encodedPNG(of image: CGImage) throws -> Data {
        let capped = try cappedToMaximumSide(image)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ShareIntakeError.unreadable
        }
        CGImageDestinationAddImage(destination, capped, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShareIntakeError.unreadable }
        return output as Data
    }

    /// `image` redrawn so its longer side is at most `maximumPixelSide`, keeping its proportions;
    /// the image itself when it is already small enough.
    static func cappedToMaximumSide(_ image: CGImage) throws -> CGImage {
        let longerSide = max(image.width, image.height)
        guard longerSide > maximumPixelSide else { return image }
        let scale = CGFloat(maximumPixelSide) / CGFloat(longerSide)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ShareIntakeError.unreadable
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw ShareIntakeError.unreadable }
        return scaled
    }
}

/// Why a shared item could not be handed over to the app.
enum ShareIntakeError: Error, Sendable, Hashable {
    /// The share sheet handed over something that is not an image.
    case notAnImage
    /// The item says it is an image, but nothing could be read from it.
    case unreadable
    /// The app group container is missing (see `ShareInbox.Failure.noContainer`).
    case noContainer
    /// The image could not be written into the container.
    case cannotWrite
}
