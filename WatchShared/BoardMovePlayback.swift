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

    enum Phase: Equatable {
        case start, moving, afterMove

        var label: LocalizedStringKey {
            switch self {
            case .start: "Start position"
            case .moving: "Moving…"
            case .afterMove: "After move"
            }
        }
    }

    struct Frame: Equatable {
        var step: Int
        var progress: Double
        var phase: Phase
    }

    // Hold both ends so a repeating move cannot be mistaken for a move played backward.
    private static let startHold: TimeInterval = 1.2
    private static let moveDuration: TimeInterval = 0.75
    private static let betweenMovesHold: TimeInterval = 0.65
    private static let endHold: TimeInterval = 1.5
    var duration: TimeInterval {
        Self.startHold + Double(steps.count) * Self.moveDuration
            + Double(max(0, steps.count - 1)) * Self.betweenMovesHold + Self.endHold
    }

    func frame(at elapsed: TimeInterval, reduceMotion: Bool = false, isPlaying: Bool = true) -> Frame {
        let start = Frame(step: 0, progress: 0, phase: .start)
        guard isPlaying, !steps.isEmpty else { return start }
        var time = (elapsed.isFinite ? max(0, elapsed) : 0).truncatingRemainder(dividingBy: duration)
        guard time >= Self.startHold else { return start }
        time -= Self.startHold
        for index in steps.indices {
            if time < Self.moveDuration {
                return Frame(step: index, progress: reduceMotion ? 1 : time / Self.moveDuration,
                             phase: reduceMotion && index == steps.count - 1 ? .afterMove : .moving)
            }
            time -= Self.moveDuration
            if index < steps.count - 1 {
                if time < Self.betweenMovesHold { return Frame(step: index, progress: 1, phase: .moving) }
                time -= Self.betweenMovesHold
            }
        }
        return Frame(step: steps.count - 1, progress: 1, phase: .afterMove)
    }

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
    var cornerRadius: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : 1.0 / 30, paused: !isPlaying)) { timeline in
            let frame = playback.frame(at: timeline.date.timeIntervalSince(startedAt),
                                       reduceMotion: reduceMotion, isPlaying: isPlaying)
            let progress = frame.progress
            Canvas { context, size in
                guard playback.isValid, playback.steps.indices.contains(frame.step) else { return }
                let side = min(size.width, size.height)
                let step = playback.steps[frame.step]
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
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: cornerRadius))
            // Callers reserve 32 points below the square, keeping labels off the pieces.
            .overlay(alignment: .bottom) {
                if isPlaying {
                    Text(frame.phase.label)
                        #if os(watchOS)
                        .font(.caption.weight(.semibold))
                        #else
                        .typography(.caption)
                        .fontWeight(.semibold)
                        #endif
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .offset(y: 32)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .onChange(of: playback) { _, _ in startedAt = .now }
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
