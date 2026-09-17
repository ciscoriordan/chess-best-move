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
@MainActor
enum CaptureDebugLaunch {
    static let markedSquares: Set<Square> = [Square("e4")!, Square("f6")!, Square("c3")!]

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
}
#endif
