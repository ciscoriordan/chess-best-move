import ChessCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// CPU-only board preview, with the same display orientation as the source screenshot.
enum WatchBoardThumbnail {
    static func center(_ square: Square, whiteAtBottom: Bool, side: CGFloat) -> CGPoint {
        let column = whiteAtBottom ? square.file : 7 - square.file
        let row = whiteAtBottom ? 7 - square.rank : square.rank
        return CGPoint(x: (CGFloat(column) + 0.5) * side / 8,
                       y: (CGFloat(row) + 0.5) * side / 8)
    }

    static func make(board: CGImage?, move: Move, whiteAtBottom: Bool) -> Data? {
        guard let board else { return nil }
        for pixels in [240, 200, 160, 128] {
            let side = CGFloat(pixels)
            guard let context = CGContext(data: nil, width: pixels, height: pixels,
                bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            // Draw the upright bitmap in Quartz coordinates, then switch to top-left for squares.
            context.draw(board, in: CGRect(x: 0, y: 0, width: side, height: side))
            context.translateBy(x: 0, y: side)
            context.scaleBy(x: 1, y: -1)
            let start = center(move.from, whiteAtBottom: whiteAtBottom, side: side)
            let end = center(move.to, whiteAtBottom: whiteAtBottom, side: side)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = side * 0.07
            let shaftEnd = CGPoint(x: end.x - cos(angle) * head * 0.55, y: end.y - sin(angle) * head * 0.55)
            context.setLineCap(.round)
            for (width, color) in [(side * 0.038, CGColor(gray: 0, alpha: 0.85)),
                                    (side * 0.022, CGColor(red: 1, green: 0.84, blue: 0.18, alpha: 1))] {
                context.setStrokeColor(color)
                context.setLineWidth(width)
                context.move(to: start)
                context.addLine(to: shaftEnd)
                context.strokePath()
            }
            context.setFillColor(CGColor(red: 1, green: 0.84, blue: 0.18, alpha: 1))
            context.move(to: end)
            context.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
            context.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
            context.closePath()
            context.fillPath()
            guard let image = context.makeImage() else { return nil }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if bytes.length <= WatchWire.maximumThumbnailBytes { return bytes as Data }
        }
        return nil
    }
}
