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
        static let longerSearchCeiling = "longerSearchCeilingSeconds"
        static let switchesToBetterMoveAutomatically = "switchesToBetterMoveAutomatically"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The saved think time (default 3 s). Tapping a THINK segment on the result screen also
    /// makes it the saved default (design.md 9.4).
    var thinkTime: ThinkTime {
        didSet { defaults.set(thinkTime.rawValue, forKey: Key.thinkTime) }
    }

    /// How long the search that keeps running after the first answer may go on
    /// (design.md section 16). A Pro setting: read it through
    /// `effectiveLongerSearchCeiling(isPro:)`, never directly.
    var longerSearchCeiling: LongerSearchCeiling {
        didSet { defaults.set(longerSearchCeiling.rawValue, forKey: Key.longerSearchCeiling) }
    }

    /// Put a move the longer search prefers on screen without asking (design.md section 16).
    /// A Pro setting, and off by default: the user may be reading or copying the move that is
    /// there. Read it through `switchesToBetterMoveAutomatically(isPro:)`, never directly.
    var switchesToBetterMoveAutomatically: Bool {
        didSet { defaults.set(switchesToBetterMoveAutomatically, forKey: Key.switchesToBetterMoveAutomatically) }
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
        longerSearchCeiling = LongerSearchCeiling(rawValue: defaults.integer(forKey: Key.longerSearchCeiling)) ?? .defaultValue
        switchesToBetterMoveAutomatically = defaults.bool(forKey: Key.switchesToBetterMoveAutomatically)
        hasCompletedAnalysis = defaults.bool(forKey: Key.hasCompletedAnalysis)
        pendingApprovalBoard = defaults.data(forKey: Key.pendingApprovalBoard)
            .flatMap { try? JSONDecoder().decode(AppPendingApprovalBoard.self, from: $0) }
    }

    /// The ceiling that actually applies. The setting belongs to Pro, so a free user's longer
    /// search always stops at the default, whatever is saved (design.md section 16). Saving it
    /// while free is still allowed: a later purchase then finds the choice already made.
    func effectiveLongerSearchCeiling(isPro: Bool) -> LongerSearchCeiling {
        isPro ? longerSearchCeiling : .defaultValue
    }

    /// Whether a preferred move goes on screen by itself. Pro only, so a free user never has
    /// the move under their eyes replaced.
    func switchesToBetterMoveAutomatically(isPro: Bool) -> Bool {
        isPro && switchesToBetterMoveAutomatically
    }
}

/// How long the longer search may keep going after the first answer (design.md section 16),
/// the hard ceiling of `build/ui-requests.md` item 8. Two minutes is the top of the range on
/// purpose: a sustained search warms the device and the returns flatten.
enum LongerSearchCeiling: Int, CaseIterable, Identifiable, Sendable, Codable, Hashable {
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120

    static let defaultValue: LongerSearchCeiling = .thirtySeconds

    var id: Int { rawValue }
    var seconds: Int { rawValue }
    var duration: Duration { .seconds(rawValue) }

    /// "15 s", "1 min", with a no-break space before the unit (design.md section 4).
    var label: String {
        switch self {
        case .fifteenSeconds, .thirtySeconds: "\(rawValue)\u{00A0}s"
        case .oneMinute: "1\u{00A0}min"
        case .twoMinutes: "2\u{00A0}min"
        }
    }

    /// What VoiceOver reads for a segment.
    var spokenLabel: String {
        switch self {
        case .fifteenSeconds: "15 seconds"
        case .thirtySeconds: "30 seconds"
        case .oneMinute: "1 minute"
        case .twoMinutes: "2 minutes"
        }
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
