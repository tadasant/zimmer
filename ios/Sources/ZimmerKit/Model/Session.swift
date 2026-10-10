import Foundation

/// A session's lifecycle state, as `Session#status` reports it.
///
/// `unknown` keeps an older app working against a newer server: TestFlight ships minutes
/// after a merge, so a status added to the server later must decode rather than fail the
/// whole list.
public enum SessionStatus: Hashable, Sendable, Codable, CaseIterable {
    case waiting
    case running
    case needsInput
    case failed
    case archived
    case unknown(String)

    public static let allCases: [SessionStatus] = [.waiting, .running, .needsInput, .failed, .archived]

    public init(rawValue: String) {
        switch rawValue {
        case "waiting": self = .waiting
        case "running": self = .running
        case "needs_input": self = .needsInput
        case "failed": self = .failed
        case "archived": self = .archived
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .waiting: return "waiting"
        case .running: return "running"
        case .needsInput: return "needs_input"
        case .failed: return "failed"
        case .archived: return "archived"
        case let .unknown(raw): return raw
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The words on screen and in speech.
    public var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .running: return "Running"
        case .needsInput: return "Needs input"
        case .failed: return "Failed"
        case .archived: return "Archived"
        case let .unknown(raw): return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Lower sorts first. Needs input above all: it is the only status that is waiting on
    /// the person holding the phone.
    public var urgency: Int {
        switch self {
        case .needsInput: return 0
        case .failed: return 1
        case .running: return 2
        case .waiting: return 3
        case .unknown: return 4
        case .archived: return 5
        }
    }
}

/// One row of `GET /api/v1/sessions`. Only the fields the app reads; every one beyond `id`
/// and `status` is optional, so a field the server drops later degrades a row, not the list.
public struct SessionSummary: Hashable, Sendable, Codable, Identifiable {
    public let id: Int
    public var slug: String?
    public var title: String?
    public var status: SessionStatus
    public var agentRuntime: String?
    public var prompt: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, slug, title, status, prompt
        case agentRuntime = "agent_runtime"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
    }

    public init(
        id: Int, slug: String? = nil, title: String? = nil, status: SessionStatus,
        agentRuntime: String? = nil, prompt: String? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil, archivedAt: Date? = nil
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.status = status
        self.agentRuntime = agentRuntime
        self.prompt = prompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    /// The title, or what Zimmer's web UI falls back to.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return "Session \(id)"
    }
}

struct SessionListResponse: Decodable {
    let sessions: [SessionSummary]
}
