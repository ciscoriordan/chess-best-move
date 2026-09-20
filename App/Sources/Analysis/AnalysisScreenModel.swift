import ChessCore
import Observation
import SwiftUI

// MARK: - Run ledger

/// How one analysis run of a session ended.
enum AnalysisRunCompletion: Sendable, Hashable {
    /// `move` gives the spoken form its full from-square ("knight from b1 to d2").
    case bestMove(san: String, move: Move?, score: WhiteScore?)
    case noLegalMoves(checkmate: Bool)
    /// The engine rejected the board; the app went back to Check position.
    case invalidPosition
    case failed(String)
}

/// Which session owns the engine's current search, and how each session's latest run ended.
/// The Analysis screen writes it; the Find Best Move App Shortcut reads it to answer with the
/// result of the board it imported.
@MainActor
final class AnalysisRunLedger {
    static let shared = AnalysisRunLedger()

    /// The session whose run started most recently.
    private(set) var activeSessionID: UUID?
    private var completions: [UUID: AnalysisRunCompletion] = [:]
    private var completionOrder: [UUID] = []

    func markStarted(_ sessionID: UUID) {
        activeSessionID = sessionID
        completions[sessionID] = nil
    }

    func record(_ completion: AnalysisRunCompletion, for sessionID: UUID) {
        if completions.updateValue(completion, forKey: sessionID) == nil {
            completionOrder.append(sessionID)
        }
        // Only recent sessions matter; keep the ledger small.
        while completionOrder.count > 20 {
            completions[completionOrder.removeFirst()] = nil
        }
    }

    func completion(for sessionID: UUID) -> AnalysisRunCompletion? {
        completions[sessionID]
    }
}

// MARK: - Screen model

/// State and actions of the Analysis screen (design.md 9.3 and 9.4). Owns nothing global:
/// the engine, settings, credits and navigation are reached through `AppModel`.
@MainActor
@Observable
final class AnalysisScreenModel {
    enum RunState: Hashable, Sendable {
        /// Not run yet (for example waiting for a purchase).
        case notStarted
        /// `EngineController.start` was called and has not returned.
        case starting
        case running
        /// The search finished, or Stop was pressed.
        case completed
        /// Stopped because the app went to the background or the screen was left.
        case interrupted
        case failed(String)
    }

    enum Interruption: Hashable, Sendable {
        case background
        case leftScreen
    }

    let app: AppModel
    let session: AnalysisSession
    /// The search that keeps running quietly after the first answer (design.md section 16).
    let longerSearch: AnalysisLongerSearch

    private(set) var runState: RunState = .notStarted
    private(set) var interruption: Interruption?
    /// The think time of the current or last run.
    private(set) var runThinkTime: ThinkTime
    /// When the current run's engine search began, for the think-time progress rule.
    private(set) var searchStartedAt: Date?
    /// Incremented when an analysis completes (success haptic).
    private(set) var completionCount = 0
    /// Incremented when the side to move is swapped or the board flipped (selection haptic).
    private(set) var adjustmentCount = 0
    var isLineExpanded = false

    @ObservationIgnored private let ledger: AnalysisRunLedger
    @ObservationIgnored private var runToken = 0
    @ObservationIgnored private var observationToken = 0
    @ObservationIgnored private var isObservingEngine = false
    /// True from `run` until the engine shows this run's own phase (busy, or `start`
    /// returned), so a terminal phase left over from the previous run is never taken as
    /// this run's result.
    @ObservationIgnored private var awaitingRunPhase = false
    /// The user pressed Stop. They asked the engine to stop thinking, so the longer search
    /// does not start behind that.
    @ObservationIgnored private var didStopEarly = false

    init(app: AppModel, session: AnalysisSession, ledger: AnalysisRunLedger = .shared) {
        self.app = app
        self.session = session
        self.ledger = ledger
        runThinkTime = app.settings.thinkTime
        // A stub engine (tests, previews) cannot take a quiet search; the feature then never
        // runs and the screen behaves exactly as it did before.
        longerSearch = AnalysisLongerSearch(runner: app.engine as? any AnalysisLongerSearchRunner)
        longerSearch.didFinish = { [weak self] state in
            self?.longerSearchDidFinish(state)
        }
    }

    // MARK: Derived state

    /// The session's position as the engine sees it (inconsistent castling and en passant
    /// removed), used for SAN and legality checks.
    var position: Position { AnalysisPositionCheck.sanitized(session.snapshot.position) }

    var isThinking: Bool { runState == .starting || runState == .running }

    /// The engine's readout, when it belongs to this session's run.
    ///
    /// Once the user (or their Pro setting) has taken the longer search's move, that search's
    /// readout is the one the whole screen reads: the badge, the arrow, the line, the
    /// evaluation and the depth all come from the answer that is actually shown.
    var readout: EngineReadout? {
        guard ledger.activeSessionID == session.id, runState != .notStarted else { return nil }
        if case .failed = runState { return nil }
        if let adopted = longerSearch.adoptedReadout { return adopted }
        return app.engine.readout
    }

    /// The best move so far, when it is legal on the board shown (never a stale move from a
    /// board before a flip or side swap).
    var bestMove: (move: Move, san: String)? {
        guard let uci = readout?.bestMove, let move = Move(uci: uci), let san = position.san(for: move) else { return nil }
        return (move, san)
    }

    /// Checkmate or stalemate on the board shown, once the engine reported it.
    var noLegalMoves: Bool? {
        guard ledger.activeSessionID == session.id, runState == .completed,
              case .noLegalMoves(let checkmate) = app.engine.phase
        else { return nil }
        return checkmate
    }

    /// What the result readout shows (design.md 9.4): the move in the badge, the pill and the
    /// evaluation beside it, and the guessed move the badge answers when the screenshot caught
    /// the turn of the player at the top.
    var resultReadout: AnalysisReadoutContent {
        readoutContent(for: readout, status: readoutStatus, quickAnswerIsBeaten: longerSearch.quickAnswerIsBeaten)
    }

    /// The readout a given engine answer produces on this board. `resultReadout` is this for
    /// the answer on screen; the longer-search notice is this for the answer it found, so the
    /// notice names the move the badge would hold rather than a move of the engine's own that
    /// the badge would not show (the reply case of design.md 9.4).
    private func readoutContent(
        for readout: EngineReadout?,
        status: AnalysisReadoutContent.Status,
        quickAnswerIsBeaten: Bool
    ) -> AnalysisReadoutContent {
        let board = position
        let best: (move: Move, san: String)? = {
            guard let uci = readout?.bestMove, let move = Move(uci: uci), let san = board.san(for: move) else { return nil }
            return (move, san)
        }()
        return AnalysisReadoutContent.make(
            status: status,
            position: board,
            whiteAtBottom: session.snapshot.whiteAtBottom,
            sideToMoveOrigin: session.snapshot.sideToMoveOrigin,
            bestMove: best,
            principalVariation: readout?.principalVariation ?? [],
            noLegalMoves: noLegalMoves,
            quickAnswerIsBeaten: quickAnswerIsBeaten
        )
    }

    private var readoutStatus: AnalysisReadoutContent.Status {
        switch runState {
        case .notStarted: .notRun
        case .starting, .running: .thinking
        case .completed: .done
        case .interrupted: .stopped
        case .failed: .engineError
        }
    }

    /// The badge move's VoiceOver label: the spoken form of the move the badge shows
    /// (design.md 12), which is the engine's answer rather than its best move when the
    /// screenshot caught the turn of the player at the top. Nil when the badge shows no move
    /// (checkmate, stalemate, or no move yet).
    var heroSpokenDescription: String? {
        resultReadout.move?.words
    }

    /// The callout line under the hero (design.md 9.3 and 9.4): the spoken form of the move, or
    /// what is going on.
    var detailLine: String {
        let side = AnalysisSpeech.colorName(session.snapshot.position.sideToMove)
        if let checkmate = noLegalMoves {
            return checkmate ? "\(side) is checkmated." : "\(side) has no legal moves. The game is drawn."
        }
        switch runState {
        case .failed(let message):
            return message
        case .interrupted where interruption == .background:
            return "Stopped when the app went to the background. Run it again for the full think time."
        case .interrupted:
            return "Stopped before the think time was up. Run it again for the full think time."
        case .notStarted:
            switch session.creditState {
            case .waitingForApproval: return "Waiting for purchase approval. The analysis starts when it is approved."
            case .waitingForPurchase, .authorized: return "Analysis not run."
            }
        case .starting, .running, .completed:
            if let spoken = heroSpokenDescription { return spoken }
            return app.engine.phase == .preparing ? "Loading the engine." : "Thinking."
        }
    }

    /// The callout line says exactly what the hero move's VoiceOver label says, so VoiceOver
    /// skips the callout and reads the move once.
    var detailRepeatsHero: Bool {
        guard let spoken = heroSpokenDescription else { return false }
        return detailLine == spoken
    }

    /// The castling right the result's best move (or the first move of the engine line) uses
    /// when the user never confirmed it: a screenshot cannot show whether the king or rook has
    /// already moved. Analysis then shows "Assumes castling is still allowed." with a way to turn
    /// the right off (design.md 9.4). Nil while the engine thinks, and for any other move.
    var assumedCastlingRight: CastlingRights? {
        guard runState == .completed || runState == .interrupted, noLegalMoves == nil else { return nil }
        let unconfirmed = session.snapshot.unconfirmedCastlingRights
        guard !unconfirmed.isEmpty else { return nil }
        let sanitized = position
        var moves: [Move] = []
        if let best = bestMove?.move { moves.append(best) }
        if let first = readout?.principalVariation.first.flatMap({ Move(uci: $0) }) { moves.append(first) }
        for move in moves {
            if let right = Self.castlingRight(of: move, in: sanitized), unconfirmed.contains(right) {
                return right
            }
        }
        return nil
    }

    /// The castling right `move` uses when it castles in `position` (the king from its home
    /// square two files toward a rook), or nil.
    nonisolated static func castlingRight(of move: Move, in position: Position) -> CastlingRights? {
        guard let piece = position.board[move.from.index], piece.kind == .king else { return nil }
        let homeRank = piece.color == .white ? 0 : 7
        guard move.from.file == 4, move.from.rank == homeRank, move.to.rank == homeRank else { return nil }
        let right: CastlingRights
        switch (piece.color, move.to.file) {
        case (.white, 6): right = .whiteKingside
        case (.white, 2): right = .whiteQueenside
        case (.black, 6): right = .blackKingside
        case (.black, 2): right = .blackQueenside
        default: return nil
        }
        return position.castlingRights.contains(right) ? right : nil
    }

    /// "Turn off White O-O" for the assumed right.
    nonisolated static func turnOffTitle(_ right: CastlingRights) -> String {
        "Turn off \(castlingName(right))"
    }

    /// "White O-O", as on the castling chips of Check position and the editor.
    nonisolated static func castlingName(_ right: CastlingRights) -> String {
        switch right {
        case .whiteKingside: "White O-O"
        case .whiteQueenside: "White O-O-O"
        case .blackKingside: "Black O-O"
        default: "Black O-O-O"
        }
    }

    /// "White castling kingside", for VoiceOver.
    nonisolated static func spokenCastlingName(_ right: CastlingRights) -> String {
        switch right {
        case .whiteKingside: "White castling kingside"
        case .whiteQueenside: "White castling queenside"
        case .blackKingside: "Black castling kingside"
        default: "Black castling queenside"
        }
    }

    /// "Think longer: 10 s", or "Run again: 30 s" at the longest preset.
    var thinkLongerTitle: String {
        if let next = runThinkTime.next { return "Think longer: \(next.label)" }
        return "Run again: \(runThinkTime.label)"
    }

    // MARK: Lifecycle

    func appear() {
        startObservingEngine()
        // Back from the editor after an interrupted run, the screen offers "Run again"
        // instead of starting by itself.
        if runState == .notStarted {
            run(thinkTime: app.settings.thinkTime)
        }
    }

    func disappear() {
        // The longer search belongs to a screen nobody is looking at any more.
        longerSearch.cancel()
        if isThinking, ledger.activeSessionID == session.id {
            interruption = .leftScreen
            app.engine.stop()
        }
    }

    /// The session's credit state changed (a purchase or approval authorized it).
    func creditStateChanged() {
        if session.canAnalyze, runState == .notStarted {
            run(thinkTime: app.settings.thinkTime)
        }
    }

    /// iOS freezes the search threads in the background: stop there and offer a re-run.
    func scenePhaseChanged(to phase: ScenePhase) {
        guard phase == .background else { return }
        // The longer search stops and forgets what it had: it would be frozen anyway, and
        // nobody is there to read a notice (design.md section 16).
        longerSearch.cancel()
        guard isThinking, ledger.activeSessionID == session.id else { return }
        interruption = .background
        app.engine.stop()
    }

    // MARK: Actions

    /// Runs the engine on the session's board. Does nothing without credit authorization;
    /// the credit is committed through `AppModel.analysisDidStart` once the search runs.
    func run(thinkTime: ThinkTime) {
        guard session.canAnalyze else { return }
        let sanitized = position
        let blocking = AnalysisPositionCheck.blockingIssues(in: sanitized)
        guard blocking.isEmpty else {
            returnToCheckPosition(issues: blocking)
            return
        }

        // Whatever the longer search had to say was about the answer this run replaces.
        longerSearch.cancel()
        didStopEarly = false
        runToken += 1
        let token = runToken
        runThinkTime = thinkTime
        interruption = nil
        searchStartedAt = nil
        runState = .starting
        awaitingRunPhase = true
        ledger.markStarted(session.id)
        startObservingEngine()

        let engine = app.engine
        let snapshotPosition = session.snapshot.position
        Task { [weak self] in
            // A newer run, or a return to Check position, may have replaced this one before
            // the task ran: never start a search for a board that is no longer shown.
            guard self?.runToken == token else { return }
            let started = await engine.start(snapshotPosition, thinkTime: thinkTime)
            guard let self, token == self.runToken else { return }
            self.awaitingRunPhase = false
            if started {
                #if DEBUG
                DebugTimeline.shared.mark("engineStarted")
                #endif
                self.app.analysisDidStart(self.session)
                if self.runState == .starting { self.runState = .running }
                self.handle(engine.phase)
            } else {
                self.handle(engine.phase)
                if self.runState == .starting {
                    self.fail("The chess engine did not start.")
                }
            }
        }
    }

    func stop() {
        guard isThinking else { return }
        didStopEarly = true
        app.engine.stop()
    }

    /// A THINK segment: re-run with that time and make it the saved default (design.md 9.4).
    func selectThinkTime(_ thinkTime: ThinkTime) {
        app.settings.thinkTime = thinkTime
        guard thinkTime != runThinkTime || !isThinking else { return }
        run(thinkTime: thinkTime)
    }

    /// "Think longer": the next preset up, or the same 30 s again.
    func thinkLonger() {
        run(thinkTime: runThinkTime.next ?? runThinkTime)
    }

    /// Runs again with the current think time (after an interruption or a failure).
    func runAgain() {
        run(thinkTime: runThinkTime)
    }

    /// Swaps the side to move and re-runs. Free: an adjustment of the same board.
    func toggleSideToMove() {
        session.snapshot = session.snapshot.withSideToMove(session.snapshot.position.sideToMove.opposite)
        adjustmentCount += 1
        rerunAfterAdjustment()
    }

    /// Turns off the assumed castling right the best move uses and re-runs. Free: an
    /// adjustment of the same board, like the side to move.
    func turnOffAssumedCastling() {
        guard let right = assumedCastlingRight else { return }
        session.snapshot.position.castlingRights.remove(right)
        session.snapshot.confirmCastlingRight(right)
        adjustmentCount += 1
        rerunAfterAdjustment()
    }

    /// Flips the orientation (`BoardSnapshot.flippedByUser()`). Re-runs when the analyzed position changed;
    /// a board set up by hand only turns around on screen and keeps its result. Free.
    func flip() {
        let before = session.snapshot.position
        session.snapshot = session.snapshot.flippedByUser()
        adjustmentCount += 1
        guard session.snapshot.position != before else { return }
        rerunAfterAdjustment()
    }

    func edit() {
        if isThinking, ledger.activeSessionID == session.id {
            interruption = .leftScreen
            app.engine.stop()
        }
        app.presentEditor(EditorContext(snapshot: session.snapshot, purpose: .correction))
    }

    /// Analyze on a board that was not run for lack of credit.
    func analyzeAfterPaywall() {
        app.retryAnalysis(session)
        creditStateChanged()
    }

    func newAnalysis() {
        if isThinking, ledger.activeSessionID == session.id { app.engine.stop() }
        app.goHome()
    }

    // MARK: The longer search (design.md section 16)

    /// What the longer-search notice says, or nil when it says nothing. The notice sits under
    /// the assumed-castling caution and above the monetization notices
    /// (`AnalysisView.readoutGroups`).
    var longerSearchNotice: AnalysisLongerSearchNoticeContent? {
        guard runState == .completed, noLegalMoves == nil else { return nil }
        return AnalysisLongerSearchCopy.content(
            for: longerSearch.state,
            move: longerSearchMove,
            isPro: app.store.isPro
        )
    }

    /// The move the notice names: the one the badge would hold if the deeper answer were
    /// taken, which is the reply where the screenshot caught the turn of the player at the top.
    private var longerSearchMove: AnalysisReadoutContent.MoveText? {
        guard let preferred = longerSearch.preferredReadout else { return nil }
        return readoutContent(for: preferred, status: .done, quickAnswerIsBeaten: false).move
    }

    /// The notice's link. With Pro it puts the deeper move in the badge; without it, it opens
    /// the purchase options, because showing the move is what Pro adds here.
    func longerSearchAction() {
        guard longerSearch.quickAnswerIsBeaten else { return }
        if app.store.isPro {
            showTheLongerSearchMove()
        } else {
            app.presentPaywall(trigger: .longerSearchNotice)
        }
    }

    /// Puts the longer search's move in the badge, with the line, evaluation and arrow that
    /// belong to it. Nothing is spent: it is the board this session already paid for, and the
    /// engine is not asked for anything new. `userAsked` is false when a Pro setting made the
    /// switch, which is not a moment for a haptic.
    func showTheLongerSearchMove(userAsked: Bool = true) {
        guard longerSearch.quickAnswerIsBeaten else { return }
        longerSearch.showTheBetterMove()
        isLineExpanded = false
        if userAsked { adjustmentCount += 1 }
        if let best = bestMove {
            ledger.record(.bestMove(san: best.san, move: best.move, score: readout?.score), for: session.id)
        }
        if let notice = longerSearchNotice { announce(notice.spokenSentence) }
    }

    /// Starts the quiet search once an answer is on screen. It does not start behind a Stop
    /// the user pressed: they asked the engine to stop thinking about this board.
    private func startLongerSearch() {
        guard !didStopEarly, interruption == nil, noLegalMoves == nil,
              let quickAnswer = app.engine.readout, quickAnswer.bestMove != nil
        else { return }
        longerSearch.start(
            position: position,
            quickAnswer: quickAnswer,
            ceiling: app.settings.effectiveLongerSearchCeiling(isPro: app.store.isPro)
        )
    }

    /// The quiet search settled. A notice appears by itself, so VoiceOver is told what it says;
    /// with automatic switching on, the move is taken first and the notice says it is shown.
    private func longerSearchDidFinish(_ state: AnalysisLongerSearch.State) {
        guard case .prefers = state else { return }
        if app.settings.switchesToBetterMoveAutomatically(isPro: app.store.isPro) {
            showTheLongerSearchMove(userAsked: false)
            return
        }
        if let notice = longerSearchNotice { announce(notice.spokenSentence) }
    }

    // MARK: Engine observation

    private func rerunAfterAdjustment() {
        isLineExpanded = false
        guard session.canAnalyze else { return }
        run(thinkTime: runThinkTime)
    }

    private func startObservingEngine() {
        guard !isObservingEngine else { return }
        isObservingEngine = true
        observationToken += 1
        observeEngine(token: observationToken)
    }

    private func observeEngine(token: Int) {
        guard token == observationToken else { return }
        let phase = withObservationTracking {
            app.engine.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeEngine(token: token) }
        }
        handle(phase)
    }

    private func handle(_ phase: EnginePhase) {
        guard isThinking, ledger.activeSessionID == session.id else { return }
        switch phase {
        case .idle:
            break
        case .preparing:
            awaitingRunPhase = false
        case .searching:
            awaitingRunPhase = false
            if searchStartedAt == nil { searchStartedAt = .now }
        case .finished, .noLegalMoves, .failed:
            guard !awaitingRunPhase else { return }
            handleTerminal(phase)
        }
    }

    private func handleTerminal(_ phase: EnginePhase) {
        switch phase {
        case .idle, .preparing, .searching:
            break
        case .finished:
            complete()
        case .noLegalMoves(let checkmate):
            runState = .completed
            ledger.record(.noLegalMoves(checkmate: checkmate), for: session.id)
            completionCount += 1
            announce(checkmate ? "Checkmate. There are no legal moves." : "Stalemate. There are no legal moves.")
        case .failed(let message):
            if AnalysisEngineFailure.isInvalidPosition(phase) {
                let issues = AnalysisPositionCheck.blockingIssues(in: position)
                if issues.isEmpty {
                    fail(AnalysisEngineFailure.unexplainedRejection)
                } else {
                    returnToCheckPosition(issues: issues)
                }
            } else {
                fail(message)
            }
        }
    }

    private func complete() {
        if interruption != nil {
            runState = .interrupted
            return
        }
        runState = .completed
        guard let best = bestMove else {
            ledger.record(.failed("No best move."), for: session.id)
            return
        }
        let score = readout?.score
        #if DEBUG
        DebugTimeline.shared.mark("final")
        #endif
        completionCount += 1
        app.settings.hasCompletedAnalysis = true
        ledger.record(.bestMove(san: best.san, move: best.move, score: score), for: session.id)
        startLongerSearch()
        let content = resultReadout
        let description = content.move?.words ?? AnalysisSpeech.moveDescription(san: best.san, move: best.move)
        // With the turn of the player at the top on the board, the screen leads with the answer
        // to the move the engine expects, so the announcement says both (design.md 9.4).
        if let guessed = content.guessedMove {
            announce(AnalysisSpeech.replyAnnouncement(guessedMove: guessed.words, reply: description, score: score))
        } else {
            announce(AnalysisSpeech.completionAnnouncement(moveDescription: description, score: score))
        }
    }

    private func fail(_ message: String) {
        runState = .failed(message)
        ledger.record(.failed(message), for: session.id)
        // A failure changes the screen on its own, like a completion, so it is announced like
        // one. Without this the pill quietly became ENGINE ERROR and a reader who had pressed
        // Analyze heard nothing at all and went on waiting.
        announce(Self.failureAnnouncement(message))
    }

    /// "Analysis failed. <what went wrong>" - the sentence VoiceOver is given when a search
    /// ends in an error.
    static func failureAnnouncement(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Analysis failed." }
        return trimmed.hasSuffix(".") ? "Analysis failed. " + trimmed : "Analysis failed. " + trimmed + "."
    }

    /// The last sentence handed to VoiceOver. Kept so the announcements can be checked without
    /// a running screen reader.
    private(set) var lastAnnouncement: String?

    private func announce(_ text: String) {
        lastAnnouncement = text
        AccessibilityNotification.Announcement(text).post()
    }

    /// A board the engine cannot search goes back to Check position with the offending
    /// squares flagged, without spending anything. A search of this session still running
    /// (an adjustment made the board invalid mid-search) is stopped: nothing would show it.
    private func returnToCheckPosition(issues: [PositionIssue]) {
        longerSearch.cancel()
        if isThinking, ledger.activeSessionID == session.id {
            app.engine.stop()
        }
        runToken += 1
        runState = .notStarted
        ledger.record(.invalidPosition, for: session.id)
        var snapshot = session.snapshot
        snapshot.lowConfidenceSquares.formUnion(AnalysisPositionCheck.squares(for: issues))
        app.returnToCheckPosition(snapshot)
    }
}
