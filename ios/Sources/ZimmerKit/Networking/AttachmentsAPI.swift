import Foundation

/// A photo or a file sent with a message, as the web composer's *Attach image* and
/// *Attach file* send them. The server decides which it is from `mediaType`: a PNG, JPEG,
/// GIF or WebP reaches the agent as an image, anything else as a file it is told to read.
public struct MessageAttachment: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var filename: String
    public var mediaType: String
    public var data: Data

    public init(id: UUID = UUID(), filename: String, mediaType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.data = data
    }

    /// The image types the server keeps as images (`ImageStorageService::SUPPORTED_TYPES`).
    public static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    /// The most one message carries, as the server counts.
    public static let limit = 20
    /// The largest image the server stores (`ImageStorageService::MAX_IMAGE_SIZE`).
    public static let maxImageBytes = 10 * 1024 * 1024

    public var isImage: Bool { Self.imageTypes.contains(mediaType) }

    /// Why this one would be refused before it is sent, or nil.
    public var problem: String? {
        if isImage, data.count > Self.maxImageBytes { return "\(filename) is over the 10 MB image limit." }
        if data.isEmpty { return "\(filename) is empty." }
        return nil
    }

    var json: [String: Any] {
        ["filename": filename, "media_type": mediaType, "data": data.base64EncodedString()]
    }
}

/// A follow-up with attachments. They go with the message however it is delivered: now,
/// queued behind a turn in flight, or sent now (`now`), ending that turn.
public protocol AttachmentsAPI: Sendable {
    func followUp(_ id: Int, prompt: String, attachments: [MessageAttachment], now: Bool) async throws -> FollowUpResult
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `AttachmentsAPI`.
extension ZimmerHTTPClient {
    public func followUp(_ id: Int, prompt: String, attachments: [MessageAttachment], now: Bool) async throws -> FollowUpResult {
        let segment = ZimmerPathComponent(String(id))
        var json: [String: Any] = ["prompt": prompt, "attachments": attachments.map(\.json)]
        if now { json["force_immediate"] = true }
        let response: FollowUpResponse = try await post("/api/v1/sessions/\(segment)/follow_up", json: json)
        let queued = !now && response.enqueued_message != nil
        return FollowUpResult(queued: queued, message: response.message ?? (now ? "Sent now" : (queued ? "Queued" : "Sent")))
    }
}
