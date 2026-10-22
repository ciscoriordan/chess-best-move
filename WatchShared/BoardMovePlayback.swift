import CoreText
import Foundation
import SwiftUI

/// Small, image-free animation data. The phone applies legal moves, including captures,
/// castling, en passant and promotion; the Watch only draws the supplied board states.
struct BoardMovePlayback: Codable, Sendable, Equatable {
    struct MovingPiece: Codable, Sendable, Equatable {
        var piece: String
        var from: Int
        var to: Int
    }
    struct Step: Codable, Sendable, Equatable {
        var before: [String?]
        var after: [String?]
        var moving: [MovingPiece]
    }
    var steps: [Step]
    var whiteAtBottom: Bool
    var duration: TimeInterval { Double(steps.count) + 1 }

    var isValid: Bool {
        let pieces = Set("KQRBNPkqrbnp".map(String.init))
        func valid(_ board: [String?]) -> Bool { board.count == 64 && board.allSatisfy { $0 == nil || pieces.contains($0!) } }
        return (1...2).contains(steps.count) && steps.allSatisfy {
            valid($0.before) && valid($0.after) && (1...2).contains($0.moving.count)
                && $0.moving.allSatisfy { pieces.contains($0.piece) && (0..<64).contains($0.from) && (0..<64).contains($0.to) }
        }
    }
}

struct BoardMovePlaybackView: View {
    let playback: BoardMovePlayback
    var isPlaying = true
    var sprites: [String: CGImage] = [:]
    var light: Color = Color(red: 0.90, green: 0.90, blue: 0.78)
    var dark: Color = Color(red: 0.48, green: 0.60, blue: 0.32)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date.now
    @State private var hasFinished = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying || hasFinished)) { timeline in
            let elapsed = !isPlaying ? 0 : hasFinished ? Double(playback.steps.count) : max(0, timeline.date.timeIntervalSince(startedAt))
            let index = min(Int(elapsed), max(0, playback.steps.count - 1))
            let progress: Double = !isPlaying ? 0 : reduceMotion ? 1 : min(1, max(0, (elapsed - Double(index)) / 0.75))
            Canvas { context, size in
                guard playback.isValid, playback.steps.indices.contains(index) else { return }
                let side = min(size.width, size.height)
                let step = playback.steps[index]
                func rect(_ index: Int) -> CGRect {
                    let file = index % 8, rank = index / 8
                    let column = playback.whiteAtBottom ? file : 7 - file
                    let row = playback.whiteAtBottom ? 7 - rank : rank
                    return CGRect(x: CGFloat(column) * side / 8, y: CGFloat(row) * side / 8, width: side / 8, height: side / 8)
                }
                for square in 0..<64 {
                    context.fill(Path(rect(square)), with: .color((square % 8 + square / 8).isMultiple(of: 2) ? dark : light))
                }
                if progress >= 1 {
                    for square in 0..<64 {
                        if let piece = step.after[square] { draw(piece, in: rect(square), context: &context) }
                    }
                } else {
                    for square in 0..<64 where !step.moving.contains(where: { $0.from == square }) {
                        guard let piece = step.before[square] else { continue }
                        var layer = context
                        if step.after[square] != piece { layer.opacity = 1 - progress }
                        draw(piece, in: rect(square), context: &layer)
                    }
                    for mover in step.moving {
                        let start = rect(mover.from), end = rect(mover.to)
                        let moving = CGRect(x: start.minX + (end.minX - start.minX) * progress,
                                            y: start.minY + (end.minY - start.minY) * progress,
                                            width: start.width, height: start.height)
                        draw(mover.piece, in: moving, context: &context)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .task {
            guard isPlaying else { return }
            do { try await Task.sleep(for: .seconds(Double(playback.steps.count))) } catch { return }
            hasFinished = true
        }
    }

    private func draw(_ piece: String, in rect: CGRect, context: inout GraphicsContext) {
        if let sprite = sprites[piece] {
            context.draw(Image(decorative: sprite, scale: 1), in: rect)
        } else {
            PlaybackPieceOutlines.draw(piece, in: rect, context: &context)
        }
    }
}

/// A bundled-font chess symbol, shared with the Watch move label. It is never an emoji.
struct ChessPieceSymbol: View {
    let piece: String
    var body: some View {
        Canvas { context, size in
            PlaybackPieceOutlines.draw(piece, in: CGRect(origin: .zero, size: size), context: &context, monochrome: .primary)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private enum PlaybackPieceOutlines {
    /// CTFont is immutable; this wrapper only exposes concurrent read-only glyph queries.
    private struct FontReference: @unchecked Sendable { let value: CTFont }
    private static let font: FontReference = {
        if let url = Bundle.main.url(forResource: "NotoSansSymbols2-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return FontReference(value: CTFontCreateWithName("NotoSansSymbols2-Regular" as CFString, 100, nil))
    }()

    static func draw(_ piece: String, in rect: CGRect, context: inout GraphicsContext, monochrome: Color? = nil) {
        guard let letter = piece.first,
              let index = ["K": 0, "Q": 1, "R": 2, "B": 3, "N": 4, "P": 5][String(letter).uppercased()] else { return }
        let white = letter.isUppercase
        func path(_ solid: Bool) -> CGPath? {
            var character = UniChar((solid ? 0x265A : 0x2654) + index)
            var glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(font.value, &character, &glyph, 1) else { return nil }
            return CTFontCreatePathForGlyph(font.value, glyph, nil)
        }
        guard let solid = path(true), let outline = path(false) else { return }
        let reference = monochrome != nil ? solid : white ? outline : solid
        let bounds = reference.boundingBoxOfPath
        let factor = min(rect.width, rect.height) * 0.82 / max(bounds.width, bounds.height)
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: factor, y: -factor).translatedBy(x: -bounds.midX, y: -bounds.midY)
        if monochrome == nil, white, let filled = solid.copy(using: &transform) { context.fill(Path(filled), with: .color(.white)) }
        if let ink = reference.copy(using: &transform) { context.fill(Path(ink), with: .color(monochrome ?? Color(white: 0.08))) }
    }
}
