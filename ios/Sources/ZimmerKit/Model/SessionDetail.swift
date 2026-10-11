import Foundation

/// Zimmer's cached "where things stand" blurb for a session (`status_summary` on
/// `GET /api/v1/sessions/:id`). Written when a session comes to rest; may be stale.
public struct StatusSummary: Hashable, Sendable, Codable {
    public var summary: String?
    public var generatedAt: Date?
    public var generating: Bool?
    /// Why the last generation failed, when it did.
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case summary, generating, error
        case generatedAt = "generated_at"
    }

    public init(summary: String?, generatedAt: Date? = nil, generating: Bool? = nil, error: String? = nil) {
        self.summary = summary
        self.generatedAt = generatedAt
        self.generating = generating
        self.error = error
    }
}

/// One session, as the detail screen shows it.
public struct SessionDetail: Hashable, Sendable {
    public var session: SessionSummary
    public var statusSummary: StatusSummary?

    public init(session: SessionSummary, statusSummary: StatusSummary? = nil) {
        self.session = session
        self.statusSummary = statusSummary
    }

    /// Follow-ups are accepted for these; Zimmer queues one sent mid-turn.
    public var acceptsFollowUp: Bool {
        switch session.status {
        case .needsInput, .running, .waiting: return true
        default: return false
        }
    }

}

struct SessionShowResponse: Decodable {
    let session: SessionSummary
    let statusSummary: StatusSummary?

    enum CodingKeys: String, CodingKey {
        case session
        case statusSummary = "status_summary"
    }
}

/// One message of a session's conversation (`GET /api/v1/sessions/:id/conversation`).
public struct ConversationMessage: Hashable, Sendable, Codable, Identifiable {
    public enum Role: String, Sendable, Codable {
        case user, assistant
    }

    /// Position in the conversation, which is stable for a given transcript.
    public var id: Int
    public var role: Role
    public var content: String
    public var timestamp: Date?
    public var hasToolUse: Bool
    public var hasToolResult: Bool

    public init(id: Int, role: Role, content: String, timestamp: Date? = nil, hasToolUse: Bool = false, hasToolResult: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.hasToolUse = hasToolUse
        self.hasToolResult = hasToolResult
    }

    /// Tool calls and their output: shown folded, because on a phone they bury the words.
    public var isToolTraffic: Bool { hasToolUse || hasToolResult }
}

/// The conversation, newest last, and whether older messages were left out.
public struct Conversation: Hashable, Sendable {
    public var messages: [ConversationMessage]
    public var total: Int
    public var truncated: Bool

    public init(messages: [ConversationMessage], total: Int? = nil, truncated: Bool = false) {
        self.messages = messages
        self.total = total ?? messages.count
        self.truncated = truncated
    }

    /// The last thing the agent said: what a person deciding a follow-up wants first.
    public var lastAgentMessage: ConversationMessage? {
        messages.last { $0.role == .assistant && !$0.isToolTraffic && !$0.content.isEmpty }
    }
}

struct ConversationResponse: Decodable {
    struct Wire: Decodable {
        let role: String
        let content: String?
        let timestamp: String?
        let has_tool_use: Bool?
        let has_tool_result: Bool?
    }

    let messages: [Wire]
    let total: Int?
    let truncated: Bool?

    var conversation: Conversation {
        let offset = (total ?? messages.count) - messages.count
        let decoded = messages.enumerated().compactMap { index, wire -> ConversationMessage? in
            guard let role = ConversationMessage.Role(rawValue: wire.role) else { return nil }
            return ConversationMessage(
                id: offset + index,
                role: role,
                content: wire.content ?? "",
                timestamp: wire.timestamp.flatMap(ZimmerJSON.parseDate),
                hasToolUse: wire.has_tool_use ?? false,
                hasToolResult: wire.has_tool_result ?? false
            )
        }
        return Conversation(messages: decoded, total: total, truncated: truncated ?? false)
    }
}

/// What happened to a follow-up: delivered now, or queued behind a turn in flight.
public struct FollowUpResult: Hashable, Sendable {
    public var queued: Bool
    public var message: String

    public init(queued: Bool, message: String) {
        self.queued = queued
        self.message = message
    }
}

struct FollowUpResponse: Decodable {
    struct Enqueued: Decodable { let position: Int? }
    let message: String?
    let enqueued_message: Enqueued?
}

struct ArchiveResponse: Decodable {
    let session: SessionSummary
}

struct QuickRouterResponse: Decodable {
    let session_id: Int
}
