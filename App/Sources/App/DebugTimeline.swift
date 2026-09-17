#if DEBUG
import Foundation
import Observation
import os

/// DEBUG-only timeline of one import, from the user's tap to the final result, for measuring
/// latency on a simulator or device. Each event is the time since `begin`. Events are written
/// to the unified log (subsystem `com.motomatic.chessbestmove`, category `timeline`) and shown
/// by the `-uiTestProbe` element on the Analysis screen.
///
/// Events: `imported` (the image reached `AppModel.importImage`), `recognized` (recognition
/// returned), `engineStarted` (the search is running), `firstArrow` (the first best move is on
/// the board), `final` (the think time elapsed).
@MainActor
@Observable
final class DebugTimeline {
    static let shared = DebugTimeline()

    private(set) var origin: String?
    private(set) var events: [(name: String, milliseconds: Int)] = []
    @ObservationIgnored private var start: ContinuousClock.Instant?
    @ObservationIgnored private let log = Logger(subsystem: "com.motomatic.chessbestmove", category: "timeline")

    /// Starts a new timeline at a user action, for example "latestScreenshotTap".
    func begin(_ name: String) {
        start = .now
        origin = name
        events = []
        log.notice("timeline begin \(name, privacy: .public)")
    }

    /// Records `name` once per timeline.
    func mark(_ name: String) {
        guard let start, !events.contains(where: { $0.name == name }) else { return }
        let elapsed = ContinuousClock.now - start
        let milliseconds = Int((elapsed / .milliseconds(1)).rounded())
        events.append((name, milliseconds))
        log.notice("timeline \(self.origin ?? "", privacy: .public) \(name, privacy: .public) \(milliseconds, privacy: .public) ms")
    }

    /// "latestScreenshotTap:imported=40,recognized=310,..."
    var summary: String {
        guard let origin else { return "" }
        return origin + ":" + events.map { "\($0.name)=\($0.milliseconds)" }.joined(separator: ",")
    }
}
#endif
