import Foundation

/// Photo library access, as Home needs it.
enum CapturePhotoAccess: Sendable, Hashable {
    /// Never asked. Home must not ask at launch, only when "Use latest screenshot" is tapped.
    case notDetermined
    case authorized
    /// Limited access: the newest screenshot is usually not visible.
    case limited
    case denied
    /// Parental controls or device management; the user cannot change it.
    case restricted
}

/// The newest screenshot in the photo library.
struct CaptureScreenshotAsset: Sendable, Hashable {
    /// PhotoKit local identifier.
    let localIdentifier: String
    let creationDate: Date?
}

/// Remembers which photo library screenshots were already imported, so Home's promotion
/// ("Analyze new screenshot") and the new-screenshot row on the Analysis result and Check
/// position (design.md 9.4) never offer the same screenshot twice. Stored in `UserDefaults`;
/// only the most recent `limit` identifiers are kept.
struct CaptureAnalyzedScreenshots {
    static let defaultsKey = "capture.analyzedScreenshotIdentifiers"
    static let limit = 50

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var identifiers: [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func contains(_ identifier: String) -> Bool {
        identifiers.contains(identifier)
    }

    func markAnalyzed(_ identifier: String) {
        var list = identifiers.filter { $0 != identifier }
        list.append(identifier)
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
        defaults.set(list, forKey: Self.defaultsKey)
    }
}

/// When Home promotes the newest screenshot, and how it words the screenshot's age
/// (design.md 9.1, "Recommendation for the App owner"). The new-screenshot row of the Analysis
/// result and Check position offers only screenshots this rule would promote, and words their
/// age the same way (`CaptureNewScreenshotPolicy`, design.md 9.4).
enum CaptureRecentScreenshotPolicy {
    /// A screenshot younger than this is "recent".
    static let window: TimeInterval = 120
    /// Creation dates slightly in the future (clock adjustments) still count as just taken.
    static let futureTolerance: TimeInterval = 5

    /// The screenshot was taken within `window` before `now`.
    static func isRecent(_ creationDate: Date?, now: Date) -> Bool {
        guard let creationDate else { return false }
        let age = now.timeIntervalSince(creationDate)
        return age >= -futureTolerance && age < window
    }

    /// Promote the primary button to "Analyze new screenshot": full photo access was
    /// already granted (Home never prompts for it on its own), the newest screenshot is
    /// recent, and it was not imported before.
    static func shouldPromote(
        _ asset: CaptureScreenshotAsset?,
        access: CapturePhotoAccess,
        analyzed: CaptureAnalyzedScreenshots,
        now: Date
    ) -> Bool {
        guard access == .authorized, let asset, isRecent(asset.creationDate, now: now) else { return false }
        return !analyzed.contains(asset.localIdentifier)
    }

    /// "12 s ago", "5 min ago", "3 h ago", "2 days ago", or the date ("Sep 2") after a week.
    /// A no-break space keeps each number with its unit.
    static func ageText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let space = "\u{00A0}"
        switch seconds {
        case ..<60: return "\(seconds)\(space)s ago"
        case ..<3600: return "\(seconds / 60)\(space)min ago"
        case ..<86_400: return "\(seconds / 3600)\(space)h ago"
        case ..<(7 * 86_400):
            let days = seconds / 86_400
            return days == 1 ? "1\(space)day ago" : "\(days)\(space)days ago"
        default:
            return "on " + date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    /// The spoken form of `ageText` for VoiceOver ("12 seconds ago").
    static func spokenAgeText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        func unit(_ value: Int, _ singular: String) -> String {
            value == 1 ? "1 \(singular) ago" : "\(value) \(singular)s ago"
        }
        switch seconds {
        case ..<60: return unit(seconds, "second")
        case ..<3600: return unit(seconds / 60, "minute")
        case ..<86_400: return unit(seconds / 3600, "hour")
        case ..<(7 * 86_400): return unit(seconds / 86_400, "day")
        default: return "on " + date.formatted(.dateTime.month(.wide).day())
        }
    }
}

/// What Home's primary "Use latest screenshot" button shows.
enum CaptureLatestScreenshotButton: Hashable {
    /// Never asked: "Allow access to your screenshots".
    case requestAccess
    /// Full access and a screenshot: "Use latest screenshot, Taken 12 s ago", or promoted to
    /// "Analyze new screenshot, Taken 8 s ago".
    case latest(CaptureScreenshotAsset, promoted: Bool)
    /// Full access but no screenshot in the library.
    case noScreenshots
    /// Limited access: pick the screenshot instead.
    case limited
    /// Denied: open Settings.
    case denied
    /// Restricted: nothing the user can do here.
    case restricted

    static func make(
        access: CapturePhotoAccess,
        latest: CaptureScreenshotAsset?,
        analyzed: CaptureAnalyzedScreenshots,
        now: Date
    ) -> CaptureLatestScreenshotButton {
        switch access {
        case .notDetermined: return .requestAccess
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized:
            guard let latest else { return .noScreenshots }
            let promoted = CaptureRecentScreenshotPolicy.shouldPromote(latest, access: access, analyzed: analyzed, now: now)
            return .latest(latest, promoted: promoted)
        }
    }

    /// The button title.
    func title(now: Date) -> String {
        switch self {
        case .requestAccess: return "Allow access to your screenshots"
        case .latest(_, let promoted):
            // The promotion names what is new, not how fast it was: the app is for studying
            // positions, not for help during a game (AppCopy).
            return promoted ? "Analyze new screenshot" : "Use latest screenshot"
        case .noScreenshots: return "Use latest screenshot"
        case .limited: return "Choose your screenshot"
        case .denied: return "Allow access in Settings"
        case .restricted: return "Use latest screenshot"
        }
    }

    /// The second line inside the button, if any.
    func detail(now: Date) -> String? {
        switch self {
        case .requestAccess: return "Only used to find your newest screenshot."
        case .latest(let asset, _):
            guard let date = asset.creationDate else { return nil }
            return "Taken \(CaptureRecentScreenshotPolicy.ageText(since: date, now: now))"
        case .noScreenshots: return "No screenshots yet"
        case .limited, .denied, .restricted: return nil
        }
    }

    /// The caption under the button, if any. `deviceName` is "iPhone", "iPad" or "Mac"
    /// (`AppDevice.name`).
    func caption(deviceName: String) -> String? {
        switch self {
        case .limited: "Limited access can't see new screenshots. Pick it yourself, or use Photos or Paste."
        case .denied: "Photo access is off. Use Photos or Paste instead."
        case .restricted: "Photo access is restricted on this \(deviceName). Use Photos or Paste instead."
        case .requestAccess, .latest, .noScreenshots: nil
        }
    }

    var isEnabled: Bool {
        switch self {
        case .noScreenshots, .restricted: false
        default: true
        }
    }
}

/// Loads a photo library screenshot for import: its data (from iCloud if needed), decoded off
/// the main actor with the orientation and the 4096 px cap of every import. Home's first row and
/// the new-screenshot row (design.md 9.4) both use it, so the two imports cannot drift apart.
/// The caller marks the screenshot analyzed.
enum CaptureScreenshotImport {
    static func importedImage(for asset: CaptureScreenshotAsset, library: CapturePhotoLibraryClient) async throws -> ImportedImage {
        let (data, orientation) = try await library.imageData(asset.localIdentifier)
        let image = try CaptureImageDecoder.decode(data: data, orientation: orientation)
        return ImportedImage(
            image: image,
            source: .latestScreenshot,
            photoAssetIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate
        )
    }
}
