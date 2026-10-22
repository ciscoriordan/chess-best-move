import ChessCore
import CoreGraphics
import CryptoKit
import Foundation
import Observation

/// A persisted engine answer. Images and PhotoKit identifiers never enter this record.
struct SavedEngineReadout: Codable, Hashable, Sendable {
    var depth: Int
    var score: WhiteScore?
    var bestMove: String?
    var principalVariation: [String]
    var nodesPerSecond: Int?
    var elapsedSeconds: Double

    init(_ value: EngineReadout) {
        depth = value.depth
        score = value.score
        bestMove = value.bestMove
        principalVariation = Array(value.principalVariation.prefix(128))
        nodesPerSecond = value.nodesPerSecond
        elapsedSeconds = Double(value.elapsed.components.seconds)
            + Double(value.elapsed.components.attoseconds) / 1e18
    }

    var value: EngineReadout {
        EngineReadout(depth: depth, score: score, bestMove: bestMove,
                      principalVariation: principalVariation, nodesPerSecond: nodesPerSecond,
                      elapsed: .seconds(max(0, min(elapsedSeconds, 86_400))))
    }
}

struct SavedAnalysisScreenshot: Codable, Sendable {
    var fingerprint: String
    var whiteAtBottom: Bool
    var sideToMoveOrigin: SideToMoveOrigin
    var assumedCastlingRights: CastlingRights
    var lastMove: String?
    var boardRect: CGRect?
    var recognizedFEN: String?

    @MainActor init?(snapshot: BoardSnapshot) {
        guard let image = snapshot.sourceImage, let fingerprint = AnalysisHistoryStore.fingerprint(image) else { return nil }
        self.fingerprint = fingerprint
        whiteAtBottom = snapshot.whiteAtBottom
        sideToMoveOrigin = snapshot.sideToMoveOrigin
        assumedCastlingRights = snapshot.assumedCastlingRights
        lastMove = snapshot.lastMove?.uci
        boardRect = snapshot.boardRect
        recognizedFEN = snapshot.recognizedBoard.map { Position(board: $0).fen }
    }
}

struct AnalysisHistoryEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var fen: String
    var whiteAtBottom: Bool
    var sideToMoveOrigin: SideToMoveOrigin
    var assumedCastlingRights: CastlingRights
    var lastMove: String?
    var origin: AnalysisOrigin
    var engineVersion: String
    var thinkTime: ThinkTime
    var analyzedAt: Date
    var lastOpenedAt: Date
    var result: SavedEngineReadout?
    var checkmate: Bool?
    /// Nonreversible pixel hashes allow the exact same image to bypass recognition.
    var screenshots: [SavedAnalysisScreenshot]

    var snapshot: BoardSnapshot? {
        guard let position = try? Position(fen: fen) else { return nil }
        return BoardSnapshot(position: position, whiteAtBottom: whiteAtBottom,
            sideToMoveOrigin: sideToMoveOrigin, lastMove: lastMove.flatMap { Move(uci: $0) },
            assumedCastlingRights: assumedCastlingRights)
    }

    @MainActor func snapshot(importing image: ImportedImage) -> BoardSnapshot? {
        guard let position = try? Position(fen: fen) else { return nil }
        let hash = AnalysisHistoryStore.fingerprint(image.image)
        let source = screenshots.first { $0.fingerprint == hash }
        let crop = source?.boardRect.flatMap { image.image.cropping(to: $0) }
        return BoardSnapshot(position: position, whiteAtBottom: source?.whiteAtBottom ?? whiteAtBottom,
            sideToMoveOrigin: source?.sideToMoveOrigin ?? sideToMoveOrigin,
            sourceImage: image.image, boardImage: crop, boardRect: source?.boardRect,
            recognizedBoard: source?.recognizedFEN.flatMap { try? Position(fen: $0).board },
            lastMove: (source?.lastMove ?? lastMove).flatMap { Move(uci: $0) }, importSource: image.source,
            assumedCastlingRights: source?.assumedCastlingRights ?? assumedCastlingRights)
    }

    private var readoutContent: AnalysisReadoutContent? {
        guard let snapshot else { return nil }
        let position = snapshot.position
        let best = result?.bestMove.flatMap { Move(uci: $0) }.flatMap { move in
            position.san(for: move).map { (move: move, san: $0) }
        }
        return AnalysisReadoutContent.make(status: .done, position: position,
            whiteAtBottom: whiteAtBottom, sideToMoveOrigin: sideToMoveOrigin,
            bestMove: best, principalVariation: result?.principalVariation ?? [],
            noLegalMoves: checkmate, quickAnswerIsBeaten: false)
    }

    var moveNotation: String? { readoutContent?.move?.san }

    var moveDescription: String {
        if let words = readoutContent?.move?.words { return words }
        if let checkmate { return checkmate ? String(localized: "Checkmate") : String(localized: "Stalemate") }
        return String(localized: "Saved analysis")
    }

    @MainActor var isValid: Bool {
        guard let position = try? Position(fen: fen),
              AnalysisPositionCheck.blockingIssues(in: position).isEmpty else { return false }
        if let checkmate { return position.legalMoves().isEmpty && position.isCheckmate == checkmate }
        guard let move = result?.bestMove.flatMap({ Move(uci: $0) }),
              position.san(for: move) != nil else { return false }
        return true
    }
}

/// Device-only, bounded history and the result cache share one source of truth. Deleting an
/// entry also removes its cached answer; it never changes the purchase/credit ledger.
@MainActor
@Observable
final class AnalysisHistoryStore {
    static let limit = 500
    private(set) var entries: [AnalysisHistoryEntry] = []
    private(set) var storageError: String?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private var unreadableFile = false

    private struct Archive: Codable {
        var version = 1
        var entries: [AnalysisHistoryEntry]
    }

    /// No URL means an isolated memory store, useful for tests and previews.
    init(fileURL: URL? = nil, limit: Int = AnalysisHistoryStore.limit) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            guard archive.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            var seen = Set<String>()
            entries = archive.entries.filter { entry in
                entry.isValid && seen.insert(Self.key(for: entry.snapshot!.position)).inserted
            }.prefix(self.limit).map { $0 }
        } catch {
            unreadableFile = true
            storageError = String(localized: "History could not be read. The saved file has been kept. Clear History to start again.")
        }
    }

    static func live() -> AnalysisHistoryStore {
        let folder = URL.applicationSupportDirectory.appending(path: "AnalysisHistory", directoryHint: .isDirectory)
        return AnalysisHistoryStore(fileURL: folder.appending(path: "history.json"))
    }

    /// Full move numbers are notation only. Turn, castling, en passant and the fifty-move
    /// clock all affect an answer and must remain distinct.
    static func key(for position: Position) -> String {
        AnalysisPositionCheck.sanitized(position).fen.split(separator: " ").prefix(5).joined(separator: " ")
    }

    static func fingerprint(_ image: CGImage) -> String? {
        guard let data = image.dataProvider?.data else { return nil }
        var hash = SHA256()
        hash.update(data: Data("\(image.width),\(image.height),\(image.bitsPerPixel),\(image.bytesPerRow),\(image.bitmapInfo.rawValue),\(String(describing: image.colorSpace?.name)):".utf8))
        hash.update(data: data as Data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func entry(for position: Position, engineVersion: String) -> AnalysisHistoryEntry? {
        let key = Self.key(for: position)
        return entries.first { $0.engineVersion == engineVersion && $0.snapshot.map { Self.key(for: $0.position) == key } == true }
    }

    func entry(for image: ImportedImage, engineVersion: String) -> AnalysisHistoryEntry? {
        guard let hash = Self.fingerprint(image.image) else { return nil }
        return entries.first { $0.engineVersion == engineVersion && $0.screenshots.contains { $0.fingerprint == hash } }
    }

    @discardableResult
    func record(snapshot: BoardSnapshot, origin: AnalysisOrigin, readout: EngineReadout?,
                checkmate: Bool? = nil, thinkTime: ThinkTime, engineVersion: String,
                at date: Date = .now) -> AnalysisHistoryEntry? {
        let position = AnalysisPositionCheck.sanitized(snapshot.position)
        let previous = entries.first { $0.snapshot.map { Self.key(for: $0.position) == Self.key(for: position) } == true }
        var screenshots = previous?.screenshots ?? []
        if let source = SavedAnalysisScreenshot(snapshot: snapshot) {
            screenshots.removeAll { $0.fingerprint == source.fingerprint }
            screenshots.insert(source, at: 0)
        }
        var entry = AnalysisHistoryEntry(id: previous?.id ?? UUID(), fen: position.fen,
            whiteAtBottom: snapshot.whiteAtBottom, sideToMoveOrigin: snapshot.sideToMoveOrigin,
            assumedCastlingRights: snapshot.assumedCastlingRights, lastMove: snapshot.lastMove?.uci,
            origin: origin, engineVersion: engineVersion, thinkTime: thinkTime,
            analyzedAt: date, lastOpenedAt: date, result: readout.map(SavedEngineReadout.init),
            checkmate: checkmate, screenshots: Array(screenshots.prefix(8)))
        // A short explicit rerun must not discard the stronger answer already saved.
        if let previous, previous.engineVersion == engineVersion,
           let old = previous.result, let new = entry.result, old.depth > new.depth {
            entry.result = old
            entry.thinkTime = previous.thinkTime
            entry.analyzedAt = previous.analyzedAt
        }
        guard entry.isValid else { return nil }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(limit))
        persist()
        return entry
    }

    func touch(_ id: UUID, at date: Date = .now) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.lastOpenedAt = date
        entries.insert(entry, at: 0)
        persist()
    }

    func rememberScreenshot(_ snapshot: BoardSnapshot, for id: UUID) {
        guard let source = SavedAnalysisScreenshot(snapshot: snapshot),
              let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].screenshots.removeAll { $0.fingerprint == source.fingerprint }
        entries[index].screenshots.insert(source, at: 0)
        entries[index].screenshots = Array(entries[index].screenshots.prefix(8))
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries = []
        unreadableFile = false
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        guard !unreadableFile else { return }
        do {
            let folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = folder
            try directory.setResourceValues(values)
            let data = try JSONEncoder().encode(Archive(entries: entries))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var file = fileURL
            try file.setResourceValues(values)
            storageError = nil
        } catch {
            storageError = String(localized: "History could not be saved. Your current results are still available while the app is open.")
        }
    }
}
