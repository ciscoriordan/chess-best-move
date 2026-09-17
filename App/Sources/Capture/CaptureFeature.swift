/// Capture's factory, called by `AppModel.live()` (App/APP_CONTRACT.md section 3).
enum CaptureFeature {
    /// The production recognition service: ChessVision's `BoardRecognizer`, created lazily
    /// off the main actor.
    static func makeRecognitionService() -> any RecognitionService {
        CaptureRecognitionService()
    }
}
