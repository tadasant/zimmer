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
    /// The lineage graph the session belongs to, origin first.
    public var hierarchy: SessionHierarchy?

    public init(session: SessionSummary, statusSummary: StatusSummary? = nil, hierarchy: SessionHierarchy? = nil) {
        self.session = session
        self.statusSummary = statusSummary
        self.hierarchy = hierarchy
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
    let hierarchy: SessionHierarchy?

    enum CodingKeys: String, CodingKey {
        case session
        case statusSummary = "status_summary"
        case hierarchy = "session_hierarchy"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(SessionSummary.self, forKey: .session)
        statusSummary = try container.decodeIfPresent(StatusSummary.self, forKey: .statusSummary)
        // Drawn when it reads, never a reason for the page to fail.
        hierarchy = try? container.decodeIfPresent(SessionHierarchy.self, forKey: .hierarchy)
    }
}

/// `session_hierarchy` on `GET /api/v1/sessions/:id`: the sessions that spawned this one
/// and the ones it spawned, as the web UI's hierarchy panel draws them — origin first, each
/// node at its depth, in the order to draw them.
public struct SessionHierarchy: Hashable, Sendable, Decodable {
    public struct Node: Hashable, Sendable, Decodable, Identifiable {
        public var id: Int
        public var title: String?
        public var agentRoot: String?
        public var status: SessionStatus
        public var depth: Int
        public var current: Bool
        /// Sessions that queued or interrupted this one and so count as additional seniors —
        /// the web UI's "also senior" chips, each of which can be detached.
        public var uncles: [Int]

        enum CodingKeys: String, CodingKey {
            case id, title, status, depth, current
            case agentRoot = "agent_root"
            case uncles = "uncle_session_ids"
        }

        public init(id: Int, title: String?, agentRoot: String? = nil, status: SessionStatus, depth: Int, current: Bool = false, uncles: [Int] = []) {
            self.id = id
            self.title = title
            self.agentRoot = agentRoot
            self.status = status
            self.depth = depth
            self.current = current
            self.uncles = uncles
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            agentRoot = try? container.decodeIfPresent(String.self, forKey: .agentRoot)
            status = (try? container.decode(SessionStatus.self, forKey: .status)) ?? .unknown("unknown")
            depth = (try? container.decodeIfPresent(Int.self, forKey: .depth)) ?? 0
            current = (try? container.decodeIfPresent(Bool.self, forKey: .current)) ?? false
            uncles = (try? container.decodeIfPresent([Int].self, forKey: .uncles)) ?? []
        }

        public var displayTitle: String {
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
            return "Session \(id)"
        }
    }

    public var nodes: [Node]
    public var truncated: Bool

    public init(nodes: [Node], truncated: Bool = false) {
        self.nodes = nodes
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey { case nodes, truncated }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        truncated = (try? container.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
    }

    /// Worth a panel only when the session is not alone in it.
    public var isWorthShowing: Bool { nodes.count > 1 }
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
