import Foundation

/// Versioned, bounded local messages. No images or results are persisted by this protocol.
enum WatchWire {
    static let version = 1
    static let maximumRequestBytes = 1_024
    static let maximumReplyBytes = 64_000
    static let maximumThumbnailBytes = 40_000
    static let screenshotMaximumAge: TimeInterval = 30

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
              (reply.thumbnail?.count ?? 0) <= maximumThumbnailBytes else { return nil }
        return reply
    }
}

struct WatchAnalysisRequest: Codable, Sendable {
    var version = WatchWire.version
    var id = UUID()
    var createdAt = Date.now
}

struct WatchAnalysisReply: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case result, checkmate, stalemate
        case setupRequired, noFreshScreenshot, needsCorrection, noBoard, noCredits
        case busy, unavailable, timedOut, invalidRequest
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
}
