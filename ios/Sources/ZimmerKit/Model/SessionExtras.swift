import Foundation

/// A message waiting in a session's queue (`GET /api/v1/sessions/:id/enqueued_messages`):
/// delivered, in `position` order, when the turn in flight ends.
public struct QueuedMessage: Hashable, Sendable, Decodable, Identifiable {
    public var id: Int
    public var content: String
    public var position: Int
    /// `pending` until it is delivered.
    public var status: String?
    /// `caller` for a message someone queued; an `automated_*` origin for a notice Zimmer
    /// queued to the session itself.
    public var origin: String?
    public var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, content, position, status, origin
        case createdAt = "created_at"
    }

    public init(id: Int, content: String, position: Int, status: String? = "pending", origin: String? = "caller", createdAt: Date? = nil) {
        self.id = id
        self.content = content
        self.position = position
        self.status = status
        self.origin = origin
        self.createdAt = createdAt
    }

    public var isPending: Bool { status == nil || status == "pending" }
    /// A notice Zimmer wrote to the session, rather than something a person or agent asked for.
    public var isAutomated: Bool { origin?.hasPrefix("automated") ?? false }
}

/// One line of a session's log (`GET /api/v1/sessions/:id/logs`), newest first.
public struct LogEntry: Hashable, Sendable, Decodable, Identifiable {
    public var id: Int
    public var content: String
    /// `info`, `warn`/`warning`, `error`, `debug`.
    public var level: String?
    public var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, content, level
        case createdAt = "created_at"
    }

    public init(id: Int, content: String, level: String? = "info", createdAt: Date? = nil) {
        self.id = id
        self.content = content
        self.level = level
        self.createdAt = createdAt
    }
}

/// A page of logs, and whether there are older ones.
public struct LogPage: Hashable, Sendable {
    public var entries: [LogEntry]
    public var hasMore: Bool

    public init(entries: [LogEntry], hasMore: Bool) {
        self.entries = entries
        self.hasMore = hasMore
    }
}

/// A subagent a session ran (`GET /api/v1/sessions/:id/subagent_transcripts`).
public struct SubagentTranscriptSummary: Hashable, Sendable, Decodable, Identifiable {
    public var id: Int
    public var label: String?
    public var description: String?
    public var subagentType: String?
    public var status: String?
    public var messageCount: Int?
    public var duration: String?
    public var tokens: String?

    enum CodingKeys: String, CodingKey {
        case id, description, status
        case label = "display_label"
        case subagentType = "subagent_type"
        case messageCount = "message_count"
        case duration = "formatted_duration"
        case tokens = "formatted_tokens"
    }

    public init(id: Int, label: String?, description: String? = nil, subagentType: String? = nil, status: String? = nil,
                messageCount: Int? = nil, duration: String? = nil, tokens: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
        self.subagentType = subagentType
        self.status = status
        self.messageCount = messageCount
        self.duration = duration
        self.tokens = tokens
    }

    public var title: String {
        if let label, !label.isEmpty { return label }
        if let description, !description.isEmpty { return description }
        return subagentType ?? "Subagent \(id)"
    }
}

/// A subagent's transcript, which the server stores as Claude Code JSONL, read into the
/// words a person wants on a phone: each user and assistant turn's text, with tool calls
/// named rather than dumped. Lines that are not JSON, or not a message, are skipped.
public enum SubagentTranscriptText {
    public static func messages(fromJSONL jsonl: String) -> [ConversationMessage] {
        var messages: [ConversationMessage] = []
        for line in jsonl.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = entry["type"] as? String,
                  let role = ConversationMessage.Role(rawValue: type),
                  let message = entry["message"] as? [String: Any]
            else { continue }

            var parts: [String] = []
            var toolUse = false
            var toolResult = false
            if let text = message["content"] as? String {
                parts.append(text)
            } else if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty { parts.append(text) }
                    case "tool_use":
                        toolUse = true
                        parts.append("Using tool: \(block["name"] as? String ?? "tool")")
                    case "tool_result":
                        toolResult = true
                        // A string, or (more often) a list of text blocks.
                        if let text = block["content"] as? String, !text.isEmpty {
                            parts.append(text)
                        } else if let inner = block["content"] as? [[String: Any]] {
                            let text = inner.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                            if !text.isEmpty { parts.append(text) }
                        }
                    default:
                        break
                    }
                }
            }
            guard !parts.isEmpty else { continue }
            messages.append(ConversationMessage(
                id: messages.count, role: role, content: parts.joined(separator: "\n\n"),
                timestamp: (entry["timestamp"] as? String).flatMap(ZimmerJSON.parseDate),
                hasToolUse: toolUse, hasToolResult: toolResult
            ))
        }
        return messages
    }
}

struct QueuedMessagesResponse: Decodable {
    let enqueued_messages: [QueuedMessage]
}

struct QueuedMessageResponse: Decodable {
    let enqueued_message: QueuedMessage
}

struct LogsResponse: Decodable {
    struct Pagination: Decodable {
        let page: Int?
        let total_pages: Int?
    }
    let logs: [LogEntry]
    let pagination: Pagination?
}

struct SubagentTranscriptsResponse: Decodable {
    let subagent_transcripts: [SubagentTranscriptSummary]
}

struct SubagentTranscriptResponse: Decodable {
    struct Full: Decodable { let transcript: String? }
    let subagent_transcript: Full
}
