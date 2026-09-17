// Contracts between the app shell and the three feature areas. See App/APP_CONTRACT.md for
// folder ownership, the entry points each folder must keep, and the flow.
//
// Changing anything in this file is a coordinated change: every feature owner has to agree.

import ChessCore
import CoreGraphics
import Foundation
import Observation
import StoreKit

// MARK: - Shared value types

/// Think-time presets (ARCHITECTURE.md "App"). The saved default is `AppSettings.thinkTime`.
enum ThinkTime: Int, CaseIterable, Identifiable, Sendable, Codable, Hashable {
    case oneSecond = 1
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30

    static let defaultValue: ThinkTime = .threeSeconds

    var id: Int { rawValue }
    var seconds: Int { rawValue }
    var milliseconds: Int { rawValue * 1000 }
    var duration: Duration { .seconds(rawValue) }

    /// "3 s" with a no-break space before the unit (design.md section 4).
    var label: String { "\(rawValue)\u{00A0}s" }
    /// "3 seconds" for VoiceOver.
    var spokenLabel: String { rawValue == 1 ? "1 second" : "\(rawValue) seconds" }

    /// The next preset up, for "Think longer"; nil at 30 s ("Run again: 30 s").
    var next: ThinkTime? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}

/// Where an imported image came from.
enum ImportSource: String, Sendable, Hashable, Codable {
    case latestScreenshot
    case photosPicker
    case paste
    case dragAndDrop
    case shortcut
    /// DEBUG builds only: the bundled sample screenshot.
    case debugSample
}

/// An image handed to recognition.
struct ImportedImage: Sendable, Identifiable, Hashable {
    let id: UUID
    let image: CGImage
    let source: ImportSource
    /// PhotoKit local identifier when the image came from the photo library, so Capture can
    /// remember which screenshots were already analyzed (the recent-screenshot banner).
    let photoAssetIdentifier: String?
    /// Creation date of the asset, when known.
    let creationDate: Date?

    init(
        id: UUID = UUID(),
        image: CGImage,
        source: ImportSource,
        photoAssetIdentifier: String? = nil,
        creationDate: Date? = nil
    ) {
        self.id = id
        self.image = image
        self.source = source
        self.photoAssetIdentifier = photoAssetIdentifier
        self.creationDate = creationDate
    }

    static func == (lhs: ImportedImage, rhs: ImportedImage) -> Bool {
        lhs.id == rhs.id && lhs.image === rhs.image && lhs.source == rhs.source
            && lhs.photoAssetIdentifier == rhs.photoAssetIdentifier && lhs.creationDate == rhs.creationDate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// How the side to move was decided.
enum SideToMoveOrigin: String, Sendable, Hashable, Codable {
    /// From the last-move highlight ("from last-move highlight").
    case lastMoveHighlight
    /// From the running clock in the screenshot ("from the clock").
    case runningClock
    /// The other side would be in check ("from check").
    case checkRule
    /// No evidence: the player at the bottom ("assumed: you are at the bottom"). The chip is
    /// shown in the attention state.
    case assumedBottomPlayer
    /// The user chose it.
    case user
}

/// Why recognition was not confident about a board, in the terms the app explains to the user.
/// Capture maps ChessVision's own reasons (`ChessVision.RecognitionDoubt`) onto these, so the
/// contract stays free of ChessVision types; Check position picks its sentence from them
/// (`CaptureCheckPositionSummary`, design.md 9.5).
enum BoardDoubt: Sendable, Hashable {
    /// These squares are outside the screenshot or transparent: nothing is known about them.
    case squaresOutsideImage(Set<Square>)
    /// Something opaque is drawn over these squares (a banner, a card, a menu, a keyboard).
    case squaresCovered(Set<Square>)
    /// The recognized content of these squares is below the classifier's confidence threshold.
    case uncertainSquares(Set<Square>)
    /// The board's squares are too small to read reliably, at this many pixels a square.
    case squaresTooSmall(pixelsPerSquare: Double)
    /// The screenshot holds this many boards (2 or more), so this may be the wrong one.
    case severalBoards(count: Int)
    /// The light and dark squares are the other way round: an unusual theme, or a mirrored
    /// screenshot, which pixels alone cannot tell apart.
    case invertedSquareColors
    /// The board was matched weakly: the screenshot may show no board at all.
    case weakBoardMatch
    /// The recognized position breaks a rule of chess, so at least one square is misread.
    case impossiblePosition
    /// No coordinate label confirms the orientation and the pieces alone do not settle it.
    case orientationUnconfirmed
    /// The side to move rests on evidence that may mislead.
    case sideToMoveUncertain
}

/// One board on its way from import to analysis: the position plus what the screens need
/// to draw it. Produced by Capture (recognition, editor), consumed by the app shell and
/// Analysis. Never contains ChessVision types, so Analysis does not depend on ChessVision.
struct BoardSnapshot: Sendable, Identifiable, Hashable {
    let id: UUID
    /// The position to analyze. `board` is in `Square.index` order, already corrected for
    /// orientation; side to move, castling rights and en passant are filled in.
    var position: Position
    /// The displayed orientation of the board image.
    var whiteAtBottom: Bool
    var sideToMoveOrigin: SideToMoveOrigin
    /// The whole imported image (for the Recognizing animation and peeking).
    var sourceImage: CGImage?
    /// The board cropped from `sourceImage` as displayed (not rotated). Nil for a board set
    /// up by hand.
    var boardImage: CGImage?
    /// The board rectangle in `sourceImage` pixels.
    var boardRect: CGRect?
    /// The pieces as recognized, before any edit (64, `Square.index`). Nil for a board set up
    /// by hand. Flipping re-maps these along with `position.board`.
    var recognizedBoard: [Piece?]?
    /// Per-square classifier confidence (64, `Square.index`), when recognized.
    var squareConfidences: [Float]?
    /// Squares still flagged as uncertain. The editor removes a square when it is edited or
    /// explicitly confirmed.
    var lowConfidenceSquares: Set<Square>
    /// The last move from the highlight, when detected.
    var lastMove: Move?
    /// How the image arrived, when it was imported.
    var importSource: ImportSource?
    /// Why recognition was not confident (empty for a confident result or a board set up by
    /// hand). Check position turns these into the sentence it shows
    /// (`CaptureCheckPositionSummary`); nothing else in the app reads them, and a board restored
    /// from disk does not carry them.
    var doubts: [BoardDoubt]
    /// Castling rights that were only inferred from king and rook placement (a screenshot
    /// cannot show whether the king or rook has moved) and that the user has not confirmed.
    /// Recognition sets every right it grants; a castling toggle on Check position, in the
    /// editor or on Analysis confirms that right. See `unconfirmedCastlingRights`.
    var assumedCastlingRights: CastlingRights
    /// The castling rights and en passant square before the last flip, with the board they
    /// belong to, so flipping back restores them instead of inferring them again.
    private var stateBeforeFlip: FlipState?

    /// What `flipped()` keeps to undo itself.
    private struct FlipState: Sendable {
        let board: [Piece?]
        let sideToMove: PieceColor
        let castlingRights: CastlingRights
        let assumedCastlingRights: CastlingRights
        let enPassant: Square?
    }

    init(
        id: UUID = UUID(),
        position: Position,
        whiteAtBottom: Bool = true,
        sideToMoveOrigin: SideToMoveOrigin = .user,
        sourceImage: CGImage? = nil,
        boardImage: CGImage? = nil,
        boardRect: CGRect? = nil,
        recognizedBoard: [Piece?]? = nil,
        squareConfidences: [Float]? = nil,
        lowConfidenceSquares: Set<Square> = [],
        lastMove: Move? = nil,
        importSource: ImportSource? = nil,
        doubts: [BoardDoubt] = [],
        assumedCastlingRights: CastlingRights = []
    ) {
        self.id = id
        self.position = position
        self.whiteAtBottom = whiteAtBottom
        self.sideToMoveOrigin = sideToMoveOrigin
        self.sourceImage = sourceImage
        self.boardImage = boardImage
        self.boardRect = boardRect
        self.recognizedBoard = recognizedBoard
        self.squareConfidences = squareConfidences
        self.lowConfidenceSquares = lowConfidenceSquares
        self.lastMove = lastMove
        self.importSource = importSource
        self.doubts = doubts
        self.assumedCastlingRights = assumedCastlingRights
    }

    /// The castling rights the position grants that the user has not confirmed. Analysis
    /// cautions when the best move castles with one of them (design.md 9.4).
    var unconfirmedCastlingRights: CastlingRights {
        assumedCastlingRights.intersection(position.castlingRights)
    }

    /// The user turned `right` on or off: it is no longer an assumption.
    mutating func confirmCastlingRight(_ right: CastlingRights) {
        assumedCastlingRights.remove(right)
    }

    /// The pieces differ from what was recognized, so screens show the diagram board with
    /// an EDITED label instead of the screenshot crop.
    var isEdited: Bool {
        guard let recognizedBoard else { return false }
        return recognizedBoard != position.board
    }

    /// Show the diagram board rather than the screenshot crop.
    var showsDiagram: Bool { boardImage == nil || isEdited }

    /// The same board with the other side to move, chosen by the user.
    func withSideToMove(_ color: PieceColor) -> BoardSnapshot {
        var copy = self
        copy.position.sideToMove = color
        copy.position.enPassant = nil
        copy.sideToMoveOrigin = .user
        return copy
    }

    /// The board with its orientation flipped (design.md 9.4 "Flip"): the crop is not
    /// rotated; every piece is re-mapped to the square rotated by 180 degrees
    /// (index `63 - i`), and so is the last move.
    ///
    /// Flipping back to the board as it was before the last flip restores its castling rights
    /// and en passant square exactly, so a right the user turned off stays off. Otherwise the
    /// castling rights are inferred for the new orientation, and en passant is taken from the
    /// re-mapped last move (a double pawn push only reads as one in the right orientation).
    func flipped() -> BoardSnapshot {
        var copy = self
        copy.whiteAtBottom.toggle()
        copy.position.board = Array(position.board.reversed())
        copy.recognizedBoard = recognizedBoard.map { Array($0.reversed()) }
        copy.squareConfidences = squareConfidences.map { Array($0.reversed()) }
        copy.lowConfidenceSquares = Set(lowConfidenceSquares.compactMap { Square(index: 63 - $0.index) })
        copy.lastMove = lastMove.flatMap { move in
            guard let from = Square(index: 63 - move.from.index), let to = Square(index: 63 - move.to.index) else { return nil }
            return Move(from: from, to: to, promotion: move.promotion)
        }

        let enPassantFromLastMove = copy.lastMove.flatMap {
            copy.position.enPassantSquare(lastMoveFrom: $0.from, to: $0.to)
        }
        if let before = stateBeforeFlip, before.board == copy.position.board {
            copy.position.castlingRights = before.castlingRights
            copy.assumedCastlingRights = before.assumedCastlingRights
            copy.position.enPassant = before.sideToMove == copy.position.sideToMove ? before.enPassant : enPassantFromLastMove
        } else {
            copy.position.inferCastlingRights()
            // Rights inferred for the new orientation are assumptions again.
            copy.assumedCastlingRights = copy.position.castlingRights
            copy.position.enPassant = enPassantFromLastMove
        }
        copy.position.removeInconsistentCastlingRights()
        copy.stateBeforeFlip = FlipState(
            board: position.board,
            sideToMove: position.sideToMove,
            castlingRights: position.castlingRights,
            assumedCastlingRights: assumedCastlingRights,
            enPassant: position.enPassant
        )
        return copy
    }

    /// What the Flip chip does, on Analysis and on Check position (design.md 9.4).
    ///
    /// - A board with a screenshot crop keeps its picture: the crop is not rotated, so every
    ///   piece is re-mapped to the square rotated by 180 degrees (`flipped()`). The recognized
    ///   orientation is what was wrong.
    /// - A board set up by hand (no crop) has no picture to keep: the position the user built
    ///   stays as it is, and only the displayed orientation turns around.
    /// - When the side to move was only assumed from the bottom player, it follows the new
    ///   bottom player, with recognition's exceptions (ARCHITECTURE.md, side to move): White in
    ///   the start position, and the other side when the assumed side's opponent is in check
    ///   (origin `.checkRule`).
    func flippedByUser() -> BoardSnapshot {
        var result: BoardSnapshot
        if boardImage == nil {
            result = self
            result.whiteAtBottom.toggle()
        } else {
            result = flipped()
        }
        guard sideToMoveOrigin == .assumedBottomPlayer else { return result }

        var side: PieceColor = result.whiteAtBottom ? .white : .black
        if result.position.board == Position.start.board { side = .white }
        var origin = SideToMoveOrigin.assumedBottomPlayer
        let probe = Position(board: result.position.board, sideToMove: side)
        if probe.isInCheck(side.opposite), !probe.isInCheck(side) {
            side = side.opposite
            origin = .checkRule
        }
        if side != result.position.sideToMove {
            result.position.sideToMove = side
            result.position.enPassant = nil
        }
        result.sideToMoveOrigin = origin
        return result
    }

    static func == (lhs: BoardSnapshot, rhs: BoardSnapshot) -> Bool {
        lhs.id == rhs.id && lhs.position == rhs.position && lhs.whiteAtBottom == rhs.whiteAtBottom
            && lhs.sideToMoveOrigin == rhs.sideToMoveOrigin && lhs.sourceImage === rhs.sourceImage
            && lhs.boardImage === rhs.boardImage && lhs.boardRect == rhs.boardRect
            && lhs.recognizedBoard == rhs.recognizedBoard && lhs.squareConfidences == rhs.squareConfidences
            && lhs.lowConfidenceSquares == rhs.lowConfidenceSquares && lhs.lastMove == rhs.lastMove
            && lhs.importSource == rhs.importSource && lhs.doubts == rhs.doubts
            && lhs.assumedCastlingRights == rhs.assumedCastlingRights
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(position)
    }
}

// MARK: - Recognition (implemented by Capture)

/// The result of recognizing one image.
enum RecognitionOutcome: Sendable {
    /// Confident: analysis starts automatically.
    case confident(BoardSnapshot)
    /// Complete but doubtful: show Check position; nothing is spent until the user confirms.
    case needsCheck(BoardSnapshot)
    /// No chessboard in the image. Never costs anything.
    case boardNotFound
    /// The image could not be read. Never costs anything.
    case invalidImage
}

/// Wraps ChessVision's `BoardRecognizer`. `recognize` must do its heavy work off the main
/// actor (the recognizer is synchronous and slow).
protocol RecognitionService: Sendable {
    func recognize(_ image: ImportedImage) async -> RecognitionOutcome

    /// Loads the recognizer (the Core ML model) ahead of the first import, off the main actor
    /// and at low priority. `AppModel.warmUpRecognition(after:)` calls it shortly after launch.
    /// A `recognize` call made while it runs waits for the same load instead of loading a
    /// second time. Returns early without loading when its task is cancelled before the load
    /// began; a load already under way finishes and is kept. Idempotent.
    func warmUp() async
}

extension RecognitionService {
    /// Services with nothing to load ahead of time (test doubles).
    func warmUp() async {}
}

// MARK: - Credits (implemented by Monetization)

/// Why an analysis is being started. The credit rules are in monetization.md section 5.
enum AnalysisOrigin: String, Sendable, Hashable, Codable {
    /// A board from recognition: confident auto-start, or Analyze on Check position.
    case recognition
    /// A recognized or paid board changed in the position editor.
    case editor
    /// A board set up by hand ("Set up the position by hand", or the editor's Start position
    /// or Clear board).
    case handSetup
    /// A board that arrived through the Find Best Move App Shortcut.
    case shortcut
    // There is no origin for a free adjustment: re-runs of a board (think time, side to move,
    // flip, castling) reuse its session and its authorization, so they never ask for credit.
}

/// What `CreditsService.authorize` decided.
enum CreditDecision: String, Sendable, Hashable, Codable {
    /// Pro is active: unlimited.
    case allowedPro
    /// No credit needed: within 3 squares of one of the last 20 paid boards.
    case allowedFreeReanalysis
    /// Spends one of the 3 free analyses on commit.
    case spendFree
    /// Spends one purchased credit on commit.
    case spendPurchased
    /// Not Pro and no credits: keep the position as the pending analysis and open the paywall.
    case needsPaywall

    /// The engine may start.
    var allowsAnalysis: Bool { self != .needsPaywall }
}

/// A decision for one board, handed back to `commit` once the engine has actually started.
struct CreditAuthorization: Sendable, Hashable, Identifiable {
    let id: UUID
    /// 64 entries, `Square.index`.
    let board: [Piece?]
    let origin: AnalysisOrigin
    let decision: CreditDecision

    init(id: UUID = UUID(), board: [Piece?], origin: AnalysisOrigin, decision: CreditDecision) {
        self.id = id
        self.board = board
        self.origin = origin
        self.decision = decision
    }
}

/// Free analyses, purchased credits and the paid-board memory (monetization.md sections 3-5).
@MainActor
protocol CreditsService: AnyObject, Observable, Sendable {
    /// The number of free analyses a new install gets (3).
    var freeAllowance: Int { get }
    /// Free analyses left, 0...freeAllowance. Stored in the Keychain.
    var freeRemaining: Int { get }
    /// Purchased credits left (a separate balance).
    var purchasedRemaining: Int { get }

    /// Decides whether analyzing `board` costs a credit, without spending anything. Order of
    /// use: Pro, then free, then purchased. Compare against paid boards treating a board
    /// rotated by 180 degrees (a flip) as the same board.
    func authorize(board: [Piece?], origin: AnalysisOrigin) -> CreditAuthorization

    /// Spends the credit (if any) and records the paid board. Call once, after the engine has
    /// actually started. Must be idempotent for the same authorization id, and must re-check
    /// the balance (spend purchased if free ran out in between; spend nothing if Pro).
    func commit(_ authorization: CreditAuthorization)

    /// Whether closing the paywall should show the pack downsell (monetization.md 4.6):
    /// the paywall came from the credit trigger, and no downsell was closed without buying
    /// in the last 24 hours.
    func shouldOfferDownsell(after trigger: PaywallTrigger) -> Bool
    /// Records that the downsell sheet was closed without buying.
    func recordDownsellDeclined()
}

// MARK: - Store (implemented by Monetization)

/// Product identifiers from monetization.md section 2.
enum ProductID {
    static let proWeekly = "com.motomatic.chessbestmove.pro.weekly"
    static let proAnnual = "com.motomatic.chessbestmove.pro.annual"
    static let proLifetime = "com.motomatic.chessbestmove.pro.lifetime"
    static let credits15 = "com.motomatic.chessbestmove.credits.15"

    /// Paywall rows in order: Weekly (preselected), Yearly, Lifetime.
    static let paywall = [proWeekly, proAnnual, proLifetime]
    static let all = [proWeekly, proAnnual, proLifetime, credits15]
    /// Credits granted per pack transaction.
    static let creditsPerPack = 15
}

/// A product as the UI needs it, decoupled from `StoreKit.Product` so views can be
/// previewed and tested without the App Store.
struct StoreProduct: Sendable, Identifiable, Hashable {
    enum Kind: Sendable, Hashable {
        case autoRenewable(period: Product.SubscriptionPeriod.Unit, value: Int)
        case nonConsumable
        case consumable
    }

    let id: String
    let displayName: String
    let description: String
    /// Localized price text from `Product.displayPrice`. Never build prices with a literal "$".
    let displayPrice: String
    let price: Decimal
    let priceFormatStyle: Decimal.FormatStyle.Currency
    let kind: Kind
}

enum StoreLoadState: Sendable, Hashable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum PurchaseOutcome: Sendable, Hashable {
    /// Verified and finished. Names the product the user bought, also for a crossgrade (a weekly
    /// subscriber buying Yearly), where StoreKit returns the current plan's transaction and the
    /// new plan starts at the next renewal.
    case purchased(productID: String)
    /// Waiting for Ask to Buy or parental approval; `Transaction.updates` delivers the result.
    case pending
    case cancelled
    case failed(String)
}

enum RestoreOutcome: Sendable, Hashable {
    /// "Purchases restored."
    case restored
    /// "No previous purchases found."
    case nothingFound
    /// The user closed the Apple Account sign-in. Nothing failed: no message, no haptic.
    case canceled
    case failed(String)
}

/// Delivered to observers registered with `StoreService.addTransactionObserver`.
enum StoreEvent: Sendable, Hashable {
    /// A verified transaction arrived and was finished (including Ask to Buy approvals).
    case transactionVerified(productID: String)
    /// A refund or revocation ended an entitlement or removed credits.
    case transactionRevoked(productID: String)
}

/// StoreKit 2 purchases and entitlements.
@MainActor
protocol StoreService: AnyObject, Observable, Sendable {
    var loadState: StoreLoadState { get }
    /// Loaded products, in `ProductID.all` order.
    var products: [StoreProduct] { get }
    /// Any active transaction in the Pro subscription group, or a verified lifetime purchase.
    /// Never a check against a fixed list of subscription ids (monetization.md section 2).
    var isPro: Bool { get }
    /// The product id of the active auto-renewable subscription, if any.
    var activeSubscriptionProductID: String? { get }
    /// True once `Transaction.currentEntitlements` has been read in this launch; until then
    /// `isPro` comes from the previous launch.
    var hasLoadedEntitlements: Bool { get }
    /// Show the one-time "Switch to yearly" card on the result screen: a weekly subscriber
    /// in their 4th paid week or later who has not dismissed the card (monetization.md 4.9).
    var shouldOfferSwitchToYearly: Bool { get }

    /// Starts the `Transaction.updates` listener and refreshes entitlements. Called once at
    /// launch by `ChessBestMoveApp`; must be idempotent.
    func start()
    func loadProducts() async
    func purchase(_ productID: String) async -> PurchaseOutcome
    /// `AppStore.sync()` then a refresh of entitlements.
    func restore() async -> RestoreOutcome
    func refreshEntitlements() async
    /// Opens the system subscription management sheet.
    func showManageSubscriptions() async
    /// Registers an observer for verified and revoked transactions. Observers live as long as
    /// the store.
    func addTransactionObserver(_ observer: @escaping @MainActor (StoreEvent) -> Void)
    /// Records that the "Switch to yearly" card was dismissed or tapped; it never shows again.
    func recordSwitchToYearlyOfferShown()
}

// MARK: - Paywall and downsell (implemented by Monetization)

/// What opened the paywall.
enum PaywallTrigger: String, Sendable, Hashable, Codable {
    /// Starting an analysis with no credits (the only trigger that can lead to the downsell).
    case creditsExhausted
    /// The CreditsIndicator at zero.
    case creditsIndicator
    /// Settings, "Unlock unlimited".
    case settings
    /// The one-time "Switch to yearly" card for weekly subscribers.
    case switchToYearly
    /// "That was your last free analysis." "See options".
    case lastFreeAnalysisNotice
}

/// Input for `PaywallView`.
struct PaywallContext: Sendable, Identifiable, Hashable {
    let id: UUID
    var trigger: PaywallTrigger
    /// The board waiting for the credit decision, for the thumbnail at the top.
    var board: BoardSnapshot?
    /// Overrides the default selection (Weekly), e.g. Yearly for `.switchToYearly`.
    var preselectedProductID: String?

    init(id: UUID = UUID(), trigger: PaywallTrigger, board: BoardSnapshot? = nil, preselectedProductID: String? = nil) {
        self.id = id
        self.trigger = trigger
        self.board = board
        self.preselectedProductID = preselectedProductID
    }
}

/// How the paywall ended. The paywall reports; `AppModel` decides what follows.
enum PaywallOutcome: Sendable, Hashable {
    /// Pro or credits were obtained (purchase or restore). The sheet is dismissed and any
    /// pending analysis starts.
    case unlocked(productID: String)
    /// A purchase is waiting for approval; the pending analysis starts when it is approved.
    case pendingApproval
    /// Closed with the close control.
    case closed
}

/// Input for `DownsellView`.
struct DownsellContext: Sendable, Identifiable, Hashable {
    let id: UUID
    var board: BoardSnapshot?

    init(id: UUID = UUID(), board: BoardSnapshot? = nil) {
        self.id = id
        self.board = board
    }
}

enum DownsellOutcome: Sendable, Hashable {
    /// The 15-pack was bought; the pending analysis spends 1 credit and runs.
    case purchased
    case pendingApproval
    /// Closed with the close control; back to the board with the analysis not run.
    case closed
}

// Further Monetization entry points other features may use (App/Sources/Monetization/):
//   struct LastFreeAnalysisNotice: View { init(session: AnalysisSession) }
//       "That was your last free analysis." + "See options"; draws nothing unless `session`
//       spent the last free analysis and no credit or Pro remains (monetization.md 4.1).
//   struct SwitchToYearlyCard: View { init() }
//       The one-time card for weekly subscribers; draws nothing unless
//       `StoreService.shouldOfferSwitchToYearly` (monetization.md 4.9).
//   enum MonetizationLegalLinks { static let termsOfUse: URL; static let privacyPolicy: URL }
//       The one place for the published Terms of Use and Privacy Policy URLs. The terms are the
//       app's own, not Apple's standard EULA, whose usage rules conflict with GPLv3.

// MARK: - Engine (implemented by Analysis)

/// An evaluation from White's point of view (converted from the engine's side-to-move POV).
enum WhiteScore: Sendable, Hashable {
    case centipawns(Int)
    /// Positive: White mates in n. Negative: Black mates in n.
    case mate(Int)
}

/// The latest engine state for display.
struct EngineReadout: Sendable, Hashable {
    var depth: Int
    var score: WhiteScore?
    /// Best move so far, UCI.
    var bestMove: String?
    /// Principal variation, UCI.
    var principalVariation: [String]
    var nodesPerSecond: Int?
    var elapsed: Duration

    init(
        depth: Int = 0,
        score: WhiteScore? = nil,
        bestMove: String? = nil,
        principalVariation: [String] = [],
        nodesPerSecond: Int? = nil,
        elapsed: Duration = .zero
    ) {
        self.depth = depth
        self.score = score
        self.bestMove = bestMove
        self.principalVariation = principalVariation
        self.nodesPerSecond = nodesPerSecond
        self.elapsed = elapsed
    }
}

enum EnginePhase: Sendable, Hashable {
    case idle
    /// Loading the network (first analysis of the session).
    case preparing
    case searching
    /// Think time elapsed or Stop was pressed; `readout` holds the result.
    case finished
    /// Checkmate or stalemate: no best move.
    case noLegalMoves(checkmate: Bool)
    case failed(String)
}

/// Wraps `StockfishEngine.shared`: validation, lazy `prepare()`, event coalescing, White
/// point of view, and stopping on background.
@MainActor
protocol EngineController: AnyObject, Observable, Sendable {
    var phase: EnginePhase { get }
    var readout: EngineReadout? { get }
    /// The think time of the current or last search.
    var thinkTime: ThinkTime? { get }
    /// "Stockfish 19".
    var engineVersion: String { get }

    /// Validates the position, prepares the engine if needed and starts the search. Returns
    /// true once the search has started (the caller then commits the credit), false if the
    /// position was rejected, has no legal moves, or the engine failed.
    func start(_ position: Position, thinkTime: ThinkTime) async -> Bool
    /// Ends the search early; `phase` becomes `.finished` with the best move so far.
    func stop()
}

// MARK: - UI test hooks

/// Accessibility identifiers that UI tests rely on. A feature that replaces a stub keeps each
/// identifier on the equivalent element.
enum AccessibilityID {
    /// DEBUG builds: Home's control that imports the bundled sample screenshot.
    static let homeDebugSample = "home.debugSample"
    /// The root of the Recognizing screen.
    static let recognizingScreen = "recognizing.screen"
    /// The best move on the Analysis screen (the hero move). Present only once a best move,
    /// provisional or final, is known.
    static let analysisBestMove = "analysis.bestMove"
}
