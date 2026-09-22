import ChessCore
import Foundation
import Observation

// The search that keeps running quietly after the first answer appears (design.md section 16,
// `build/ui-requests.md` item 8). Everything here is engine-side and pure enough to unit test:
// the stopping rule is a value, the device conditions are a value, and the notice's words are
// built from a state, not from a view.

// MARK: - The seam onto the engine

/// A quiet second search on a board that has already been answered.
///
/// It is a protocol of its own rather than part of `EngineController` because it has a rule
/// that ordinary searches do not: **it never writes the controller's `phase` or `readout`.**
/// The move on screen belongs to the search the user asked for, and it changes only when the
/// user (or their Pro setting) says so.
///
/// There is one Stockfish instance, so a quiet search runs only while nothing the user started
/// is using it, and anything the user starts takes the engine back at once.
@MainActor
protocol AnalysisLongerSearchRunner: AnyObject, Sendable {
    /// Starts searching `position` for at most `ceiling`. The stream carries the same readouts
    /// an ordinary search would publish; it ends when the search ends. Returns nil when the
    /// engine cannot take the search right now: it is still loading, it is busy with the
    /// user's own search, or the position is not one it can search.
    func startLongerSearch(_ position: Position, ceiling: Duration) -> AsyncStream<EngineReadout>?
    /// Ends the quiet search now. Never touches a search the user started.
    func stopLongerSearch()
}

// MARK: - The stopping rule

/// When the longer search has learned enough to stop (design.md section 16).
///
/// It sees the readouts the search publishes and counts how many deeper iterations the current
/// move has survived. The hard ceiling is not in here: that is the search's own time limit, so
/// the engine enforces it whether or not anybody is reading these readouts.
struct AnalysisLongerSearchProgress: Sendable, Equatable {
    /// How many deeper iterations a move has to survive before the search stops early. Four is
    /// "several depths" of item 8: enough that a move which is about to be overturned usually
    /// already has been, and few enough that a settled position gives the device back quickly.
    static let steadyDepths = 4

    /// The best move so far, UCI.
    private(set) var move: String?
    /// The deepest iteration reported.
    private(set) var depth = 0
    /// The depth at which `move` became the best move.
    private(set) var depthWhenMoveArrived = 0

    /// True once the move has held for `steadyDepths` deeper iterations.
    var hasSettled: Bool {
        move != nil && depth - depthWhenMoveArrived >= Self.steadyDepths
    }

    mutating func apply(_ readout: EngineReadout) {
        // A final event may report a shallower depth than the iteration in progress; the
        // deepest one reached is what counts.
        depth = max(depth, readout.depth)
        guard let best = readout.bestMove else { return }
        if best != move {
            move = best
            depthWhenMoveArrived = depth
        }
    }
}

// MARK: - What the device allows

/// What the device's own state says about running a search nobody asked for (design.md
/// section 16). A value, so tests drive it instead of the real `ProcessInfo`.
struct AnalysisLongerSearchConditions: Sendable, Equatable {
    var isLowPowerModeEnabled: Bool
    var thermalState: ProcessInfo.ThermalState

    static var current: AnalysisLongerSearchConditions {
        AnalysisLongerSearchConditions(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    /// The device has room for extra work: it is not saving power and it is not already warm.
    /// Low Power Mode is a stated wish to stop background work, and a warm device would slow
    /// everything the user does next, so the search neither starts nor continues in either.
    var allowsSearching: Bool {
        !isLowPowerModeEnabled && (thermalState == .nominal || thermalState == .fair)
    }
}

// MARK: - The search

/// The longer search's state and what it found, for one Analysis screen.
///
/// No credit is involved anywhere in here: the search runs on the board the screen already
/// paid for and never asks for an authorization, so it cannot spend one
/// (`MonetizationCreditRules` would call the same board a free re-analysis in any case).
@MainActor
@Observable
final class AnalysisLongerSearch {
    /// What the screen has to say about the longer search.
    enum State: Sendable, Hashable {
        /// Nothing to say: it has not run, is still running, or found nothing worth a word.
        case quiet
        /// It finished and the move on screen held. Reassurance, not news.
        case confirmed
        /// It prefers another move, and the move on screen is still the quick answer.
        case prefers(EngineReadout)
        /// The preferred move is the one on screen now, because the user asked for it or
        /// because their Pro setting switches by itself.
        case switched(EngineReadout)
    }

    private(set) var state: State = .quiet
    /// True while the quiet search runs. Nothing on screen says so; it is here for tests and
    /// for the screen to know the engine is busy with it.
    private(set) var isSearching = false

    /// Called once the search has finished and `state` is settled.
    @ObservationIgnored var didFinish: (@MainActor (State) -> Void)?
    /// The device state, replaced in tests.
    @ObservationIgnored var conditions: @MainActor () -> AnalysisLongerSearchConditions = { .current }

    @ObservationIgnored private let runner: (any AnalysisLongerSearchRunner)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// `runner` is nil where the engine cannot take a quiet search (a stub engine in tests and
    /// previews); the feature then simply never runs.
    init(runner: (any AnalysisLongerSearchRunner)?) {
        self.runner = runner
    }

    /// The readout the screen shows instead of the quick answer, once the preferred move has
    /// been taken. Nil in every other state, so the screen keeps the answer it has.
    var adoptedReadout: EngineReadout? {
        if case .switched(let readout) = state { return readout }
        return nil
    }

    /// The deeper search's readout, taken or not. It is what the notice names.
    var preferredReadout: EngineReadout? {
        switch state {
        case .prefers(let readout), .switched(let readout): readout
        case .quiet, .confirmed: nil
        }
    }

    /// The app knows the move on screen is beaten: it must not be called the best one
    /// (`build/ui-requests.md` item 8). The pill of `AnalysisReadoutContent` says so.
    var quickAnswerIsBeaten: Bool {
        if case .prefers = state { return true }
        return false
    }

    /// Starts the quiet search of `position`, which `quickAnswer` has already been answered
    /// for. Returns whether it started, which is what tests read.
    ///
    /// It does not start at all in Low Power Mode or on a warm device, and it does not start
    /// when the answer on screen already took as long as the ceiling would allow: there would
    /// be nothing deeper to find.
    @discardableResult
    func start(position: Position, quickAnswer: EngineReadout, ceiling: LongerSearchCeiling) -> Bool {
        cancel()
        guard let runner, quickAnswer.bestMove != nil else { return false }
        guard conditions().allowsSearching else { return false }
        guard ceiling.duration > quickAnswer.elapsed else { return false }
        guard let stream = runner.startLongerSearch(position, ceiling: ceiling.duration) else { return false }

        generation += 1
        let generation = generation
        isSearching = true
        task = Task { [weak self] in
            var progress = AnalysisLongerSearchProgress()
            var latest: EngineReadout?
            for await readout in stream {
                guard let self, generation == self.generation else { return }
                progress.apply(readout)
                latest = readout
                // The engine reports several times a second, so checking here is as good as
                // watching the device continuously: Low Power Mode turned on mid-search, or a
                // device that has warmed up, stops it within a moment.
                if !self.conditions().allowsSearching {
                    self.runner?.stopLongerSearch()
                    break
                }
                if progress.hasSettled {
                    self.runner?.stopLongerSearch()
                    break
                }
            }
            guard let self, generation == self.generation else { return }
            self.finish(latest, quickAnswer: quickAnswer, position: position)
        }
        return true
    }

    /// Stops the search and forgets what it found. The screen calls it when the board changes,
    /// when the user starts a search of their own, when the app goes to the background and
    /// when the screen goes away.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        if isSearching {
            isSearching = false
            runner?.stopLongerSearch()
        }
        state = .quiet
    }

    /// Puts the preferred move on screen. The user's choice, or their Pro setting's.
    func showTheBetterMove() {
        guard case .prefers(let readout) = state else { return }
        state = .switched(readout)
    }

    /// What the search leaves behind. A finding is only reported when it is actually deeper
    /// than the answer on screen: an equally deep search that happens to like another move has
    /// not beaten anything, and saying so would unsettle a move for no reason.
    private func finish(_ result: EngineReadout?, quickAnswer: EngineReadout, position: Position) {
        isSearching = false
        guard let result, let move = result.bestMove, result.depth > quickAnswer.depth else {
            state = .quiet
            didFinish?(state)
            return
        }
        if move == quickAnswer.bestMove {
            state = .confirmed
        } else if let parsed = Move(uci: move), position.san(for: parsed) != nil {
            state = .prefers(result)
        } else {
            // A move that is not legal on the board shown belongs to another board; say nothing.
            state = .quiet
        }
        didFinish?(state)
    }
}

// MARK: - The notice

/// What the longer-search notice says (design.md section 16). Built by the screen model from
/// the search's state, the tier and the move the readout would show, so the words can be
/// checked without building a view.
struct AnalysisLongerSearchNoticeContent: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        /// Pro, a different move preferred and not yet shown: the notice offers it.
        case prefersMove
        /// Pro, the preferred move is on screen now.
        case movePreferredAndShown
        /// Pro, the same move confirmed. Subtler than the others.
        case confirmed
        /// Free: a better move exists, and Pro is what shows it. The move is not named.
        case proOffer
    }

    var kind: Kind
    /// The move the sentence names, drawn with its piece glyph. Nil for the cases that name no
    /// move (`confirmed`, `proOffer`).
    var move: AnalysisReadoutContent.MoveText?
    /// The words before the move, and after it. The view puts the glyph and the move between
    /// them.
    var sentencePrefix: String
    var sentenceSuffix: String
    /// What VoiceOver reads instead of the line: words, never a symbol name.
    var spokenSentence: String
    /// The link under the sentence, when there is something to do.
    var actionTitle: String?
    var actionHint: String?

    /// The sentence without the glyph, which is what a notice with no move shows.
    var plainSentence: String {
        sentencePrefix + (move?.san ?? "") + sentenceSuffix
    }

    /// The news cases carry the `callout` weight of the castling caution above them; the
    /// confirmation is a `caption`, because it is reassurance and not news.
    var isSubtle: Bool { kind == .confirmed }
}

/// The words of the longer-search notice, in one place (design.md sections 14 and 16).
///
/// None of it frames the app as help during a game in progress (`AppCopyTests`), and none of it
/// names the tier anything but Pro.
enum AnalysisLongerSearchCopy {
    static let prefersPrefix = "A longer search prefers "
    static let prefersSuffix = "."
    static let shownPrefix = "A longer search preferred "
    static let shownSuffix = ", now shown."
    static let confirmed = "A longer search still prefers this move."
    static let proOffer = "A longer search found a different move. Pro shows it."

    static let showIt = "Show it"
    static let showItHint = "Puts that move in the badge. Nothing is spent."
    static let seePro = "See Pro"
    static let seeProHint = "Opens purchase options."

    /// "A longer search prefers knight to f3."
    static func spokenPrefers(_ move: AnalysisReadoutContent.MoveText) -> String {
        prefersPrefix + AnalysisSpeech.lowercasingFirstLetter(move.words) + prefersSuffix
    }

    /// "A longer search preferred knight to f3, now shown."
    static func spokenShown(_ move: AnalysisReadoutContent.MoveText) -> String {
        shownPrefix + AnalysisSpeech.lowercasingFirstLetter(move.words) + shownSuffix
    }

    /// The notice for a state, or nil when the notice says nothing.
    ///
    /// `move` is the move the badge would hold if the deeper answer were taken, which is not
    /// always the engine's own best move: where the screenshot caught the turn of the player at
    /// the top, the badge holds the reply from the same line (design.md 9.4). The notice names
    /// what the user would see.
    static func content(
        for state: AnalysisLongerSearch.State,
        move: AnalysisReadoutContent.MoveText?,
        isPro: Bool
    ) -> AnalysisLongerSearchNoticeContent? {
        switch state {
        case .quiet:
            return nil
        case .confirmed:
            // Free users are told nothing here: a confirmation is a Pro comfort, and an upgrade
            // push over "the move did not change" would be noise.
            guard isPro else { return nil }
            return AnalysisLongerSearchNoticeContent(
                kind: .confirmed,
                move: nil,
                sentencePrefix: confirmed,
                sentenceSuffix: "",
                spokenSentence: confirmed,
                actionTitle: nil,
                actionHint: nil
            )
        case .prefers:
            guard isPro else {
                return AnalysisLongerSearchNoticeContent(
                    kind: .proOffer,
                    move: nil,
                    sentencePrefix: proOffer,
                    sentenceSuffix: "",
                    spokenSentence: proOffer,
                    actionTitle: seePro,
                    actionHint: seeProHint
                )
            }
            guard let move else { return nil }
            return AnalysisLongerSearchNoticeContent(
                kind: .prefersMove,
                move: move,
                sentencePrefix: prefersPrefix,
                sentenceSuffix: prefersSuffix,
                spokenSentence: spokenPrefers(move),
                actionTitle: showIt,
                actionHint: showItHint
            )
        case .switched:
            guard let move else { return nil }
            return AnalysisLongerSearchNoticeContent(
                kind: .movePreferredAndShown,
                move: move,
                sentencePrefix: shownPrefix,
                sentenceSuffix: shownSuffix,
                spokenSentence: spokenShown(move),
                actionTitle: nil,
                actionHint: nil
            )
        }
    }
}
