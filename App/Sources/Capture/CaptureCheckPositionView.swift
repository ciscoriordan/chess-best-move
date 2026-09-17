import ChessCore
import SwiftUI

/// Accessibility identifiers of Capture screens for UI tests (the tests mirror these strings,
/// because UI tests cannot import the app module).
enum CaptureAccessibilityID {
    static let homeLatestScreenshot = "home.latestScreenshot"
    static let homeChooseFromPhotos = "home.chooseFromPhotos"
    static let homePaste = "home.paste"
    static let homeShortcutSetup = "home.shortcutSetup"
    static let homeFairPlayNote = "home.fairPlayNote"
    static let checkPositionTitle = "checkPosition.title"
    static let checkPositionAnalyze = "checkPosition.analyze"
    static let checkPositionReason = "checkPosition.reason"
    static let boardNotFoundTitle = "boardNotFound.title"
    static let editorBoard = "editor.board"
    static let editorAnalyze = "editor.analyze"
}

/// Check position (design.md 9.5): recognition returned a doubtful result, or a position the
/// engine cannot take. The board shows what recognition read: the recognized pieces on the
/// app's diagram board, with a dashed `caution` outline and a "?" badge on uncertain squares.
/// Over the user's own screenshot crop the marks could not show which piece was read on a
/// doubtful square, so the crop is shown only while the board is pressed and held, for
/// comparison. (Analysis, which does not ask the user to check pieces, shows the crop.)
/// Nothing is spent until Analyze.
struct CheckPositionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var snapshot: BoardSnapshot
    @State private var appeared = false
    @State private var selectionFeedback = 0
    @State private var isPeeking = false

    init(snapshot: BoardSnapshot) {
        _snapshot = State(initialValue: snapshot)
    }

    private var issues: [PositionIssue] { snapshot.position.validate() }
    private var blockingIssues: [PositionIssue] { issues.filter(CapturePositionIssues.isBlocking) }
    private var flaggedSquares: [Square] { snapshot.lowConfidenceSquares.sorted() }

    var body: some View {
        let issues = issues
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                board(issues: issues)
                if snapshot.boardImage != nil {
                    Text(isPeeking ? "Showing your screenshot" : "Press and hold the board to compare it with your screenshot.")
                        .typography(.caption)
                        .foregroundStyle(Palette.ink2)
                        .padding(.top, Spacing.s2)
                        .accessibilityHidden(true)
                }
                chips
                    .padding(.top, Spacing.s4)
                Hairline()
                    .padding(.top, Spacing.s4)
                summary(issues: issues)
                    .padding(.top, Spacing.s4)
                castling
            }
            .sideGutter()
            .padding(.top, Spacing.s4)
            .padding(.bottom, Spacing.s5)
        }
        .background(Palette.canvas)
        .navigationTitle("Check position")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { actionBar(canAnalyze: issues.allSatisfy { !CapturePositionIssues.isBlocking($0) }) }
        .sensoryFeedback(.warning, trigger: appeared) { _, new in new }
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .onAppear { appeared = true }
    }

    // MARK: Board

    private func board(issues: [PositionIssue]) -> some View {
        let whiteAtBottom = snapshot.whiteAtBottom
        return BoardFrame {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                ZStack {
                    DiagramBoard(board: snapshot.position.board, whiteAtBottom: whiteAtBottom)
                    CaptureBoardMarks(
                        whiteAtBottom: whiteAtBottom,
                        lowConfidence: snapshot.lowConfidenceSquares,
                        danger: CapturePositionIssues.dangerSquares(in: issues)
                    )
                    if isPeeking, let image = snapshot.boardImage {
                        BoardScreenshot(image: image, snapshot: snapshot)
                    }
                }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    openEditor(selecting: BoardGeometry.square(at: location, side: side, whiteAtBottom: whiteAtBottom))
                }
                .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 30) {
                    // Held long enough: show the screenshot until the finger lifts.
                    if snapshot.boardImage != nil { isPeeking = true }
                } onPressingChanged: { pressing in
                    if !pressing { isPeeking = false }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CaptureBoardSpeech.boardLabel(whiteAtBottom: whiteAtBottom))
        .accessibilityValue(boardAccessibilityValue)
        .accessibilityHint("Opens the position editor")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openEditor(selecting: nil) }
        .accessibilityActions {
            ForEach(flaggedSquares, id: \.self) { square in
                Button("Fix \(square.algebraic)") { openEditor(selecting: square) }
            }
        }
    }

    private var boardAccessibilityValue: String {
        var parts: [String] = []
        let flagged = flaggedSquares
        if !flagged.isEmpty {
            parts.append("Needs a look: " + flagged.map(\.algebraic).joined(separator: ", "))
        }
        parts.append(CaptureBoardSpeech.pieceList(snapshot.position.board))
        return parts.joined(separator: ". ")
    }

    // MARK: Chips

    private var chips: some View {
        let side = snapshot.position.sideToMove
        let caption = CapturePositionIssues.sideToMoveCaption(snapshot.sideToMoveOrigin)
        let assumed = snapshot.sideToMoveOrigin == .assumedBottomPlayer
        return VStack(alignment: .leading, spacing: Spacing.s1) {
            CaptureFlowLayout {
                Chip(
                    "\(CapturePositionIssues.name(side)) to move",
                    glyph: .piece(Piece(color: side, kind: .king)),
                    state: assumed ? .attention : .normal
                ) {
                    snapshot = snapshot.withSideToMove(side.opposite)
                    selectionFeedback += 1
                }
                .accessibilityLabel("Side to move")
                .accessibilityValue(CapturePositionIssues.name(side))
                .accessibilityHint("Switches the side to move")

                Chip("Flip board", glyph: .systemImage("arrow.up.arrow.down")) {
                    flip()
                    selectionFeedback += 1
                }
                .accessibilityHint("Swaps which side is at the bottom")
            }
            if let caption {
                Text(caption)
                    .typography(.caption)
                    .foregroundStyle(assumed ? Palette.caution : Palette.ink2)
            }
        }
    }

    private var castling: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Castling")
            CaptureFlowLayout {
                ForEach(CaptureCastlingOption.all) { option in
                    let available = snapshot.position.inferredCastlingRights.contains(option.right)
                    let on = snapshot.position.castlingRights.contains(option.right)
                    Chip(option.title, state: on ? .on : .normal) {
                        if on {
                            snapshot.position.castlingRights.remove(option.right)
                        } else {
                            snapshot.position.castlingRights.insert(option.right)
                        }
                        snapshot.confirmCastlingRight(option.right)
                        selectionFeedback += 1
                    }
                    .disabled(!available)
                    .opacity(available ? 1 : 0.4)
                    .accessibilityLabel(option.spokenTitle)
                    .accessibilityValue(on ? "On" : "Off")
                }
            }
        }
    }

    // MARK: Summary

    private func summary(issues: [PositionIssue]) -> some View {
        let summary = CaptureCheckPositionSummary(snapshot: snapshot, issues: issues)
        return VStack(alignment: .leading, spacing: Spacing.s3) {
            Text(summary.title)
                .typography(.title)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(CaptureAccessibilityID.checkPositionTitle)
            Text(summary.body)
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = summary.reason {
                Text(reason)
                    .typography(.body)
                    .foregroundStyle(Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(CaptureAccessibilityID.checkPositionReason)
            }
            CaptureIssueList(issues: issues, position: snapshot.position) {
                snapshot = snapshot.withSideToMove(snapshot.position.sideToMove.opposite)
                selectionFeedback += 1
            }
            .padding(.top, Spacing.s1)
        }
    }

    // MARK: Actions

    private func actionBar(canAnalyze: Bool) -> some View {
        PinnedActionBar {
            let layout = dynamicTypeSize >= .accessibility3
                ? AnyLayout(VStackLayout(spacing: Spacing.s2))
                : AnyLayout(HStackLayout(spacing: Spacing.s3))
            layout {
                PrimaryButton("Analyze") { analyze() }
                    .disabled(!canAnalyze)
                    .accessibilityIdentifier(CaptureAccessibilityID.checkPositionAnalyze)
                SecondaryButton("Edit", dense: dynamicTypeSize < .accessibility3) { openEditor(selecting: nil) }
                    .accessibilityHint("Opens the position editor")
            }
        }
    }

    private func analyze() {
        var confirmed = snapshot
        confirmed.position.removeInconsistentCastlingRights()
        confirmed.position.removeInvalidEnPassant()
        app.requestAnalysis(of: confirmed, origin: .recognition)
    }

    private func openEditor(selecting square: Square?) {
        app.presentEditor(EditorContext(snapshot: snapshot, selectedSquare: square, purpose: .correction))
    }

    /// Flips the orientation the same way the Analysis screen does
    /// (`BoardSnapshot.flippedByUser()`): for a recognized board the picture stays the same and
    /// the squares are renamed, and an assumed side to move follows the new bottom player.
    private func flip() {
        snapshot = snapshot.flippedByUser()
    }
}

/// What Check position says about a doubtful board, in plain language: a title, what to do,
/// and, when the screenshot itself explains the doubt, why.
///
/// The reason comes from what recognition reported (`BoardSnapshot.doubts`) and, for the
/// screenshot's edge, from the geometry the app checks itself (`CaptureBoardCoverage`):
///
/// - Marked squares outside the screenshot: the recognizer never saw them, so pieces there may
///   be missing.
/// - Marked squares under a cover: something is drawn over them (a banner, a card, a menu).
/// - Other marked squares: hard to read, for whatever reason.
/// - Nothing marked and nothing to fix, so the doubt is about the board as a whole: several
///   boards in the screenshot, squares too small to read, inverted square colors, an orientation
///   no coordinates confirm, or a side to move read from weak evidence. A doubt with nothing to
///   say about the screenshot (a weak board match) leaves the reason out, because the body
///   already asks the user to compare the board with the screenshot.
struct CaptureCheckPositionSummary: Equatable, Sendable {
    let title: String
    let body: String
    /// Why the board needs a look, shown in `caution`; nil when there is nothing specific to say.
    let reason: String?

    init(snapshot: BoardSnapshot, issues: [PositionIssue]) {
        let flagged = snapshot.lowConfidenceSquares
        let blocking = issues.filter(CapturePositionIssues.isBlocking)
        // Squares the recognizer could not see: cut off by the image edge (geometry) or reported
        // by ChessVision, which also counts transparent pixels inside the image.
        let outside = CaptureBoardCoverage.cutOffSquares(
            in: snapshot,
            below: CaptureBoardCoverage.partlyOutsideVisibleFraction
        ).union(snapshot.doubts.squares(outsideTheImage: true)).intersection(flagged)
        let covered = snapshot.doubts.squares(outsideTheImage: false).intersection(flagged)

        if !flagged.isEmpty {
            title = flagged.count == 1 ? "1 square needs a look" : "\(flagged.count) squares need a look"
        } else if !blocking.isEmpty {
            title = "Fix the position"
        } else {
            title = "Check the position"
        }

        // Reasons that point at the screenshot apply only to pieces as recognized from one.
        let readFromScreenshot = snapshot.boardImage != nil && !snapshot.isEdited

        if !blocking.isEmpty {
            body = "Tap a square to fix it. You can analyze once the problems below are fixed."
        } else if !flagged.isEmpty {
            body = "Tap a marked square to fix it, or analyze as recognized."
        } else if readFromScreenshot {
            body = "Recognition wasn't sure it read the right board. Press and hold the board to compare it with your screenshot, then analyze."
        } else {
            body = "Check the pieces, then analyze."
        }

        if !readFromScreenshot {
            reason = nil
        } else if !outside.isEmpty {
            let rest = outside.count == flagged.count ? ""
                : covered.isEmpty ? " Other marked squares were hard to read."
                : " Something in your screenshot covers the other marked squares."
            reason = "Part of the board is outside your screenshot, so pieces on the marked edge squares may be missing." + rest
        } else if !covered.isEmpty {
            reason = "Something in your screenshot covers the marked squares, such as a banner, a card or a menu."
                + (covered.count == flagged.count ? "" : " The other marked squares were hard to read.")
        } else if !flagged.isEmpty {
            reason = "Marked squares were hard to read. Something may cover them in your screenshot, such as a banner, an arrow or a menu."
        } else if blocking.isEmpty {
            reason = Self.boardReason(snapshot.doubts)
        } else {
            reason = nil
        }
    }

    /// What to say when no single square is marked and the doubt is about the board as a whole.
    /// The first doubt that has something to say about the screenshot wins.
    static func boardReason(_ doubts: [BoardDoubt]) -> String? {
        for doubt in doubts {
            switch doubt {
            case .severalBoards(let count):
                return "Your screenshot shows \(count) boards. If this is not the one you want, crop the screenshot to that board and import it again."
            case .squaresTooSmall(let pixelsPerSquare):
                return "The board is small in your screenshot, about \(Int(pixelsPerSquare.rounded())) pixels a square, which makes the pieces hard to read. A screenshot with the board larger reads better."
            case .invertedSquareColors:
                return "The light and dark squares are the other way round on this board. Some board themes look like that; so does a mirrored screenshot, and then the pieces sit on mirrored squares."
            case .orientationUnconfirmed:
                return "Recognition is not sure which way the board faces. Check that the right color is at the bottom, and flip it if it is not."
            case .sideToMoveUncertain:
                return "Recognition is not sure who is to move. Check the side to move below."
            case .weakBoardMatch, .squaresOutsideImage, .squaresCovered, .uncertainSquares, .impossiblePosition:
                continue
            }
        }
        return nil
    }
}

extension [BoardDoubt] {
    /// The squares of the `squaresOutsideImage` doubt, or of the `squaresCovered` doubt.
    func squares(outsideTheImage: Bool) -> Set<Square> {
        var squares: Set<Square> = []
        for doubt in self {
            switch doubt {
            case .squaresOutsideImage(let list) where outsideTheImage: squares.formUnion(list)
            case .squaresCovered(let list) where !outsideTheImage: squares.formUnion(list)
            default: continue
            }
        }
        return squares
    }
}

/// One castling right as a toggle.
struct CaptureCastlingOption: Identifiable, Hashable, Sendable {
    let right: CastlingRights
    let title: String
    let spokenTitle: String

    var id: UInt8 { right.rawValue }

    static let all: [CaptureCastlingOption] = [
        CaptureCastlingOption(right: .whiteKingside, title: "White O-O", spokenTitle: "White castles kingside"),
        CaptureCastlingOption(right: .whiteQueenside, title: "White O-O-O", spokenTitle: "White castles queenside"),
        CaptureCastlingOption(right: .blackKingside, title: "Black O-O", spokenTitle: "Black castles kingside"),
        CaptureCastlingOption(right: .blackQueenside, title: "Black O-O-O", spokenTitle: "Black castles queenside"),
    ]
}

/// The validation list (design.md 9.6): blocking issues in `danger`, "No legal moves" in
/// `ink2`, and an inline "Switch side to move" for a side in check that is not to move.
struct CaptureIssueList: View {
    let issues: [PositionIssue]
    let position: Position
    let switchSideToMove: () -> Void

    /// The issue symbol grows with the `body` text next to it.
    @ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 15

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                ForEach(issues, id: \.self) { issue in
                    let blocking = CapturePositionIssues.isBlocking(issue)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s2) {
                            Image(systemName: blocking ? "exclamationmark.circle.fill" : "info.circle")
                                .font(.system(size: symbolSize, weight: .semibold))
                                .accessibilityHidden(true)
                            Text(CapturePositionIssues.message(for: issue, in: position))
                                .typography(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(blocking ? Palette.danger : Palette.ink2)
                        .accessibilityElement(children: .combine)
                        if issue == .sideNotToMoveInCheck {
                            TextLink("Switch side to move", action: switchSideToMove)
                                .padding(.leading, symbolSize + Spacing.s2)
                        }
                    }
                }
            }
        }
    }
}
