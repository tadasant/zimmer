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
/// The JSON objects whose inner shape Zimmer does not promise (`config`, `metadata`,
/// `custom_metadata`, `effort`) are read through types that never throw: a key that changes
/// type on the server blanks that one field rather than the whole list.
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
    /// When a trashed session's clone and attachments are deleted for good.
    public var trashAfter: Date?
    public var goal: String?
    public var notes: String?
    public var favorited: Bool?
    /// The stored board-visibility choice: `visible`, `hidden` or `snoozed`.
    public var visibility: SessionVisibility?
    /// That choice with an expired snooze already resolved back to visible — what a board draws.
    public var effectiveVisibility: SessionVisibility?
    public var snoozedUntil: Date?
    /// `priority` or `spot`: the class the session actually runs under.
    public var priorityClass: String?
    public var heartbeatEnabled: Bool?
    public var precedence: Int?
    public var effort: EffortSummary?
    public var config: SessionConfig?
    public var metadata: SessionMetadata?
    public var customMetadata: SessionCustomMetadata?

    enum CodingKeys: String, CodingKey {
        case id, slug, title, status, prompt, goal, favorited, visibility, precedence, effort, config, metadata
        case agentRuntime = "agent_runtime"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
        case trashAfter = "trash_after"
        case notes = "session_notes"
        case effectiveVisibility = "effective_visibility"
        case snoozedUntil = "snoozed_until"
        case priorityClass = "priority_class"
        case heartbeatEnabled = "heartbeat_enabled"
        case customMetadata = "custom_metadata"
    }

    public init(
        id: Int, slug: String? = nil, title: String? = nil, status: SessionStatus,
        agentRuntime: String? = nil, prompt: String? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil, archivedAt: Date? = nil,
        goal: String? = nil, notes: String? = nil, favorited: Bool? = nil,
        visibility: SessionVisibility? = nil, snoozedUntil: Date? = nil,
        priorityClass: String? = nil, precedence: Int? = nil, effort: EffortSummary? = nil, model: String? = nil,
        agentRoot: String? = nil, lastUserActivityAt: Date? = nil, pullRequests: [PullRequestLink] = []
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
        self.goal = goal
        self.notes = notes
        self.favorited = favorited
        self.visibility = visibility
        self.effectiveVisibility = visibility
        self.snoozedUntil = snoozedUntil
        self.priorityClass = priorityClass
        self.precedence = precedence
        self.effort = effort
        self.config = model.map { SessionConfig(model: $0) }
        self.metadata = (agentRoot != nil || lastUserActivityAt != nil)
            ? SessionMetadata(agentRoot: agentRoot, lastUserActivityAt: lastUserActivityAt) : nil
        self.customMetadata = pullRequests.isEmpty ? nil : SessionCustomMetadata(pullRequests: pullRequests)
    }

    /// The title, or what Zimmer's web UI falls back to.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return "Session \(id)"
    }

    public var isFavorite: Bool { favorited ?? false }
    public var isPriority: Bool { priorityClass == "priority" }
    public var model: String? { config?.model }
    public var agentRoot: String? { metadata?.agentRoot }
    /// When a person last did something to this session — the web UI's "Last Touched" key,
    /// which falls back to when the session was created.
    public var lastTouchedAt: Date? { metadata?.lastUserActivityAt ?? createdAt }
    public var pullRequests: [PullRequestLink] { customMetadata?.pullRequests ?? [] }

    /// What the board shows for this session's visibility, with an expired snooze read as visible.
    public var boardVisibility: SessionVisibility { effectiveVisibility ?? visibility ?? .visible }

    public var hasNotes: Bool {
        !(notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Board visibility: how a person tidies their board. It never starts, stops or reorders a
/// session — that is `status`. A snoozed session comes back on its own when the time passes.
public enum SessionVisibility: String, Hashable, Sendable, Codable {
    case visible, hidden, snoozed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionVisibility(rawValue: raw) ?? .visible
    }
}

/// `effort` on a session: the level in force, whether it was chosen, and the levels the
/// session's model accepts — so the picker needs no model catalog of its own.
public struct EffortSummary: Hashable, Sendable, Codable {
    public var level: String?
    public var source: String?
    public var `default`: String?
    public var levels: [String]

    public init(level: String?, source: String? = nil, default defaultLevel: String? = nil, levels: [String] = []) {
        self.level = level
        self.source = source
        self.default = defaultLevel
        self.levels = levels
    }

    enum CodingKeys: String, CodingKey { case level, source, `default`, levels }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        level = try? container?.decodeIfPresent(String.self, forKey: .level)
        source = try? container?.decodeIfPresent(String.self, forKey: .source)
        self.default = try? container?.decodeIfPresent(String.self, forKey: .default)
        levels = (try? container?.decodeIfPresent([String].self, forKey: .levels)) ?? []
    }

    public var isExplicit: Bool { source == "explicit" }
}

/// The part of a session's free-form `config` the app reads.
public struct SessionConfig: Hashable, Sendable, Codable {
    public var model: String?

    public init(model: String?) { self.model = model }

    enum CodingKeys: String, CodingKey { case model }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        model = try? container?.decodeIfPresent(String.self, forKey: .model)
    }
}

/// The part of a session's Zimmer-owned `metadata` the app reads.
public struct SessionMetadata: Hashable, Sendable, Codable {
    public var agentRoot: String?
    public var lastUserActivityAt: Date?

    public init(agentRoot: String?, lastUserActivityAt: Date? = nil) {
        self.agentRoot = agentRoot
        self.lastUserActivityAt = lastUserActivityAt
    }

    enum CodingKeys: String, CodingKey {
        case agentRoot = "agent_root_key"
        case lastUserActivityAt = "last_user_activity_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        agentRoot = try? container?.decodeIfPresent(String.self, forKey: .agentRoot)
        // A string the server writes by hand, so a value that is not a timestamp is ignored,
        // as the web UI's `LAST_TOUCHED_ORDER` ignores it.
        lastUserActivityAt = (try? container?.decodeIfPresent(String.self, forKey: .lastUserActivityAt)).flatMap(ZimmerJSON.parseDate)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(agentRoot, forKey: .agentRoot)
        try container.encodeIfPresent(lastUserActivityAt.map { ISO8601DateFormatter().string(from: $0) }, forKey: .lastUserActivityAt)
    }
}

/// A pull request a session opened, as Zimmer's PR poller records it.
public struct PullRequestLink: Hashable, Sendable, Identifiable {
    public var url: URL
    /// `open`, `merged`, `closed`, or nil before the poller has looked.
    public var state: String?
    /// The CI rollup on an open PR, as `Github::PrStatusEvaluator` writes it: `pass`, `fail`,
    /// `pending`, `skipping` or `cancel`.
    public var ci: String?

    public var id: URL { url }

    public init(url: URL, state: String? = nil, ci: String? = nil) {
        self.url = url
        self.state = state
        self.ci = ci
    }

    /// `#1261`, read from the URL; the web UI's label for the same link.
    public var label: String {
        let parts = url.path.split(separator: "/")
        if let index = parts.firstIndex(of: "pull"), parts.indices.contains(index + 1) { return "#\(parts[index + 1])" }
        return "PR"
    }
}

/// The part of a session's `custom_metadata` the app reads: its pull requests, newest last.
public struct SessionCustomMetadata: Hashable, Sendable, Codable {
    public var pullRequests: [PullRequestLink]

    public init(pullRequests: [PullRequestLink]) { self.pullRequests = pullRequests }

    enum CodingKeys: String, CodingKey {
        case urls = "github_pull_request_urls"
        case statuses = "github_pull_request_statuses"
        case ci = "github_pull_request_ci_statuses"
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        let urls = (try? container?.decodeIfPresent([String].self, forKey: .urls)) ?? []
        let statuses = (try? container?.decodeIfPresent([String: String].self, forKey: .statuses)) ?? [:]
        let ci = (try? container?.decodeIfPresent([String: String].self, forKey: .ci)) ?? [:]
        pullRequests = urls.compactMap { raw in
            guard let url = URL(string: raw), url.scheme == "https" else { return nil }
            return PullRequestLink(url: url, state: statuses[raw], ci: ci[raw])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pullRequests.map(\.url.absoluteString), forKey: .urls)
        try container.encode(Dictionary(pullRequests.compactMap { pr in pr.state.map { (pr.url.absoluteString, $0) } }, uniquingKeysWith: { a, _ in a }), forKey: .statuses)
        try container.encode(Dictionary(pullRequests.compactMap { pr in pr.ci.map { (pr.url.absoluteString, $0) } }, uniquingKeysWith: { a, _ in a }), forKey: .ci)
    }
}

struct SessionListResponse: Decodable {
    struct Pagination: Decodable { let total_pages: Int? }
    let sessions: [SessionSummary]
    let pagination: Pagination?
}
