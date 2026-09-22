import Accessibility
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import UIKit

// The new-screenshot row of the Analysis result and Check position (design.md 9.4, 9.5; owner
// decision of 2026-09-21): what it offers, when it looks, and what its Analyze does. The row
// itself and the modifier that owns this model are in `CaptureNewScreenshotRow.swift`.

/// When the app was not active, and when a screenshot of it was taken, for the new-screenshot
/// row (design.md 9.4). A pure value; `CaptureAppActivity` feeds it.
///
/// A screenshot the row may offer was taken while the app was away. That one condition keeps
/// the row from offering what is already on screen: a screenshot of this result, taken to share
/// it, is taken while the app is active, and the screenshot the board on screen came from was
/// taken before the screen appeared.
struct CaptureForegroundLog: Sendable, Hashable {
    /// How many closed absences and screenshots of this app are kept. A screenshot is offered
    /// for 2 minutes at most, so older entries never decide anything.
    static let capacity = 20

    /// Closed absences, oldest first.
    private(set) var awayIntervals: [DateInterval] = []
    /// The app is away now, since this moment.
    private(set) var awaySince: Date?
    /// When the system reported a screenshot of this app (`userDidTakeScreenshotNotification`).
    private(set) var screenshotsOfThisApp: [Date] = []

    init(isActive: Bool, now: Date) {
        awaySince = isActive ? nil : now
    }

    /// The app stopped being active. A second departure before a return (inactive, then the
    /// background) keeps the first.
    mutating func leftActive(at date: Date) {
        if awaySince == nil { awaySince = date }
    }

    /// The app is active again: closes the open absence, if any.
    mutating func becameActive(at date: Date) {
        guard let start = awaySince else { return }
        awaySince = nil
        awayIntervals.append(DateInterval(start: start, end: max(start, date)))
        if awayIntervals.count > Self.capacity { awayIntervals.removeFirst(awayIntervals.count - Self.capacity) }
    }

    mutating func screenshotTaken(at date: Date) {
        screenshotsOfThisApp.append(date)
        if screenshotsOfThisApp.count > Self.capacity {
            screenshotsOfThisApp.removeFirst(screenshotsOfThisApp.count - Self.capacity)
        }
    }

    /// `date` is after `since`, and inside an absence (closed, or still open) widened by
    /// `tolerance` at both edges.
    func wasAway(at date: Date, after since: Date, tolerance: TimeInterval) -> Bool {
        guard date > since else { return false }
        if let awaySince, date >= awaySince.addingTimeInterval(-tolerance) { return true }
        return awayIntervals.contains { interval in
            date >= interval.start.addingTimeInterval(-tolerance) && date <= interval.end.addingTimeInterval(tolerance)
        }
    }

    /// Whether the system reported a screenshot of this app within `window` of `date`.
    func isScreenshotOfThisApp(_ date: Date, within window: TimeInterval) -> Bool {
        screenshotsOfThisApp.contains { abs($0.timeIntervalSince(date)) <= window }
    }
}

/// The app-wide record of when the app was away (design.md 9.4), from UIApplication's
/// notifications, which are delivered on the main queue.
///
/// It is not tied to any view: a flow screen under the editor's full-screen cover is taken off
/// screen, so an observer in that screen would miss an absence that happened while the editor
/// was up. The app has one scene (`UIApplicationSupportsMultipleScenes` is false), so the app's
/// activity is the scene's.
@MainActor
final class CaptureAppActivity {
    /// Created the first time a flow screen asks for it. Absences before then never matter:
    /// every offer needs a date after its screen appeared.
    static let shared = CaptureAppActivity(
        observesApplication: true,
        isActive: UIApplication.shared.applicationState == .active
    )

    private(set) var log: CaptureForegroundLog
    private let now: () -> Date

    /// `observesApplication` false is for tests, which call the three methods themselves. A test
    /// of the notifications passes a center of its own, so its posts never reach the host app.
    init(
        observesApplication: Bool,
        isActive: Bool,
        center: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
        log = CaptureForegroundLog(isActive: isActive, now: now())
        guard observesApplication else { return }
        // The notification center keeps each registration for the life of the process, which is
        // the life of `shared`.
        _ = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.leftActive() }
        }
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
        _ = center.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenshotTaken() }
        }
    }

    func leftActive(at date: Date? = nil) {
        log.leftActive(at: date ?? now())
    }

    func becameActive(at date: Date? = nil) {
        log.becameActive(at: date ?? now())
    }

    func screenshotTaken(at date: Date? = nil) {
        log.screenshotTaken(at: date ?? now())
    }
}

/// Which screenshot the new-screenshot row offers (design.md 9.4).
enum CaptureNewScreenshotPolicy {
    /// The moment the app is switching away or back. Both clocks are the device's.
    static let awayTolerance: TimeInterval = 1
    /// A screenshot this close to one the system reported of this app is that screenshot: the
    /// Screenshot control in Control Center makes the app inactive before it captures it.
    static let ownScreenshotWindow: TimeInterval = 3
    /// An offer set this soon after the user comes back scrolls into view at accessibility
    /// sizes, whichever check set it: the return and the photo library change that built up
    /// while the app was away reach the app in either order.
    static let revealWindow: TimeInterval = 5
    /// Enough to skip a few screenshots of the app itself; as cheap to fetch as one.
    static let candidateLimit = 5

    /// The newest of `candidates` (newest first) that Home would promote, that was taken while
    /// the app was away after `since`, and that is not a screenshot of this app.
    static func offer(
        from candidates: [CaptureScreenshotAsset],
        access: CapturePhotoAccess,
        analyzed: CaptureAnalyzedScreenshots,
        activity: CaptureForegroundLog,
        since: Date,
        now: Date
    ) -> CaptureScreenshotAsset? {
        candidates.first { asset in
            guard CaptureRecentScreenshotPolicy.shouldPromote(asset, access: access, analyzed: analyzed, now: now),
                  let date = asset.creationDate
            else { return false }
            return activity.wasAway(at: date, after: since, tolerance: awayTolerance)
                && !activity.isScreenshotOfThisApp(date, within: ownScreenshotWindow)
        }
    }
}

/// What made the model look again.
enum CaptureNewScreenshotRefreshTrigger: Sendable, Hashable {
    /// The screen appeared, or appeared again (after the editor's cover).
    case appeared
    /// The app came back to the foreground.
    case returned
    /// The photo library changed, which the user on this screen may not have caused.
    case libraryChanged
}

/// The words of the new-screenshot row (design.md 6 and 9.4).
enum CaptureNewScreenshotCopy {
    static let title = "New screenshot"
    static let button = "Analyze"
    /// Home's promoted title, on purpose: one screenshot is spoken the same way on every screen.
    static let accessibilityLabel = "Analyze new screenshot"
    static let hint = "Replaces the board on this screen."
    static let importing = "Importing"
    /// Home's own message names a Photos row these screens do not have.
    static let importFailed = "Couldn't open this screenshot. Try again, or use Choose from Photos on the start screen."
    /// The widest age line the row is laid out for, so the button does not move as the age counts.
    static let widestAge = "Taken 59\u{00A0}min ago"

    /// "Taken 8 s ago".
    static func age(since date: Date, now: Date) -> String {
        "Taken " + CaptureRecentScreenshotPolicy.ageText(since: date, now: now)
    }

    /// "Taken 8 seconds ago".
    static func spokenAge(since date: Date, now: Date) -> String {
        "Taken " + CaptureRecentScreenshotPolicy.spokenAgeText(since: date, now: now)
    }

    /// "New screenshot, taken 8 seconds ago. Analyze new screenshot is at the bottom of the
    /// screen.", or "at the top" where the row is at the top of the scrolling content.
    static func announcement(since date: Date, now: Date, placement: NewScreenshotRow.Placement) -> String {
        let spoken = CaptureRecentScreenshotPolicy.spokenAgeText(since: date, now: now)
        let edge = placement == .pinnedBar ? "bottom" : "top"
        return "New screenshot, taken \(spoken). \(accessibilityLabel) is at the \(edge) of the screen."
    }

    /// What Voice Control answers to: the spoken name, the title and the word on the button.
    static var inputLabels: [String] { [accessibilityLabel, title, button] }
}

/// What the tap was made on. The import goes ahead only if none of it changed while the
/// screenshot loaded: `AppModel.importImage` replaces the route, closes the editor and takes
/// down every sheet, which would throw away the user's edits in an editor opened meanwhile, a
/// purchase in progress, or a newer import (Share, the Shortcut, New).
///
/// The board waiting for a purchase or an Ask to Buy approval is part of it: a purchase that
/// lands while the screenshot loads runs that board and spends a credit on it, and replacing it
/// at once would throw away what was just paid for.
struct CaptureNewScreenshotScreenState: Equatable {
    let path: [Route]
    let editorID: UUID?
    let sheet: SheetRoute?
    let pendingSessionID: UUID?

    @MainActor
    init(_ app: AppModel) {
        path = app.path
        editorID = app.editor?.id
        sheet = app.sheet
        pendingSessionID = app.pendingAnalysis?.id
    }
}

/// One screen's new-screenshot offer (design.md 9.4): which screenshot is offered, its
/// thumbnail, the import its Analyze runs, and whether the screen should scroll to it.
///
/// Owned by the `offersNewScreenshot()` modifier on the screen's root, one per route. It never
/// asks for photo access, registers with PhotoKit only with full access, and unregisters only
/// its own observer. Nothing is imported without a tap.
@MainActor
@Observable
final class CaptureNewScreenshotOfferModel {
    struct Offer: Equatable {
        let asset: CaptureScreenshotAsset
        /// Belongs to `asset`, so the row can never show one screenshot's image beside
        /// another's age.
        let thumbnail: CGImage?

        static func == (lhs: Offer, rhs: Offer) -> Bool { lhs.asset == rhs.asset }
    }

    private(set) var offer: Offer?
    /// From the tap until the import fails or is dropped. After a successful import it stays
    /// true: this screen is on its way out, and its row must not offer the same tap again while
    /// it slides away.
    private(set) var isImporting = false
    /// Shown on a line of its own under the row, in `danger`, until the next offer or tap.
    private(set) var importError: String?
    /// The screenshot the screen should scroll to (the row at the top of the scrolling content).
    private(set) var revealTarget: String?
    /// At accessibility sizes: whether the row at the top of the scrolling content may be drawn
    /// now. An offer that arrives while the reader is scrolled away from the top, outside the
    /// window after a return, waits, so the text being read does not move down by its height.
    private(set) var isShownAtTop = true

    @ObservationIgnored let observer = CapturePhotoLibraryObserver()
    @ObservationIgnored private let library: CapturePhotoLibraryClient
    @ObservationIgnored private let analyzed: CaptureAnalyzedScreenshots
    @ObservationIgnored private let activity: CaptureAppActivity
    @ObservationIgnored private let now: () -> Date
    /// When this screen first appeared: nothing taken before it is offered.
    @ObservationIgnored private(set) var since: Date?
    @ObservationIgnored private var revealUntil: Date?
    @ObservationIgnored private var isAtTop = true
    @ObservationIgnored private var generation = 0
    /// A check the user caused (the return, the screen appearing again) started and no check has
    /// finished since. A photo library change that overtakes it decides in its place, age
    /// included.
    @ObservationIgnored private var userCheckPending = false
    @ObservationIgnored private var revealDueFor: String?
    @ObservationIgnored private var announced: Set<String> = []
    /// The last sentence posted, so announcements can be checked without a screen reader
    /// (APP_CONTRACT.md section 9).
    @ObservationIgnored private(set) var lastAnnouncement: String?

    /// Cheap: no PhotoKit call until the first check.
    init(
        library: CapturePhotoLibraryClient,
        analyzed: CaptureAnalyzedScreenshots,
        activity: CaptureAppActivity,
        now: @escaping () -> Date = Date.init
    ) {
        self.library = library
        self.analyzed = analyzed
        self.activity = activity
        self.now = now
    }

    deinit {
        // This screen's observer only; Home's and any other screen's are their own.
        observer.unregister()
    }

    /// The model a screen uses: PhotoKit, or with `-captureFakeNewScreenshot YES` in DEBUG the
    /// stand-in library (`CaptureNewScreenshotDebug`).
    static func forScreen() -> CaptureNewScreenshotOfferModel {
        #if DEBUG
        if CaptureNewScreenshotDebug.isRequested {
            return CaptureNewScreenshotOfferModel(
                library: CaptureNewScreenshotDebug.library,
                analyzed: CaptureAnalyzedScreenshots(),
                activity: .shared
            )
        }
        #endif
        return CaptureNewScreenshotOfferModel(library: .live, analyzed: CaptureAnalyzedScreenshots(), activity: .shared)
    }

    // MARK: Checks

    /// The screen appeared. Only the first call counts: a screen that appears again after the
    /// editor is still the same screen.
    func screenAppeared() {
        if since == nil { since = now() }
    }

    /// The user came back to the app: an offer set within `revealWindow` scrolls into view, when
    /// the reader is scrolled away from the top of the screen.
    func returned() {
        revealUntil = now().addingTimeInterval(CaptureNewScreenshotPolicy.revealWindow)
    }

    /// Whether the reader is at the top of the screen's scroll view.
    func scrolledToTop(_ top: Bool) {
        isAtTop = top
        if top, !isShownAtTop { isShownAtTop = true }
    }

    /// The first check, then one per photo library change, until the task is cancelled (the
    /// screen went away). A new stream per appearance, as on Home: the stream is asked for first,
    /// so a change during the first check is kept for the loop.
    func watchLibrary() async {
        let changes = observer.changes()
        await refresh(.appeared)
        for await _ in changes {
            await refresh(.libraryChanged)
        }
    }

    /// Looks for a screenshot to offer. A check overtaken by a later one drops its result, and
    /// the later one decides in its place.
    ///
    /// Once shown, the row stays until a check finds a newer screenshot to offer, or finds the
    /// one it offers deleted, analyzed or out of reach (access withdrawn). Its age decides only at
    /// the checks the user causes, coming back to the app or to the screen: a library change
    /// nobody on this screen made never removes the row for its age, because a control that
    /// removes itself on an event the reader did not cause is a time limit (WCAG 2.2.1). A
    /// library change that overtakes a check the user caused decides on the age for it: the
    /// change a return brings with it can reach the app while the return's own check is waiting
    /// for PhotoKit, and the row must not outlive a return it failed.
    func refresh(_ trigger: CaptureNewScreenshotRefreshTrigger) async {
        guard !isImporting, let since else { return }
        generation += 1
        let current = generation
        if trigger != .libraryChanged { userCheckPending = true }
        let access = library.currentAccess()
        guard access == .authorized else {
            userCheckPending = false
            withdraw()
            return
        }
        library.startObserving(observer)
        let candidates = await library.newestScreenshots(CaptureNewScreenshotPolicy.candidateLimit)
        guard current == generation, !isImporting else { return }
        let judgesAge = userCheckPending
        userCheckPending = false
        let found = CaptureNewScreenshotPolicy.offer(
            from: candidates,
            access: access,
            analyzed: analyzed,
            activity: activity.log,
            since: since,
            now: now()
        )
        guard let asset = found else {
            if !judgesAge, let shown = offer, !analyzed.contains(shown.asset.localIdentifier) {
                let exists = await library.assetExists(shown.asset.localIdentifier)
                guard current == generation, !isImporting else { return }
                if exists { return }
            }
            withdraw()
            return
        }
        if asset == offer?.asset {
            // The same screenshot: keep its thumbnail, error and announcement. One that was
            // waiting for the reader to scroll back to the top shows now, on the user's return.
            if isRevealing, !isShownAtTop {
                revealDueFor = asset.localIdentifier
                isShownAtTop = true
            }
            return
        }
        let thumbnail = await library.thumbnail(asset.localIdentifier, CaptureHomeModel.thumbnailPixelSide)
        guard current == generation, !isImporting else { return }
        let revealing = isRevealing
        // A row already drawn at the top of the content stays there for the screenshot that
        // replaces it: taking it out would move the text being read up by the row's height.
        let wasShownAtTop = offer != nil && isShownAtTop
        offer = Offer(asset: asset, thumbnail: thumbnail)
        importError = nil
        // A reader already at the top sees the row where it is drawn, under the credits
        // indicator; scrolling to it would only push that indicator under the navigation bar.
        revealDueFor = revealing && !isAtTop ? asset.localIdentifier : nil
        isShownAtTop = revealing || isAtTop || wasShownAtTop
    }

    /// Within `revealWindow` of the user's return to the app. The return is read from the
    /// app-wide record as well as from `returned()`, because a screen under the editor's cover
    /// may not hear its scene become active.
    private var isRevealing: Bool {
        let appReturn = activity.log.awayIntervals.last?.end.addingTimeInterval(CaptureNewScreenshotPolicy.revealWindow)
        guard let until = [revealUntil, appReturn].compactMap({ $0 }).max() else { return false }
        return now() <= until
    }

    private func withdraw() {
        if offer != nil { offer = nil }
        if importError != nil { importError = nil }
        revealDueFor = nil
    }

    // MARK: The row

    /// The row for `identifier` was drawn at `placement`. At the top of the scrolling content it
    /// is scrolled to, if it arrived on the user's return.
    func rowShown(_ identifier: String, placement: NewScreenshotRow.Placement) {
        guard revealDueFor == identifier else { return }
        revealDueFor = nil
        if placement == .scrollingContent { revealTarget = identifier }
    }

    func revealHandled() {
        revealTarget = nil
    }

    /// Announces the row once per screenshot, without moving focus: it can appear on any photo
    /// library change, and moving focus each time would pull a reader out of the readout
    /// (design.md 12). The sentence waits until VoiceOver finishes what it is saying, such as
    /// the element it reads by itself when the app comes back, instead of cutting it off.
    func announceIfDue(_ identifier: String, placement: NewScreenshotRow.Placement) {
        guard let offer, offer.asset.localIdentifier == identifier, !announced.contains(identifier),
              let date = offer.asset.creationDate
        else { return }
        announced.insert(identifier)
        announce(CaptureNewScreenshotCopy.announcement(since: date, now: now(), placement: placement), waits: true)
    }

    /// `waits`: spoken at low priority, after whatever VoiceOver is saying. Without it the
    /// sentence is spoken at once, as the answer to the user's own tap is.
    private func announce(_ text: String, waits: Bool) {
        lastAnnouncement = text
        var sentence = AttributedString(text)
        if waits { sentence.accessibilitySpeechAnnouncementPriority = .low }
        AccessibilityNotification.Announcement(sentence).post()
    }

    // MARK: Analyze

    /// The row's Analyze, at the tap and before anything is awaited: blocks another tap and
    /// records what the tap was made on, so a route change queued behind the tap is not taken
    /// for the screen the user tapped. Nil when there is nothing to import or an import runs.
    func beginAnalyze(app: AppModel) -> CaptureNewScreenshotScreenState? {
        guard offer != nil, !isImporting else { return nil }
        isImporting = true
        importError = nil
        // A check the user caused that is still waiting for PhotoKit is dropped once it sees the
        // import; its claim to judge the age must not pass to a later library change.
        userCheckPending = false
        return CaptureNewScreenshotScreenState(app)
    }

    /// Imports the offered screenshot exactly as Home's first row does (marked analyzed first,
    /// then `AppModel.importImage`), which replaces this screen. The tap calls nothing in the
    /// credits service; the new board is authorized like any other.
    func analyzeOffer(app: AppModel, tappedOn screen: CaptureNewScreenshotScreenState) async {
        guard let offer else {
            isImporting = false
            return
        }
        do {
            let image = try await CaptureScreenshotImport.importedImage(for: offer.asset, library: library)
            // The user opened the editor or a sheet, a purchase ran the board waiting for it, or
            // something else replaced the screen, while the screenshot loaded: that is theirs to
            // keep, and the row stays.
            guard CaptureNewScreenshotScreenState(app) == screen else {
                isImporting = false
                return
            }
            analyzed.markAnalyzed(offer.asset.localIdentifier)
            // `isImporting` stays true: this screen is on its way out, and its row stays
            // disabled while it goes.
            app.importImage(image)
        } catch {
            isImporting = false
            importError = CaptureNewScreenshotCopy.importFailed
            announce(CaptureNewScreenshotCopy.importFailed, waits: false)
        }
    }

    /// `beginAnalyze`, then the import, as one tap makes them.
    func analyzeOffer(app: AppModel) async {
        guard let screen = beginAnalyze(app: app) else { return }
        await analyzeOffer(app: app, tappedOn: screen)
    }
}
