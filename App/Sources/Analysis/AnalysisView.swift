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

    /// The board side for a content width (inside the side gutters): the width left after the
    /// evaluation bar, capped at `Layout.maximumBoardSide`.
    @MainActor static func boardSide(contentWidth: CGFloat) -> CGFloat {
        let available = isWide(contentWidth: contentWidth) ? (contentWidth - columnSpacing) / 2 : contentWidth
        let side = available - evalBarColumn
        return side > 0 ? min(side, Layout.maximumBoardSide) : 300
    }
}

private struct AnalysisScreen: View {
    @State private var model: AnalysisScreenModel
    @State private var contentWidth: CGFloat = 0
    @State private var isPeeking = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(app: AppModel, session: AnalysisSession) {
        _model = State(initialValue: AnalysisScreenModel(app: app, session: session))
    }

    private var app: AppModel { model.app }
    private var session: AnalysisSession { model.session }
    private var snapshot: BoardSnapshot { session.snapshot }
    private var isFinal: Bool { model.runState == .completed }
    /// Two columns on iPad and in landscape (design.md section 5).
    private var isWide: Bool { AnalysisLayout.isWide(contentWidth: contentWidth) }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    contentWidth = width
                }
                .sideGutter()
                .padding(.top, AnalysisLayout.topPadding)
                .padding(.bottom, Spacing.s5)
        }
        .background(Palette.canvas)
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { CreditsToolbarIndicator() }
        }
        .safeAreaInset(edge: .bottom) {
            PinnedActionBar { actionBar }
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .onChange(of: session.canAnalyze) { _, _ in model.creditStateChanged() }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(to: phase) }
        .sensoryFeedback(.success, trigger: model.completionCount)
        .sensoryFeedback(.selection, trigger: model.adjustmentCount)
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
    private var content: some View {
        if isWide {
            HStack(alignment: .top, spacing: AnalysisLayout.columnSpacing) {
                VStack(alignment: .leading, spacing: 0) { boardGroup }
                    .frame(width: boardSide + AnalysisLayout.evalBarColumn)
                VStack(alignment: .leading, spacing: 0) { readoutGroups }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                boardGroup
                readoutGroups
            }
        }
    }

    /// The board side: the width left after the eval bar, capped at 600 pt.
    private var boardSide: CGFloat {
        AnalysisLayout.boardSide(contentWidth: contentWidth)
    }

    // MARK: Board

    @ViewBuilder
    private var boardGroup: some View {
        HStack(alignment: .top, spacing: AnalysisEvalBar.spacing) {
            AnalysisEvalBar(
                whiteShare: evalShare,
                isPlaceholder: evalIsPlaceholder,
                whiteAtBottom: snapshot.whiteAtBottom,
                accessibilityValueText: evalSpoken
            )
            .frame(height: boardSide)
            board
                .frame(width: boardSide, height: boardSide)
        }
        AnalysisThinkProgress(
            startedAt: model.searchStartedAt,
            thinkTime: model.runThinkTime,
            isActive: model.isThinking
        )
        .padding(.top, Spacing.s2)
        chips
            .padding(.top, Spacing.s3)
    }

    private var board: some View {
        let canPeek = snapshot.showsDiagram && snapshot.boardImage != nil
        let showsScreenshot = snapshot.boardImage != nil && (!snapshot.showsDiagram || isPeeking)
        return BoardFrame {
            ZStack(alignment: .topTrailing) {
                if showsScreenshot, let image = snapshot.boardImage {
                    BoardScreenshot(image: image, snapshot: snapshot)
                } else {
                    DiagramBoard(board: snapshot.position.board, whiteAtBottom: snapshot.whiteAtBottom)
                }
                AnalysisArrowOverlay(
                    move: isPeeking ? nil : model.bestMove?.move,
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Board, \(snapshot.whiteAtBottom ? "White" : "Black") at bottom\(snapshot.showsDiagram && snapshot.boardImage != nil ? ", edited" : "")")
        .accessibilityValue(boardAccessibilityValue)
        .accessibilityCustomContent("Pieces", AnalysisSpeech.pieceList(snapshot.position.board))
        .accessibilityCustomContent("Side to move", sideToMoveAccessibilityText)
        .accessibilityCustomContent("FEN", snapshot.position.fen)
    }

    private var boardAccessibilityValue: String {
        if let checkmate = model.noLegalMoves {
            return checkmate ? "Checkmate." : "Stalemate."
        }
        guard let best = model.bestMove else {
            return model.isThinking ? "Thinking." : "No best move yet."
        }
        let description = AnalysisSpeech.moveDescription(san: best.san, move: best.move, alwaysIncludeFromSquare: true)
        return (isFinal ? "Best move: " : "Best move so far: ") + AnalysisSpeech.lowercasingFirstLetter(description) + "."
    }

    private var sideToMoveAccessibilityText: String {
        let color = AnalysisSpeech.colorName(snapshot.position.sideToMove)
        guard let source = sideToMoveSourceText else { return color }
        return "\(color), \(source)"
    }

    // MARK: Chips

    private var sideToMoveSourceText: String? {
        switch snapshot.sideToMoveOrigin {
        case .lastMoveHighlight: "from last-move highlight"
        case .runningClock: "from the clock"
        case .checkRule: "from check"
        case .assumedBottomPlayer: "assumed: you are at the bottom"
        case .user: nil
        }
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: Spacing.s1) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.s2) { chipItems }
                VStack(alignment: .leading, spacing: Spacing.s2) { chipItems }
            }
            if [.lastMoveHighlight, .runningClock, .checkRule].contains(snapshot.sideToMoveOrigin),
               let source = sideToMoveSourceText {
                Text(source)
                    .typography(.caption)
                    .foregroundStyle(Palette.ink2)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var chipItems: some View {
        let side = snapshot.position.sideToMove
        let isAssumed = snapshot.sideToMoveOrigin == .assumedBottomPlayer
        Chip(
            "\(AnalysisSpeech.colorName(side)) to move",
            glyph: .piece(Piece(color: side, kind: .king)),
            state: isAssumed ? .attention : .normal,
            attentionCaption: sideToMoveSourceText
        ) {
            model.toggleSideToMove()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Side to move")
        .accessibilityValue(sideToMoveAccessibilityText)
        .accessibilityHint("Swaps the side to move and analyzes again.")
        // At accessibility sizes a chip label wraps instead of widening the screen (design.md 12).
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)

        Chip("Flip", glyph: .systemImage("arrow.up.arrow.down")) {
            model.flip()
        }
        .accessibilityLabel("Flip board")
        // A board set up by hand only turns around on screen (BoardSnapshot.flippedByUser).
        .accessibilityHint(snapshot.boardImage == nil ? "Turns the board around." : "Turns the board around and analyzes again.")
        // At accessibility sizes a chip label wraps instead of widening the screen (design.md 12).
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)

        Chip("Edit", glyph: .systemImage("square.and.pencil")) {
            model.edit()
        }
        .accessibilityLabel("Edit position")
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
        if let right = model.assumedCastlingRight {
            castlingCaution(right)
                .padding(.bottom, Spacing.s3)
        }
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

    private var readout: some View {
        VStack(alignment: .leading, spacing: Spacing.s1) {
            HStack(alignment: .center, spacing: Spacing.s2) {
                AccentLegendSquare()
                Text(statusLabel)
                    .typography(.label)
                    .foregroundStyle(Palette.ink2)
                Spacer(minLength: Spacing.s3)
                if let score = displayedScore {
                    Text(AnalysisScore.text(score))
                        .typography(.dataLarge)
                        .foregroundStyle(isFinal ? Palette.ink : Palette.ink2)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .easeOut(duration: Motion.valueChange), value: score)
                        .accessibilityLabel("Evaluation")
                        .accessibilityValue(AnalysisScore.spoken(score))
                }
            }
            hero
            Text(model.detailLine)
                .typography(.callout)
                .foregroundStyle(detailIsCaution ? Palette.caution : Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                // The hero move already speaks this line as its label; VoiceOver reads it once.
                .accessibilityHidden(model.detailRepeatsHero)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(model.isThinking ? .updatesFrequently : [])
    }

    @ViewBuilder
    private var hero: some View {
        if let checkmate = model.noLegalMoves {
            Text(checkmate ? "Checkmate" : "Stalemate")
                .typography(.moveHero, width: 75)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Palette.ink)
        } else if let best = model.bestMove {
            AnalysisHeroMove(
                san: best.san,
                spokenDescription: model.heroSpokenDescription ?? best.san,
                isFinal: isFinal
            )
            .id(best.san)
            .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: Motion.valueChange)))
        } else {
            Text(model.isThinking ? "\u{2026}" : "\u{2014}")
                .typography(.moveHero)
                .lineLimit(1)
                .foregroundStyle(Palette.ink3)
                .accessibilityHidden(true)
        }
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
            .accessibilityLabel("Turn off \(AnalysisScreenModel.spokenCastlingName(right))")
            .accessibilityHint("Analyzes again without it. Re-running is free.")
            .accessibilityIdentifier("analysis.turnOffCastling")
        }
    }

    private var statusLabel: String {
        switch model.runState {
        case .starting, .running: "Thinking"
        case .completed: model.noLegalMoves != nil ? "No legal moves" : "Best move"
        case .interrupted: "Stopped"
        case .failed: "Engine error"
        case .notStarted: "Best move"
        }
    }

    /// The score shown next to the label, never for checkmate or stalemate.
    private var displayedScore: WhiteScore? {
        guard model.noLegalMoves == nil, model.bestMove != nil else { return nil }
        return model.readout?.score
    }

    private var detailIsCaution: Bool {
        if case .failed = model.runState { return true }
        return false
    }

    // MARK: Engine line

    private var lineRow: some View {
        let sanMoves = model.readout.map { model.position.sanLine($0.principalVariation) } ?? []
        let expanded = model.isLineExpanded || dynamicTypeSize.isAccessibilitySize
        let (tokens, isTruncated) = AnalysisLine.tokens(
            sanMoves: sanMoves,
            position: model.position,
            plies: expanded ? nil : AnalysisLine.collapsedPlies
        )
        return AnalysisLabeledRow(label: "Line", alignment: .firstTextBaseline) {
            Text(lineText(tokens, isTruncated: isTruncated, placeholder: sanMoves.isEmpty))
                .typography(.line)
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard sanMoves.count > AnalysisLine.collapsedPlies else { return }
            model.isLineExpanded.toggle()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Engine line")
        .accessibilityValue(sanMoves.isEmpty ? "None yet" : AnalysisSpeech.line(sanMoves: sanMoves))
        .accessibilityAddTraits(sanMoves.count > AnalysisLine.collapsedPlies ? .isButton : [])
    }

    private func lineText(_ tokens: [AnalysisLineToken], isTruncated: Bool, placeholder: Bool) -> AttributedString {
        guard !placeholder else {
            var empty = AttributedString("\u{2014}")
            empty.foregroundColor = Palette.ink3
            return empty
        }
        var result = AttributedString()
        for token in tokens {
            if !result.characters.isEmpty {
                result += AttributedString(result.characters.last == "." ? "\u{00A0}" : " ")
            }
            var piece = AttributedString(token.text)
            piece.foregroundColor = token.isFirstMove ? Palette.accent : (token.kind == .moveNumber ? Palette.ink2 : Palette.ink)
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
            AnalysisLabeledRow(label: "Think") {
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
        let depth = readout.map { AnalysisDataText.depth($0.depth) } ?? "depth \u{2014}"
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
        .foregroundStyle(readout == nil ? Palette.ink3 : Palette.ink2)
        .accessibilityElement(children: .combine)
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

    // MARK: Pinned action bar

    @ViewBuilder
    private var actionBar: some View {
        let layout = dynamicTypeSize >= .accessibility3
            ? AnyLayout(VStackLayout(spacing: Spacing.s2))
            : AnyLayout(HStackLayout(spacing: Spacing.s3))
        layout {
            switch model.runState {
            case .starting, .running:
                SecondaryButton("Stop", systemImage: "stop.fill") { model.stop() }
            case .completed:
                if model.noLegalMoves != nil || model.bestMove == nil {
                    PrimaryButton("New") { model.newAnalysis() }
                } else {
                    PrimaryButton(model.thinkLongerTitle) { model.thinkLonger() }
                    newButton
                }
            case .interrupted:
                PrimaryButton("Run again: \(model.runThinkTime.label)") { model.runAgain() }
                newButton
            case .failed:
                PrimaryButton("Try again") { model.runAgain() }
                newButton
            case .notStarted:
                switch session.creditState {
                case .waitingForPurchase:
                    PrimaryButton("Analyze") { model.analyzeAfterPaywall() }
                    newButton
                case .waitingForApproval:
                    // A declined Ask to Buy request is never reported, so the user can still
                    // choose another purchase; an approval starts the analysis by itself.
                    PrimaryButton("See options") { model.analyzeAfterPaywall() }
                        .accessibilityHint("Opens purchase options.")
                    newButton
                case .authorized:
                    SecondaryButton("Stop", systemImage: "stop.fill") {}
                        .disabled(true)
                }
            }
        }
    }

    private var newButton: some View {
        SecondaryButton("New", dense: dynamicTypeSize < .accessibility3) { model.newAnalysis() }
            .accessibilityHint("Returns to the start screen.")
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
            return checkmate ? "\(side) is checkmated" : "Stalemate"
        }
        guard let score = displayedScore else { return "Not evaluated yet" }
        return AnalysisScore.spoken(score)
    }
}

// MARK: - Pieces

/// The best move in `move.hero`. Long moves switch to the narrow width (a second layout, not a
/// shrink); only then may the text scale down to 70%.
private struct AnalysisHeroMove: View {
    let san: String
    let spokenDescription: String
    let isFinal: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(san)
                .typography(.moveHero)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(san)
                .typography(.moveHero, width: 75)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(isFinal ? Palette.ink : Palette.ink2)
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.stateShort), value: isFinal)
        .accessibilityLabel(spokenDescription)
        .accessibilityIdentifier(AccessibilityID.analysisBestMove)
    }
}

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
