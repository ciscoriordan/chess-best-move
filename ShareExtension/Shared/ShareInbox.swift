import Foundation

/// The names the app and its share extension have to agree on, in one place. This file is
/// compiled into both targets (see `project.yml`), so neither can drift from the other.
///
/// The extension writes the shared image into the app group container and opens the app at a
/// URL that names it; the app reads the file, deletes it and imports the image. Nothing else
/// crosses between the two processes.
enum ShareInboxNames {
    /// The app group both bundle ids belong to. It has to match the
    /// `com.apple.security.application-groups` entitlement of both targets exactly.
    static let appGroupIdentifier = "group.com.motomatic.chessbestmove"
    /// The app's custom URL scheme (`App/Info.plist`, `CFBundleURLTypes`).
    static let urlScheme = "chessbestmove"
    /// The host of the hand-over URL: `chessbestmove://shared-image?id=<uuid>`.
    static let sharedImageHost = "shared-image"
    /// The query item that carries the item's identifier.
    static let itemQueryName = "id"
    /// The directory inside the group container that holds handed-over images.
    static let directoryName = "ShareInbox"
    /// How long after it was written an image may still be imported when the app is opened
    /// without the hand-over URL, for example because opening the app from the extension
    /// failed. Long enough to cover a slow launch, short enough that an image the user has
    /// forgotten about is never analyzed behind their back.
    static let handoverWindow: TimeInterval = 120
    /// How long an item that was never imported stays on disk before the app deletes it, so
    /// the container cannot fill up.
    static let staleAge: TimeInterval = 24 * 60 * 60
    /// The file extension used when the shared item names no usable one.
    static let fallbackFileExtension = "img"
}

// MARK: - The hand-over URL

/// The grammar of `chessbestmove://shared-image?id=<uuid>`.
///
/// The identifier is always a UUID, and `itemID(from:)` checks that before the app touches
/// the file system, so a URL from anywhere else cannot name a path of its own choosing (a
/// URL is an input from outside the app: anything can open it).
enum ShareInboxURL {
    static func url(forItemID id: String) -> URL {
        var components = URLComponents()
        components.scheme = ShareInboxNames.urlScheme
        components.host = ShareInboxNames.sharedImageHost
        components.queryItems = [URLQueryItem(name: ShareInboxNames.itemQueryName, value: id)]
        // The components above are all valid, so the URL is never nil; the fallback keeps the
        // signature free of an optional the callers cannot act on.
        return components.url ?? URL(string: "\(ShareInboxNames.urlScheme)://\(ShareInboxNames.sharedImageHost)")!
    }

    /// The item identifier this URL names, or nil when the URL is not a hand-over URL or does
    /// not carry a UUID.
    static func itemID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == ShareInboxNames.urlScheme,
              components.host?.lowercased() == ShareInboxNames.sharedImageHost,
              let value = components.queryItems?.first(where: { $0.name == ShareInboxNames.itemQueryName })?.value,
              let uuid = UUID(uuidString: value)
        else { return nil }
        return uuid.uuidString
    }
}

// MARK: - The container

/// One image handed over by the share extension.
struct ShareInboxItem: Sendable, Hashable {
    /// The UUID string in the hand-over URL.
    var id: String
    var fileURL: URL
    var writtenAt: Date
}

/// The directory in the app group container that the extension writes into and the app reads
/// from. Both processes build it from the same app group identifier.
///
/// Every method works on plain files and is safe to call off the main actor. Failures are
/// thrown, never ignored: the extension has to tell the user when it cannot hand the image
/// over, rather than opening an app that will show nothing.
struct ShareInbox: Sendable, Hashable {
    enum Failure: Error, Sendable, Hashable {
        /// The app group container is not available. In practice: the app group entitlement is
        /// missing from this build, or the group was not registered for this bundle id.
        case noContainer
        /// The directory could not be created or written to.
        case cannotWrite
    }

    /// The directory holding the items.
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The inbox inside the app group container, or nil when this build cannot reach it.
    init?(appGroupIdentifier: String = ShareInboxNames.appGroupIdentifier,
          fileManager: FileManager = .default) {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        self.init(directory: container.appending(path: ShareInboxNames.directoryName, directoryHint: .isDirectory))
    }

    // MARK: Writing (the extension's side)

    /// Writes `data` as a new item and returns its identifier.
    func write(data: Data, fileExtension: String?) throws -> String {
        let id = UUID().uuidString
        let destination = fileURL(id: id, fileExtension: Self.sanitized(fileExtension))
        let staging = stagingURL(for: destination)
        try prepareDirectory()
        do {
            try data.write(to: staging, options: .atomic)
            try replaceItem(at: destination, with: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Failure.cannotWrite
        }
        return id
    }

    /// Copies the file at `url` in as a new item and returns its identifier. The file is
    /// copied rather than read into memory, so an image of any size costs the extension no
    /// more than disk: the app applies its own 4096 px decode cap when it reads it back.
    func write(copyingFileAt url: URL, fileExtension: String?) throws -> String {
        let id = UUID().uuidString
        let extensionToUse = Self.sanitized(fileExtension) ?? Self.sanitized(url.pathExtension)
        let destination = fileURL(id: id, fileExtension: extensionToUse)
        let staging = stagingURL(for: destination)
        try prepareDirectory()
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.copyItem(at: url, to: staging)
            try replaceItem(at: destination, with: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Failure.cannotWrite
        }
        return id
    }

    // MARK: Reading (the app's side)

    /// The file of the item with this identifier, or nil when there is none. Only a UUID names
    /// an item, so nothing outside `directory` can be reached from a URL.
    func fileURL(forItemID id: String) -> URL? {
        guard let id = UUID(uuidString: id)?.uuidString else { return nil }
        return contents().first { $0.deletingPathExtension().lastPathComponent == id }
    }

    /// Deletes the item with this identifier, whatever its file extension. Deleting an item
    /// that is not there is not an error.
    func remove(itemID id: String) {
        guard let url = fileURL(forItemID: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The items written within `window` of `now`, newest first.
    func items(writtenWithin window: TimeInterval, now: Date = Date()) -> [ShareInboxItem] {
        items(now: now)
            .filter { now.timeIntervalSince($0.writtenAt) <= window }
            .sorted { $0.writtenAt > $1.writtenAt }
    }

    /// Deletes every item older than `age`, so an image the app never imported cannot stay in
    /// the container forever.
    func removeItems(olderThan age: TimeInterval, now: Date = Date()) {
        for item in items(now: now) where now.timeIntervalSince(item.writtenAt) > age {
            try? FileManager.default.removeItem(at: item.fileURL)
        }
    }

    /// Every item in the inbox, in no particular order.
    func items(now: Date = Date()) -> [ShareInboxItem] {
        contents().compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)?.uuidString else { return nil }
            let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            return ShareInboxItem(id: id, fileURL: url, writtenAt: written)
        }
    }

    // MARK: Implementation

    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure.cannotWrite
        }
    }

    private func fileURL(id: String, fileExtension: String?) -> URL {
        directory.appending(path: "\(id).\(fileExtension ?? ShareInboxNames.fallbackFileExtension)", directoryHint: .notDirectory)
    }

    /// The name a file is written under before it is moved into place, so the app can never
    /// read a half-written image. It starts with a dot, and `contents()` skips those.
    private func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).part", directoryHint: .notDirectory)
    }

    private func replaceItem(at destination: URL, with staging: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
        // When the item came from a file, the copy keeps that file's modification date: a photo
        // shared from the library carries the date the picture was taken. The app reads this
        // date to decide how recently an image was handed over, so it is set to now. Without
        // this, sharing a photo taken more than a day ago hands over an item the app treats as
        // stale and deletes without importing (measured on an iPhone 17 Pro simulator,
        // iOS 26.5: a photo from six days earlier never reached the app).
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
    }

    private func contents() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return urls.filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// A file extension that is safe to put in a file name: letters and digits only, lowercase,
    /// at most eight characters. Nil for anything else, which falls back to `img` (the app
    /// decodes by content, not by name).
    static func sanitized(_ fileExtension: String?) -> String? {
        guard let fileExtension, !fileExtension.isEmpty, fileExtension.count <= 8,
              fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return fileExtension.lowercased()
    }
}
