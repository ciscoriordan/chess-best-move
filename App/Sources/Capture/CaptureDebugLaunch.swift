#if DEBUG
import ChessCore
import Foundation

/// DEBUG-only launch options for Capture screenshots and manual checks. Pass them as launch
/// arguments, for example
/// `xcrun simctl launch <device> com.motomatic.chessbestmove -captureImportFile /path/to/image.png`.
///
/// - `-captureImportFile <path>`: decodes the file with `CaptureImageDecoder` and imports it
///   as if it had been pasted (full path through recognition).
/// - `-captureCheckPosition YES`: recognizes the DEBUG sample screenshot and opens Check
///   position with three squares marked uncertain, whatever the recognizer said.
/// - `-captureBoardNotFound YES`: opens Board not found for the sample screenshot.
/// - `-captureEditorCorrection YES`: opens the editor on the recognized sample with the same
///   three squares marked and e4 selected.
/// - `-captureSideToMove <origin>`: opens the Analysis result on a fixed position whose side to
///   move carries that origin (a `SideToMoveOrigin` raw value: `lastMoveHighlight`,
///   `runningClock`, `checkRule`, `startPosition`, `assumedBottomPlayer` or `user`), for the
///   wording of design.md 9.4. `-captureSideToMoveScreen checkPosition` opens Check position on
///   the same board instead (9.5), and `-captureBlackAtBottom YES` turns the board around, which
///   is the case the wording is for: the side to move is then the player at the top. Use it with
///   `-monetizationDemo 3`, because Analysis spends a credit like any board set up by hand.
@MainActor
enum CaptureDebugLaunch {
    static let markedSquares: Set<Square> = [Square("e4")!, Square("f6")!, Square("c3")!]

    /// White is in check from the queen on h4 and has four legal moves, so `checkRule` shows a
    /// board on which the check rule could have decided who is to move.
    static let checkRuleFEN = "r3k2r/pppp1ppp/8/8/7q/8/PPPP2PP/R3K2R w KQkq - 0 1"

    private static var hasRun = false

    static func run(app: AppModel, model: CaptureHomeModel) async {
        guard !hasRun, app.path.isEmpty, app.sheet == nil, app.editor == nil else { return }
        hasRun = true
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "captureImportFile") {
            guard let data = FileManager.default.contents(atPath: path) else { return }
            await model.importData(data, source: .paste, app: app)
            return
        }
        if let raw = defaults.string(forKey: "captureSideToMove"), let origin = SideToMoveOrigin(rawValue: raw) {
            presentSideToMove(origin: origin, app: app, defaults: defaults)
            return
        }
        if defaults.bool(forKey: "captureBoardNotFound"), let sample = DebugSample.load() {
            app.importImage(sample)
            app.handleRecognition(.boardNotFound, for: sample)
            return
        }
        let wantsCheck = defaults.bool(forKey: "captureCheckPosition")
        let wantsEditor = defaults.bool(forKey: "captureEditorCorrection")
        guard wantsCheck || wantsEditor, let sample = DebugSample.load() else { return }
        var snapshot: BoardSnapshot
        switch await app.recognition.recognize(sample) {
        case .confident(let recognized), .needsCheck(let recognized):
            snapshot = recognized
        case .boardNotFound, .invalidImage:
            guard let position = try? Position(fen: DebugSample.fen) else { return }
            snapshot = BoardSnapshot(position: position, sideToMoveOrigin: .assumedBottomPlayer, sourceImage: sample.image, recognizedBoard: position.board)
        }
        snapshot.lowConfidenceSquares = markedSquares
        if wantsEditor {
            app.presentEditor(EditorContext(snapshot: snapshot, selectedSquare: Square("e4"), purpose: .correction))
        } else {
            app.importImage(sample)
            app.handleRecognition(.needsCheck(snapshot), for: sample)
        }
    }

    /// `-captureSideToMove`: a board whose side to move carries `origin`, on the Analysis result
    /// or on Check position. The board is the app's own diagram (no screenshot crop), so the
    /// screens read the same on every run whatever recognition would have made of an image.
    private static func presentSideToMove(origin: SideToMoveOrigin, app: AppModel, defaults: UserDefaults) {
        let fen: String? = switch origin {
        case .startPosition: nil
        case .checkRule: checkRuleFEN
        default: DebugSample.fen
        }
        var position = fen.flatMap { try? Position(fen: $0) } ?? .start
        let whiteAtBottom = !defaults.bool(forKey: "captureBlackAtBottom")
        // The assumed origin is the player at the bottom by definition, so the board turning
        // around turns that side around with it (`BoardSnapshot.flippedByUser`).
        if origin == .assumedBottomPlayer {
            position.sideToMove = whiteAtBottom ? .white : .black
        }
        // The doubt recognition reports with an assumed side to move, so Check position shows
        // the note that belongs to it; every other origin is a board recognition was sure of.
        let doubts: [BoardDoubt] = origin == .assumedBottomPlayer ? [.sideToMoveNotEstablished] : []
        let snapshot = BoardSnapshot(
            position: position,
            whiteAtBottom: whiteAtBottom,
            sideToMoveOrigin: origin,
            doubts: doubts,
            assumedCastlingRights: position.castlingRights
        )
        if defaults.string(forKey: "captureSideToMoveScreen") == "checkPosition" {
            app.returnToCheckPosition(snapshot)
        } else {
            app.requestAnalysis(of: snapshot, origin: .handSetup)
        }
    }
}
#endif
