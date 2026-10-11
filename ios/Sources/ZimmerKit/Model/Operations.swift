import Foundation

/// One entry of the web UI's notifications inbox (`GET /api/v1/notifications`).
public struct InboxNotification: Hashable, Sendable, Decodable, Identifiable {
    public struct SessionRef: Hashable, Sendable, Decodable {
        public var id: Int
        public var title: String?
        public var status: SessionStatus?
    }

    public var id: Int
    /// What happened: `needs_input`, `completed`, `failed`, …
    public var type: String?
    public var read: Bool
    /// The session has moved on since; the notification no longer says where it stands.
    public var stale: Bool?
    public var createdAt: Date?
    public var session: SessionRef?

    enum CodingKeys: String, CodingKey {
        case id, read, stale, session
        case type = "notification_type"
        case createdAt = "created_at"
    }

    public init(id: Int, type: String?, read: Bool, stale: Bool? = false, createdAt: Date? = nil, session: SessionRef? = nil) {
        self.id = id
        self.type = type
        self.read = read
        self.stale = stale
        self.createdAt = createdAt
        self.session = session
    }

    /// The line the web UI's inbox shows for the type (`_notification_row.html.erb`).
    public var headline: String {
        switch type {
        case "needs_input": return "Needs your input"
        case "session_failed": return "Session failed"
        case "session_complete": return "Session completed"
        default: return "Status update"
        }
    }
}

/// A trigger, as the web UI's triggers list shows it (`GET /api/v1/triggers`).
public struct TriggerSummary: Hashable, Sendable, Decodable, Identifiable {
    public struct Condition: Hashable, Sendable, Decodable {
        public var type: String?
        public var description: String?

        enum CodingKeys: String, CodingKey {
            case description
            case type = "condition_type"
        }
    }

    public var id: Int
    public var name: String
    /// `enabled`, `disabled`, or `failed` (a fire that errored, waiting for a re-arm).
    public var status: String
    public var agentRoot: String?
    public var lastError: String?
    public var lastTriggeredAt: Date?
    public var lastSessionID: Int?
    public var sessionsCreated: Int?
    public var conditions: [Condition]

    enum CodingKeys: String, CodingKey {
        case id, name, status, conditions
        case agentRoot = "agent_root_name"
        case lastError = "last_error"
        case lastTriggeredAt = "last_triggered_at"
        case lastSessionID = "last_session_id"
        case sessionsCreated = "sessions_created_count"
    }

    public init(id: Int, name: String, status: String, agentRoot: String? = nil, lastError: String? = nil,
                lastTriggeredAt: Date? = nil, lastSessionID: Int? = nil, sessionsCreated: Int? = nil, conditions: [Condition] = []) {
        self.id = id
        self.name = name
        self.status = status
        self.agentRoot = agentRoot
        self.lastError = lastError
        self.lastTriggeredAt = lastTriggeredAt
        self.lastSessionID = lastSessionID
        self.sessionsCreated = sessionsCreated
        self.conditions = conditions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "Trigger \(id)"
        status = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? "unknown"
        agentRoot = try? container.decodeIfPresent(String.self, forKey: .agentRoot)
        lastError = try? container.decodeIfPresent(String.self, forKey: .lastError)
        lastTriggeredAt = try? container.decodeIfPresent(Date.self, forKey: .lastTriggeredAt)
        lastSessionID = try? container.decodeIfPresent(Int.self, forKey: .lastSessionID)
        sessionsCreated = try? container.decodeIfPresent(Int.self, forKey: .sessionsCreated)
        conditions = (try? container.decodeIfPresent([Condition].self, forKey: .conditions)) ?? []
    }

    public var isEnabled: Bool { status == "enabled" }
}

/// What invoking a trigger did, as the web UI's Invoke tells them apart.
public struct TriggerInvocation: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// It started (or re-used) a session.
        case started
        /// A burst of fires was folded into a notice session; the one asked for was not made.
        case burstNotice
        /// It found a session of its own still pending, and started nothing (409).
        case pendingSession
        /// The session it re-uses cannot take another turn (422).
        case notReusable
    }

    public var outcome: Outcome
    /// The session to open: the one started, the burst notice, or the one in the way.
    public var sessionID: Int?
    public var message: String

    public init(outcome: Outcome = .started, sessionID: Int?, message: String) {
        self.outcome = outcome
        self.sessionID = sessionID
        self.message = message
    }

    /// Whether the session that was asked for now exists.
    public var started: Bool { outcome == .started }
}

/// The web UI's Costs page, in the parts a phone shows (`GET /api/v1/costs`): the window's
/// total, spend by day, the biggest agent roots and the most expensive sessions.
public struct CostSnapshot: Hashable, Sendable, Decodable {
    public struct Day: Hashable, Sendable, Decodable, Identifiable {
        public var day: String
        public var costUSD: Double
        public var id: String { day }

        enum CodingKeys: String, CodingKey {
            case day
            case costUSD = "cost_usd"
        }
    }

    public struct Row: Hashable, Sendable, Identifiable {
        public var label: String
        public var costUSD: Double
        public var id: String { label }
    }

    public struct TopSession: Hashable, Sendable, Decodable, Identifiable {
        public var sessionID: Int
        public var costUSD: Double
        public var tokens: Int?
        public var id: Int { sessionID }

        enum CodingKeys: String, CodingKey {
            case tokens
            case sessionID = "session_id"
            case costUSD = "cost_usd"
        }
    }

    public var from: Date?
    public var to: Date?
    public var totalUSD: Double
    public var days: [Day]
    public var agentRoots: [Row]
    public var models: [Row]
    public var topSessions: [TopSession]

    public init(from: Date? = nil, to: Date? = nil, totalUSD: Double, days: [Day] = [], agentRoots: [Row] = [], models: [Row] = [], topSessions: [TopSession] = []) {
        self.from = from
        self.to = to
        self.totalUSD = totalUSD
        self.days = days
        self.agentRoots = agentRoots
        self.models = models
        self.topSessions = topSessions
    }

    enum CodingKeys: String, CodingKey {
        case window, totals
        case days = "by_day"
        case agentRoots = "by_agent_root"
        case models = "by_model"
        case topSessions = "top_sessions"
    }

    struct Window: Decodable { let from: Date?; let to: Date? }
    struct Totals: Decodable {
        let cost_usd: Double?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let window = try? container.decodeIfPresent(Window.self, forKey: .window)
        from = window?.from
        to = window?.to
        totalUSD = ((try? container.decodeIfPresent(Totals.self, forKey: .totals)) ?? nil)?.cost_usd ?? 0
        days = (try? container.decodeIfPresent([Day].self, forKey: .days)) ?? []
        agentRoots = Self.rows(container, .agentRoots, label: "agent_root")
        models = Self.rows(container, .models, label: "model")
        topSessions = (try? container.decodeIfPresent([TopSession].self, forKey: .topSessions)) ?? []
    }

    /// The by-X rows each name their label differently (`agent_root`, `model`), so they are
    /// read as loose objects.
    private static func rows(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, label: String) -> [Row] {
        guard let raw = try? container.decodeIfPresent([LooseObject].self, forKey: key) else { return [] }
        return raw.compactMap { object in
            guard let name = object.strings[label], let cost = object.numbers["cost_usd"] else { return nil }
            return Row(label: name, costUSD: cost)
        }
    }
}

/// A JSON object's string and number fields, ignoring the rest.
struct LooseObject: Decodable {
    var strings: [String: String] = [:]
    var numbers: [String: Double] = [:]

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        for key in container.allKeys {
            if let string = try? container.decode(String.self, forKey: key) {
                strings[key.stringValue] = string
            } else if let number = try? container.decode(Double.self, forKey: key) {
                numbers[key.stringValue] = number
            }
        }
    }
}

/// The web UI's Health page, read-only: the overall status, then each section's.
public struct HealthReport: Hashable, Sendable {
    public struct Section: Hashable, Sendable, Identifiable {
        public var key: String
        public var status: String
        public var message: String?
        public var id: String { key }

        public init(key: String, status: String, message: String? = nil) {
            self.key = key
            self.status = status
            self.message = message
        }

        /// `process_health` → "Process".
        public var title: String {
            key.replacingOccurrences(of: "_health", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public var overall: Section
    public var sections: [Section]
    public var generatedAt: Date?

    public init(overall: Section, sections: [Section], generatedAt: Date? = nil) {
        self.overall = overall
        self.sections = sections
        self.generatedAt = generatedAt
    }

    /// Read from `GET /api/v1/health`. Each section's `status` is either a word or an object
    /// with `status` and `message`; anything else in a section is detail the phone leaves out.
    static func parse(_ data: Data) throws -> HealthReport {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let report = root["health_report"] as? [String: Any]
        else { throw ZimmerError.decoding("/api/v1/health: no health_report") }

        func status(_ value: Any?) -> (String, String?)? {
            if let word = value as? String { return (word, nil) }
            if let object = value as? [String: Any], let word = object["status"] as? String { return (word, object["message"] as? String) }
            return nil
        }

        let overall = status(report["overall_status"]).map { Section(key: "overall", status: $0.0, message: $0.1) }
            ?? Section(key: "overall", status: "unknown")
        let sections = report.keys.sorted().compactMap { key -> Section? in
            guard key.hasSuffix("_health"), let section = report[key] as? [String: Any], let (word, message) = status(section["status"]) else { return nil }
            return Section(key: key, status: word, message: message)
        }
        let generatedAt = (report["generated_at"] as? String).flatMap(ZimmerJSON.parseDate)
        return HealthReport(overall: overall, sections: sections, generatedAt: generatedAt)
    }
}

struct NotificationsResponse: Decodable {
    let notifications: [InboxNotification]
}

struct NotificationResponse: Decodable {
    let notification: InboxNotification
}

struct BadgeResponse: Decodable {
    let pending_count: Int?
}

struct TriggersResponse: Decodable {
    let triggers: [TriggerSummary]
}

struct TriggerResponse: Decodable {
    let trigger: TriggerSummary
}

struct TriggerInvokeResponse: Decodable {
    struct SessionRef: Decodable { let id: Int }
    let session: SessionRef?
    let message: String?
    let burst_notice: Bool?
}
