import ChessCore
import SwiftUI

/// The position editor (design.md 9.6), presented full screen by `RootView`.
///
/// Closes with the native close control ("Discard changes?" when the position changed);
/// there is no Done button: the action is Analyze, which is disabled while the position has
/// blocking issues.
struct PositionEditorView: View {
    let context: EditorContext

    @Environment(AppModel.self) private var app
    @State private var model: CaptureEditorModel
    @State private var confirmsDiscard = false
    @State private var selectionFeedback = 0

    init(context: EditorContext) {
        self.context = context
        _model = State(initialValue: CaptureEditorModel(context: context))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    CaptureEditorBoard(model: model)
                    trayCaption
                        .padding(.top, Spacing.s3)
                    CapturePieceTray(model: model)
                        .padding(.top, Spacing.s2)
                    Hairline()
                        .padding(.top, Spacing.s4)
                    sideToMove
                        .padding(.top, Spacing.s3)
                    castling
                        .padding(.top, Spacing.s3)
                    if !model.issues.isEmpty {
                        Hairline()
                            .padding(.top, Spacing.s4)
                        CaptureIssueList(issues: model.issues, position: model.position) {
                            model.switchSideToMove()
                            selectionFeedback += 1
                        }
                        .padding(.top, Spacing.s3)
                    }
                }
                .sideGutter()
                .padding(.top, Spacing.s3)
                .padding(.bottom, Spacing.s5)
            }
            .background(Palette.canvas)
            .navigationTitle("Edit position")
            .navigationBarTitleDisplayMode(.inline)
            .modalCloseButton { close() }
            .toolbar { trailingToolbar }
            .safeAreaInset(edge: .bottom) {
                PinnedActionBar {
                    PrimaryButton("Analyze") { analyze() }
                        .disabled(!model.canAnalyze)
                        .accessibilityIdentifier(CaptureAccessibilityID.editorAnalyze)
                        .accessibilityHint(model.canAnalyze ? "" : "Fix the problems listed above first")
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { app.dismissEditor() }
                Button("Keep editing", role: .cancel) {}
            }
            .sensoryFeedback(.selection, trigger: selectionFeedback)
        }
        .interactiveDismissDisabled(model.hasUnsavedChanges)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var trailingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .accessibilityLabel("Undo")

            Menu {
                if model.canResetToRecognized {
                    Button {
                        model.resetToRecognized()
                    } label: {
                        Label("Reset to recognized", systemImage: "arrow.counterclockwise")
                    }
                }
                Button {
                    model.setStartPosition()
                } label: {
                    Label("Start position", systemImage: "square.grid.3x3")
                }
                Button(role: .destructive) {
                    model.clearBoard()
                } label: {
                    Label("Clear board", systemImage: "square.slash")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    // MARK: Sections

    private var trayCaption: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s2) {
            Text(trayCaptionText)
                .typography(.callout)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let square = model.selectedSquare, model.isLowConfidence(square) {
                TextLink("Looks right") { model.confirm(square) }
                    .accessibilityHint("Keeps \(square.algebraic) as recognized")
            }
        }
        .frame(minHeight: Layout.minimumHitTarget)
    }

    private var trayCaptionText: String {
        if let square = model.selectedSquare {
            let occupant = model.piece(at: square).map(CapturePositionIssues.name) ?? "empty"
            return "\(square.algebraic): \(occupant)" + (model.isLowConfidence(square) ? ", not sure" : "")
        }
        if let armed = model.armedItem {
            let name = armed.piece.map { "a \(CapturePositionIssues.name($0))" } ?? "Empty"
            return armed.piece == nil ? "Tap squares to clear them" : "Tap squares to place \(name)"
        }
        return "Tap a square, then a piece. Or tap a piece, then squares."
    }

    private var sideToMove: some View {
        let side = model.position.sideToMove
        return CaptureFlowLayout {
            ForEach(PieceColor.allCases, id: \.self) { color in
                Chip(
                    "\(CapturePositionIssues.name(color)) to move",
                    glyph: .piece(Piece(color: color, kind: .king)),
                    state: side == color ? .on : .normal
                ) {
                    model.setSideToMove(color)
                    selectionFeedback += 1
                }
                .accessibilityAddTraits(side == color ? .isSelected : [])
            }
        }
    }

    private var castling: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            Text("Castling")
                .typography(.sectionLabel)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Castling")
                .accessibilityAddTraits(.isHeader)
            CaptureFlowLayout {
                ForEach(CaptureCastlingOption.all) { option in
                    let available = model.isCastlingAvailable(option.right)
                    let on = model.hasCastlingRight(option.right)
                    Chip(option.title, state: on ? .on : .normal) {
                        model.toggleCastling(option.right)
                        selectionFeedback += 1
                    }
                    .disabled(!available)
                    .accessibilityLabel(option.spokenTitle)
                    .accessibilityValue(on ? "On" : "Off")
                    .accessibilityHint(available ? "" : CaptureCastlingOption.unavailableHint)
                    // Voice Control matches what is written on the chip as well as what it is
                    // called: "W O-O" is on screen, "White castles kingside" is spoken.
                    .accessibilityInputLabels([option.title, option.spokenTitle])
                }
            }
        }
    }

    // MARK: Actions

    private func close() {
        if model.hasUnsavedChanges {
            confirmsDiscard = true
        } else {
            app.dismissEditor()
        }
    }

    private func analyze() {
        guard model.canAnalyze else { return }
        app.finishEditing(with: model.finishedSnapshot(), origin: model.analysisOrigin)
    }
}
