import Foundation
import ImageIO

/// Versioned, bounded local messages. No images or results are persisted by this protocol.
enum WatchWire {
    static let version = 1
    static let maximumRequestBytes = 1_024
    static let maximumReplyBytes = 64_000
    static let maximumThumbnailBytes = 40_000

    static func request(from data: Data, now: Date = .now) -> WatchAnalysisRequest? {
        guard data.count <= maximumRequestBytes,
              let request = try? JSONDecoder().decode(WatchAnalysisRequest.self, from: data),
              request.version == version,
              (-5...30).contains(now.timeIntervalSince(request.createdAt)) else { return nil }
        return request
    }

    static func reply(from data: Data, for id: UUID) -> WatchAnalysisReply? {
        guard data.count <= maximumReplyBytes,
              let reply = try? JSONDecoder().decode(WatchAnalysisReply.self, from: data),
              reply.version == version, reply.requestID == id,
              (reply.thumbnail?.count ?? 0) <= maximumThumbnailBytes,
              reply.playback?.isValid != false else { return nil }
        return reply
    }

    static func boardPreview(from data: Data) -> WatchBoardPreview? {
        guard data.count <= maximumReplyBytes,
              let preview = try? JSONDecoder().decode(WatchBoardPreview.self, from: data),
              preview.version == version, preview.messageType == "boardPreview",
              !preview.thumbnail.isEmpty, preview.thumbnail.count <= maximumThumbnailBytes,
              let source = CGImageSourceCreateWithData(preview.thumbnail as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...240).contains(width), width == height,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return preview
    }
}

struct WatchAnalysisRequest: Codable, Sendable {
    var version = WatchWire.version
    var id = UUID()
    var createdAt = Date.now
    /// Missing in older Watch builds; only opted-in peers receive intermediate images.
    var supportsBoardPreview: Bool? = true
    /// Missing in older peers and in manual requests.
    var automaticallyTriggered: Bool?
}

struct WatchBoardPreview: Codable, Sendable {
    var version = WatchWire.version
    var messageType = "boardPreview"
    var requestID: UUID
    var screenshotDate: Date?
    var thumbnail: Data
}

struct WatchAnalysisReply: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case result, checkmate, stalemate
        case setupRequired, needsCorrection, noBoard, noCredits
        /// Preserve the version-one wire value; this now means no screenshot exists.
        case noScreenshot = "noFreshScreenshot"
        case busy, unavailable, timedOut, invalidRequest
        /// Only returned to an opted-in automatic request when the phone setting is off.
        case automaticAnalysisSkipped
    }

    var version = WatchWire.version
    var requestID: UUID
    var status: Status
    var screenshotDate: Date?
    var completedAt = Date.now
    var whiteToMove: Bool?
    var san: String?
    var moveDescription: String?
    var thumbnail: Data?
    var playback: BoardMovePlayback?
    var moveDisplayFormat: MoveDisplayFormat?
    /// Optional for compatibility with earlier phone and Watch builds.
    var stealthMode: Bool?
}
