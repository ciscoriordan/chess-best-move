import ChessCore
import Foundation
import Observation

/// User preferences shared across features, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let thinkTime = "thinkTimeSeconds"
        static let hasCompletedAnalysis = "hasCompletedAnalysis"
        static let pendingApprovalBoard = "pendingApprovalBoard"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The saved think time (default 3 s). Tapping a THINK segment on the result screen also
    /// makes it the saved default (design.md 9.4).
    var thinkTime: ThinkTime {
        didSet { defaults.set(thinkTime.rawValue, forKey: Key.thinkTime) }
    }

    /// Set after the first successful analysis; Home collapses its HOW IT WORKS steps.
    var hasCompletedAnalysis: Bool {
        didSet { defaults.set(hasCompletedAnalysis, forKey: Key.hasCompletedAnalysis) }
    }

    /// The board whose analysis waits for an Ask to Buy approval (monetization.md 4.4). It is
    /// kept on disk because the approval usually arrives minutes or hours later, often after
    /// iOS has ended the app. `AppModel` writes and clears it; nil when no board waits.
    var pendingApprovalBoard: AppPendingApprovalBoard? {
        didSet {
            if let pendingApprovalBoard, let data = try? JSONEncoder().encode(pendingApprovalBoard) {
                defaults.set(data, forKey: Key.pendingApprovalBoard)
            } else {
                defaults.removeObject(forKey: Key.pendingApprovalBoard)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        thinkTime = ThinkTime(rawValue: defaults.integer(forKey: Key.thinkTime)) ?? .defaultValue
        hasCompletedAnalysis = defaults.bool(forKey: Key.hasCompletedAnalysis)
        pendingApprovalBoard = defaults.data(forKey: Key.pendingApprovalBoard)
            .flatMap { try? JSONDecoder().decode(AppPendingApprovalBoard.self, from: $0) }
    }
}

/// A board kept for an Ask to Buy request: enough to show it again as a diagram and analyze
/// it (the screenshot itself is not stored).
struct AppPendingApprovalBoard: Codable, Hashable, Sendable {
    /// Ask to Buy requests expire after 24 hours; an older board is never restored.
    static let lifetime: TimeInterval = 24 * 60 * 60

    var fen: String
    var whiteAtBottom: Bool
    var sideToMoveOrigin: SideToMoveOrigin
    var origin: AnalysisOrigin
    /// The last move in UCI, when it was detected.
    var lastMove: String?
    /// `BoardSnapshot.assumedCastlingRights`; nil in boards saved before it existed.
    var assumedCastlingRights: CastlingRights?
    var savedAt: Date

    init(snapshot: BoardSnapshot, origin: AnalysisOrigin, savedAt: Date) {
        fen = snapshot.position.fen
        whiteAtBottom = snapshot.whiteAtBottom
        sideToMoveOrigin = snapshot.sideToMoveOrigin
        self.origin = origin
        lastMove = snapshot.lastMove?.uci
        assumedCastlingRights = snapshot.assumedCastlingRights
        self.savedAt = savedAt
    }

    /// The board as a snapshot without images, so screens draw the diagram board. Nil when
    /// the stored position no longer parses.
    var snapshot: BoardSnapshot? {
        guard let position = try? Position(fen: fen) else { return nil }
        return BoardSnapshot(
            position: position,
            whiteAtBottom: whiteAtBottom,
            sideToMoveOrigin: sideToMoveOrigin,
            lastMove: lastMove.flatMap { Move(uci: $0) },
            assumedCastlingRights: assumedCastlingRights ?? []
        )
    }

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(savedAt) > Self.lifetime || now < savedAt.addingTimeInterval(-60)
    }
}
