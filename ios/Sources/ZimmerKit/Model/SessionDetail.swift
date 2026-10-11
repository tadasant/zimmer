import Foundation

/// Zimmer's cached "where things stand" blurb for a session (`status_summary` on
/// `GET /api/v1/sessions/:id`). Written when a session comes to rest; may be stale.
public struct StatusSummary: Hashable, Sendable, Codable {
    public var summary: String?
    public var generatedAt: Date?
    public var generating: Bool?
    /// Why the last generation failed, when it did.
    public var error: String?
    /// Messages that landed after the summary was written: the web UI's "3 messages since
    /// summary generated". Nil when there is no summary.
    public var messagesSinceGenerated: Int?

    enum CodingKeys: String, CodingKey {
        case summary, generating, error
        case generatedAt = "generated_at"
        case messagesSinceGenerated = "messages_since_generated"
    }

    public init(summary: String?, generatedAt: Date? = nil, generating: Bool? = nil, error: String? = nil, messagesSinceGenerated: Int? = nil) {
        self.summary = summary
        self.generatedAt = generatedAt
        self.generating = generating
        self.error = error
        self.messagesSinceGenerated = messagesSinceGenerated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try? container.decodeIfPresent(String.self, forKey: .summary)
        generatedAt = try? container.decodeIfPresent(Date.self, forKey: .generatedAt)
        generating = try? container.decodeIfPresent(Bool.self, forKey: .generating)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        messagesSinceGenerated = try? container.decodeIfPresent(Int.self, forKey: .messagesSinceGenerated)
    }

    /// Whether the summary still describes the session: no message since it was written.
    public var isCurrent: Bool { (messagesSinceGenerated ?? 0) == 0 }
}

/// One session, as the detail screen shows it.
public struct SessionDetail: Hashable, Sendable {
    public var session: SessionSummary
    public var statusSummary: StatusSummary?
    /// The lineage graph the session belongs to, origin first.
    public var hierarchy: SessionHierarchy?
    /// The web UI's Goal check panel: what Zimmer can read back about the goal.
    public var goalCheck: GoalCheck?
    /// The web UI's Human messages panel: what people said to this session and its family.
    public var humanMessages: [HumanMessage]

    public init(session: SessionSummary, statusSummary: StatusSummary? = nil, hierarchy: SessionHierarchy? = nil,
                goalCheck: GoalCheck? = nil, humanMessages: [HumanMessage] = []) {
        self.session = session
        self.statusSummary = statusSummary
        self.hierarchy = hierarchy
        self.goalCheck = goalCheck
        self.humanMessages = humanMessages
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
    let goalCheck: GoalCheck?
    let humanMessages: [HumanMessage]

    enum CodingKeys: String, CodingKey {
        case session
        case statusSummary = "status_summary"
        case hierarchy = "session_hierarchy"
        case humanMessages = "human_messages"
    }

    enum SessionKeys: String, CodingKey {
        case goalCheck = "goal_check"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(SessionSummary.self, forKey: .session)
        statusSummary = try? container.decodeIfPresent(StatusSummary.self, forKey: .statusSummary)
        // Drawn when they read, never a reason for the page to fail.
        hierarchy = try? container.decodeIfPresent(SessionHierarchy.self, forKey: .hierarchy)
        // The goal check rides inside the session object, as `session_json` writes it.
        let sessionContainer = try? container.nestedContainer(keyedBy: SessionKeys.self, forKey: .session)
        goalCheck = (try? sessionContainer?.decodeIfPresent(GoalCheck.self, forKey: .goalCheck)) ?? nil
        humanMessages = (try? container.decodeIfPresent([LenientHumanMessage].self, forKey: .humanMessages))?.compactMap(\.message) ?? []
    }

    var detail: SessionDetail {
        SessionDetail(session: session, statusSummary: statusSummary, hierarchy: hierarchy, goalCheck: goalCheck, humanMessages: humanMessages)
    }
}

/// `goal_check` on a session: the web UI's Goal check panel — one line per criterion the
/// goal's catalog entry declares, each met, unmet, pending or unknown, and a verdict over
/// them. Advisory: nothing acts on it. Nil when the goal is free text or has no checks.
public struct GoalCheck: Hashable, Sendable, Decodable {
    public struct Criterion: Hashable, Sendable, Decodable, Identifiable {
        public var key: String
        public var label: String
        public var status: String
        public var detail: String?

        public var id: String { key }

        public init(key: String, label: String, status: String, detail: String? = nil) {
            self.key = key
            self.label = label
            self.status = status
            self.detail = detail
        }

        enum CodingKeys: String, CodingKey { case key, label, status, detail }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? key
            status = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? "unknown"
            detail = try? container.decodeIfPresent(String.self, forKey: .detail)
        }
    }

    public var goalName: String?
    /// "met", "unmet" or "pending".
    public var verdict: String
    /// The session has not come to rest, so an unmet criterion is work in progress.
    public var provisional: Bool
    public var criteria: [Criterion]

    public init(goalName: String? = nil, verdict: String, provisional: Bool = false, criteria: [Criterion]) {
        self.goalName = goalName
        self.verdict = verdict
        self.provisional = provisional
        self.criteria = criteria
    }

    enum CodingKeys: String, CodingKey {
        case verdict, provisional, criteria
        case goalName = "goal_name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goalName = try? container.decodeIfPresent(String.self, forKey: .goalName)
        verdict = (try? container.decodeIfPresent(String.self, forKey: .verdict)) ?? "pending"
        provisional = (try? container.decodeIfPresent(Bool.self, forKey: .provisional)) ?? false
        criteria = (try? container.decodeIfPresent([Criterion].self, forKey: .criteria)) ?? []
    }

    public var metCount: Int { criteria.filter { $0.status == "met" }.count }
}

/// One entry of `human_messages` on a session: something a person said to this session or
/// to one of its family, through whichever channel, as the web UI's Human messages panel
/// lists them.
public struct HumanMessage: Hashable, Sendable, Identifiable {
    public var author: String?
    public var channelLabel: String?
    public var authoredInSessionID: Int?
    public var content: String
    public var occurredAt: Date?

    /// The same words at the same moment through two channels are two entries.
    public var id: String {
        "\(authoredInSessionID ?? 0)-\(occurredAt?.timeIntervalSince1970 ?? 0)-\(channelLabel ?? "")-\(author ?? "")-\(content.hashValue)"
    }

    public init(author: String?, channelLabel: String?, authoredInSessionID: Int?, content: String, occurredAt: Date?) {
        self.author = author
        self.channelLabel = channelLabel
        self.authoredInSessionID = authoredInSessionID
        self.content = content
        self.occurredAt = occurredAt
    }
}

/// An entry that does not read (no content) is dropped, not the whole panel.
struct LenientHumanMessage: Decodable {
    let message: HumanMessage?

    enum CodingKeys: String, CodingKey {
        case content, author
        case authorDisplayName = "author_display_name"
        case channelLabel = "channel_label"
        case authoredInSessionID = "authored_in_session_id"
        case occurredAt = "occurred_at"
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        guard let content = try? container?.decodeIfPresent(String.self, forKey: .content), !content.isEmpty else {
            message = nil
            return
        }
        let display = try? container?.decodeIfPresent(String.self, forKey: .authorDisplayName)
        let author = try? container?.decodeIfPresent(String.self, forKey: .author)
        message = HumanMessage(
            author: display ?? author,
            channelLabel: try? container?.decodeIfPresent(String.self, forKey: .channelLabel),
            authoredInSessionID: try? container?.decodeIfPresent(Int.self, forKey: .authoredInSessionID),
            content: content,
            occurredAt: (try? container?.decodeIfPresent(String.self, forKey: .occurredAt)).flatMap(ZimmerJSON.parseDate)
        )
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
    /// Where this message sits in the stored transcript: what `fork` takes to fork here. Nil
    /// for a message that did not come from a session's own conversation (a subagent's).
    public var transcriptIndex: Int?

    public init(id: Int, role: Role, content: String, timestamp: Date? = nil, hasToolUse: Bool = false, hasToolResult: Bool = false, transcriptIndex: Int? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.hasToolUse = hasToolUse
        self.hasToolResult = hasToolResult
        self.transcriptIndex = transcriptIndex
    }

    /// Tool calls and their output: shown folded, because on a phone they bury the words.
    public var isToolTraffic: Bool { hasToolUse || hasToolResult }
}

/// The conversation, newest last, and whether older messages were left out.
public struct Conversation: Hashable, Sendable {
    /// How many the page reads at a time, and by how much *Show earlier* widens the window.
    public static let pageSize = 100
    /// The most the server returns in one read (`CONVERSATION_MAX_LIMIT`).
    public static let maxLimit = 200

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
        let transcript_index: Int?
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
                hasToolResult: wire.has_tool_result ?? false,
                transcriptIndex: wire.transcript_index
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
