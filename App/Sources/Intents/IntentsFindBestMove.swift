import AppIntents
import ChessCore
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// MARK: - App Intent

/// "Find Best Move" (ARCHITECTURE.md "App", monetization.md 4.10, design.md 9.1).
///
/// The intent opens the app and hands the image to the normal flow: recognition, the credit
/// check, and the analysis with the saved think time, all in the foreground app process. The
/// engine needs roughly 300 MB and Core ML wants the GPU, neither of which a background App
/// Intent process can count on. The intent then waits for that flow and answers with a
/// dialog such as "Best move: knight to f3. White is ahead by 0.4 pawns.", while the app shows
/// the full result.
///
/// Without credit the app shows the paywall with the board kept as the pending analysis, and
/// the dialog says "You've used your free analyses. Open Chess Best Move to continue."
struct FindBestMoveIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Best Move"
    static let description = IntentDescription(
        "Finds the best move in a screenshot of a chess position. Chess Best Move opens and shows the analysis."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Screenshot", description: "A screenshot of a chess position.", supportedContentTypes: [.image])
    var screenshot: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Find the best move in \(\.$screenshot)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let app = AppModel.current else {
            return .result(dialog: IntentDialog("\(IntentsShortcutOutcome.appNotReady.dialog)"))
        }
        let data = screenshot.data
        let image = await Task.detached(priority: .userInitiated) {
            IntentsImageDecoding.image(from: data)
        }.value
        guard let image else {
            return .result(dialog: IntentDialog("\(IntentsShortcutOutcome.unreadableImage.dialog)"))
        }

        let imported = ImportedImage(image: image, source: .shortcut)
        app.importImage(imported)
        let outcome = await IntentsShortcutWaiter(app: app).outcome(for: imported)
        return .result(dialog: IntentDialog("\(outcome.dialog)"))
    }
}

// MARK: - App Shortcuts

struct ChessBestMoveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FindBestMoveIntent(),
            phrases: [
                "Find the best move with \(.applicationName)",
                "Find the best move in \(.applicationName)",
                "Get the best move from \(.applicationName)",
                "\(.applicationName) find best move",
            ],
            shortTitle: "Find Best Move",
            systemImageName: "arrow.turn.up.right"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .navy }
}

// MARK: - Decoding

enum IntentsImageDecoding {
    /// Decodes the first image in `data` the same way every other import path does
    /// (`CaptureImageDecoder`): the file's orientation is applied, so recognition never sees
    /// a sideways board, and the longer side is capped at 4096 px to bound memory. The
    /// shortcut accepts any image, not only screenshots. Nil when the data is not an image.
    /// Synchronous and possibly slow: call it off the main actor.
    static func image(from data: Data) -> CGImage? {
        try? CaptureImageDecoder.decode(data: data)
    }
}

// MARK: - Waiting for the app's flow

/// How the app's flow ended for an image the shortcut imported.
enum IntentsShortcutOutcome: Sendable, Hashable {
    /// `move` gives the spoken form its full from-square when the SAN disambiguates.
    case bestMove(san: String, move: Move?, score: WhiteScore?)
    case noLegalMoves(checkmate: Bool)
    case boardNotFound
    case needsCheck
    case needsPurchase
    case waitingForApproval
    case failed
    case canceled
    case stillRunning
    case appNotReady
    case unreadableImage

    /// The dialog the shortcut returns. Siri may speak it, so a move is never given as SAN,
    /// which speech reads letter by letter (design.md 12): it uses the same spoken form as the
    /// Analysis screen's completion announcement.
    var dialog: String {
        switch self {
        case .bestMove(let san, let move, let score):
            AnalysisSpeech.completionAnnouncement(
                moveDescription: AnalysisSpeech.moveDescription(san: san, move: move),
                score: score
            )
        case .noLegalMoves(let checkmate):
            checkmate ? "No legal moves: it's checkmate." : "No legal moves: it's stalemate."
        case .boardNotFound:
            "No chessboard found in that image. This didn't use a free analysis."
        case .needsCheck:
            "Some squares need a look. Check the position in Chess Best Move."
        case .needsPurchase:
            "You've used your free analyses. Open Chess Best Move to continue."
        case .waitingForApproval:
            "The purchase is waiting for approval. The analysis starts in Chess Best Move when it is approved."
        case .failed:
            "Chess Best Move couldn't analyze this position."
        case .canceled:
            "The analysis was canceled."
        case .stillRunning:
            "The analysis is still running in Chess Best Move."
        case .appNotReady:
            "Chess Best Move isn't ready. Open the app, then run the shortcut again."
        case .unreadableImage:
            "Chess Best Move couldn't read that image. Pass a screenshot to the shortcut."
        }
    }
}

/// Follows the app's navigation after `AppModel.importImage` until the imported board has an
/// answer: a result on the Analysis screen, Check position, Board not found, or the paywall.
@MainActor
struct IntentsShortcutWaiter {
    let app: AppModel
    var ledger: AnalysisRunLedger = .shared
    var pollInterval: Duration = .milliseconds(100)
    /// Recognition and loading the engine, on top of the think time.
    var overhead: Duration = .seconds(30)

    func outcome(for image: ImportedImage) async -> IntentsShortcutOutcome {
        let deadline = ContinuousClock.now.advanced(by: app.settings.thinkTime.duration + overhead)
        while ContinuousClock.now < deadline {
            if let outcome = currentOutcome(for: image) { return outcome }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return .canceled
            }
        }
        return .stillRunning
    }

    /// The outcome visible right now, or nil while the flow is still working.
    func currentOutcome(for image: ImportedImage) -> IntentsShortcutOutcome? {
        switch app.path.last {
        case .recognizing(let shown)? where shown.id == image.id:
            return nil
        case .boardNotFound(let shown)? where shown.id == image.id:
            return .boardNotFound
        case .checkPosition?:
            return .needsCheck
        case .analysis(let session)?:
            switch session.creditState {
            case .waitingForPurchase:
                // Until this launch has read the entitlements, a subscriber may still be treated
                // as a free user; the board then runs as soon as they load.
                return app.store.hasLoadedEntitlements ? .needsPurchase : nil
            case .waitingForApproval:
                return .waitingForApproval
            case .authorized:
                break
            }
            switch ledger.completion(for: session.id) {
            case .bestMove(let san, let move, let score)?: return .bestMove(san: san, move: move, score: score)
            case .noLegalMoves(let checkmate)?: return .noLegalMoves(checkmate: checkmate)
            case .invalidPosition?: return .needsCheck
            case .failed?: return .failed
            case nil: return nil
            }
        default:
            return .canceled
        }
    }
}
