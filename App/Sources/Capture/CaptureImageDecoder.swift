import CoreGraphics
import Foundation
import ImageIO

/// Why an imported file could not become an image.
enum CaptureImageDecodingError: Error, Sendable, Hashable {
    /// No bytes at all.
    case empty
    /// ImageIO could not read the data as an image (not HEIC, PNG, JPEG or another format
    /// ImageIO understands, or a damaged file).
    case unreadable
}

/// Decodes imported image data (HEIC, PNG, JPEG and anything else ImageIO reads) into an
/// upright `CGImage`.
///
/// - The EXIF or container orientation is applied, so the returned pixels are in display
///   orientation. Recognition works in image pixel coordinates with a top-left origin, so it
///   must never see a sideways image.
/// - Memory is capped: an image larger than `maximumPixelSide` on its longer side is
///   downscaled while decoding (ImageIO subsamples without decoding the full bitmap first).
///   Smaller images keep their exact pixel size.
///
/// Everything here is synchronous and can be slow for large files: call it off the main
/// actor.
enum CaptureImageDecoder {
    /// The longest side, in pixels, an imported image keeps. Phone screenshots are at most
    /// 2868 px tall, so they are never scaled.
    static let maximumPixelSide = 4096

    /// Decodes `data`. `orientation` overrides the orientation stored in the file (PhotoKit
    /// reports the orientation of an edited asset separately from its data).
    static func decode(data: Data, orientation: CGImagePropertyOrientation? = nil) throws -> CGImage {
        guard !data.isEmpty else { throw CaptureImageDecodingError.empty }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            throw CaptureImageDecodingError.unreadable
        }
        return try decode(source: source, orientation: orientation)
    }

    /// Decodes the image file at `url`.
    static func decode(fileURL url: URL, orientation: CGImagePropertyOrientation? = nil) throws -> CGImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            throw CaptureImageDecodingError.unreadable
        }
        return try decode(source: source, orientation: orientation)
    }

    // MARK: - Implementation

    private static func decode(source: CGImageSource, orientation override: CGImagePropertyOrientation?) throws -> CGImage {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else {
            throw CaptureImageDecodingError.unreadable
        }
        let stored = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        let orientation = override ?? stored.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up

        let decoded: CGImage
        if max(width, height) <= maximumPixelSide {
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
                throw CaptureImageDecodingError.unreadable
            }
            decoded = image
        } else {
            // Downscale while decoding. The transform stays off: orientation is applied below
            // in one place for every path, so an override behaves like a stored orientation.
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSide,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                throw CaptureImageDecodingError.unreadable
            }
            decoded = image
        }
        return try upright(decoded, orientation: orientation)
    }

    /// Redraws `image` so its pixels are in display orientation.
    static func upright(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> CGImage {
        guard orientation != .up else { return image }
        let width = image.width
        let height = image.height
        let outputWidth = orientation.captureSwapsWidthAndHeight ? height : width
        let outputHeight = orientation.captureSwapsWidthAndHeight ? width : height

        let colorSpace: CGColorSpace
        if let own = image.colorSpace, own.model == .rgb {
            colorSpace = own
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureImageDecodingError.unreadable
        }
        context.interpolationQuality = .none
        context.concatenate(transform(for: orientation, outputWidth: CGFloat(outputWidth), outputHeight: CGFloat(outputHeight)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw CaptureImageDecodingError.unreadable }
        return result
    }

    /// The Core Graphics transform (bottom-left origin) that maps stored pixels to display
    /// pixels for an EXIF orientation.
    static func transform(for orientation: CGImagePropertyOrientation, outputWidth w: CGFloat, outputHeight h: CGFloat) -> CGAffineTransform {
        switch orientation {
        case .up:
            return .identity
        case .upMirrored:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored:
            return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .left:
            // Stored image rotated 90 degrees clockwise from display: rotate it back
            // counterclockwise.
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0)
        case .leftMirrored:
            return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: w, ty: h)
        case .right:
            // Stored image rotated 90 degrees counterclockwise from display: rotate it
            // clockwise.
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h)
        case .rightMirrored:
            return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        @unknown default:
            return .identity
        }
    }
}

extension CGImagePropertyOrientation {
    /// Orientations 5 to 8 display the stored image rotated by 90 degrees.
    var captureSwapsWidthAndHeight: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored: true
        default: false
        }
    }
}
