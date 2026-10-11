import Foundation

/// A photo or a file sent with a message, as the web composer's *Attach image* and
/// *Attach file* send them. The server decides which it is from the bytes, as
/// `ImageStorageService` sniffs them: a PNG, JPEG, GIF or WebP reaches the agent as an
/// image, anything else as a file it is told to read. `isImage` reads them the same way.
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
    /// The most one message's attachments may add up to
    /// (`Api::V1::SessionsController::FOLLOW_UP_ATTACHMENT_BYTES`).
    public static let maxTotalBytes = 75 * 1024 * 1024

    /// Whether the server will keep this as an image: its magic bytes are a PNG, JPEG, GIF or
    /// WebP, whatever its name or `mediaType` say.
    public var isImage: Bool { Self.sniffsAsImage(data) }

    static func sniffsAsImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return false }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        return bytes.count >= 12 && bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50]
    }

    /// Why this one would be refused before it is sent, or nil.
    public var problem: String? {
        if isImage, data.count > Self.maxImageBytes { return "\(filename) is over the 10 MB image limit." }
        if data.isEmpty { return "\(filename) is empty." }
        return nil
    }

    /// Why `candidate` cannot join `attached` in one message — the server's per-message
    /// count and total — or nil. Its own `problem` is checked too.
    public static func refusal(adding candidate: MessageAttachment, to attached: [MessageAttachment]) -> String? {
        if let problem = candidate.problem { return problem }
        if attached.count >= limit { return "A message carries at most \(limit) attachments." }
        if attached.reduce(0, { $0 + $1.data.count }) + candidate.data.count > maxTotalBytes {
            return "\(candidate.filename) would take this message over its 75 MB of attachments."
        }
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
