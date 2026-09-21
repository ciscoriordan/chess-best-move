import ChessCore
import Foundation
import Observation

// MARK: - Routes

/// Pushed screens. The stack is always one of:
/// `[]` (Home), `[.recognizing]`, `[.checkPosition]`, `[.boardNotFound]`, `[.analysis]`.
enum Route: Hashable {
    /// Recognizing (design.md 9.2). Capture's `RecognizingView` runs recognition and calls
    /// `AppModel.handleRecognition(_:for:)`.
    case recognizing(ImportedImage)
    /// Board not found (design.md 9.5, second wireframe).
    case boardNotFound(ImportedImage)
    /// Check position (design.md 9.5): low-confidence recognition, nothing spent yet.
    case checkPosition(BoardSnapshot)
    /// Analyzing and Result in one screen (design.md 9.3, 9.4).
    case analysis(AnalysisSession)
}

/// Modal sheets presented from the root.
enum SheetRoute: Identifiable, Hashable {
    case paywall(PaywallContext)
    case downsell(DownsellContext)
    case settings
    case shortcutSetup

    var id: String {
        switch self {
        case .paywall(let context): "paywall-\(context.id)"
        case .downsell(let context): "downsell-\(context.id)"
        case .settings: "settings"
        case .shortcutSetup: "shortcutSetup"
        }
    }

    /// Whether this sheet asks the user to buy something. `AppModel.present(_:)` refuses these
    /// for a member of the free launch cohort (monetization.md section 11).
    var offersAPurchase: Bool {
        switch self {
        case .paywall, .downsell: true
        case .settings, .shortcutSetup: false
        }
    }
}

/// Input for the full-screen position editor (design.md 9.6).
struct EditorContext: Identifiable, Hashable, Sendable {
    enum Purpose: String, Sendable, Hashable {
        /// Fix a recognized (or already analyzed) board. Analyze uses origin `.editor`, or
        /// `.handSetup` if the user chose Start position or Clear board.
        case correction
        /// "Set up the position by hand". Analyze uses origin `.handSetup`.
        case handSetup
    }

    let id: UUID
    var snapshot: BoardSnapshot
    /// Preselected square, e.g. a tapped low-confidence square on Check position.
    var selectedSquare: Square?
    var purpose: Purpose

    init(id: UUID = UUID(), snapshot: BoardSnapshot, selectedSquare: Square? = nil, purpose: Purpose) {
        self.id = id
        self.snapshot = snapshot
        self.selectedSquare = selectedSquare
        self.purpose = purpose
    }
}

// MARK: - Analysis session

/// One board on the Analysis screen, including its credit state. Analysis mutates
/// `snapshot` for free adjustments (flip, side to move, castling); the app shell owns
/// `creditState`.
@MainActor
@Observable
final class AnalysisSession: Identifiable, Hashable {
    enum CreditState: Hashable, Sendable {
        /// The engine may run. Commit happens once through `AppModel.analysisDidStart`.
        case authorized(CreditAuthorization)
        /// No credit: the board is shown with the analysis not run and the paywall is (or
        /// was) presented. "Analyze" calls `AppModel.retryAnalysis(_:)`.
        case waitingForPurchase
        /// A purchase awaits Ask to Buy approval.
        case waitingForApproval
    }

    nonisolated let id: UUID
    let origin: AnalysisOrigin
    var snapshot: BoardSnapshot
    fileprivate(set) var creditState: CreditState
    fileprivate(set) var isCreditCommitted = false

    init(id: UUID = UUID(), snapshot: BoardSnapshot, origin: AnalysisOrigin, creditState: CreditState = .waitingForPurchase) {
        self.id = id
        self.snapshot = snapshot
        self.origin = origin
        self.creditState = creditState
    }

    /// The authorization when the engine may run.
    var authorization: CreditAuthorization? {
        if case .authorized(let authorization) = creditState { return authorization }
        return nil
    }

    var canAnalyze: Bool { authorization != nil }

    nonisolated static func == (lhs: AnalysisSession, rhs: AnalysisSession) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - App model

/// Composition root, router and owner of the pending analysis.
///
/// Features read services and call navigation methods through
/// `@Environment(AppModel.self)`. Views never set `path`, `sheet` or `editor` directly
/// except through the binding in `RootView`.
@MainActor
@Observable
final class AppModel {
    /// The live model, for App Intents that run inside the app process.
    private(set) static var current: AppModel?

    let settings: AppSettings
    let store: any StoreService
    let credits: any CreditsService
    let recognition: any RecognitionService
    let engine: any EngineController

    /// The navigation stack (see `Route`). Leaving a board's Analysis screen by any means
    /// (New, the back button or edge swipe, a new import) drops its pending analysis.
    var path: [Route] = [] {
        didSet { dropPendingAnalysisIfOffScreen() }
    }
    /// The presented sheet.
    var sheet: SheetRoute?
    /// The full-screen position editor.
    var editor: EditorContext?

    /// The position waiting for a credit decision (paywall, downsell or Ask to Buy approval).
    /// Always a board on the navigation stack.
    private(set) var pendingAnalysis: AnalysisSession? {
        didSet {
            // A board that stopped waiting (it ran, or the user left it) no longer needs its
            // Ask to Buy copy on disk.
            if pendingAnalysis !== oldValue, settings.pendingApprovalBoard != nil {
                settings.pendingApprovalBoard = nil
            }
        }
    }

    /// The sheet SwiftUI shows, or is still taking down, until `sheetDidDismiss()`.
    @ObservationIgnored private var presentedSheet: SheetRoute?
    /// Whether `presentedSheet` has already reported how it ended (or was replaced by the
    /// app), so its dismissal must not report it again.
    @ObservationIgnored private var presentedSheetFinished = false
    /// The sheet to present once the previous one is gone.
    @ObservationIgnored private var queuedSheet: SheetRoute?
    @ObservationIgnored private var dismissalWatchdog: Task<Void, Never>?
    /// Pro and the purchased balance as last observed, to react only when they grow.
    @ObservationIgnored private var lastSeenEntitlements: (isPro: Bool, purchasedRemaining: Int)?
    /// How long a queued sheet waits for SwiftUI's dismissal callback of the previous sheet.
    /// A dismissal takes about half a second; the callback never comes for a sheet that was
    /// taken down before SwiftUI presented it, and the queue must not wait for it forever.
    @ObservationIgnored var dismissalTimeout: Duration = .seconds(2)
    /// The clock for the Ask to Buy board's expiry.
    @ObservationIgnored var now: () -> Date = Date.init
    /// Whether `warmUpRecognition(after:)` has started or finished its warm-up.
    @ObservationIgnored private(set) var hasStartedRecognitionWarmUp = false

    init(
        settings: AppSettings,
        store: any StoreService,
        credits: any CreditsService,
        recognition: any RecognitionService,
        engine: any EngineController
    ) {
        self.settings = settings
        self.store = store
        self.credits = credits
        self.recognition = recognition
        self.engine = engine
        store.addTransactionObserver { [weak self] event in
            self?.handleStoreEvent(event)
        }
        observeEntitlements()
    }

    /// The production object graph, built from each feature folder's factory.
    static func live() -> AppModel {
        let store = MonetizationFeature.makeStoreService()
        return AppModel(
            settings: AppSettings(),
            store: store,
            credits: MonetizationFeature.makeCreditsService(store: store),
            recognition: CaptureFeature.makeRecognitionService(),
            engine: AnalysisFeature.makeEngineController()
        )
    }

    /// Makes this the model App Intents reach through `AppModel.current`.
    func makeCurrent() {
        Self.current = self
    }

    // MARK: Recognition warm-up

    /// How long after the first frame the recognition model starts loading: late enough to
    /// leave launch and the first Home render alone, early enough to finish before a user
    /// usually taps an import.
    static let recognitionWarmUpDelay: Duration = .milliseconds(800)

    /// Loads the recognition model in the background (`RecognitionService.warmUp()`), once per
    /// launch, after `delay`. Never blocks the main actor: the load runs on the recognition
    /// queue at utility priority, and a recognition started meanwhile waits for that load
    /// instead of loading again. Cancel-safe: cancelled during the delay, it loads nothing and
    /// a later call may try again; cancelled during the load, the load finishes and is kept.
    func warmUpRecognition(after delay: Duration) async {
        guard !hasStartedRecognitionWarmUp else { return }
        hasStartedRecognitionWarmUp = true
        do {
            try await Task.sleep(for: delay)
        } catch {
            hasStartedRecognitionWarmUp = false
            return
        }
        await recognition.warmUp()
    }

    // MARK: Import and recognition

    /// Starts recognition of an imported image from any import path (Home, paste, drop,
    /// App Shortcut). Replaces whatever screen is showing, including a sheet: a paywall or
    /// downsell taken down this way reports nothing (no downsell follows, no decline is
    /// recorded).
    func importImage(_ image: ImportedImage) {
        #if DEBUG
        DebugTimeline.shared.mark("imported")
        #endif
        editor = nil
        pendingAnalysis = nil
        settings.pendingApprovalBoard = nil
        replaceSheets()
        path = [.recognizing(image)]
    }

    /// Routes a finished recognition. Ignored if the user already left the Recognizing
    /// screen for that image.
    func handleRecognition(_ outcome: RecognitionOutcome, for image: ImportedImage) {
        guard case .recognizing(let current)? = path.last, current.id == image.id else { return }
        #if DEBUG
        DebugTimeline.shared.mark("recognized")
        #endif
        switch outcome {
        case .confident(let snapshot):
            requestAnalysis(of: snapshot, origin: image.source == .shortcut ? .shortcut : .recognition)
        case .needsCheck(let snapshot):
            path = [.checkPosition(snapshot)]
        case .boardNotFound, .invalidImage:
            path = [.boardNotFound(image)]
        }
    }

    /// Back to Home. Drops the pending analysis.
    func goHome() {
        editor = nil
        pendingAnalysis = nil
        settings.pendingApprovalBoard = nil
        path = []
    }

    /// A board the engine refused (for example two kings of one color after a misrecognized
    /// square) goes back to Check position with its problems flagged. Nothing was spent: the
    /// engine never ran.
    func returnToCheckPosition(_ snapshot: BoardSnapshot) {
        editor = nil
        pendingAnalysis = nil
        path = [.checkPosition(snapshot)]
    }

    // MARK: Editor

    func presentEditor(_ context: EditorContext) {
        editor = context
    }

    /// Closes the editor without analyzing (after "Discard changes?" if needed).
    func dismissEditor() {
        editor = nil
    }

    /// The editor's Analyze button.
    func finishEditing(with snapshot: BoardSnapshot, origin: AnalysisOrigin) {
        editor = nil
        requestAnalysis(of: snapshot, origin: origin)
    }

    // MARK: Analysis and credits

    /// Shows the Analysis screen for `snapshot` and asks the credits service whether it may
    /// run. Without credit the board stays on screen, the session becomes the pending
    /// analysis, and the paywall opens (monetization.md 4.2).
    func requestAnalysis(of snapshot: BoardSnapshot, origin: AnalysisOrigin) {
        let session = AnalysisSession(snapshot: snapshot, origin: origin)
        path = [.analysis(session)]
        authorize(session, presentingPaywall: true)
    }

    /// "Analyze" on a board whose analysis was not run for lack of credit, or that waits for
    /// an Ask to Buy approval (the user may buy something else meanwhile).
    func retryAnalysis(_ session: AnalysisSession) {
        authorize(session, presentingPaywall: true)
    }

    /// Called by Analysis once the engine has actually started for `session`. Commits the
    /// credit exactly once per session; later re-runs (think time, flip, side to move) are
    /// free adjustments and commit nothing.
    func analysisDidStart(_ session: AnalysisSession) {
        guard let authorization = session.authorization, !session.isCreditCommitted else { return }
        session.isCreditCommitted = true
        credits.commit(authorization)
    }

    private func authorize(_ session: AnalysisSession, presentingPaywall: Bool) {
        let authorization = credits.authorize(board: session.snapshot.position.board, origin: session.origin,
                                              recognition: MonetizationRecognitionEvidence(session.snapshot))
        if authorization.decision.allowsAnalysis {
            session.creditState = .authorized(authorization)
            if pendingAnalysis === session { pendingAnalysis = nil }
        } else {
            if session.creditState != .waitingForApproval {
                session.creditState = .waitingForPurchase
            }
            pendingAnalysis = isOnScreen(session) ? session : nil
            if presentingPaywall {
                present(.paywall(PaywallContext(trigger: .creditsExhausted, board: session.snapshot)))
            }
        }
    }

    private func resumePendingAnalysis() {
        guard let session = pendingAnalysis else { return }
        authorize(session, presentingPaywall: false)
    }

    /// The pending analysis now waits for an Ask to Buy approval. Its board is also kept on
    /// disk, so the analysis can start when the approval arrives after iOS ended the app.
    private func pendingAnalysisAwaitsApproval() {
        guard let session = pendingAnalysis else { return }
        session.creditState = .waitingForApproval
        settings.pendingApprovalBoard = AppPendingApprovalBoard(snapshot: session.snapshot, origin: session.origin, savedAt: now())
    }

    private func handleStoreEvent(_ event: StoreEvent) {
        switch event {
        case .transactionVerified:
            // A purchase or an Ask to Buy approval, possibly for another board than the one
            // that asked (the user may have moved on to a newer board meanwhile).
            if pendingAnalysis != nil {
                resumePendingAnalysisIfItMayRun()
            } else {
                restorePendingApprovalBoard()
            }
        case .transactionRevoked:
            break
        }
    }

    /// Re-authorizes the pending board without opening a paywall. When it may now run, a sheet
    /// that only offered credit for it closes without an outcome.
    private func resumePendingAnalysisIfItMayRun() {
        guard let session = pendingAnalysis else { return }
        authorize(session, presentingPaywall: false)
        if session.canAnalyze { closePurchaseSheets() }
    }

    /// Pro or purchased credits can also arrive without a transaction event: the launch refresh
    /// of entitlements finishing after the board opened the paywall (Pro starts from the
    /// previous launch's state), or packs bought on another device. The pending board then
    /// runs as after a purchase.
    private func observeEntitlements() {
        let seen = withObservationTracking {
            (isPro: store.isPro, purchasedRemaining: credits.purchasedRemaining)
        } onChange: { [weak self] in
            // Called before the new value is set; read it on the next turn of the main actor.
            Task { @MainActor [weak self] in
                self?.observeEntitlements()
            }
        }
        defer { lastSeenEntitlements = seen }
        // Only a gain counts (Pro turned on, more purchased credits), so re-reading the credits
        // while authorizing can never start another round.
        guard let last = lastSeenEntitlements,
              (seen.isPro && !last.isPro) || seen.purchasedRemaining > last.purchasedRemaining,
              let session = pendingAnalysis, !session.canAnalyze else { return }
        resumePendingAnalysisIfItMayRun()
    }

    /// Starts the board kept for an Ask to Buy request when its approval arrives after iOS
    /// ended the app (monetization.md 4.4). Only on Home with nothing presented, so it never
    /// replaces what the user is doing, and only when the board may now run.
    private func restorePendingApprovalBoard() {
        guard let saved = settings.pendingApprovalBoard else { return }
        guard !saved.isExpired(now: now()), let snapshot = saved.snapshot else {
            settings.pendingApprovalBoard = nil
            return
        }
        guard path.isEmpty, sheet == nil, presentedSheet == nil, editor == nil else { return }
        // A board restored for an Ask to Buy approval keeps no reading, so it gets no free
        // squares (monetization.md section 5).
        let authorization = credits.authorize(board: snapshot.position.board, origin: saved.origin,
                                              recognition: MonetizationRecognitionEvidence(snapshot))
        guard authorization.decision.allowsAnalysis else { return }
        settings.pendingApprovalBoard = nil
        path = [.analysis(AnalysisSession(snapshot: snapshot, origin: saved.origin, creditState: .authorized(authorization)))]
    }

    private func isOnScreen(_ session: AnalysisSession) -> Bool {
        path.contains { route in
            if case .analysis(let shown) = route { return shown === session }
            return false
        }
    }

    private func dropPendingAnalysisIfOffScreen() {
        if let session = pendingAnalysis, !isOnScreen(session) {
            pendingAnalysis = nil
        }
    }

    // MARK: Sheets

    /// Opens the paywall from anywhere other than the credit trigger (CreditsIndicator,
    /// Settings, "See options", "Switch to yearly").
    func presentPaywall(trigger: PaywallTrigger, preselectedProductID: String? = nil) {
        present(.paywall(PaywallContext(
            trigger: trigger,
            board: pendingAnalysis?.snapshot,
            preselectedProductID: preselectedProductID
        )))
    }

    func presentSettings() {
        present(.settings)
    }

    func presentShortcutSetup() {
        present(.shortcutSetup)
    }

    /// Presents a sheet, replacing (after its dismissal) any sheet already showing or still
    /// going away. Presenting while the previous sheet is still being dismissed would let
    /// that dismissal's callback end the new sheet.
    ///
    /// A member of the free launch cohort is never shown a purchase screen (monetization.md
    /// section 11). Nothing should ask: the credit rules answer `.allowedPro` for them, so
    /// there is no credit trigger, and every control that opens the paywall is hidden. This is
    /// the last lock, here because the cost of one missed control is a member meeting a price
    /// they were promised they would never see.
    func present(_ route: SheetRoute) {
        if store.isLaunchCohortMember, route.offersAPurchase {
            MonetizationLog.store.notice("a purchase sheet was refused: this Apple Account is in the free launch cohort")
            return
        }
        if sheet != nil || presentedSheet != nil {
            queuedSheet = route
            sheet = nil
            startDismissalWatchdog()
        } else {
            show(route)
        }
    }

    /// Closes the current sheet (Settings, Shortcut setup).
    func dismissSheet() {
        sheet = nil
    }

    /// `PaywallView` reports how it ended. Safe to call from a paywall that is no longer the
    /// presented sheet: the root sheet is only dismissed, and the downsell only offered, for
    /// the presented paywall.
    func paywallFinished(_ context: PaywallContext, outcome: PaywallOutcome) {
        var isPresented = false
        if case .paywall(let presented)? = presentedSheet, presented.id == context.id {
            isPresented = !presentedSheetFinished
            presentedSheetFinished = true
        }
        if case .paywall(let shown)? = sheet, shown.id == context.id {
            sheet = nil
        }
        switch outcome {
        case .unlocked:
            resumePendingAnalysis()
        case .pendingApproval:
            pendingAnalysisAwaitsApproval()
        case .closed:
            if isPresented, context.trigger == .creditsExhausted, queuedSheet == nil, let pending = pendingAnalysis,
               credits.shouldOfferDownsell(after: context.trigger) {
                queuedSheet = .downsell(DownsellContext(board: pending.snapshot))
            }
        }
    }

    /// `DownsellView` reports how it ended.
    func downsellFinished(_ context: DownsellContext, outcome: DownsellOutcome) {
        var isPresented = false
        if case .downsell(let presented)? = presentedSheet, presented.id == context.id {
            isPresented = !presentedSheetFinished
            presentedSheetFinished = true
        }
        if case .downsell(let shown)? = sheet, shown.id == context.id {
            sheet = nil
        }
        switch outcome {
        case .purchased:
            resumePendingAnalysis()
        case .pendingApproval:
            pendingAnalysisAwaitsApproval()
        case .closed:
            if isPresented {
                credits.recordDownsellDeclined()
            }
        }
    }

    /// Called by `RootView` when a sheet has gone away (close control, swipe, or a finish
    /// call). A paywall or downsell dismissed by swiping counts as closed.
    ///
    /// SwiftUI calls this only after the sheet binding became nil, so a call while a sheet is
    /// set belongs to an earlier sheet whose dismissal finished late, and is ignored.
    func sheetDidDismiss() {
        guard sheet == nil else { return }
        dismissalWatchdog?.cancel()
        dismissalWatchdog = nil
        if let dismissed = presentedSheet, !presentedSheetFinished {
            // The finish calls mark the sheet finished themselves.
            switch dismissed {
            case .paywall(let context): paywallFinished(context, outcome: .closed)
            case .downsell(let context): downsellFinished(context, outcome: .closed)
            case .settings, .shortcutSetup: break
            }
            presentedSheetFinished = true
        }
        presentedSheet = nil
        if case .downsell? = queuedSheet, pendingAnalysis?.canAnalyze != false || store.isPro {
            // The pack offer has nothing left to offer: the board it was for is gone or may run
            // (Pro arrived while the paywall was going away).
            queuedSheet = nil
            resumePendingAnalysisIfItMayRun()
        }
        if let next = queuedSheet {
            queuedSheet = nil
            show(next)
        }
    }

    private func show(_ route: SheetRoute) {
        dismissalWatchdog?.cancel()
        dismissalWatchdog = nil
        presentedSheet = route
        presentedSheetFinished = false
        sheet = route
    }

    /// Takes down every sheet for a programmatic replacement, without an outcome.
    private func replaceSheets() {
        queuedSheet = nil
        if presentedSheet != nil { presentedSheetFinished = true }
        if sheet != nil { sheet = nil }
    }

    /// A purchase or approval made the pending analysis runnable: a sheet that only offered
    /// credit for it (the downsell, or a paywall opened for having no credit) has nothing left
    /// to offer and closes without an outcome. A paywall the user opened from Settings or the
    /// "Switch to yearly" card stays; it closes itself when its own purchase ends.
    private func closePurchaseSheets() {
        func offersCreditOnly(_ route: SheetRoute?) -> Bool {
            switch route {
            case .downsell?: true
            case .paywall(let context)?: [.creditsExhausted, .creditsIndicator, .lastFreeAnalysisNotice].contains(context.trigger)
            case .settings?, .shortcutSetup?, nil: false
            }
        }
        if offersCreditOnly(queuedSheet) { queuedSheet = nil }
        if offersCreditOnly(presentedSheet) {
            presentedSheetFinished = true
            if sheet == presentedSheet { sheet = nil }
        }
    }

    /// Presents the queued sheet even if SwiftUI never reports the previous dismissal.
    private func startDismissalWatchdog() {
        dismissalWatchdog?.cancel()
        let timeout = dismissalTimeout
        dismissalWatchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.sheet == nil, self.queuedSheet != nil else { return }
            self.sheetDidDismiss()
        }
    }
}
