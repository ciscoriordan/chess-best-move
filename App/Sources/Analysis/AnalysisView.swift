import Foundation
import ChessCore
import SwiftUI

/// Analyzing and Result in one screen (design.md 9.3 and 9.4): the layout stays the same while
/// the engine thinks and after it finishes, so nothing jumps.
struct AnalysisView: View {
    let session: AnalysisSession

    @Environment(AppModel.self) private var app

    var body: some View {
        AnalysisScreen(app: app, session: session)
            .id(session.id)
    }
}

/// The Analysis screen's board layout. Capture's Recognizing screen lands the screenshot's board
/// exactly on this frame before this screen takes over (`CaptureBoardLanding`), so both read it
/// from here.
enum AnalysisLayout {
    /// Two columns (board, readout) from this content width, on iPad and in landscape
    /// (design.md section 5).
    static let twoColumnMinimumWidth: CGFloat = 700
    /// Space between the navigation bar and the board group.
    static let topPadding: CGFloat = Spacing.s2
    /// Space between the two columns.
    static let columnSpacing: CGFloat = Spacing.s5
    /// The evaluation bar column on the board's leading side.
    @MainActor static var evalBarColumn: CGFloat { AnalysisEvalBar.width + AnalysisEvalBar.spacing }

    static func isWide(contentWidth: CGFloat) -> Bool {
        contentWidth >= twoColumnMinimumWidth
    }

    /// Leave room for scrolling details and the action bar when the board stays on screen.
    /// Height is the safe area below the navigation bar, before the bottom action bar is added,
    /// so the board does not resize when the screenshot offer arrives or the search finishes.
    @MainActor static func boardSide(
        contentWidth: CGFloat,
        containerHeight: CGFloat? = nil,
        isAccessibilitySize: Bool = false
    ) -> CGFloat {
        let available = isWide(contentWidth: contentWidth) ? (contentWidth - columnSpacing) / 2 : contentWidth
        let side = available - evalBarColumn
        let widthBound = side > 0 ? min(side, Layout.maximumBoardSide) : 300
        guard let containerHeight else { return widthBound }
        let fraction: CGFloat = if isWide(contentWidth: contentWidth) {
            isAccessibilitySize ? 0.5 : 0.7
        } else {
            isAccessibilitySize ? 1 / 3 : 0.5
        }
        let heightBound = max(0, containerHeight * fraction - topPadding - Spacing.s2 - 2)
        return min(widthBound, heightBound)
    }
}

private struct AnalysisScreen: View {
    @State private var playback: BoardMovePlayback?
    @State private var playbackID = UUID()
    @State private var model: AnalysisScreenModel
    @State private var isPeeking = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.legibilityWeight) private var legibilityWeight

    init(app: AppModel, session: AnalysisSession) {
        _model = State(initialValue: AnalysisScreenModel(app: app, session: session))
    }

    private var app: AppModel { model.app }
    private var session: AnalysisSession { model.session }
    private var snapshot: BoardSnapshot { session.snapshot }
    private var isFinal: Bool { model.runState == .completed }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                content(in: geometry.size)
                PinnedActionBar {
                    NewScreenshotRow(placement: .pinnedBar, emphasized: model.runState != .notStarted)
                } content: {
                    AnalysisActionBar(model: model)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CreditsToolbarIndicator(dynamicTypeSize: dynamicTypeSize)
            }
        }
        .offersNewScreenshot()
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .onChange(of: session.canAnalyze) { _, _ in model.creditStateChanged() }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(to: phase) }
        .sensoryFeedback(.success, trigger: model.completionCount)
        .sensoryFeedback(.selection, trigger: model.adjustmentCount)
        .sensoryFeedback(.success, trigger: model.improvementCount)
        .onChange(of: model.position) { _, _ in playback = nil }
        .onChange(of: model.bestMove?.move) { _, _ in playback = nil }
        .task(id: playbackID) {
            guard let playback else { return }
            do { try await Task.sleep(for: .seconds(playback.duration)) } catch { return }
            self.playback = nil
        }
        #if DEBUG
        .onChange(of: model.bestMove?.san) { _, san in
            if san != nil { DebugTimeline.shared.mark("firstArrow") }
        }
        .background(alignment: .topLeading) {
            if DebugLaunchOptions.uiTestProbe { probe }
        }
        #endif
    }

    #if DEBUG
    /// `-uiTestProbe`: an invisible element whose label carries the result for UI tests.
    private var probe: some View {
        let state: String = switch model.runState {
        case .notStarted: "notStarted"
        case .starting: "starting"
        case .running: "running"
        case .completed: model.noLegalMoves != nil ? "noLegalMoves" : "completed"
        case .interrupted: "interrupted"
        case .failed: "failed"
        }
        let credit: String = switch session.creditState {
        case .authorized: "authorized"
        case .waitingForPurchase: "waitingForPurchase"
        case .waitingForApproval: "waitingForApproval"
        }
        let fields = [
            "state=\(state)",
            "credit=\(credit)",
            "uci=\(model.bestMove?.move.uci ?? "")",
            "san=\(model.bestMove?.san ?? "")",
            "whiteAtBottom=\(snapshot.whiteAtBottom ? 1 : 0)",
            "fen=\(model.position.fen)",
            "timeline=\(DebugTimeline.shared.summary)",
            "playing=\(playback != nil ? 1 : 0)",
        ]
        return Text(fields.joined(separator: ";"))
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityIdentifier("analysis.probe")
    }
    #endif

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        let contentWidth = max(0, size.width - 2 * Layout.sideGutter(forWidth: size.width))
        let isWide = AnalysisLayout.isWide(contentWidth: contentWidth)
        let side = AnalysisLayout.boardSide(
            contentWidth: contentWidth,
            containerHeight: size.height,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
        if isWide {
            HStack(alignment: .top, spacing: AnalysisLayout.columnSpacing) {
                boardGroup(side: side)
                    .frame(width: (contentWidth - AnalysisLayout.columnSpacing) / 2, alignment: .leading)
                    .padding(.top, AnalysisLayout.topPadding)
                ScrollView {
                    details
                        .padding(.top, Spacing.s3)
                        .padding(.bottom, Spacing.s5)
                }
                .accessibilityIdentifier("analysis.details")
            }
            .startsSideGutterContainer()
            .sideGutter()
        } else {
            VStack(spacing: 0) {
                boardGroup(side: side)
                    .frame(maxWidth: .infinity)
                    .sideGutter()
                    .padding(.top, AnalysisLayout.topPadding)
                ScrollView {
                    details
                        .sideGutter()
                        .padding(.top, Spacing.s3)
                        .padding(.bottom, Spacing.s5)
                }
                .accessibilityIdentifier("analysis.details")
            }
        }
    }

    /// All text and controls can scroll, including at the largest text size. Only the board,
    /// evaluation bar and progress rule stay put; the bottom action bar remains separate.
    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            CreditsInlineIndicator()
            NewScreenshotRow(placement: .scrollingContent, emphasized: model.runState != .notStarted)
            chips
            readoutGroups
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Board

    private func boardGroup(side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            HStack(alignment: .top, spacing: AnalysisEvalBar.spacing) {
                AnalysisEvalBar(
                    whiteShare: evalShare,
                    isPlaceholder: evalIsPlaceholder,
                    whiteAtBottom: snapshot.whiteAtBottom,
                    accessibilityValueText: evalSpoken
                )
                .frame(height: side)
                board
                    .frame(width: side, height: side)
            }
            AnalysisThinkProgress(
                startedAt: model.searchStartedAt,
                thinkTime: model.runThinkTime,
                isActive: model.isThinking
            )
        }
        .frame(width: side + AnalysisLayout.evalBarColumn)
    }

    /// The original crop can be revealed under an edited diagram.
    private var canPeek: Bool { snapshot.showsDiagram && snapshot.boardImage != nil }

    /// Shows the original crop under an edited diagram, or puts it away: what pressing and
    /// holding the board does, as something that is not a gesture.
    ///
    /// The board is one focus stop: activation plays the visible move when available,
    /// otherwise it compares the crop. Comparison also remains a named custom action.
    /// Full Keyboard Access and Switch Control can activate this same focus stop.
    private func togglePeek() {
        guard canPeek else { return }
        isPeeking.toggle()
    }

    private var board: some View {
        let canPeek = canPeek
        let showsScreenshot = snapshot.boardImage != nil && isPeeking
        return BoardFrame {
            ZStack(alignment: .topTrailing) {
                if let playback {
                    playbackBoard(playback).id(playbackID)
                } else if showsScreenshot, let image = snapshot.boardImage {
                    BoardScreenshot(image: image, snapshot: snapshot)
                } else {
                    ScreenshotStyledBoard(snapshot: snapshot, appearance: app.settings.boardAppearance)
                        .modifier(AnalysisBoardTint(status: model.resultReadout.checkStatus))
                }
                AnalysisArrowOverlay(
                    // The readout is what decides which moves are drawn and whose they are,
                    // so the board and the words under it can never disagree (design.md 9.4).
                    arrows: isPeeking || playback != nil ? [] : model.resultReadout.boardArrows,
                    whiteAtBottom: snapshot.whiteAtBottom,
                    isFinal: isFinal
                )
                if snapshot.showsDiagram, snapshot.boardImage != nil, !isPeeking {
                    Text("Edited")
                        .typography(.label)
                        .foregroundStyle(Palette.ink2)
                        .padding(.horizontal, Spacing.s1 + 2)
                        .padding(.vertical, 2)
                        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.r1, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.r1, style: .continuous).strokeBorder(Palette.rule2, lineWidth: LineWidth.control))
                        .padding(Spacing.s2)
                        .accessibilityHidden(true)
                }
            }
        }
        .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 40) {
        } onPressingChanged: { pressing in
            isPeeking = canPeek && pressing
        }
        .simultaneousGesture(TapGesture().onEnded { playMove() })
        .focusable(canPeek || canPlayMove, interactions: .activate)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("analysis.board")
        .accessibilityLabel(Text(boardAccessibilityLabel))
        .accessibilityValue(Text(boardAccessibilityValue))
        .accessibilityCustomContent("Pieces", AnalysisSpeech.pieceList(snapshot.position.board))
        .accessibilityCustomContent("Side to move", sideToMoveAccessibilityText)
        .accessibilityCustomContent("FEN", snapshot.position.fen)
        // Playback and crop comparison both have named actions for assistive technologies.
        .accessibilityHint(canPlayMove ? String(localized: "Tap to animate the move. The original position returns afterward.") : "")
        .accessibilityAction { if canPlayMove { playMove() } else { togglePeek() } }
        .accessibilityActions {
            if canPlayMove { Button("Play move animation") { playMove() } }
            peekAction
        }
    }

    private var canPlayMove: Bool { isFinal && !model.resultReadout.boardArrows.isEmpty }

    private func playMove() {
        guard canPlayMove else { return }
        isPeeking = false
        playback = .make(position: model.position, moves: model.resultReadout.boardArrows.map(\.move),
                         whiteAtBottom: snapshot.whiteAtBottom)
        playbackID = UUID()
    }

    private func playbackBoard(_ playback: BoardMovePlayback) -> some View {
        var sprites: [String: CGImage] = [:]
        var light = Palette.greenBoardLight
        var dark = Palette.greenBoardDark
        if app.settings.boardAppearance == .screenshot, let image = snapshot.boardImage {
            let artwork = ScreenshotBoardArtwork(snapshot: snapshot, image: image)
            if let square = Square(index: 1) { light = artwork.background(for: square) }
            if let square = Square(index: 0) { dark = artwork.background(for: square) }
            for piece in snapshot.position.board.compactMap({ $0 }) {
                if let sprite = artwork.sprite(for: piece) { sprites[String(piece.fenCharacter)] = sprite }
            }
        } else if app.settings.boardAppearance == .standard {
            light = Palette.diagramLight
            dark = Palette.diagramDark
        }
        return BoardMovePlaybackView(playback: playback, sprites: sprites, light: light, dark: dark)
    }

    /// The custom action that stands in for pressing and holding the board. Nothing to offer
    /// when there is no screenshot under the diagram.
    @ViewBuilder
    private var peekAction: some View {
        if snapshot.showsDiagram, snapshot.boardImage != nil {
            Button(isPeeking ? CaptureBoardSpeech.hideScreenshotAction : CaptureBoardSpeech.compareAction) {
                isPeeking.toggle()
            }
        }
    }

    private var boardAccessibilityLabel: String {
        let edited = snapshot.showsDiagram && snapshot.boardImage != nil ? String(localized: ", edited") : ""
        return String(localized: "Board, \(AnalysisSpeech.colorName(snapshot.whiteAtBottom ? .white : .black)) at bottom") + edited
    }

    /// What the board is read out as: the moves its arrows draw, in the order they are played
    /// (design.md section 7 and 12). A reader who cannot see the two colors or the two heads
    /// gets which move is whose, and that the reply depends on the other one being played.
    private var boardAccessibilityValue: String {
        if let checkmate = model.noLegalMoves {
            return checkmate ? String(localized: "Checkmate.") : String(localized: "Stalemate.")
        }
        let readout = model.resultReadout
        guard let shown = readout.move else {
            return model.isThinking ? String(localized: "Thinking.") : String(localized: "No best move yet.")
        }
        let spoken = { (move: AnalysisReadoutContent.MoveText) in
            AnalysisSpeech.moveDescription(san: move.san, move: move.move, capture: move.capture, alwaysIncludeFromSquare: true)
        }
        if let guessed = readout.guessedMove {
            return AnalysisSpeech.boardArrowPair(
                theirMove: spoken(guessed),
                reply: spoken(shown),
                isFinal: isFinal
            )
        }
        if readout.answersForThePlayerAtTheTop {
            return AnalysisSpeech.boardTheirMoveOnly(theirMove: spoken(shown), isFinal: isFinal)
        }
        return (isFinal ? String(localized: "Best move: ") : String(localized: "Best move so far: "))
            + AnalysisSpeech.lowercasingFirstLetter(spoken(shown)) + "."
    }

    /// "White, the player at the top, from last-move highlight": the chip's VoiceOver value and
    /// the board's "Side to move" custom content.
    private var sideToMoveAccessibilityText: String {
        SideToMoveCopy.spoken(
            side: snapshot.position.sideToMove,
            whiteAtBottom: snapshot.whiteAtBottom,
            origin: snapshot.sideToMoveOrigin
        )
    }

    // MARK: Chips

    /// "the player at the top, from last-move highlight" (design.md 9.4): where the player whose
    /// move it is sits, then where the side to move came from. With the chip above it the two
    /// read as one statement, so a user whose own pieces are at the bottom sees at once whether
    /// the result answers for them or for the player across the board.
    private var sideToMoveCaption: String {
        SideToMoveCopy.caption(
            side: snapshot.position.sideToMove,
            whiteAtBottom: snapshot.whiteAtBottom,
            origin: snapshot.sideToMoveOrigin
        )
    }

    /// The side to move is the player at the top and the user has not chosen it: offer the
    /// switch. Taking it sets the origin to `.user`, so the offer is made once per board and
    /// never over a result that already answers for the player at the bottom.
    private var offersSwitchToBottomPlayer: Bool {
        SideToMoveCopy.offersSwitchToBottomPlayer(
            side: snapshot.position.sideToMove,
            whiteAtBottom: snapshot.whiteAtBottom,
            origin: snapshot.sideToMoveOrigin
        )
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: Spacing.s1) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.s2) { chipItems }
                VStack(alignment: .leading, spacing: Spacing.s2) { chipItems }
            }
            // The assumed case says the same sentence in `caution` under its own chip
            // (`Chip.attentionCaption`), so it is not repeated here.
            if snapshot.sideToMoveOrigin != .assumedBottomPlayer {
                Text(sideToMoveCaption)
                    .typography(.caption)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    // The chip's VoiceOver value already says it (`sideToMoveAccessibilityText`).
                    .accessibilityHidden(true)
            }
            if offersSwitchToBottomPlayer {
                TextLink(SideToMoveCopy.switchToBottomPlayerTitle) {
                    model.toggleSideToMove()
                }
                .accessibilityHint(SideToMoveCopy.switchToBottomPlayerHint(side: snapshot.position.sideToMove))
                .accessibilityIdentifier("analysis.switchSideToMove")
            }
        }
    }

    @ViewBuilder
    private var chipItems: some View {
        let side = snapshot.position.sideToMove
        let isAssumed = snapshot.sideToMoveOrigin == .assumedBottomPlayer
        Chip(
            String(localized: "\(AnalysisSpeech.colorName(side)) to move"),
            glyph: .piece(Piece(color: side, kind: .king)),
            state: isAssumed ? .attention : .normal,
            attentionCaption: sideToMoveCaption
        ) {
            model.toggleSideToMove()
        }
        .accessibilityElement(children: .combine)
        // The label is the text on the chip, so "Tap White to move" addresses it; where that
        // side came from is the value. Voice Control matches the name, not the value.
        .accessibilityLabel("\(AnalysisSpeech.colorName(side)) to move")
        .accessibilityValue(sideToMoveAccessibilityText)
        .accessibilityInputLabels(["\(AnalysisSpeech.colorName(side)) to move", "Side to move"])
        .accessibilityHint("Swaps the side to move and analyzes again.")
        // At accessibility sizes a chip label wraps instead of widening the screen (design.md 12).
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)

        Chip(String(localized: "Flip"), glyph: .systemImage("arrow.up.arrow.down")) {
            model.flip()
        }
        .accessibilityLabel("Flip board")
        // Voice Control matches the name, and the word on the chip is "Flip".
        .accessibilityInputLabels(["Flip", "Flip board"])
        // A board set up by hand only turns around on screen (BoardSnapshot.flippedByUser).
        .accessibilityHint(snapshot.boardImage == nil ? "Turns the board around." : "Turns the board around and analyzes again.")
        // At accessibility sizes a chip label wraps instead of widening the screen (design.md 12).
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)

        Chip(String(localized: "Edit"), glyph: .systemImage("square.and.pencil")) {
            model.edit()
        }
        .accessibilityLabel("Edit position")
        .accessibilityInputLabels(["Edit", "Edit position"])
        // At accessibility sizes a chip label wraps instead of widening the screen (design.md 12).
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
    }

    // MARK: Readout

    @ViewBuilder
    private var readoutGroups: some View {
        Hairline()
            .padding(.top, Spacing.s3)
        readout
            .padding(.vertical, Spacing.s3)
        if let saved = model.savedResult {
            VStack(alignment: .leading, spacing: Spacing.s1) {
                Text("Saved analysis. No analysis used.").typography(.callout)
                Text(saved.analyzedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .typography(.caption)
            }
            .foregroundStyle(Palette.ink2)
            .padding(.bottom, Spacing.s3)
            .accessibilityIdentifier("analysis.savedResult")
        }
        if let right = model.assumedCastlingRight {
            castlingCaution(right)
                .padding(.bottom, Spacing.s3)
        }
        // The notice that a longer search prefers another move goes here (ui-requests item 8):
        // under everything that qualifies the move on screen, above the monetization notices.
        // It draws nothing until that round lands.
        AnalysisLongerSearchNotice(model: model)
        if isFinal {
            // Draws nothing unless this result spent the last free analysis (Monetization).
            LastFreeAnalysisNotice(session: session)
                .padding(.bottom, Spacing.s3)
        }
        if model.noLegalMoves == nil {
            Hairline()
            lineRow
        }
        Hairline()
        thinkRow
        if isFinal, app.store.isPro {
            // Draws nothing unless the store offers the switch (Monetization, 4.9).
            SwitchToYearlyCard()
        }
    }

    /// The readout itself (`AnalysisResultReadout`, design.md 9.4). The detail line is passed
    /// only when it says something the badge does not: while it repeats the move in the badge,
    /// the badge's own line says it and VoiceOver reads the move once.
    private var readout: some View {
        AnalysisResultReadout(
            content: model.resultReadout,
            score: displayedScore,
            isFinal: isFinal,
            detail: model.detailRepeatsHero ? nil : model.detailLine,
            detailIsCaution: detailIsCaution
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(model.isThinking ? .updatesFrequently : [])
    }

    /// The best move castles with a right that was only inferred from the screenshot
    /// (design.md 9.4): a `caution` line and a link that turns the right off and re-runs.
    private func castlingCaution(_ right: CastlingRights) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Assumes castling is still allowed.")
                .typography(.callout)
                .foregroundStyle(Palette.caution)
                .fixedSize(horizontal: false, vertical: true)
            TextLink(AnalysisScreenModel.turnOffTitle(right)) {
                model.turnOffAssumedCastling()
            }
            .accessibilityLabel(String(localized: "Turn off \(AnalysisScreenModel.spokenCastlingName(right))"))
            .accessibilityInputLabels([
                AnalysisScreenModel.turnOffTitle(right),
                String(localized: "Turn off \(AnalysisScreenModel.spokenCastlingName(right))"),
            ])
            .accessibilityHint("Analyzes again without it. Re-running is free.")
            .accessibilityIdentifier("analysis.turnOffCastling")
        }
    }

    /// The score shown beside the badge, never for checkmate or stalemate.
    private var displayedScore: WhiteScore? {
        guard model.noLegalMoves == nil, model.bestMove != nil else { return nil }
        return model.readout?.score
    }

    private var detailIsCaution: Bool {
        if case .failed = model.runState { return true }
        return false
    }

    // MARK: Engine line

    /// The engine line, which expands and collapses.
    ///
    /// A real `Button` rather than a plain view with an `onTapGesture`. A tap gesture is
    /// reachable by a finger and by nothing else: a hardware keyboard, Full Keyboard Access and
    /// Switch Control mapped to keys all drive the focus system, and a plain view is not in it.
    /// `.buttonStyle(.plain)` keeps the row exactly as it was drawn.
    ///
    /// The row is a button only while activating it changes something. At accessibility text
    /// sizes the line is always fully expanded, so a button there would be a focus stop whose
    /// activation did nothing and announced nothing.
    @ViewBuilder
    private var lineRow: some View {
        let sanMoves = model.readout.map { model.position.sanLine($0.principalVariation) } ?? []
        let expanded = model.isLineExpanded || dynamicTypeSize.isAccessibilitySize
        let (tokens, isTruncated) = AnalysisLine.tokens(
            sanMoves: sanMoves,
            position: model.position,
            plies: expanded ? nil : AnalysisLine.collapsedPlies
        )
        let canExpand = sanMoves.count > AnalysisLine.collapsedPlies && !dynamicTypeSize.isAccessibilitySize
        let spoken = sanMoves.isEmpty
            ? String(localized: "None yet")
            : AnalysisSpeech.line(sanMoves: sanMoves, plies: expanded ? sanMoves.count : AnalysisLine.collapsedPlies)
        let row = AnalysisLabeledRow(label: String(localized: "Line"), alignment: .firstTextBaseline) {
            Text(lineText(tokens, isTruncated: isTruncated, placeholder: sanMoves.isEmpty))
                .typography(.line)
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        if canExpand {
            Button {
                model.isLineExpanded.toggle()
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            // Said explicitly: taking the element over with `children: .ignore` drops the trait
            // the `Button` would have carried, and with it the row stops being a button to
            // VoiceOver, to Full Keyboard Access and to a UI test.
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Engine line")
            // Voice Control matches the name, and the word on the row is "Line".
            .accessibilityInputLabels(["Line", "Engine line"])
            // The value follows what is on screen: collapsed, it is the moves that are shown.
            .accessibilityValue(spoken)
            .accessibilityHint(expanded ? "Shows fewer moves" : "Shows the whole line")
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Engine line")
                .accessibilityInputLabels(["Line", "Engine line"])
                .accessibilityValue(spoken)
        }
    }

    /// The engine line as one attributed string.
    ///
    /// The first move of the line is the recommendation, and cobalt is what says so in a run of
    /// otherwise identical monospaced text. Color alone cannot carry that: cobalt against the
    /// ink beside it is 2.9:1 in light mode and 2.3:1 in dark, so the two are not separable by
    /// lightness either, and a reader with a color vision deficiency has nothing to go on. It
    /// is therefore also set in bold, which is a second signal that survives any color
    /// treatment, Differentiate Without Color included (design.md 12).
    private func lineText(_ tokens: [AnalysisLineToken], isTruncated: Bool, placeholder: Bool) -> AttributedString {
        guard !placeholder else {
            var empty = AttributedString("\u{2014}")
            empty.foregroundColor = Palette.ink3
            return empty
        }
        let resolved = Typography.resolve(.line, sizeCategory: UIContentSizeCategory(dynamicTypeSize),
                                          boldText: Typography.boldTextEnabled(legibilityWeight))
        let firstMoveFont = Font(UIFont.monospacedSystemFont(ofSize: resolved.pointSize,
            weight: Typography.boldTextEnabled(legibilityWeight) ? .heavy : .bold) as CTFont)
        var result = AttributedString()
        for token in tokens {
            if !result.characters.isEmpty {
                result += AttributedString(result.characters.last == "." ? "\u{00A0}" : " ")
            }
            var piece = AttributedString(token.text)
            piece.foregroundColor = token.isFirstMove ? Palette.accent : (token.kind == .moveNumber ? Palette.ink2 : Palette.ink)
            if token.isFirstMove { piece.font = firstMoveFont }
            result += piece
        }
        if isTruncated {
            var ellipsis = AttributedString(" \u{2026}")
            ellipsis.foregroundColor = Palette.ink2
            result += ellipsis
        }
        return result
    }

    // MARK: Think time

    private var thinkRow: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            AnalysisLabeledRow(label: String(localized: "Think")) {
                ThinkTimeControl(selection: Binding(
                    get: { model.runThinkTime },
                    set: { model.selectThinkTime($0) }
                ))
                .disabled(!session.canAnalyze)
            }
            statsRow
                .padding(.bottom, Spacing.s3)
        }
    }

    private var statsRow: some View {
        let readout = model.readout
        let depth = readout.map { AnalysisDataText.depth($0.depth) } ?? String(localized: "depth \u{2014}")
        let time: String = {
            guard let readout else { return model.runThinkTime.label }
            return model.isThinking
                ? AnalysisDataText.clock(elapsed: readout.elapsed, thinkTime: model.runThinkTime)
                : AnalysisDataText.seconds(readout.elapsed)
        }()
        let speed = readout?.nodesPerSecond.map(AnalysisDataText.nodesPerSecond) ?? ""
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.s5) { statsItems(depth: depth, time: time, speed: speed) }
            VStack(alignment: .leading, spacing: Spacing.s1) { statsItems(depth: depth, time: time, speed: speed) }
        }
        // `ink2`, not `ink3`, before the first report: the row is still something to read, and
        // `ink3` is 3.3:1 on canvas.
        .foregroundStyle(Palette.ink2)
        .accessibilityElement(children: .ignore)
        // The three figures are abbreviated for a fixed monospaced column. Spoken they need
        // naming: "depth 20, 1.4 s slash 3 s, 2.1 M n slash s" says what none of them are.
        .accessibilityLabel("Engine")
        .accessibilityAddTraits(.isStaticText)
        .accessibilityValue(AnalysisSpeech.engineFigures(
            depth: readout?.depth,
            elapsed: readout?.elapsed,
            thinkTime: model.runThinkTime,
            nodesPerSecond: readout?.nodesPerSecond
        ))
        .accessibilityAddTraits(model.isThinking ? .updatesFrequently : [])
    }

    @ViewBuilder
    private func statsItems(depth: String, time: String, speed: String) -> some View {
        Group {
            Text(depth)
            Text(time)
            if !speed.isEmpty { Text(speed) }
        }
        .typography(.data)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .contentTransition(reduceMotion ? .identity : .numericText())
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.valueChange), value: depth + time + speed)
    }

    // MARK: Evaluation bar input

    private var evalShare: Double {
        if let checkmate = model.noLegalMoves {
            guard checkmate else { return 0.5 }
            return snapshot.position.sideToMove == .white ? 0 : 1
        }
        return AnalysisScore.whiteShare(displayedScore)
    }

    private var evalIsPlaceholder: Bool {
        model.noLegalMoves == nil && displayedScore == nil
    }

    private var evalSpoken: String {
        if let checkmate = model.noLegalMoves {
            let side = AnalysisSpeech.colorName(snapshot.position.sideToMove)
            return checkmate ? String(localized: "\(side) is checkmated") : String(localized: "Stalemate")
        }
        guard let score = displayedScore else { return String(localized: "Not evaluated yet") }
        return AnalysisScore.spoken(score)
    }
}

/// The next screenshot is the primary next step. A detected screenshot carries that action
/// in its own row; otherwise the bar leads back to the import choices. Re-running this board
/// stays available as a quieter text action below it (owner decision of 2026-10-09).
private struct AnalysisActionBar: View {
    let model: AnalysisScreenModel

    @Environment(CaptureNewScreenshotOfferModel.self) private var screenshotOffer: CaptureNewScreenshotOfferModel?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var showsScreenshotOffer: Bool {
        screenshotOffer?.offer != nil && (!dynamicTypeSize.isAccessibilitySize || screenshotOffer?.isShownAtTop == true)
    }

    var body: some View {
        VStack(spacing: Spacing.s1) {
            switch model.runState {
            case .starting, .running:
                SecondaryButton(String(localized: "Stop"), systemImage: "stop.fill") { model.stop() }
            case .completed, .interrupted, .failed:
                if !showsScreenshotOffer {
                    PrimaryButton(String(localized: "Analyze new screenshot")) { model.newAnalysis() }
                        .accessibilityHint("Opens the start screen to choose a screenshot.")
                        .accessibilityIdentifier("analysis.newScreenshot")
                }
                switch model.runState {
                case .completed:
                    if model.noLegalMoves == nil, model.bestMove != nil {
                        Button(model.thinkLongerTitle) { model.thinkLonger() }
                            .buttonStyle(.textLink)
                    }
                case .interrupted:
                    Button("Run again: \(model.runThinkTime.label)") { model.runAgain() }
                        .buttonStyle(.textLink)
                case .failed:
                    Button("Try again") { model.runAgain() }
                        .buttonStyle(.textLink)
                default:
                    EmptyView()
                }
            case .notStarted:
                switch model.session.creditState {
                case .waitingForPurchase:
                    PrimaryButton(String(localized: "Analyze")) { model.analyzeAfterPaywall() }
                    chooseAnotherScreenshot
                case .waitingForApproval:
                    // An approval starts this board's analysis by itself.
                    PrimaryButton(String(localized: "See options")) { model.analyzeAfterPaywall() }
                        .accessibilityHint("Opens purchase options.")
                    chooseAnotherScreenshot
                case .authorized:
                    SecondaryButton(String(localized: "Stop"), systemImage: "stop.fill") {}
                        .disabled(true)
                }
            }
        }
        .multilineTextAlignment(.center)
    }

    private var chooseAnotherScreenshot: some View {
        Button("Choose another screenshot") { model.newAnalysis() }
            .buttonStyle(.textLink)
            .accessibilityHint("Opens the start screen to choose a screenshot.")
            .accessibilityIdentifier("analysis.newScreenshot")
    }
}

// MARK: - Pieces

/// An uppercase instrument label in a leading column, followed by content.
private struct AnalysisLabeledRow<Content: View>: View {
    let label: String
    /// `.firstTextBaseline` for text that wraps (the engine line), `.center` for controls.
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: () -> Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s2))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: Spacing.s3))
        layout {
            Text(label)
                .typography(.label)
                .foregroundStyle(Palette.ink2)
                .frame(minWidth: 44, alignment: .leading)
                .accessibilityHidden(true)
            content()
        }
        .padding(.vertical, Spacing.s3)
    }
}

/// The think-time progress rule under the board: 2 pt, `accent`, filling linearly over the
/// think time like a clock (it does not ease; Reduce Motion keeps it, it is information).
private struct AnalysisThinkProgress: View {
    let startedAt: Date?
    let thinkTime: ThinkTime
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive || startedAt == nil)) { context in
            GeometryReader { proxy in
                let elapsed = startedAt.map { context.date.timeIntervalSince($0) } ?? 0
                let fraction = min(max(elapsed / Double(thinkTime.seconds), 0), 1)
                ZStack(alignment: .leading) {
                    Rectangle().fill(Palette.rule)
                    Rectangle().fill(Palette.accent).frame(width: proxy.size.width * fraction)
                }
            }
        }
        .frame(height: 2)
        .opacity(isActive ? 1 : 0)
        .accessibilityHidden(true)
    }
}
