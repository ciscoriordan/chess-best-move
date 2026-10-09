import ChessCore
import SwiftUI

/// A saved choice, independent of light/dark mode and recognition confidence.
enum BoardAppearance: String, CaseIterable, Identifiable {
    case green
    case screenshot
    case standard

    var id: String { rawValue }
    var label: String {
        switch self {
        case .green: "Classic green"
        case .screenshot: "Match screenshot"
        case .standard: "Standard board"
        }
    }
}

/// Every feature uses this presentation. Unchanged squares retain the actual screenshot;
/// edits replace only the affected squares, borrowing piece artwork from that screenshot.
struct ScreenshotStyledBoard: View {
    let snapshot: BoardSnapshot
    let appearance: BoardAppearance
    var board: [Piece?]? = nil
    var showsCoordinates = true

    var body: some View {
        if appearance == .screenshot, let image = snapshot.boardImage {
            let artwork = ScreenshotBoardArtwork(snapshot: snapshot, image: image)
            let board = board ?? snapshot.position.board
            Canvas { context, size in
                let side = min(size.width, size.height)
                let placement = artwork.placement
                context.draw(Image(decorative: image, scale: 1), in: CGRect(
                    x: placement.minX * side, y: placement.minY * side,
                    width: placement.width * side, height: placement.height * side
                ))
                if let original = snapshot.recognizedBoard, original.count == 64 {
                    for index in 0..<64 where board.indices.contains(index) && board[index] != original[index] {
                        guard let square = Square(index: index) else { continue }
                        let rect = BoardGeometry.rect(of: square, side: side, whiteAtBottom: snapshot.whiteAtBottom)
                        context.fill(Path(rect), with: .color(artwork.background(for: square)))
                        if let piece = board[index] {
                            artwork.draw(piece, in: rect, context: &context)
                        }
                    }
                }
            }
            .background(Palette.sunken)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityIgnoresInvertColors()
        } else {
            DiagramBoard(board: board ?? snapshot.position.board, whiteAtBottom: snapshot.whiteAtBottom,
                         showsCoordinates: showsCoordinates, usesGreenPalette: appearance == .green)
        }
    }
}

/// Uses complete, confidently recognized source cells only. A screenshot cannot supply a
/// piece that is absent from it; in that case only that newly added piece uses our glyph.
/// Never replace the whole board because a piece was edited or recognition was uncertain.
struct ScreenshotBoardArtwork {
    let snapshot: BoardSnapshot
    let image: CGImage
    let placement: CGRect

    init(snapshot: BoardSnapshot, image: CGImage) {
        self.snapshot = snapshot
        self.image = image
        placement = BoardScreenshot.placement(imageWidth: image.width, imageHeight: image.height,
                                               boardRect: snapshot.boardRect)
    }

    func tile(at square: Square) -> CGImage? {
        let unit = BoardGeometry.rect(of: square, side: 1, whiteAtBottom: snapshot.whiteAtBottom)
        let rect = CGRect(x: (unit.minX - placement.minX) / placement.width * CGFloat(image.width),
                          y: (unit.minY - placement.minY) / placement.height * CGFloat(image.height),
                          width: unit.width / placement.width * CGFloat(image.width),
                          height: unit.height / placement.height * CGFloat(image.height))
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) else { return nil }
        return image.cropping(to: rect.intersection(bounds))
    }

    private func isReliable(_ square: Square) -> Bool {
        guard !snapshot.lowConfidenceSquares.contains(square) else { return false }
        if let confidence = snapshot.squareConfidences, confidence.indices.contains(square.index),
           confidence[square.index] < 0.85 { return false }
        return true
    }

    func background(for square: Square) -> Color {
        // Prefer an empty square of the same color so highlights and pieces don't tint edits.
        if let original = snapshot.recognizedBoard, original.count == 64 {
            for index in 0..<64 where original[index] == nil {
                guard let donor = Square(index: index), isReliable(donor),
                      (donor.file + donor.rank) % 2 == (square.file + square.rank) % 2,
                      let tile = tile(at: donor), let pixels = Pixels(tile) else { continue }
                return pixels.backgroundColor
            }
        }
        if let tile = tile(at: square), let pixels = Pixels(tile) { return pixels.backgroundColor }
        return (square.file + square.rank).isMultiple(of: 2) ? Palette.diagramDark : Palette.diagramLight
    }

    func sprite(for piece: Piece) -> CGImage? {
        guard let original = snapshot.recognizedBoard, original.count == 64 else { return nil }
        for index in 0..<64 where original[index] == piece {
            guard let square = Square(index: index), isReliable(square),
                  let tile = tile(at: square), let pixels = Pixels(tile),
                  let sprite = pixels.removingBackground() else { continue }
            return sprite
        }
        return nil
    }

    func draw(_ piece: Piece, in rect: CGRect, context: inout GraphicsContext) {
        if let sprite = sprite(for: piece) {
            context.draw(Image(decorative: sprite, scale: 1), in: rect)
        } else {
            PieceGlyphRenderer.draw(piece, in: rect, context: &context)
        }
    }

    /// Small bounded working images keep edits and drag previews inexpensive. Flood-fill
    /// removes only background connected to the edge, preserving enclosed piece details.
    private struct Pixels {
        let side: Int
        var bytes: [UInt8]
        let background: [UInt8]

        init?(_ image: CGImage) {
            let side = min(192, max(64, max(image.width, image.height)))
            self.side = side
            var data = [UInt8](repeating: 0, count: side * side * 4)
            let success = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard success else { return nil }
            bytes = data
            // Median of inset corners avoids coordinate labels on the outer edges.
            let near = side / 10, far = side - near - 1
            let offsets = [(near, near), (far, near), (near, far), (far, far)].map { ($0.1 * side + $0.0) * 4 }
            background = (0..<3).map { channel in offsets.map { data[$0 + channel] }.sorted()[1] }
        }

        var backgroundColor: Color {
            Color(red: Double(background[0]) / 255, green: Double(background[1]) / 255,
                  blue: Double(background[2]) / 255)
        }

        func removingBackground() -> CGImage? {
            var result = bytes
            var visited = [Bool](repeating: false, count: side * side)
            var queue: [Int] = []
            for i in 0..<side {
                queue.append(i)
                queue.append((side - 1) * side + i)
                queue.append(i * side)
                queue.append(i * side + side - 1)
            }
            var cursor = 0
            var removed = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                guard !visited[index] else { continue }
                visited[index] = true
                let offset = index * 4
                let distance = (0..<3).reduce(0) { $0 + abs(Int(bytes[offset + $1]) - Int(background[$1])) }
                guard distance < 110 else { continue }
                for channel in 0..<4 { result[offset + channel] = 0 }
                removed += 1
                let x = index % side, y = index / side
                if x > 0 { queue.append(index - 1) }
                if x + 1 < side { queue.append(index + 1) }
                if y > 0 { queue.append(index - side) }
                if y + 1 < side { queue.append(index + side) }
            }
            // A covered or textured tile with no separable background isn't a usable sprite.
            guard removed > side * side / 5, removed < side * side * 97 / 100 else { return nil }
            // Coordinate labels and other detached edge decorations are not part of the
            // piece. Keep components reaching the center region, including enclosed details.
            // Eight neighbors preserve diagonally connected outlines and narrow crowns.
            visited = Array(repeating: false, count: side * side)
            var retained = 0
            for start in 0..<(side * side) where !visited[start] && result[start * 4 + 3] > 0 {
                var component = [start]
                visited[start] = true
                var cursor = 0
                var touchesCenter = false
                while cursor < component.count {
                    let index = component[cursor]
                    cursor += 1
                    let x = index % side, y = index / side
                    touchesCenter = touchesCenter || (x >= side / 5 && x < side * 4 / 5
                        && y >= side / 8 && y < side * 7 / 8)
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < side, ny >= 0, ny < side else { continue }
                            let neighbor = ny * side + nx
                            if !visited[neighbor], result[neighbor * 4 + 3] > 0 {
                                visited[neighbor] = true
                                component.append(neighbor)
                            }
                        }
                    }
                }
                if touchesCenter {
                    retained += component.count
                } else {
                    for index in component {
                        for c in 0..<4 { result[index * 4 + c] = 0 }
                    }
                }
            }
            guard retained > side * side / 100 else { return nil }
            guard let provider = CGDataProvider(data: Data(result) as CFData) else { return nil }
            return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
}
